//! The HTTP side of `nerva api` (docs/DECISIONS.md N33): one request at a time, keyed by
//! `X-Nerva-Key`, every route one Nerva request (`api.zig`). Run several for more throughput:
//! each is a separate client of the cluster, and commits from all of them are serialized there.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.api);

const Client = @import("../client.zig").Client;
const api = @import("api.zig");
const http_connection = @import("../http_connection.zig");
const CatalogStore = @import("catalog_store.zig").CatalogStore;
const MemoryBudget = @import("memory_budget.zig");

/// The largest request body: a full commit request in JSON is well under this.
const body_size_max = 4 * 1024 * 1024;
/// Between attempts to replace a client that timed out or was evicted (#27): in between, requests
/// for the cluster answer 503 at once rather than each waiting out a registration.
const reconnect_interval_ns = 5 * std.time.ns_per_s;

/// The cluster client's health (#27). A request that times out, or a session evicted, breaks the
/// client; the next request for the cluster after `reconnect_interval_ns` replaces it. `/healthz`
/// reports it, so that a gateway that cannot reach the cluster is not taken for a healthy one.
const ClientHealth = struct {
    state: enum {
        ready,
        /// Timed out or evicted: `deinit` it, then `init` a new one (`Client.reconnect`).
        broken,
        /// A replacement failed partway: the memory is uninitialized; only `init` it.
        gone,
    } = .ready,
    /// When it broke, or the last attempt to replace it failed (a `timer` reading).
    since_ns: u64 = 0,
    timer: std.time.Timer,
    allocator: std.mem.Allocator,
    options: Client.Options,

    fn broke(health: *ClientHealth) void {
        health.state = .broken;
        health.since_ns = health.timer.read();
    }

    /// Ready, or replaced now if it has been long enough since the last attempt.
    fn ready(health: *ClientHealth, client: *Client) bool {
        if (health.state == .ready) return true;
        if (health.timer.read() - health.since_ns < reconnect_interval_ns) return false;
        const result = switch (health.state) {
            .ready => unreachable,
            .broken => client.reconnect(),
            .gone => client.init(health.allocator, health.options),
        };
        result catch |err| {
            log.err("reconnecting to the cluster: {}", .{err});
            health.state = .gone;
            health.since_ns = health.timer.read();
            return false;
        };
        log.info("reconnected to the cluster", .{});
        health.state = .ready;
        return true;
    }
};

/// Connections whose requests are read at once (N45): each holds a buffer of `body_size_max`.
const connections_max = 16;

pub const Options = struct {
    listen: std.net.Address,
    /// Compared against `X-Nerva-Key`. Never empty.
    key: []const u8,
    on_listening: ?*const fn (address: std.net.Address) void = null,
};

pub fn serve(gpa: std.mem.Allocator, client: *Client, options: Options) !noreturn {
    assert(options.key.len > 0);
    var receiver = try http_connection.Receiver.init(gpa, options.listen, .{
        .connections_max = connections_max,
        .body_size_max = body_size_max,
    });
    defer receiver.deinit(gpa);
    log.info("listening on {}", .{receiver.listen_address()});
    if (options.on_listening) |on_listening| on_listening(receiver.listen_address());

    var layouts = CatalogStore.init(client);
    var health: ClientHealth = .{
        .timer = try std.time.Timer.start(),
        .allocator = client.allocator,
        .options = client.options,
    };
    // Each request's memory is bounded, and the arena gives back what one large request took
    // (#31).
    var budget = MemoryBudget.init(gpa, MemoryBudget.limit_default);
    var arena_instance = std.heap.ArenaAllocator.init(budget.allocator());
    defer arena_instance.deinit();

    while (true) {
        // Requests are read from many connections at once, and served one at a time (N45).
        const received = try receiver.next(-1) orelse continue;
        _ = arena_instance.reset(.{ .retain_with_limit = MemoryBudget.retain_max });
        budget.request_start();
        const arena = arena_instance.allocator();
        const reply = serve_request(
            arena,
            client,
            &health,
            &layouts,
            options,
            &received.request,
        ) catch |err|
            reply: {
                if (err == error.OutOfMemory and budget.exceeded) {
                    log.warn("request: past its memory budget", .{});
                    break :reply api.Reply{
                        .status = 413,
                        .body = "{\"error\":\"request too complex\"}",
                    };
                }
                log.warn("request: {}", .{err});
                break :reply api.Reply{ .status = 500, .body = "{\"error\":\"internal error\"}" };
            };
        receiver.respond(received, reply.status, reply.body);
    }
}

fn serve_request(
    arena: std.mem.Allocator,
    client: *Client,
    health: *ClientHealth,
    layouts: *CatalogStore,
    options: Options,
    request: *const http_connection.Request,
) !api.Reply {
    const target = request.target;
    if (request.method == .get and std.mem.eql(u8, target, "/healthz")) {
        if (health.state != .ready) {
            return .{ .status = 503, .body = "{\"ok\":false,\"error\":\"cluster unavailable\"}" };
        }
        return .{ .status = 200, .body = "{\"ok\":true}" };
    }
    const method: api.Method = switch (request.method) {
        .get => .get,
        .post => .post,
        .put => .put,
        .other => return api.error_reply(arena, 405, "method not allowed"),
    };
    if (!http_connection.key_matches(request.key, options.key)) {
        return api.error_reply(arena, 401, "invalid key");
    }

    if (!health.ready(client)) return api.error_reply(arena, 503, "cluster unavailable");
    return api.handle(arena, client, layouts, method, target, request.body) catch |err|
        switch (err) {
            error.Evicted, error.Timeout => {
                log.err("{s}: {}", .{ target, err });
                health.broke();
                return api.error_reply(arena, 503, "cluster unavailable");
            },
            error.OutOfMemory => return err,
            else => {
                log.err("{s}: {}", .{ target, err });
                return api.error_reply(arena, 500, "internal error");
            },
        };
}
