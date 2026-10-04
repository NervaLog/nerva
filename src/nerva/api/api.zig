//! `nerva api`: Nerva's core operations as JSON over HTTP (docs/DECISIONS.md N33).
//!
//! A thin translation, with no application concepts: every route is one Nerva request.
//!
//!     POST /v1/lookup   {"rows": [{"table": 1, "id": "5"}, …]}
//!     POST /v1/commit   {"entries": [{"kind": "read", "table": 1, "id": "5", "op_seen": "9"},
//!                                    {"kind": "put", "table": 1, "id": "5", "value_hex": "…"},
//!                                    {"kind": "delete", "table": 1, "id": "6"}]}
//!     GET  /v1/changes?cursor=<c>&limit=<n>
//!     GET  /v1/history?table=<t>&id=<i>&op_max=<n|latest>&cursor=<c>&limit=<n>
//!     GET  /v1/row?table=<t>&id=<i>&as_of=<op>
//!     PUT  /v1/tables/<t>   {"name": "seats", "fields": [{"name": "price", "type": "u64"}, …]}
//!     GET  /v1/tables/<t>
//!     PUT  /v1/views/<name>  {"table": 5, "where": […], "group_by": […], "aggregates": […]}
//!     GET  /v1/views/<name>  (the declaration; `nerva view` serves the view itself)
//!
//! Conventions:
//! - 64-bit numbers (`id`, `op`, `op_seen`, cursors) are decimal strings: JSON numbers lose
//!   precision past 2^53 in JavaScript. `table` (32-bit) and `limit` are numbers.
//! - A value is `value_hex`: up to 80 bytes as hex, zero-padded on write, always the full 80
//!   bytes on read.
//! - A commit is one transaction: `200 {"status": "committed", "op"}`, or `409 {"status":
//!   "conflict", "index", "op"}` (the entry whose read was stale, and the row's current version),
//!   or `400 {"error", "index"}` for an invalid entry. Nothing applies unless it committed.
//! - A table may have a layout (`catalog.zig`, N34): then puts may give `fields` instead of
//!   `value_hex`, and every row or change of that table also comes back with `fields`.
//! - Tables from `catalog.tables_reserved_min` up are Nerva's own: refused here, and left out of
//!   `changes`.
//! - Errors are `{"error": "<reason>"}` with 400, 401, 404, 405, 409 or 503.

const std = @import("std");
const assert = std.debug.assert;

const nerva = @import("../../nerva.zig");
const catalog = @import("../catalog.zig");

const Change = nerva.Change;
const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
const value_size = nerva.value_size;

/// Changes per `changes` or `history` call, at most; larger limits are capped.
pub const page_limit_max = 1024;

pub const Method = enum { get, post, put };

pub const Reply = struct {
    status: u16,
    /// JSON.
    body: []const u8,
};

const Route = enum { lookup, commit, changes, history, row, tables, views };

const routes = [_]struct { path: []const u8, route: Route, method: Method }{
    .{ .path = "/v1/lookup", .route = .lookup, .method = .post },
    .{ .path = "/v1/commit", .route = .commit, .method = .post },
    .{ .path = "/v1/changes", .route = .changes, .method = .get },
    .{ .path = "/v1/history", .route = .history, .method = .get },
    .{ .path = "/v1/row", .route = .row, .method = .get },
};

const tables_prefix = "/v1/tables/";
const views_prefix = "/v1/views/";

/// What `handle` needs of the catalog (`catalog_store.zig` in the server, a map in tests):
///
///     layout(arena, table: u32) !?catalog.Layout
///     layout_put(arena, table: u32, layout: *const catalog.Layout) !LayoutPut
///     view(arena, name: []const u8) !?catalog.View
///     view_put(arena, name: []const u8, view: *const catalog.View) !ViewPut
pub const LayoutPut = enum { created, extended, unchanged, incompatible };
/// A view's declaration is immutable: declaring a different one under the same name conflicts.
pub const ViewPut = enum { created, unchanged, different };

