//! The runtime's `Store` ability over HTTP (docs/DECISIONS.md N29): agent state in Nerva instead
//! of files in a state directory.
//!
//!     POST /v1/store/get   name_hex=<hex>                  → found=true value_hex=<hex>
//!                                                          | found=false
//!     POST /v1/store/put   name_hex=<hex> value_hex=<hex>
//!
//! The runtime's ability is `get : Text -> Optional Bytes` and `put : Text -> Bytes -> ()`, which
//! its production handler keeps as files (`<id>.cont`, `<id>.code`, `<id>.receipt`, …). These two
//! routes are that handler's contract with the files replaced by rows: a put replaces the value,
//! an empty value is a value, and nothing is ever deleted. Replies follow the ledger protocol:
//! `key=value` lines ending `ok=true`; `400` for a missing or malformed field or a name or value
//! over the limits.
//!
//! Not part of `ledgerd.py`: there is no oracle, so `tests/ledgerd/store.py` checks the routes
//! against a model instead.

const std = @import("std");

const store_module = @import("store.zig");
const routes = @import("routes.zig");

const Fields = routes.Fields;
const Reply = routes.Reply;

pub const prefix = "/v1/store/";

/// Runs one store route against `store` (a `table_store` transaction, or any store with `get`
/// and `put`). Returns null for an unknown route.
pub fn handle(
    arena: std.mem.Allocator,
    store: anytype,
    route: []const u8,
    fields: *const Fields,
) !?Reply {
    const Route = enum { get, put };
    const kind: Route = if (std.mem.eql(u8, route, prefix ++ "get"))
        .get
    else if (std.mem.eql(u8, route, prefix ++ "put"))
        .put
    else
        return null;

    const name = hex_field(arena, fields, "name_hex", store_module.key_size_max) catch |err|
        return try bad(arena, err, "name_hex");
    switch (kind) {
        .get => {
            const value = try store.get(name) orelse return .{
                .status = 200,
                .body = "found=false\nok=true",
            };
            var body = std.ArrayList(u8).init(arena);
            try body.appendSlice("found=true\nvalue_hex=");
            for (value) |byte| try body.writer().print("{x:0>2}", .{byte});
            try body.appendSlice("\nok=true");
            return .{ .status = 200, .body = body.items };
        },
        .put => {
            const value_size_max = store_module.value_size_max;
            const value = hex_field(arena, fields, "value_hex", value_size_max) catch |err|
                return try bad(arena, err, "value_hex");
            try store.put(name, value);
            return .{ .status = 200, .body = "ok=true" };
        },
    }
}

const FieldError = error{ OutOfMemory, Missing, InvalidHex, TooLarge };

fn hex_field(
    arena: std.mem.Allocator,
    fields: *const Fields,
    name: []const u8,
    size_max: usize,
) FieldError![]const u8 {
    const text = fields.get(name) orelse return error.Missing;
    if (text.len % 2 != 0) return error.InvalidHex;
    if (text.len / 2 > size_max) return error.TooLarge;
    const bytes = try arena.alloc(u8, text.len / 2);
    return std.fmt.hexToBytes(bytes, text) catch error.InvalidHex;
}

fn bad(arena: std.mem.Allocator, err: FieldError, name: []const u8) !Reply {
    const reason = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Missing, error.InvalidHex => name,
        error.TooLarge => try std.fmt.allocPrint(arena, "{s} too large", .{name}),
    };
    return .{
        .status = 400,
        .body = try std.fmt.allocPrint(arena, "error=bad request: {s}", .{reason}),
    };
}

const testing = std.testing;

test "store routes: put, get, replace, empty values, bad requests" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var memory: routes.MemoryStore = .{ .allocator = arena };
    const call = struct {
        fn call(
            arena_: std.mem.Allocator,
            store: *routes.MemoryStore,
            route: []const u8,
            body: []const u8,
        ) !Reply {
            const fields = try routes.fields_parse(arena_, body);
            return (try handle(arena_, store, route, &fields)).?;
        }
    }.call;

    const missing = try call(arena, &memory, "/v1/store/get", "name_hex=612e636f6e74");
    try testing.expectEqualStrings("found=false\nok=true", missing.body);

    _ = try call(arena, &memory, "/v1/store/put", "name_hex=612e636f6e74\nvalue_hex=0001ff");
    const found = try call(arena, &memory, "/v1/store/get", "name_hex=612e636f6e74");
    try testing.expectEqualStrings("found=true\nvalue_hex=0001ff\nok=true", found.body);

    // A put replaces; an empty value is a value (the runtime clears a staged receipt so).
    _ = try call(arena, &memory, "/v1/store/put", "name_hex=612e636f6e74\nvalue_hex=");
    const empty = try call(arena, &memory, "/v1/store/get", "name_hex=612e636f6e74");
    try testing.expectEqualStrings("found=true\nvalue_hex=\nok=true", empty.body);

    try testing.expectEqual(@as(u16, 400), (try call(arena, &memory, "/v1/store/get", "")).status);
    try testing.expectEqual(
        @as(u16, 400),
        (try call(arena, &memory, "/v1/store/put", "name_hex=61\nvalue_hex=0")).status,
    );
    try testing.expectEqual(
        @as(u16, 400),
        (try call(arena, &memory, "/v1/store/put", "name_hex=61")).status,
    );
    const fields = try routes.fields_parse(arena, "name_hex=61");
    try testing.expectEqual(null, try handle(arena, &memory, "/v1/store/delete", &fields));
}
