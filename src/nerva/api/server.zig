//! The HTTP side of `nerva api` (docs/DECISIONS.md N33): one request at a time, keyed by
//! `X-Nerva-Key`, every route one Nerva request (`api.zig`). Run several for more throughput:
//! each is a separate client of the cluster, and commits from all of them are serialized there.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.api);

const Client = @import("../client.zig").Client;
const api = @import("api.zig");

/// The largest request body: a full commit request in JSON is well under this.
const body_size_max = 4 * 1024 * 1024;

pub const Options = struct {
    listen: std.net.Address,
    /// Compared against `X-Nerva-Key`. Never empty.
    key: []const u8,
    on_listening: ?*const fn (address: std.net.Address) void = null,
};

pub fn serve(gpa: std.mem.Allocator, client: *Client, options: Options) !noreturn {
    assert(options.key.len > 0);
    var server = try options.listen.listen(.{ .reuse_address = true });
    defer server.deinit();
    log.info("listening on {}", .{server.listen_address});
    if (options.on_listening) |on_listening| on_listening(server.listen_address);

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const read_buffer = try gpa.alloc(u8, 16 * 1024);
    defer gpa.free(read_buffer);

    while (true) {
        const connection = server.accept() catch |err| {
            log.warn("accept: {}", .{err});
            continue;
        };
        defer connection.stream.close();

        var http = std.http.Server.init(connection, read_buffer);
        while (true) {
            var request = http.receiveHead() catch break;
            _ = arena_instance.reset(.retain_capacity);
            serve_request(arena_instance.allocator(), client, options, &request) catch |err| {
                log.warn("request: {}", .{err});
                break;
            };
            if (!request.head.keep_alive) break;
        }
    }
}

fn serve_request(
    arena: std.mem.Allocator,
    client: *Client,
    options: Options,
    request: *std.http.Server.Request,
) !void {
    const target = request.head.target;
    if (request.head.method == .GET and std.mem.eql(u8, target, "/healthz")) {
        return respond(request, .{ .status = 200, .body = "{\"ok\":true}" });
    }
    const method: api.Method = switch (request.head.method) {
        .GET => .get,
        .POST => .post,
        else => return respond(request, try api.error_reply(arena, 405, "method not allowed")),
    };

    var key_header: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-nerva-key")) key_header = header.value;
    }
    const body = (try request.reader()).readAllAlloc(arena, body_size_max) catch |err|
        switch (err) {
            error.StreamTooLong => return respond(
                request,
                try api.error_reply(arena, 400, "body too large"),
            ),
            else => return err,
        };
    if (key_header == null or !std.mem.eql(u8, key_header.?, options.key)) {
        return respond(request, try api.error_reply(arena, 401, "invalid key"));
    }

    const reply = api.handle(arena, client, method, target, body) catch |err| switch (err) {
        error.Evicted, error.Timeout => {
            log.err("{s}: {}", .{ target, err });
            return respond(request, try api.error_reply(arena, 503, "cluster unavailable"));
        },
        else => return err,
    };
    return respond(request, reply);
}

fn respond(request: *std.http.Server.Request, reply: api.Reply) !void {
    try request.respond(reply.body, .{
        .status = @enumFromInt(reply.status),
        .keep_alive = request.head.keep_alive,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}
