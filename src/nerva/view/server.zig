//! `nerva view`: follows the change feed and serves the ledgerd views
//! (docs/DECISIONS.md N22–N24).
//!
//!     GET /v1/views/<ledger>/journal?min_op=<n|latest>
//!     GET /v1/views/<ledger>/spend?min_op=<n|latest>
//!     GET /v1/ledgers/<ledger>/as_of?op=<n|latest>&key_hex=<hex>
//!
//! Replies are `key=value` lines: `op=<watermark>` first, then `line=<op>:<hex>` per journal line
//! (the op that wrote it) or `rollup=<path hex>:<depth>:<own>:<subtree>:<settled>:<denied>` per
//! agent, then `ok=true`.
//!
//! `as_of` reads one ledger key as it was at an op (G6, N28): `op=<n>`, then `found=false` or
//! `found=true` and `value_hex=<hex>`, then `ok=true`. It waits until the view has seen op `n`,
//! so that nothing can still commit at or before it; `latest` reads at the watermark after
//! catching up.
//!
//! One thread: between requests the process follows the feed; a request whose `min_op` is ahead
//! of the watermark follows it until reached (N23).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.view);

const Client = @import("../client.zig").Client;
const store = @import("../ledgerd/store.zig");
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

    const parsed = try target_parse(arena, target) orelse
        return respond(request, 404, "error=not found");

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
    switch (parsed.view) {
        .as_of => |key| {
            const op = switch (parsed.min_op) {
                .latest => follower.watermark,
                .op => |op| op,
            };
            if (op == 0) return respond(request, 400, "error=op must be positive");
            try writer.print("op={}\n", .{op});
            const client = follower.client;
            const value = store.get_as_of(client, arena, parsed.ledger, key, op) catch |err|
                switch (err) {
                    error.TooLarge => return respond(request, 400, "error=key too long"),
                    else => return err,
                };
            if (value) |bytes| {
                try writer.writeAll("found=true\nvalue_hex=");
                for (bytes) |byte| try writer.print("{x:0>2}", .{byte});
                try writer.writeAll("\n");
            } else {
                try writer.writeAll("found=false\n");
            }
        },
        .journal => {
            try writer.print("op={}\n", .{follower.watermark});
            for (views.journal(parsed.ledger)) |entry| {
                try writer.print("line={}:", .{entry.op});
                for (entry.line) |byte| try writer.print("{x:0>2}", .{byte});
                try writer.writeAll("\n");
            }
        },
        .spend => {
            try writer.print("op={}\n", .{follower.watermark});
            for (try views.rollup(arena, parsed.ledger)) |row| {
                try writer.writeAll("rollup=");
                for (row.path) |byte| try writer.print("{x:0>2}", .{byte});
                try writer.print(":{}:{}:{}:{}:{}\n", .{
                    row.depth,
                    row.own,
                    row.subtree,
                    row.settled_count,
                    row.denied_count,
                });
            }
        },
    }
    try writer.writeAll("ok=true");
    return respond(request, 200, body.items);
}

const Target = struct {
    ledger: u64,
    view: union(enum) {
        journal,
        spend,
        /// The key to read.
        as_of: []const u8,
    },
    /// `min_op` for views; `op` for `as_of`, which also waits for it.
    min_op: union(enum) { op: u64, latest },
};

