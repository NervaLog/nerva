//! A gateway's cluster client, and replacing it when it breaks (#27, #42, #44).
//!
//! `nerva api` and `nerva view` each hold one `Client`. A request that times out, or a session
//! evicted, breaks it; it is replaced at most every `reconnect_interval_ns`, both on the next
//! request for the cluster and while the gateway is idle, so that a gateway recovers after the
//! cluster does even when nothing sends it requests (a load balancer that routes by `/healthz`).

const std = @import("std");
const log = std.log.scoped(.client_health);

const stdx = @import("stdx");

const nerva = @import("../nerva.zig");
const catalog = @import("catalog.zig");
const Client = @import("client.zig").Client;

/// Between attempts to replace a broken client: in between, requests for the cluster answer 503
/// at once rather than each waiting out a registration.
pub const reconnect_interval_ns = 5 * std.time.ns_per_s;
/// An idle gateway with no cluster reply for this long sends one read, so that a cluster that
/// went away breaks the session within this plus the request timeout (P168d).
pub const health_probe_interval_ns = reconnect_interval_ns;
/// How often an idle gateway with a broken client wakes to try replacing it.
pub const idle_poll_ms = 1000;

/// Milliseconds until a probe is due after `quiet_ns` without a cluster reply: at least 1, so
/// that a late wake does not spin.
fn probe_wait_ms(quiet_ns: u64) i32 {
    const due_ns = health_probe_interval_ns -| quiet_ns;
    return @intCast(@max(1, (due_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms));
}

pub const ClientHealth = struct {
    state: enum {
        ready,
        /// Timed out or evicted: `deinit` it, then `init` a new one (`Client.reconnect`).
        broken,
        /// A replacement failed partway: the memory is uninitialized; only `init` it.
        gone,
    } = .ready,
    /// When it broke, or the last attempt to replace it failed (a `timer` reading).
    since_ns: u64 = 0,
    /// When the cluster last replied (a `timer` reading): a request, a probe, a new session.
    replied_ns: u64 = 0,
    /// Attempts to replace the client, by outcome, since the start (`ready`).
    reconnects_ok: u64 = 0,
    reconnects_failed: u64 = 0,
    timer: std.time.Timer,
    allocator: std.mem.Allocator,
    options: Client.Options,
    /// The open request window (`window_open`), for a client replaced meanwhile.
    window_end: ?stdx.Instant = null,

    pub fn init(client: *const Client) !ClientHealth {
        return .{
            .timer = try std.time.Timer.start(),
            .allocator = client.allocator,
            .options = client.options,
        };
    }

    /// A request arrived: one deadline, `--request-timeout` from now, for everything it does
    /// (a reconnection, then its cluster calls), until `window_close` (#186).
    pub fn window_open(health: *ClientHealth, client: *Client) void {
        std.debug.assert(health.window_end == null);
        // A client in `gone` is uninitialized: its window is set when `ready` replaces it.
        if (health.state == .gone) {
            var time_os: stdx.TimeOS = .{};
            health.window_end = time_os.monotonic().add(health.options.timeout);
        } else {
            health.window_end = client.window_open();
        }
    }

    /// The options of a new client, with the request's window if one is open.
    fn options_in_window(health: *const ClientHealth) Client.Options {
        var options = health.options;
        options.window_end = health.window_end;
        return options;
    }

    pub fn window_close(health: *ClientHealth, client: *Client) void {
        std.debug.assert(health.window_end != null);
        health.window_end = null;
        if (health.state != .gone) client.window_close();
    }

    pub fn broke(health: *ClientHealth) void {
        std.debug.assert(health.state == .ready);
        health.state = .broken;
        health.since_ns = health.timer.read();
    }

    /// Ready, or replaced now if it has been long enough since the last attempt. Replacing it
    /// blocks until the new session registers, or the client's timeout.
    pub fn ready(health: *ClientHealth, client: *Client) bool {
        if (health.state == .ready) return true;
        if (health.timer.read() - health.since_ns < reconnect_interval_ns) return false;
        const result = switch (health.state) {
            .ready => unreachable,
            .broken => client.reconnect(),
            .gone => client.init(health.allocator, health.options_in_window()),
        };
        result catch |err| {
            log.err("reconnecting to the cluster: {}", .{err});
            health.reconnects_failed += 1;
            health.state = .gone;
            health.since_ns = health.timer.read();
            return false;
        };
        log.info("reconnected to the cluster", .{});
        health.reconnects_ok += 1;
        health.state = .ready;
        health.replied();
        return true;
    }

    /// The cluster has just replied.
    pub fn replied(health: *ClientHealth) void {
        health.replied_ns = health.timer.read();
    }

    /// Idle and ready: sends one read if the cluster has not replied for
    /// `health_probe_interval_ns`. A probe that times out or is evicted breaks the session as a
    /// request would; returns false then.
    pub fn probe(health: *ClientHealth, client: *Client) bool {
        if (health.state != .ready) return true;
        if (health.timer.read() - health.replied_ns < health_probe_interval_ns) return true;
        const keys = [1]nerva.RowKey{.{ .id = 0, .table = catalog.table_catalog }};
        var values: [1]nerva.RowValue = undefined;
        client.lookup_rows(&keys, &values) catch |err| switch (err) {
            error.Expired => unreachable, // A probe runs between requests: no window is open.
            error.Timeout, error.Evicted => {
                log.err("probing the cluster: {}", .{err});
                health.broke();
                return false;
            },
            error.TooManyEvents => unreachable, // One key is not events.
        };
        health.replied();
        return true;
    }

    /// The `receiver.next` timeout for an idle gateway: wake to probe while ready, and to retry
    /// while broken.
    pub fn idle_timeout_ms(health: *ClientHealth, idle_ms: i32) i32 {
        if (health.state == .ready) {
            // Wake when the next probe is due (at least 1 ms, so a late wake does not spin).
            const due_ms = probe_wait_ms(health.timer.read() -| health.replied_ns);
            return if (idle_ms < 0) due_ms else @min(idle_ms, due_ms);
        }
        return if (idle_ms < 0) idle_poll_ms else @min(idle_ms, idle_poll_ms);
    }
};

test "an idle ready gateway wakes when its next probe is due" {
    var health: ClientHealth = .{
        .timer = try std.time.Timer.start(),
        .allocator = std.testing.allocator,
        .options = undefined,
    };
    // Just replied: the wake is the probe interval away, or the caller's shorter one.
    health.replied();
    const wake = health.idle_timeout_ms(-1);
    try std.testing.expect(wake > 4000 and wake <= 5000);
    try std.testing.expectEqual(@as(i32, 1000), health.idle_timeout_ms(1000));
    // Broken: poll every second to replace the client.
    health.state = .broken;
    try std.testing.expectEqual(@as(i32, idle_poll_ms), health.idle_timeout_ms(-1));
}

test "a probe is due after the interval, and never wakes sooner than 1 ms" {
    try std.testing.expectEqual(@as(i32, 5000), probe_wait_ms(0));
    try std.testing.expectEqual(@as(i32, 5000), probe_wait_ms(1)); // 4,999.999999 ms rounds up
    try std.testing.expectEqual(@as(i32, 1), probe_wait_ms(health_probe_interval_ns - 1));
    try std.testing.expectEqual(@as(i32, 1), probe_wait_ms(health_probe_interval_ns));
    try std.testing.expectEqual(@as(i32, 1), probe_wait_ms(10 * health_probe_interval_ns));
}

/// A client with only what `window_open` and `window_close` read: it is not connected.
fn client_stub(options: Client.Options) Client {
    var client: Client = undefined;
    client.state = .idle;
    client.sending = null;
    client.time_os = .{};
    client.options = options;
    return client;
}

const dead_address = [_]stdx.SocketAddress{.{ .ip = .@"127.0.0.1", .port = 1 }};

test "a window is opened and closed in a live or a broken session (#186)" {
    const options: Client.Options = .{
        .cluster = 0,
        .addresses = &dead_address,
        .timeout = stdx.Duration.ms(20_000),
    };
    var client = client_stub(options);
    var health: ClientHealth = .{
        .timer = try std.time.Timer.start(),
        .allocator = std.testing.allocator,
        .options = options,
    };
    // `broken` takes the same path as `ready`: the client is initialized and holds the window,
    // which `reconnect` carries over with the rest of its options.
    for ([_]@TypeOf(health.state){ .ready, .broken }) |state| {
        health.state = state;
        health.window_open(&client);
        try std.testing.expect(health.window_end != null);
        try std.testing.expectEqual(health.window_end.?.ns, client.options.window_end.?.ns);
        health.window_close(&client);
        try std.testing.expect(health.window_end == null);
        try std.testing.expect(client.options.window_end == null);
    }
}

test "a window opened over a client that is gone is shared by its reconnections (#186)" {
    const options: Client.Options = .{
        .cluster = 0,
        .addresses = &dead_address,
        .timeout = stdx.Duration.ms(600),
    };
    var client = client_stub(options);
    var health: ClientHealth = .{
        .state = .gone,
        .timer = try std.time.Timer.start(),
        .allocator = std.testing.allocator,
        .options = options,
    };
    var time_os: stdx.TimeOS = .{};

    health.window_open(&client);
    try std.testing.expect(health.window_end != null);
    // What `ready` hands `Client.init` (it logs a failure as an error, which a test may not).
    const in_window = health.options_in_window();
    try std.testing.expectEqual(health.window_end.?.ns, in_window.window_end.?.ns);
    const begin = time_os.monotonic();
    var replacement: Client = undefined;
    try std.testing.expectError(
        error.Timeout,
        replacement.init(std.testing.allocator, in_window),
    );
    try std.testing.expect(begin.elapsed(time_os.monotonic()).ns >= 500 * std.time.ns_per_ms);
    // A second attempt in the same window finds it spent: it gives up at once, not after a
    // timeout of its own.
    const second = time_os.monotonic();
    try std.testing.expectError(
        error.Timeout,
        replacement.init(std.testing.allocator, health.options_in_window()),
    );
    try std.testing.expect(second.elapsed(time_os.monotonic()).ns < 300 * std.time.ns_per_ms);
    // `gone` has no client to close: only the health's window.
    health.window_close(&client);
    try std.testing.expect(health.window_end == null);
    try std.testing.expect(health.options_in_window().window_end == null);
    // The next request opens a new one.
    health.window_open(&client);
    health.window_close(&client);
}
