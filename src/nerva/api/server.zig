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
const ClientHealth = @import("../client_health.zig").ClientHealth;

/// The largest request body: a full commit request in JSON is well under this.
const body_size_max = 4 * 1024 * 1024;
/// Connections whose requests are read at once (N45): each holds a buffer of `body_size_max`.
const connections_max = 16;

pub const Options = struct {
    listen: std.net.Address,
    /// `X-Nerva-Key` must be one of these (`http_connection.key_accepted`).
    keys: http_connection.Keys,
    on_listening: ?*const fn (address: std.net.Address) void = null,
};

pub fn serve(gpa: std.mem.Allocator, client: *Client, options: Options) !noreturn {
    assert(http_connection.Keys.invalid(options.keys.current, options.keys.next) == null);
    var receiver = try http_connection.Receiver.init(gpa, options.listen, .{
        .connections_max = connections_max,
        .body_size_max = body_size_max,
    });
    defer receiver.deinit(gpa);
    log.info("listening on {}", .{receiver.listen_address()});
    if (options.on_listening) |on_listening| on_listening(receiver.listen_address());

    var layouts = CatalogStore.init(client);
    var health = try ClientHealth.init(client);
    // Each request's memory is bounded, and the arena gives back what one large request took
    // (#31).
    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    var budget = MemoryBudget.init(arena_instance.allocator(), MemoryBudget.limit_default);

    while (true) {
        // Requests are read from many connections at once, and served one at a time (N45).
        const received = try receiver.next(health.idle_timeout_ms(-1)) orelse {
            // Idle with a broken client: replace it without waiting for a request (#44).
            _ = health.ready(client);
            continue;
        };
        budget.request_start();
        const arena = budget.allocator();
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
        // `respond` has written the reply: give back what the request took at once, rather than
        // when the next request arrives (#60).
        _ = arena_instance.reset(.{ .retain_with_limit = MemoryBudget.retain_max });
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
    if (!http_connection.key_accepted(options.keys, request.key)) {
        return api.error_reply(arena, 401, "invalid key");
    }

    if (!health.ready(client)) return api.error_reply(arena, 503, "cluster unavailable");
    return api.handle(arena, client, layouts, method, target, request.body) catch |err|
        switch (err) {
            error.Evicted, error.Timeout => {
                log.err("{s}: {}", .{ target, err });
                health.broke();
                // The cluster may have changed under the new client: read layouts again (P135).
                layouts.cache_clear();
                return api.error_reply(arena, 503, "cluster unavailable");
            },
            error.OutOfMemory => return err,
            else => {
                log.err("{s}: {}", .{ target, err });
                return api.error_reply(arena, 500, "internal error");
            },
        };
}