/// `/v1/views/<ledger>/<journal|spend>[?min_op=<n|latest>]` or
/// `/v1/ledgers/<ledger>/as_of?op=<n|latest>&key_hex=<hex>`.
fn target_parse(arena: std.mem.Allocator, target: []const u8) !?Target {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..question];
    const query = if (question < target.len) target[question + 1 ..] else "";

    const views_prefix = "/v1/views/";
    const ledgers_prefix = "/v1/ledgers/";
    const as_of = std.mem.startsWith(u8, path, ledgers_prefix);
    if (!as_of and !std.mem.startsWith(u8, path, views_prefix)) return null;
    const rest = path[if (as_of) ledgers_prefix.len else views_prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const ledger = std.fmt.parseInt(u64, rest[0..slash], 10) catch return null;
    const name = rest[slash + 1 ..];

    // Parameters: `min_op` for views; `op` (required) and `key_hex` (required) for `as_of`.
    var min_op: ?@FieldType(Target, "min_op") = null;
    var key: ?[]const u8 = null;
    if (query.len > 0) {
        var parameters = std.mem.splitScalar(u8, query, '&');
        while (parameters.next()) |parameter| {
            const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse return null;
            const parameter_name = parameter[0..equals];
            const value = parameter[equals + 1 ..];
            if (std.mem.eql(u8, parameter_name, if (as_of) "op" else "min_op")) {
                min_op = if (std.mem.eql(u8, value, "latest"))
                    .latest
                else
                    .{ .op = std.fmt.parseInt(u64, value, 10) catch return null };
            } else if (as_of and std.mem.eql(u8, parameter_name, "key_hex")) {
                if (value.len % 2 != 0) return null;
                const bytes = try arena.alloc(u8, value.len / 2);
                key = std.fmt.hexToBytes(bytes, value) catch return null;
            } else return null;
        }
    }

    if (as_of) {
        if (!std.mem.eql(u8, name, "as_of")) return null;
        return .{
            .ledger = ledger,
            .view = .{ .as_of = key orelse return null },
            .min_op = min_op orelse return null,
        };
    }
    return .{
        .ledger = ledger,
        .view = if (std.mem.eql(u8, name, "journal"))
            .journal
        else if (std.mem.eql(u8, name, "spend"))
            .spend
        else
            return null,
        .min_op = min_op orelse .{ .op = 0 },
    };
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
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const journal = (try target_parse(arena, "/v1/views/7/journal")).?;
    try testing.expectEqual(@as(u64, 7), journal.ledger);
    try testing.expectEqual(.journal, std.meta.activeTag(journal.view));
    try testing.expectEqual(@as(u64, 0), journal.min_op.op);

    const spend = (try target_parse(arena, "/v1/views/1/spend?min_op=latest")).?;
    try testing.expectEqual(.spend, std.meta.activeTag(spend.view));
    try testing.expectEqual(.latest, std.meta.activeTag(spend.min_op));
    try testing.expectEqual(
        @as(u64, 42),
        (try target_parse(arena, "/v1/views/1/spend?min_op=42")).?.min_op.op,
    );

    const as_of = (try target_parse(arena, "/v1/ledgers/3/as_of?op=9&key_hex=6869")).?;
    try testing.expectEqual(@as(u64, 3), as_of.ledger);
    try testing.expectEqualStrings("hi", as_of.view.as_of);
    try testing.expectEqual(@as(u64, 9), as_of.min_op.op);
    const as_of_latest = (try target_parse(arena, "/v1/ledgers/3/as_of?key_hex=&op=latest")).?;
    try testing.expectEqualStrings("", as_of_latest.view.as_of);
    try testing.expectEqual(.latest, std.meta.activeTag(as_of_latest.min_op));

    const invalid = [_][]const u8{
        "/v1/views/x/spend",
        "/v1/views/1/other",
        "/v1/views/1/spend?min_op=abc",
        "/v1/views/1/spend?other=1",
        "/v1/views/1/spend?op=1",
        "/v1/other",
        "/v1/ledgers/1/as_of?op=1", // No key.
        "/v1/ledgers/1/as_of?key_hex=61", // No op.
        "/v1/ledgers/1/as_of?op=1&key_hex=6", // Odd hex.
        "/v1/ledgers/1/as_of?op=1&key_hex=zz",
        "/v1/ledgers/1/journal?op=1&key_hex=61",
        "/v1/ledgers/1/as_of?min_op=1&key_hex=61",
    };
    for (invalid) |target| try testing.expectEqual(null, try target_parse(arena, target));
}
