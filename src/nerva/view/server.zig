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

/// Connections whose requests are read at once (N45).
const connections_max = 16;
/// How long to wait for a connection before reading the feed again, when idle.
const idle_poll_ms = 50;

const Follower = FollowerType(DeclaredViews);

pub const Options = struct {
    listen: std.net.Address,
    /// Compared against `X-Nerva-Key`. Never empty.
    key: []const u8,
    /// Also accepted while clients move to it (`NERVA_KEY_NEXT`); never empty when set.
    key_next: ?[]const u8 = null,
    on_listening: ?*const fn (address: std.net.Address) void = null,
};

pub fn serve(gpa: std.mem.Allocator, client: *Client, options: Options) !noreturn {
    assert(options.key.len > 0);
    assert(options.key_next == null or options.key_next.?.len > 0);
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
        // Requests are read from many connections at once, and served one at a time (N45).
        const received = try receiver.next(health.idle_timeout_ms(idle_poll_ms)) orelse {
            // Idle: keep up with the feed so reads rarely wait, once the client is ready.
            if (health.ready(client)) {
                _ = follower.poll() catch |err| switch (err) {
                    error.Timeout, error.Evicted => {
                        log.err("following the feed: {}", .{err});
                        health.broke();
                    },
                    else => return err,
                };
            }
            continue;
        };
        _ = arena_instance.reset(.retain_capacity);
        const arena = arena_instance.allocator();
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
                break :reply Reply{ .status = 500, .body = "{\"error\":\"internal error\"}" };
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
        return .{ .status = 405, .body = "{\"error\":\"method not allowed\"}" };
    }
    const target = request.target;
    if (std.mem.eql(u8, target, "/healthz")) {
        if (health.state != .ready) return unavailable_healthz;
        return .{ .status = 200, .body = "{\"ok\":true}" };
    }
    if (!http_connection.keys_match(request.key, options.key, options.key_next)) {
        return .{ .status = 401, .body = "{\"error\":\"invalid key\"}" };
    }

    const declared = declared_target(target) orelse
        return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
    if (!health.ready(client)) return unavailable;
    return serve_declared(arena, follower, views, declared) catch |err| switch (err) {
        error.Timeout, error.Evicted => {
            log.err("{s}: {}", .{ target, err });
            health.broke();
            return unavailable;
        },
        else => return err,
    };
}

const unavailable: Reply = .{ .status = 503, .body = "{\"error\":\"cluster unavailable\"}" };
const unavailable_healthz: Reply = .{
    .status = 503,
    .body = "{\"ok\":false,\"error\":\"cluster unavailable\"}",
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
            return .{ .status = 400, .body = "{\"error\":\"unexpected query\"}" };
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
            return .{ .status = 400, .body = "{\"error\":\"malformed query\"}" };
        const value = parameter[equals + 1 ..];
        if (std.mem.eql(u8, parameter[0..equals], "min_op")) {
            min_op = if (std.mem.eql(u8, value, "latest")) .latest else .{
                .op = std.fmt.parseInt(u64, value, 10) catch
                    return .{ .status = 400, .body = "{\"error\":\"min_op is malformed\"}" },
            };
        } else if (std.mem.eql(u8, parameter[0..equals], "as_of")) {
            as_of = std.fmt.parseInt(u64, value, 10) catch
                return .{ .status = 400, .body = "{\"error\":\"as_of is malformed\"}" };
            if (as_of.? == 0) {
                return .{ .status = 400, .body = "{\"error\":\"as_of must be positive\"}" };
            }
        } else {
            return .{ .status = 400, .body = "{\"error\":\"unknown query parameter\"}" };
        }
    }
    if (as_of != null and std.mem.indexOf(u8, target.query, "min_op=") != null) {
        return .{ .status = 400, .body = "{\"error\":\"min_op or as_of, not both\"}" };
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
            return .{ .status = 504, .body = "{\"error\":\"the op is not committed yet\"}" };
        }
    }

    const result = declared.compute(arena, name, as_of) catch |err| switch (err) {
        error.NoSuchView => return .{ .status = 404, .body = "{\"error\":\"no such view\"}" },
        error.NoLayout, error.Invalid => return .{
            .status = 409,
            .body = "{\"error\":\"the view does not match its table's layout\"}",
        },
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