/// Runs one request against `client` (a `Client`, or anything with its methods) and `layouts`
/// (see `LayoutPut`). Client errors other than `TooManyEvents` propagate: the server answers 503.
pub fn handle(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    method: Method,
    target: []const u8,
    body: []const u8,
) !Reply {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..question];
    const query = if (question < target.len) target[question + 1 ..] else "";

    const route: Route = if (std.mem.startsWith(u8, path, tables_prefix) or
        std.mem.startsWith(u8, path, views_prefix))
    route: {
        if (method != .get and method != .put) {
            return error_reply(arena, 405, "method not allowed");
        }
        if (query.len > 0) return error_reply(arena, 400, "unexpected query");
        break :route if (std.mem.startsWith(u8, path, tables_prefix)) .tables else .views;
    } else route: {
        const entry = for (routes) |entry| {
            if (std.mem.eql(u8, entry.path, path)) break entry;
        } else return error_reply(arena, 404, "not found");
        if (entry.method != method) return error_reply(arena, 405, "method not allowed");
        break :route entry.route;
    };
    if (method == .get and body.len > 0) return error_reply(arena, 400, "unexpected body");

    var cache: Layouts(@TypeOf(layouts)) = .{ .arena = arena, .layouts = layouts };
    return switch (route) {
        .lookup => lookup(arena, client, &cache, body),
        .commit => commit(arena, client, &cache, body),
        .changes => changes(arena, client, &cache, query),
        .history => history(arena, client, &cache, query),
        .row => row(arena, client, &cache, query),
        .tables => tables(arena, layouts, method, path[tables_prefix.len..], body),
        .views => views(arena, layouts, method, path[views_prefix.len..], body),
    } catch |err| switch (err) {
        error.BadRequest => error_reply(arena, 400, bad_request_reason),
        error.TooManyEvents => error_reply(arena, 400, "too many rows or entries for one request"),
        error.Invalid => error_reply(arena, 400, catalog.invalid_reason),
        else => |e| e,
    };
}

/// The layouts one request has read, so that each table's is read at most once per request.
fn Layouts(comptime Catalog: type) type {
    return struct {
        const Self = @This();

        arena: std.mem.Allocator,
        layouts: Catalog,
        loaded: std.AutoHashMapUnmanaged(u32, ?catalog.Layout) = .{},

        fn get(self: *Self, table: u32) !?*const catalog.Layout {
            assert(table != 0 and table < catalog.tables_reserved_min);
            const entry = try self.loaded.getOrPut(self.arena, table);
            if (!entry.found_existing) {
                entry.value_ptr.* = try self.layouts.layout(self.arena, table);
            }
            return if (entry.value_ptr.*) |*layout| layout else null;
        }
    };
}

/// The reason for the last `error.BadRequest` (set just before it is returned; one thread).
var bad_request_reason: []const u8 = "";

fn bad(reason: []const u8) error{BadRequest} {
    bad_request_reason = reason;
    return error.BadRequest;
}

// ---- Routes ----

fn lookup(arena: std.mem.Allocator, client: anytype, layouts: anytype, body: []const u8) !Reply {
    const Request = struct { rows: []const struct { table: u32, id: []const u8 } };
    const request = try json_parse(Request, arena, body);
    if (request.rows.len == 0) return bad("rows must not be empty");

    const keys = try arena.alloc(RowKey, request.rows.len);
    for (keys, request.rows) |*key, row_request| {
        try table_check(row_request.table);
        key.* = .{ .table = row_request.table, .id = try u64_parse(row_request.id, "id") };
    }
    const results = try arena.alloc(RowValue, keys.len);
    try client.lookup_rows(keys, results);

    var out = Writer.init(arena);
    try out.raw("{\"op\":");
    try out.number(results[0].op_read);
    try out.raw(",\"rows\":[");
    for (results, 0..) |*result, index| {
        assert(result.op_read == results[0].op_read);
        if (index > 0) try out.raw(",");
        try out.raw("{\"table\":");
        try out.print("{}", .{result.table});
        try out.raw(",\"id\":");
        try out.number(result.id);
        try out.print(",\"exists\":{},\"op\":", .{result.flags.exists});
        try out.number(result.op);
        try out.raw(",\"value_hex\":");
        try out.hex(&result.value);
        if (result.flags.exists) try out.fields(try layouts.get(result.table), &result.value);
        try out.raw("}");
    }
    try out.raw("]}");
    return .{ .status = 200, .body = out.items() };
}

