//! `nerva view`: follows the change feed and serves declared views (docs/DECISIONS.md N22,
//! N23, N35), as JSON:
//!
//!     GET /v1/views                                → {"views": [name, …]}
//!     GET /v1/views/<name>?min_op=<n|latest>       → {"view", "op", "hash", "groups"}
//!     GET /v1/views/<name>?as_of=<op>              → the same, as of that op
//!
//! One thread: between requests the process follows the feed; a request whose `min_op` (or
//! `as_of`) is ahead of the watermark reads the feed to its end, and answers 504 if the op has
//! still not been committed (N23, N45). A request that times out, or a session evicted, breaks
//! the client: requests answer 503 and `/healthz` 503 until it is replaced (`client_health.zig`,
//! #42), and the feed is read again from where it stopped.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.view);

const Client = @import("../client.zig").Client;
const http_connection = @import("../http_connection.zig");
const FollowerType = @import("follower.zig").FollowerType;
const DeclaredViews = @import("declared.zig").DeclaredViews;
const ClientHealth = @import("../client_health.zig").ClientHealth;
const wire = @import("../wire_code.zig");

/// A fixed error reply: nothing a view server does changes the cluster (it only reads).
fn failed(comptime status: u16, comptime code: wire.Code, comptime reason: []const u8) Reply {
    return .{ .status = status, .body = wire.error_body(code, reason, .no) };
}

/// Connections whose requests are read at once (N45).
const connections_max = 16;
/// How long to wait for a connection before reading the feed again, when idle.
const idle_poll_ms = 50;

const Follower = FollowerType(DeclaredViews);

pub const Options = struct {
    listen: std.net.Address,
    /// `X-Nerva-Key` must be one of these (`http_connection.key_accepted`).
    keys: http_connection.Keys,
    on_listening: ?*const fn (address: std.net.Address) void = null,
};

pub fn serve(gpa: std.mem.Allocator, client: *Client, options: Options) !noreturn {
    assert(http_connection.Keys.invalid(options.keys.current, options.keys.next) == null);
    var views = DeclaredViews.init(gpa);
    defer views.deinit();
    var follower = try Follower.init(gpa, client, &views);
    defer follower.deinit(gpa);

    // Rebuild from the start of the feed before serving (N22).
    try follower.catch_up();
    log.info("caught up through op {}", .{follower.watermark});
    var health = try ClientHealth.init(client);

    var receiver = try http_connection.Receiver.init(gpa, options.listen, .{
        .connections_max = connections_max,
        .body_size_max = 0,
    });
    defer receiver.deinit(gpa);
    log.info("listening on {}", .{receiver.listen_address()});
    if (options.on_listening) |on_listening| on_listening(receiver.listen_address());

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();

    while (true) {
        // Before every wait, not only when idle: requests that arrive often (a load balancer
        // polling `/healthz`) must not keep a broken client from being replaced (#44).
        if (health.state != .ready) _ = health.ready(client);
        // Requests are read from many connections at once, and served one at a time (N45).
        const received = try receiver.next(health.idle_timeout_ms(idle_poll_ms)) orelse {
            // Idle: keep up with the feed so reads rarely wait, once the client is ready.
            if (health.ready(client)) {
                // Polling the feed is the probe: a reply to it is the cluster's.
                _ = follower.poll() catch |err| switch (err) {
                    error.Timeout, error.Evicted => {
                        log.err("following the feed: {}", .{err});
                        health.broke();
                    },
                    else => return err,
                };
                if (health.state == .ready) health.replied();
            }
            continue;
        };
        _ = arena_instance.reset(.retain_capacity);
        const arena = arena_instance.allocator();
        // One deadline for everything this request does (#186).
        health.window_open(client);
        defer health.window_close(client);
        const reply = serve_request(
            arena,
            client,
            &health,
            &follower,
            &views,
            options,
            &received.request,
        ) catch |err|
            reply: {
                log.warn("request: {}", .{err});
                break :reply failed(500, .B0001, "internal error");
            };
        receiver.respond(received, reply.status, reply.body);
    }
}

const Reply = struct {
    status: u16,
    /// JSON.
    body: []const u8,
};

fn serve_request(
    arena: std.mem.Allocator,
    client: *Client,
    health: *ClientHealth,
    follower: *Follower,
    views: *DeclaredViews,
    options: Options,
    request: *const http_connection.Request,
) !Reply {
    if (request.method != .get) {
        return failed(405, .E0104, "method not allowed");
    }
    const target = request.target;
    if (std.mem.eql(u8, target, "/healthz")) {
        if (health.state != .ready) return unavailable_healthz;
        return .{ .status = 200, .body = "{\"ok\":true,\"session\":\"ready\"}" };
    }
    if (!http_connection.key_accepted(options.keys, request.key)) {
        return failed(401, .E0103, "invalid key");
    }

    const declared = declared_target(target) orelse
        return failed(404, .E0104, "not found");
    if (!health.ready(client)) return unavailable;
    return serve_declared(arena, follower, views, declared) catch |err| switch (err) {
        // The window passed while the view caught up with the feed (or before a page was
        // sent): the session is intact and the cursor kept, so the next request goes on.
        error.Expired => return expired,
        error.Timeout, error.Evicted => {
            log.err("{s}: {}", .{ target, err });
            health.broke();
            return lost;
        },
        else => return err,
    };
}

