//! `nerva view`: follows the change feed and serves declared views (docs/DECISIONS.md N22,
//! N23, N35), as JSON:
//!
//!     GET /v1/views                                → {"views": [name, …]}
//!     GET /v1/views/<name>?min_op=<n|latest>       → {"view", "op", "hash", "groups"}
//!     GET /v1/views/<name>?as_of=<op>              → the same, as of that op
//!
//! One thread: between requests the process follows the feed; a request whose `min_op` (or
//! `as_of`) is ahead of the watermark follows it until reached, or answers 504 after 10 s (N23).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.view);

const Client = @import("../client.zig").Client;
const http_connection = @import("../http_connection.zig");
const FollowerType = @import("follower.zig").FollowerType;
const DeclaredViews = @import("declared.zig").DeclaredViews;

/// How long a request may wait for its `min_op`.
const wait_max_ns = 10 * std.time.ns_per_s;
/// How long to wait for a connection before reading the feed again, when idle.
const idle_poll_ms = 50;

const Follower = FollowerType(DeclaredViews);

pub const Options = struct {
    listen: std.net.Address,
    key: []const u8,
    on_listening: ?*const fn (address: std.net.Address) void = null,
};

pub fn serve(gpa: std.mem.Allocator, client: *Client, options: Options) !noreturn {
    assert(options.key.len > 0);
    var views = DeclaredViews.init(gpa);
    defer views.deinit();
    var follower = try Follower.init(gpa, client, &views);
    defer follower.deinit(gpa);

    // Rebuild from the start of the feed before serving (N22).
    try follower.catch_up();
    log.info("caught up through op {}", .{follower.watermark});

    var server = try options.listen.listen(.{ .reuse_address = true });
    defer server.deinit();
    log.info("listening on {}", .{server.listen_address});
    if (options.on_listening) |on_listening| on_listening(server.listen_address);

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const read_buffer = try gpa.alloc(u8, 16 * 1024);
    defer gpa.free(read_buffer);

    while (true) {
        var fds = [_]std.posix.pollfd{.{
            .fd = server.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, idle_poll_ms);
        if (ready == 0) {
            // Idle: keep up with the feed so reads rarely wait.
            _ = try follower.poll();
            continue;
        }

        const connection = server.accept() catch |err| {
            log.warn("accept: {}", .{err});
            continue;
        };
        defer connection.stream.close();
        // One request per connection, sent within a deadline, answered without delay (N37).
        http_connection.prepare(connection.stream);
        var http = std.http.Server.init(connection, read_buffer);
        var request = http.receiveHead() catch continue;
        _ = arena_instance.reset(.retain_capacity);
        const allocator = arena_instance.allocator();
        serve_request(allocator, &follower, &views, options, &request) catch |err| {
            log.warn("request: {}", .{err});
        };
    }
}

fn serve_request(
    arena: std.mem.Allocator,
    follower: *Follower,
    views: *DeclaredViews,
    options: Options,
    request: *std.http.Server.Request,
) !void {
    if (request.head.method != .GET) {
        return respond_json(request, 405, "{\"error\":\"method not allowed\"}");
    }
    const target = request.head.target;
    if (std.mem.eql(u8, target, "/healthz")) return respond_json(request, 200, "{\"ok\":true}");

    var key_header: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-nerva-key")) key_header = header.value;
    }
    if (key_header == null or !std.mem.eql(u8, key_header.?, options.key)) {
        return respond_json(request, 401, "{\"error\":\"invalid key\"}");
    }

    const declared = declared_target(target) orelse
        return respond_json(request, 404, "{\"error\":\"not found\"}");
    return serve_declared(arena, follower, views, declared, request);
}

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
    request: *std.http.Server.Request,
) !void {
    var out = std.ArrayList(u8).init(arena);
    const writer = out.writer();
    const name = target.name orelse {
        if (target.query.len > 0) {
            return respond_json(request, 400, "{\"error\":\"unexpected query\"}");
        }
        try follower.catch_up();
        try writer.writeAll("{\"views\":[");
        for (try declared.view_names(arena), 0..) |view_name, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{view_name});
        }
        try writer.writeAll("]}");
        return respond_json(request, 200, out.items);
    };

    // `min_op=<n|latest>` (default latest), or `as_of=<n>`: never both.
    var min_op: union(enum) { op: u64, latest } = .latest;
    var as_of: ?u64 = null;
    var parameters = std.mem.splitScalar(u8, target.query, '&');
    while (parameters.next()) |parameter| {
        if (parameter.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse
            return respond_json(request, 400, "{\"error\":\"malformed query\"}");
        const value = parameter[equals + 1 ..];
        if (std.mem.eql(u8, parameter[0..equals], "min_op")) {
            min_op = if (std.mem.eql(u8, value, "latest")) .latest else .{
                .op = std.fmt.parseInt(u64, value, 10) catch
                    return respond_json(request, 400, "{\"error\":\"min_op is malformed\"}"),
            };
        } else if (std.mem.eql(u8, parameter[0..equals], "as_of")) {
            as_of = std.fmt.parseInt(u64, value, 10) catch
                return respond_json(request, 400, "{\"error\":\"as_of is malformed\"}");
            if (as_of.? == 0) {
                return respond_json(request, 400, "{\"error\":\"as_of must be positive\"}");
            }
        } else {
            return respond_json(request, 400, "{\"error\":\"unknown query parameter\"}");
        }
    }
    if (as_of != null and std.mem.indexOf(u8, target.query, "min_op=") != null) {
        return respond_json(request, 400, "{\"error\":\"min_op or as_of, not both\"}");
    }

    // An answer as of op n waits until the view has seen n, so that nothing can still commit at
    // or before it.
    const wait_op: ?u64 = if (as_of) |op| op else switch (min_op) {
        .op => |op| op,
        .latest => null,
    };
    if (wait_op) |op| {
        var timer = try std.time.Timer.start();
        while (follower.watermark < op) {
            if (timer.read() > wait_max_ns) {
                return respond_json(request, 504, "{\"error\":\"view did not reach the op\"}");
            }
            _ = try follower.poll();
        }
    } else {
        try follower.catch_up();
    }

    const result = declared.compute(arena, name, as_of) catch |err| switch (err) {
        error.NoSuchView => return respond_json(request, 404, "{\"error\":\"no such view\"}"),
        error.NoLayout, error.Invalid => return respond_json(
            request,
            409,
            "{\"error\":\"the view does not match its table's layout\"}",
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
    return respond_json(request, 200, out.items);
}

fn respond_json(request: *std.http.Server.Request, status: u16, body: []const u8) !void {
    try request.respond(body, .{
        .status = @enumFromInt(status),
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
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