fn commit(arena: std.mem.Allocator, client: anytype, layouts: anytype, body: []const u8) !Reply {
    const Request = struct {
        entries: []const struct {
            kind: enum { read, put, delete },
            table: u32,
            id: []const u8,
            op_seen: ?[]const u8 = null,
            value_hex: ?[]const u8 = null,
            fields: ?std.json.Value = null,
        },
    };
    const request = try json_parse(Request, arena, body);
    if (request.entries.len == 0) return bad("entries must not be empty");

    const entries = try arena.alloc(Entry, request.entries.len);
    for (entries, request.entries) |*entry, entry_request| {
        try table_check(entry_request.table);
        if (entry_request.kind != .put and entry_request.fields != null) {
            return bad("only a put has fields");
        }
        entry.* = .{
            .id = try u64_parse(entry_request.id, "id"),
            .table = entry_request.table,
            .kind = switch (entry_request.kind) {
                .read => .read,
                .put => .put,
                .delete => .delete,
            },
            .op_seen = 0,
            .value = @splat(0),
        };
        switch (entry_request.kind) {
            .read => {
                if (entry_request.value_hex != null) return bad("a read has no value_hex");
                const op_seen = entry_request.op_seen orelse
                    return bad("a read needs op_seen (\"0\" if the row was absent)");
                entry.op_seen = try u64_parse(op_seen, "op_seen");
            },
            .put => {
                if (entry_request.op_seen != null) return bad("a put has no op_seen");
                if (entry_request.fields) |fields| {
                    if (entry_request.value_hex != null) {
                        return bad("a put has value_hex or fields, not both");
                    }
                    const layout = try layouts.get(entry_request.table) orelse
                        return bad("fields need a layout for the table (PUT /v1/tables/<t>)");
                    entry.value = try catalog.fields_encode(layout, fields);
                } else {
                    const value_hex = entry_request.value_hex orelse
                        return bad("a put needs value_hex or fields");
                    entry.value = try value_parse(value_hex);
                }
            },
            .delete => {
                if (entry_request.op_seen != null) return bad("a delete has no op_seen");
                if (entry_request.value_hex != null) return bad("a delete has no value_hex");
            },
        }
        assert(nerva.entry_validate(entry) == null);
    }

    const results = try arena.alloc(EntryResult, entries.len);
    try client.commit(entries, results);

    var out = Writer.init(arena);
    for (results, 0..) |result, index| {
        switch (result.status) {
            .ok, .aborted => continue,
            .conflict => {
                try out.print("{{\"status\":\"conflict\",\"index\":{},\"op\":", .{index});
                try out.number(result.op);
                try out.raw("}");
                return .{ .status = 409, .body = out.items() };
            },
            .write_duplicate => {
                try out.print(
                    "{{\"error\":\"a transaction writes a row at most once\",\"index\":{}}}",
                    .{index},
                );
                return .{ .status = 400, .body = out.items() };
            },
            // Validated above: the server would be at fault.
            else => std.debug.panic("api: commit rejected entry {}: {s}", .{
                index,
                @tagName(result.status),
            }),
        }
    }
    assert(results[0].status == .ok);
    try out.raw("{\"status\":\"committed\",\"op\":");
    try out.number(results[0].op);
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

fn changes(arena: std.mem.Allocator, client: anytype, layouts: anytype, query: []const u8) !Reply {
    const parameters = try query_parse(arena, query, &.{ "cursor", "limit" });
    const limit = try limit_parse(parameters.get("limit"));
    const cursor = if (parameters.get("cursor")) |text| try u64_parse(text, "cursor") else 0;

    const page = try arena.alloc(Change, limit + 1);
    const count = try client.get_changes(.{ .timestamp_min = cursor, .limit = limit }, page);
    if (count == 0) return bad("invalid cursor");
    return page_reply(arena, layouts, page[0..count], .ascending);
}

fn history(arena: std.mem.Allocator, client: anytype, layouts: anytype, query: []const u8) !Reply {
    const parameters = try query_parse(
        arena,
        query,
        &.{ "table", "id", "op_max", "cursor", "limit" },
    );
    const table = try table_parse(parameters.get("table"));
    const id = try u64_parse(parameters.get("id") orelse return bad("id is required"), "id");
    const op_max: u64 = if (parameters.get("op_max")) |text|
        if (std.mem.eql(u8, text, "latest")) std.math.maxInt(u64) else try u64_parse(text, "op_max")
    else
        std.math.maxInt(u64);
    if (op_max == 0) return bad("op_max must be positive");
    const limit = try limit_parse(parameters.get("limit"));
    const cursor = if (parameters.get("cursor")) |text| try u64_parse(text, "cursor") else 0;

    const page = try arena.alloc(Change, limit + 1);
    const count = try client.get_history(.{
        .table = table,
        .id = id,
        .limit = limit,
        .op_max = op_max,
        .timestamp_max = cursor,
    }, page);
    if (count == 0) return bad("invalid cursor");
    return page_reply(arena, layouts, page[0..count], .descending);
}

/// A row as of an op: its last change at or before `as_of`. `as_of` must already be committed,
/// or the answer could still change.
fn row(arena: std.mem.Allocator, client: anytype, layouts: anytype, query: []const u8) !Reply {
    const parameters = try query_parse(arena, query, &.{ "table", "id", "as_of" });
    const table = try table_parse(parameters.get("table"));
    const id = try u64_parse(parameters.get("id") orelse return bad("id is required"), "id");
    const as_of_text = parameters.get("as_of") orelse return bad("as_of is required");
    const as_of = try u64_parse(as_of_text, "as_of");
    if (as_of == 0) return bad("as_of must be positive");

    // A lookup's own op is newer than every committed op: anything at or after it may not have
    // happened yet, so its answer could still change.
    var current: [1]RowValue = undefined;
    try client.lookup_rows(&.{.{ .table = table, .id = id }}, &current);
    if (as_of >= current[0].op_read) return bad("as_of is not yet committed");

    var page: [65]Change = undefined;
    var cursor: u64 = 0;
    const found: ?Change = while (true) {
        const count = try client.get_history(.{
            .table = table,
            .id = id,
            .limit = page.len - 1,
            .op_max = as_of,
            .timestamp_max = cursor,
        }, &page);
        assert(count >= 1);
        const end = page[count - 1];
        assert(end.kind == .end);
        if (count > 1) break page[0];
        if (!end.flags.more) {
            assert(as_of < end.op);
            break null;
        }
        cursor = end.timestamp;
    };

    var out = Writer.init(arena);
    try out.print("{{\"table\":{},\"id\":", .{table});
    try out.number(id);
    try out.raw(",\"as_of\":");
    try out.number(as_of);
    if (found) |change| {
        assert(change.op <= as_of);
        try out.print(",\"exists\":{},\"op\":", .{change.kind == .put});
        try out.number(change.op);
        try out.raw(",\"value_hex\":");
        try out.hex(&change.value);
        if (change.kind == .put) try out.fields(try layouts.get(table), &change.value);
    } else {
        try out.raw(",\"exists\":false,\"op\":\"0\",\"value_hex\":");
        try out.hex(&@as([value_size]u8, @splat(0)));
    }
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

fn page_reply(
    arena: std.mem.Allocator,
    layouts: anytype,
    page: []const Change,
    direction: enum { ascending, descending },
) !Reply {
    assert(page.len >= 1);
    const end = page[page.len - 1];
    assert(end.kind == .end);

    var out = Writer.init(arena);
    try out.raw("{\"changes\":[");
    var written: u32 = 0;
    for (page[0 .. page.len - 1]) |*change| {
        assert(change.kind == .put or change.kind == .delete);
        // Nerva's own rows (the catalog) are not part of the application's feed.
        if (change.table >= catalog.tables_reserved_min) continue;
        if (written > 0) try out.raw(",");
        written += 1;
        try out.print("{{\"kind\":\"{s}\",\"table\":{},\"id\":", .{
            @tagName(change.kind),
            change.table,
        });
        try out.number(change.id);
        try out.raw(",\"op\":");
        try out.number(change.op);
        if (change.kind == .put) {
            try out.raw(",\"value_hex\":");
            try out.hex(&change.value);
            try out.fields(try layouts.get(change.table), &change.value);
        }
        try out.raw("}");
    }
    try out.print("],\"more\":{},\"cursor\":", .{end.flags.more});
    // Ascending: the next `cursor` always. Descending: the next `cursor` while there is more.
    if (direction == .descending and !end.flags.more) {
        try out.raw("null");
    } else {
        try out.number(end.timestamp);
    }
    // The op the answer is complete through, once there is no more.
    try out.raw(",\"op\":");
    if (end.flags.more) try out.raw("null") else try out.number(end.op);
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

fn tables(
    arena: std.mem.Allocator,
    layouts: anytype,
    method: Method,
    table_text: []const u8,
    body: []const u8,
) !Reply {
    const table = try table_parse(table_text);
    var out = Writer.init(arena);
    switch (method) {
        .get => {
            const layout = try layouts.layout(arena, table) orelse
                return error_reply(arena, 404, "no layout for this table");
            try out.raw(try catalog.layout_render(arena, &layout));
            return .{ .status = 200, .body = out.items() };
        },
        .put => {
            const layout = try catalog.layout_parse(arena, body);
            switch (try layouts.layout_put(arena, table, &layout)) {
                .incompatible => return error_reply(
                    arena,
                    409,
                    "a layout may only be extended by appending fields",
                ),
                inline else => |outcome| {
                    try out.print("{{\"table\":{},\"layout\":\"{s}\"}}", .{
                        table,
                        @tagName(outcome),
                    });
                    return .{ .status = 200, .body = out.items() };
                },
            }
        },
        .post => unreachable,
    }
}

fn views(
    arena: std.mem.Allocator,
    layouts: anytype,
    method: Method,
    name: []const u8,
    body: []const u8,
) !Reply {
    try catalog.view_name_validate(name);
    var out = Writer.init(arena);
    switch (method) {
        .get => {
            const view = try layouts.view(arena, name) orelse
                return error_reply(arena, 404, "no such view");
            try out.raw(try catalog.view_render(arena, &view));
            return .{ .status = 200, .body = out.items() };
        },
        .put => {
            const view = try catalog.view_parse(arena, body);
            try table_check(view.table);
            const layout = try layouts.layout(arena, view.table) orelse
                return bad("a view needs a layout for its table (PUT /v1/tables/<t>)");
            try catalog.view_check(&view, &layout);
            switch (try layouts.view_put(arena, name, &view)) {
                .different => return error_reply(
                    arena,
                    409,
                    "a view with this name is declared differently; views are immutable",
                ),
                inline else => |outcome| {
                    try out.print("{{\"view\":\"{s}\",\"declared\":\"{s}\"}}", .{
                        name,
                        @tagName(outcome),
                    });
                    return .{ .status = 200, .body = out.items() };
                },
            }
        },
        .post => unreachable,
    }
}

// ---- Parsing ----

fn json_parse(comptime T: type, arena: std.mem.Allocator, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownField => bad("unknown field"),
        error.MissingField => bad("missing field"),
        else => bad("malformed JSON"),
    };
}

fn u64_parse(text: []const u8, comptime name: []const u8) error{BadRequest}!u64 {
    // Decimal digits only: no sign, no spaces, no leading `+`.
    if (text.len == 0 or text.len > 20) return bad(name ++ " must be a decimal string");
    for (text) |c| if (c < '0' or c > '9') return bad(name ++ " must be a decimal string");
    return std.fmt.parseInt(u64, text, 10) catch bad(name ++ " is out of range");
}

fn table_parse(text: ?[]const u8) error{BadRequest}!u32 {
    const value = try u64_parse(text orelse return bad("table is required"), "table");
    if (value > std.math.maxInt(u32)) return bad("table is out of range");
    try table_check(@intCast(value));
    return @intCast(value);
}

fn table_check(table: u32) error{BadRequest}!void {
    if (table == 0) return bad("table must not be zero");
    if (table >= catalog.tables_reserved_min) return bad("table is reserved");
}

fn limit_parse(text: ?[]const u8) error{BadRequest}!u32 {
    const value = try u64_parse(text orelse return bad("limit is required"), "limit");
    if (value == 0) return bad("limit must be positive");
    return @intCast(@min(value, page_limit_max));
}

fn value_parse(text: []const u8) error{BadRequest}![value_size]u8 {
    if (text.len % 2 != 0 or text.len > value_size * 2) {
        return bad("value_hex must be at most 80 bytes of hex");
    }
    var value: [value_size]u8 = @splat(0);
    _ = std.fmt.hexToBytes(value[0 .. text.len / 2], text) catch return bad("value_hex is not hex");
    return value;
}

/// Query parameters; each at most once, and only those listed.
fn query_parse(
    arena: std.mem.Allocator,
    query: []const u8,
    comptime allowed: []const []const u8,
) !std.StringHashMapUnmanaged([]const u8) {
    var parameters: std.StringHashMapUnmanaged([]const u8) = .{};
    if (query.len == 0) return parameters;
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse return bad("malformed query");
        const name = pair[0..equals];
        inline for (allowed) |allowed_name| {
            if (std.mem.eql(u8, name, allowed_name)) break;
        } else return bad("unknown query parameter");
        const entry = try parameters.getOrPut(arena, name);
        if (entry.found_existing) return bad("repeated query parameter");
        entry.value_ptr.* = pair[equals + 1 ..];
    }
    return parameters;
}

// ---- Rendering ----

pub fn error_reply(arena: std.mem.Allocator, status: u16, reason: []const u8) !Reply {
    var out = Writer.init(arena);
    try out.raw("{\"error\":");
    try std.json.stringify(reason, .{}, out.list.writer());
    try out.raw("}");
    return .{ .status = status, .body = out.items() };
}

const Writer = struct {
    list: std.ArrayList(u8),

    fn init(arena: std.mem.Allocator) Writer {
        return .{ .list = std.ArrayList(u8).init(arena) };
    }

    fn items(writer: *const Writer) []const u8 {
        return writer.list.items;
    }

    fn raw(writer: *Writer, text: []const u8) !void {
        try writer.list.appendSlice(text);
    }

    fn print(writer: *Writer, comptime format: []const u8, args: anytype) !void {
        try writer.list.writer().print(format, args);
    }

    /// A 64-bit number, as a decimal string.
    fn number(writer: *Writer, value: u64) !void {
        try writer.print("\"{}\"", .{value});
    }

    fn hex(writer: *Writer, bytes: []const u8) !void {
        try writer.print("\"{s}\"", .{std.fmt.fmtSliceHexLower(bytes)});
    }

    /// `,"fields":{…}` if the table has a layout.
    fn fields(writer: *Writer, layout: ?*const catalog.Layout, value: *const [value_size]u8) !void {
        const layout_ = layout orelse return;
        try writer.raw(",\"fields\":");
        try catalog.fields_render(writer.list.writer(), layout_, value);
    }
};

// ---- Tests ----

const testing = std.testing;

/// An in-memory client with Nerva's semantics for one-transaction requests, to test the
/// translation without a cluster. `tests/api/api.py` checks the real thing.
const FakeClient = struct {
    op: u64 = 0,
    rows: std.AutoArrayHashMapUnmanaged(u128, Version) = .{},
    allocator: std.mem.Allocator,

    const Version = struct { op: u64, exists: bool, value: [value_size]u8 };

    pub const Error = error{ TooManyEvents, OutOfMemory };

    pub fn lookup_rows(fake: *FakeClient, keys: []const RowKey, results: []RowValue) Error!void {
        fake.op += 1;
        for (keys, results) |key, *result| {
            const found = fake.rows.get(nerva.row_key(key.table, key.id));
            result.* = .{
                .id = key.id,
                .table = key.table,
                .flags = .{ .exists = if (found) |f| f.exists else false },
                .op = if (found) |f| f.op else 0,
                .op_read = fake.op,
                .value = if (found) |f| f.value else @splat(0),
            };
        }
    }

    pub fn commit(fake: *FakeClient, entries: []const Entry, results: []EntryResult) Error!void {
        fake.op += 1;
        for (entries, 0..) |entry, index| {
            if (entry.kind != .read) continue;
            const found = fake.rows.get(nerva.row_key(entry.table, entry.id));
            const version = if (found) |f| f.op else 0;
            if (version != entry.op_seen) {
                for (results, 0..) |*result, i| result.* = if (i == index)
                    .{ .status = .conflict, .op = version }
                else
                    .{ .status = .aborted, .op = 0 };
                return;
            }
        }
        for (entries) |entry| {
            if (entry.kind == .read) continue;
            try fake.rows.put(fake.allocator, nerva.row_key(entry.table, entry.id), .{
                .op = fake.op,
                .exists = entry.kind == .put,
                .value = entry.value,
            });
        }
        @memset(results, .{ .status = .ok, .op = fake.op });
    }

    pub fn get_changes(_: *FakeClient, _: nerva.ChangesFilter, _: []Change) Error!usize {
        unreachable; // Covered by `tests/api/api.py`.
    }

    pub fn get_history(_: *FakeClient, _: nerva.HistoryFilter, _: []Change) Error!usize {
        unreachable; // Covered by `tests/api/api.py`.
    }
};

/// An in-memory catalog.
const FakeLayouts = struct {
    map: std.AutoHashMapUnmanaged(u32, catalog.Layout) = .{},
    allocator: std.mem.Allocator,

    pub fn layout(fake: *FakeLayouts, _: std.mem.Allocator, table: u32) !?catalog.Layout {
        return fake.map.get(table);
    }

    pub fn layout_put(
        fake: *FakeLayouts,
        _: std.mem.Allocator,
        table: u32,
        new: *const catalog.Layout,
    ) !LayoutPut {
        const outcome: LayoutPut = if (fake.map.get(table)) |old| outcome: {
            if (!catalog.layout_extends(&old, new)) break :outcome .incompatible;
            break :outcome if (old.fields.len == new.fields.len) .unchanged else .extended;
        } else .created;
        if (outcome != .incompatible) try fake.map.put(fake.allocator, table, new.*);
        return outcome;
    }

    pub fn view(_: *FakeLayouts, _: std.mem.Allocator, _: []const u8) !?catalog.View {
        unreachable; // Covered by `tests/api/api.py`.
    }

    pub fn view_put(
        _: *FakeLayouts,
        _: std.mem.Allocator,
        _: []const u8,
        _: *const catalog.View,
    ) !ViewPut {
        unreachable; // Covered by `tests/api/api.py`.
    }
};

var no_layouts_instance: FakeLayouts = .{ .allocator = testing.failing_allocator };
const no_layouts = &no_layouts_instance;

test "api: layouts give puts and reads named fields" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    var layouts: FakeLayouts = .{ .allocator = arena };

    const declare =
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"}]}
    ;
    const created = try handle(arena, &fake, &layouts, .put, "/v1/tables/7", declare);
    try testing.expectEqualStrings(
        \\{"table":7,"layout":"created"}
    , created.body);
    const again = try handle(arena, &fake, &layouts, .put, "/v1/tables/7", declare);
    try testing.expectEqualStrings(
        \\{"table":7,"layout":"unchanged"}
    , again.body);
    const narrowed = try handle(arena, &fake, &layouts, .put, "/v1/tables/7",
        \\{"name":"seats","fields":[{"name":"section","type":"u16"}]}
    );
    try testing.expectEqual(@as(u16, 409), narrowed.status);

    const put = try handle(arena, &fake, &layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"put","table":7,"id":"1","fields":{"section":2,"price":"4500"}}]}
    );
    try testing.expectEqual(@as(u16, 200), put.status);
    const found = try handle(arena, &fake, &layouts, .post, "/v1/lookup",
        \\{"rows":[{"table":7,"id":"1"}]}
    );
    try testing.expect(std.mem.endsWith(u8, found.body,
        \\,"fields":{"section":2,"price":"4500"}}]}
    ));

    const get = try handle(arena, &fake, &layouts, .get, "/v1/tables/7", "");
    try testing.expectEqualStrings(declare, get.body);
    const missing = try handle(arena, &fake, &layouts, .get, "/v1/tables/8", "");
    try testing.expectEqual(@as(u16, 404), missing.status);

    // Fields need a layout; an unknown field, both forms, or a reserved table are refused.
    const refused = [_]struct { target: []const u8, body: []const u8 }{
        .{ .target = "/v1/commit", .body = 
        \\{"entries":[{"kind":"put","table":8,"id":"1","fields":{"a":1}}]}
        },
        .{ .target = "/v1/commit", .body = 
        \\{"entries":[{"kind":"put","table":7,"id":"1","fields":{"row":1}}]}
        },
        .{ .target = "/v1/commit", .body = 
        \\{"entries":[{"kind":"put","table":7,"id":"1","fields":{},"value_hex":"00"}]}
        },
        .{ .target = "/v1/commit", .body = 
        \\{"entries":[{"kind":"delete","table":7,"id":"1","fields":{}}]}
        },
        .{ .target = "/v1/lookup", .body = 
        \\{"rows":[{"table":4294901761,"id":"1"}]}
        },
    };
    for (refused) |case| {
        const reply = try handle(arena, &fake, &layouts, .post, case.target, case.body);
        try testing.expectEqual(@as(u16, 400), reply.status);
    }
    try testing.expectEqual(
        @as(u16, 400),
        (try handle(arena, &fake, &layouts, .put, "/v1/tables/4294901761", declare)).status,
    );
}