/// No session: nothing was sent (NRV-E0605).
const unavailable = failed(503, .E0605, "cluster unavailable");
/// The request reached a cluster that did not answer. A read, so not applied (NRV-E0601).
const lost = failed(503, .E0601, "cluster unavailable");
/// The request's window passed before the view was up to date; a read, so not applied (NRV-E0606).
const expired = failed(503, .E0606, "request deadline passed");
const unavailable_healthz: Reply = .{
    .status = 503,
    .body = "{\"ok\":false,\"error\":\"cluster unavailable\",\"applied\":false," ++
        "\"code\":\"NRV-E0605\",\"session\":\"reconnecting\"}",
};

/// A request for a declared view, or for their list.
const DeclaredTarget = struct {
    /// Null for the list.
    name: ?[]const u8,
    query: []const u8,
};

/// `/v1/views` or `/v1/views/<name>[?…]`, where a name starts with a lowercase letter or `_`.
fn declared_target(target: []const u8) ?DeclaredTarget {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..question];
    const query = if (question < target.len) target[question + 1 ..] else "";
    if (std.mem.eql(u8, path, "/v1/views")) return .{ .name = null, .query = query };
    const prefix = "/v1/views/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const name = path[prefix.len..];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    if (!(name[0] == '_' or (name[0] >= 'a' and name[0] <= 'z'))) return null;
    return .{ .name = name, .query = query };
}

fn serve_declared(
    arena: std.mem.Allocator,
    follower: *Follower,
    declared: *const DeclaredViews,
    target: DeclaredTarget,
) !Reply {
    var out = std.ArrayList(u8).init(arena);
    const writer = out.writer();
    const name = target.name orelse {
        if (target.query.len > 0) {
            return failed(400, .E0107, "unexpected query");
        }
        try follower.catch_up();
        try writer.writeAll("{\"views\":[");
        for (try declared.view_names(arena), 0..) |view_name, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{view_name});
        }
        try writer.writeAll("]}");
        return .{ .status = 200, .body = out.items };
    };

    // `min_op=<n|latest>` (default latest), or `as_of=<n>`: never both.
    var min_op: union(enum) { op: u64, latest } = .latest;
    var as_of: ?u64 = null;
    var parameters = std.mem.splitScalar(u8, target.query, '&');
    while (parameters.next()) |parameter| {
        if (parameter.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse
            return failed(400, .E0107, "malformed query");
        const value = parameter[equals + 1 ..];
        if (std.mem.eql(u8, parameter[0..equals], "min_op")) {
            min_op = if (std.mem.eql(u8, value, "latest")) .latest else .{
                .op = std.fmt.parseInt(u64, value, 10) catch
                    return failed(400, .E0106, "min_op is malformed"),
            };
        } else if (std.mem.eql(u8, parameter[0..equals], "as_of")) {
            as_of = std.fmt.parseInt(u64, value, 10) catch
                return failed(400, .E0106, "as_of is malformed");
            if (as_of.? == 0) {
                return failed(400, .E0107, "as_of must be positive");
            }
        } else {
            return failed(400, .E0107, "unknown query parameter");
        }
    }
    if (as_of != null and std.mem.indexOf(u8, target.query, "min_op=") != null) {
        return failed(400, .E0410, "min_op or as_of, not both");
    }

    // An answer as of op n needs the view to have seen n, so that nothing can still commit at or
    // before it. Reading the feed to its end reaches past every op committed before this request
    // began, so an op still ahead after that was not committed when it arrived: answering at
    // once frees the gateway's one thread rather than waiting for it (N45).
    const wait_op: ?u64 = if (as_of) |op| op else switch (min_op) {
        .op => |op| op,
        .latest => null,
    };
    if (wait_op == null or follower.watermark < wait_op.?) try follower.catch_up();
    if (wait_op) |op| {
        if (follower.watermark < op) {
            return failed(504, .E1001, "the op is not committed yet");
        }
    }

    const result = declared.compute(arena, name, as_of) catch |err| switch (err) {
        error.NoSuchView => return failed(404, .E0402, "no such view"),
        error.NoLayout, error.Invalid => return failed(
            409,
            .E1002,
            "the view does not match its table's layout",
        ),
        error.OutOfMemory => return error.OutOfMemory,
    };
    try writer.print("{{\"view\":\"{s}\",\"op\":\"{}\",\"hash\":\"{s}\",\"groups\":", .{
        name,
        as_of orelse follower.watermark,
        std.fmt.fmtSliceHexLower(&result.hash),
    });
    try writer.writeAll(result.groups);
    try writer.writeAll("}");
    return .{ .status = 200, .body = out.items };
}

test declared_target {
    const testing = std.testing;
    try testing.expectEqual(null, declared_target("/v1/views").?.name);
    const revenue = declared_target("/v1/views/revenue?as_of=3").?;
    try testing.expectEqualStrings("revenue", revenue.name.?);
    try testing.expectEqualStrings("as_of=3", declared_target("/v1/views/revenue?as_of=3").?.query);
    try testing.expectEqual(null, declared_target("/v1/views/1abc"));
    try testing.expectEqual(null, declared_target("/v1/views/revenue/x"));
    try testing.expectEqual(null, declared_target("/v1/tables/1"));
}

test "a view read whose window passed is NRV-E0606, a read that was not applied" {
    try std.testing.expectEqual(@as(u16, 503), expired.status);
    try std.testing.expectEqualStrings(
        "{\"error\":\"request deadline passed\",\"applied\":false,\"code\":\"NRV-E0606\"}",
        expired.body,
    );
}
