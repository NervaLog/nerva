//! `nerva ledgerd`: serves the Botpike runtime's ledger protocol from a Nerva cluster.
//!
//! One request at a time (docs/DECISIONS.md N10): accept a connection, read requests until it
//! closes, run each route as one Nerva transaction (N11), and answer exactly as `ledgerd.py`
//! does: `401` for a wrong `X-Ledger-Key`, `404` for an unknown route, `400` for a bad request,
//! `GET /healthz` for liveness.
//!
//! `/v1/store/*` (not in `ledgerd.py`) serves the runtime's `Store` ability from `table_store`,
//! in the same transaction-and-retry loop (N29).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.ledgerd);

const Client = @import("../client.zig").Client;
const routes = @import("routes.zig");
const store_routes = @import("store_routes.zig");
const store_module = @import("store.zig");
const Store = store_module.Store;

/// A route that keeps conflicting is answered 503 after this many attempts (N20).
const attempts_max = 32;
/// The longest pause between attempts, in milliseconds.
const backoff_max_ms = 64;
/// The largest request body accepted: the largest value plus room for the other fields.
const body_size_max = 256 * 1024;

pub const Options = struct {
    listen: std.net.Address,
    /// Compared against `X-Ledger-Key`. Never empty.
    key: []const u8,
    ledger: u64,
    /// Called once the socket is listening, with the bound address (for `--listen=…:0`).
    on_listening: ?*const fn (address: std.net.Address) void = null,
};

pub fn serve(gpa: std.mem.Allocator, client: *Client, options: Options) !noreturn {
    assert(options.key.len > 0);
    var server = try options.listen.listen(.{ .reuse_address = true });
    defer server.deinit();
    log.info("ledger {}: listening on {}", .{ options.ledger, server.listen_address });
    if (options.on_listening) |on_listening| on_listening(server.listen_address);

    var stores: Stores = .{
        .ledger = .{ .client = client, .ledger = options.ledger },
        .state = .{ .client = client, .ledger = options.ledger, .table = store_module.table_store },
    };
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
            var request = http.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => break,
                else => {
                    log.debug("receive: {}", .{err});
                    break;
                },
            };
            _ = arena_instance.reset(.retain_capacity);
            serve_request(arena_instance.allocator(), &stores, options, &request) catch |err| {
                log.warn("request: {}", .{err});
                break;
            };
            if (!request.head.keep_alive) break;
        }
    }
}

const Stores = struct {
    /// The ledger: the routes of `ledgerd.py`.
    ledger: Store,
    /// Agent state: `/v1/store/*`.
    state: Store,
};

fn serve_request(
    arena: std.mem.Allocator,
    stores: *Stores,
    options: Options,
    request: *std.http.Server.Request,
) !void {
    const target = request.head.target;
    switch (request.head.method) {
        .GET => {
            if (std.mem.eql(u8, target, "/healthz")) return respond(request, 200, "ok=true");
            return respond(request, 404, "error=not found");
        },
        .POST => {},
        else => return respond(request, 501, "error=unsupported method"),
    }

    var key_header: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-ledger-key")) key_header = header.value;
    }
    const body = try (try request.reader()).readAllAlloc(arena, body_size_max);
    if (key_header == null or !std.mem.eql(u8, key_header.?, options.key)) {
        return respond(request, 401, "error=invalid ledger key");
    }

    const fields = try routes.fields_parse(arena, body);
    const state = std.mem.startsWith(u8, target, store_routes.prefix);
    const store = if (state) &stores.state else &stores.ledger;
    for (0..attempts_max) |attempt| {
        try store.begin(arena);
        const handled = if (state)
            store_routes.handle(arena, store, target, &fields)
        else
            routes.handle(arena, store, target, &fields);
        const reply = handled catch |err| {
            log.err("{s}: {}", .{ target, err });
            return switch (err) {
                error.Evicted, error.Timeout => respond(request, 503, "error=ledger unavailable"),
                else => respond(request, 500, "error=internal error"),
            };
        } orelse return respond(request, 404, "error=unknown route");

        const outcome = store.commit() catch |err| {
            log.err("{s}: commit: {}", .{ target, err });
            return respond(request, 503, "error=ledger unavailable");
        };
        switch (outcome) {
            .committed => return respond(request, reply.status, reply.body),
            .conflict => {
                // Info, not debug: contention between gateways is worth seeing.
                log.info("{s}: conflict, retrying (attempt {})", .{ target, attempt + 1 });
                // Randomized exponential backoff, so two gateways stop colliding in step.
                const exponent: u6 = @intCast(@min(attempt, 6));
                const ceiling: u64 = @min(backoff_max_ms, @as(u64, 1) << exponent);
                std.Thread.sleep(std.crypto.random.intRangeAtMost(u64, 1, ceiling) *
                    std.time.ns_per_ms);
            },
        }
    }
    return respond(request, 503, "error=ledger busy");
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