test "api: lookup and commit translate to and from JSON" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    const lookup_5 =
        \\{"rows":[{"table":1,"id":"5"}]}
    ;

    const absent = try handle(arena, &fake, no_layouts, .post, "/v1/lookup", lookup_5);
    try testing.expectEqual(@as(u16, 200), absent.status);
    try testing.expectEqualStrings(
        \\{"op":"1","rows":[{"table":1,"id":"5","exists":false,"op":"0","value_hex":"
    ++ "00" ** 80 ++
        \\"}]}
    , absent.body);

    const put = try handle(arena, &fake, no_layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"read","table":1,"id":"5","op_seen":"0"},
        \\            {"kind":"put","table":1,"id":"5","value_hex":"c0ffee"}]}
    );
    try testing.expectEqual(@as(u16, 200), put.status);
    try testing.expectEqualStrings(
        \\{"status":"committed","op":"2"}
    , put.body);

    const found = try handle(arena, &fake, no_layouts, .post, "/v1/lookup", lookup_5);
    try testing.expectEqualStrings(
        \\{"op":"3","rows":[{"table":1,"id":"5","exists":true,"op":"2","value_hex":"c0ffee
    ++ "00" ** 77 ++
        \\"}]}
    , found.body);

    // The same read again is stale: 409 with the row's current version, nothing applied.
    const stale = try handle(arena, &fake, no_layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"delete","table":1,"id":"6"},
        \\            {"kind":"read","table":1,"id":"5","op_seen":"0"}]}
    );
    try testing.expectEqual(@as(u16, 409), stale.status);
    try testing.expectEqualStrings(
        \\{"status":"conflict","index":1,"op":"2"}
    , stale.body);
}

