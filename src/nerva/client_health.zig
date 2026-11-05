//! A gateway's cluster client, and replacing it when it breaks (#27, #42, #44).
//!
//! `nerva api` and `nerva view` each hold one `Client`. A request that times out, or a session
//! evicted, breaks it; it is replaced at most every `reconnect_interval_ns`, both on the next
//! request for the cluster and while the gateway is idle, so that a gateway recovers after the
//! cluster does even when nothing sends it requests (a load balancer that routes by `/healthz`).

const std = @import("std");
const log = std.log.scoped(.client_health);

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

    pub fn init(client: *const Client) !ClientHealth {
        return .{
            .timer = try std.time.Timer.start(),
            .allocator = client.allocator,
            .options = client.options,
        };
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
            .gone => client.init(health.allocator, health.options),
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
