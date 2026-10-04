//! `nerva view`: follows the change feed and serves the ledgerd views
//! (docs/DECISIONS.md N22–N24).
//!
//!     GET /v1/views/<ledger>/journal?min_op=<n|latest>
//!     GET /v1/views/<ledger>/spend?min_op=<n|latest>
//!
//! Replies are `key=value` lines: `op=<watermark>` first, then `line_hex=` per journal line or
//! `rollup=<path hex>:<depth>:<own>:<subtree>:<settled>:<denied>` per agent, then `ok=true`.
//! One thread: between requests the process follows the feed; a request whose `min_op` is ahead
//! of the watermark follows it until reached (N23).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.view);

const Client = @import("../client.zig").Client;
const FollowerType = @import("follower.zig").FollowerType;
const LedgerdViews = @import("ledgerd.zig").LedgerdViews;

/// How long a request may wait for its `min_op`.
const wait_max_ns = 10 * std.time.ns_per_s;
/// How long to wait for a connection before reading the feed again, when idle.
const idle_poll_ms = 50;

const Follower = FollowerType(LedgerdViews);

pub const Options = struct {
    listen: std.net.Address,
    key: []const u8,
    on_listening: ?*const fn (address: std.net.Address) void = null,
};

pub fn serve(gpa: std.mem.Allocator, client: *Client, options: Options) !noreturn {
    assert(options.key.len > 0);
    var views = LedgerdViews.init(gpa);
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
        var http = std.http.Server.init(connection, read_buffer);
        while (true) {
            var request = http.receiveHead() catch break;
            _ = arena_instance.reset(.retain_capacity);
            const allocator = arena_instance.allocator();
            serve_request(allocator, &follower, &views, options, &request) catch |err| {
                log.warn("request: {}", .{err});
                break;
            };
            if (!request.head.keep_alive) break;
        }
    }
}

fn serve_request(
    arena: std.mem.Allocator,
    follower: *Follower,
    views: *LedgerdViews,
    options: Options,
    request: *std.http.Server.Request,
) !void {
    if (request.head.method != .GET) return respond(request, 404, "error=not found");
    const target = request.head.target;
    if (std.mem.eql(u8, target, "/healthz")) return respond(request, 200, "ok=true");

    var key_header: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-ledger-key")) key_header = header.value;
    }
    if (key_header == null or !std.mem.eql(u8, key_header.?, options.key)) {
        return respond(request, 401, "error=invalid ledger key");
    }

    const parsed = target_parse(target) orelse return respond(request, 404, "error=not found");

    // Wait for the position the reader asked for (N23).
    switch (parsed.min_op) {
        .latest => try follower.catch_up(),
        .op => |min_op| {
            var timer = try std.time.Timer.start();
            while (follower.watermark < min_op) {
                if (timer.read() > wait_max_ns) {
                    return respond(request, 504, "error=view did not reach min_op");
                }
                _ = try follower.poll();
            }
        },
    }

    var body = std.ArrayList(u8).init(arena);
    const writer = body.writer();
    try writer.print("op={}\n", .{follower.watermark});
    switch (parsed.view) {
        .journal => for (views.journal(parsed.ledger)) |line| {
            try writer.writeAll("line_hex=");
            for (line) |byte| try writer.print("{x:0>2}", .{byte});
            try writer.writeAll("\n");
        },
        .spend => for (try views.rollup(arena, parsed.ledger)) |row| {
            try writer.writeAll("rollup=");
            for (row.path) |byte| try writer.print("{x:0>2}", .{byte});
            try writer.print(":{}:{}:{}:{}:{}\n", .{
                row.depth,
                row.own,
                row.subtree,
                row.settled_count,
                row.denied_count,
            });
        },
    }
    try writer.writeAll("ok=true");
    return respond(request, 200, body.items);
}

const Target = struct {
    ledger: u64,
    view: enum { journal, spend },
    min_op: union(enum) { op: u64, latest },
};

/// `/v1/views/<ledger>/<journal|spend>[?min_op=<n|latest>]`.
fn target_parse(target: []const u8) ?Target {
    const prefix = "/v1/views/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const question = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[prefix.len..question];
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const ledger = std.fmt.parseInt(u64, path[0..slash], 10) catch return null;
    const view_name = path[slash + 1 ..];
    const view: @FieldType(Target, "view") = if (std.mem.eql(u8, view_name, "journal"))
        .journal
    else if (std.mem.eql(u8, view_name, "spend"))
        .spend
    else
        return null;

    var min_op: @FieldType(Target, "min_op") = .{ .op = 0 };
    if (question < target.len) {
        var parameters = std.mem.splitScalar(u8, target[question + 1 ..], '&');
        while (parameters.next()) |parameter| {
            const value = if (std.mem.startsWith(u8, parameter, "min_op="))
                parameter["min_op=".len..]
            else
                return null;
            min_op = if (std.mem.eql(u8, value, "latest"))
                .latest
            else
                .{ .op = std.fmt.parseInt(u64, value, 10) catch return null };
        }
    }
    return .{ .ledger = ledger, .view = view, .min_op = min_op };
}

fn respond(request: *std.http.Server.Request, status: u16, body: []const u8) !void {
    try request.respond(body, .{
        .status = @enumFromInt(status),
        .keep_alive = request.head.keep_alive,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        },
    });
}

test target_parse {
    const testing = std.testing;
    const journal = target_parse("/v1/views/7/journal").?;
    try testing.expectEqual(@as(u64, 7), journal.ledger);
    try testing.expectEqual(.journal, journal.view);
    try testing.expectEqual(@as(u64, 0), journal.min_op.op);

    const spend = target_parse("/v1/views/1/spend?min_op=latest").?;
    try testing.expectEqual(.spend, spend.view);
    try testing.expectEqual(.latest, std.meta.activeTag(spend.min_op));
    try testing.expectEqual(@as(u64, 42), target_parse("/v1/views/1/spend?min_op=42").?.min_op.op);

    try testing.expect(target_parse("/v1/views/x/spend") == null);
    try testing.expect(target_parse("/v1/views/1/other") == null);
    try testing.expect(target_parse("/v1/views/1/spend?min_op=abc") == null);
    try testing.expect(target_parse("/v1/views/1/spend?other=1") == null);
    try testing.expect(target_parse("/v1/other") == null);
}