test "api: bad requests are refused before reaching the cluster" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };

    const Case = struct { method: Method, target: []const u8, body: []const u8, status: u16 };
    const lookup_bad = [_][]const u8{
        \\{"rows":[]}
        ,
        \\{"rows":[{"table":0,"id":"1"}]}
        ,
        \\{"rows":[{"table":1,"id":1}]}
        ,
        \\{"rows":[{"table":1,"id":"-1"}]}
        ,
        \\{"rows":[{"table":1,"id":"18446744073709551616"}]}
        ,
        \\{"rows":[{"table":1,"id":"1","x":1}]}
        ,
        \\not json
    };
    const commit_bad = [_][]const u8{
        \\{"entries":[{"kind":"read","table":1,"id":"1"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"1"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"0"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"
        ++ "00" ** 81 ++
            \\"}]}
        ,
        \\{"entries":[{"kind":"delete","table":1,"id":"1","op_seen":"1"}]}
        ,
        \\{"entries":[{"kind":"merge","table":1,"id":"1"}]}
    };
    const get_bad = [_][]const u8{
        "/v1/changes", // No limit.
        "/v1/changes?limit=0",
        "/v1/changes?limit=1&limit=2",
        "/v1/changes?limit=1&other=2",
        "/v1/history?table=1&limit=1",
        "/v1/history?table=1&id=1&op_max=0&limit=1",
        "/v1/row?table=1&id=1",
        "/v1/row?table=1&id=1&as_of=0",
    };

    var cases = std.ArrayList(Case).init(arena);
    try cases.append(.{ .method = .post, .target = "/v1/nope", .body = "{}", .status = 404 });
    try cases.append(.{ .method = .get, .target = "/v1/commit", .body = "", .status = 405 });
    for (lookup_bad) |body| {
        try cases.append(.{ .method = .post, .target = "/v1/lookup", .body = body, .status = 400 });
    }
    for (commit_bad) |body| {
        try cases.append(.{ .method = .post, .target = "/v1/commit", .body = body, .status = 400 });
    }
    for (get_bad) |target| {
        try cases.append(.{ .method = .get, .target = target, .body = "", .status = 400 });
    }

    for (cases.items) |case| {
        const reply = try handle(arena, &fake, no_layouts, case.method, case.target, case.body);
        testing.expectEqual(case.status, reply.status) catch |err| {
            std.debug.print("{s} {s}: {s}\n", .{ case.target, case.body, reply.body });
            return err;
        };
        try testing.expect(std.mem.startsWith(u8, reply.body, "{\"error\":"));
    }
    try testing.expectEqual(@as(u64, 0), fake.op); // Nothing reached the cluster.
}
