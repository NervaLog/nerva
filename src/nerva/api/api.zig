//! `nerva api`: Nerva's core operations as JSON over HTTP (docs/DECISIONS.md N33).
//!
//! A thin translation, with no application concepts: every route is one Nerva request.
//!
//!     POST /v1/lookup   {"rows": [{"table": 1, "id": "5"}, …]}
//!     POST /v1/commit   {"entries": [{"kind": "read", "table": 1, "id": "5", "op_seen": "9"},
//!                                    {"kind": "put", "table": 1, "id": "5", "value_hex": "…"},
//!                                    {"kind": "delete", "table": 1, "id": "6"},
//!                                    {"kind": "add", "table": 1, "id": "7", "field": "stock",
//!                                     "delta": "-3", "min": "0"}]}
//!     GET  /v1/changes?cursor=<c>&limit=<n>
//!     GET  /v1/history?table=<t>&id=<i>&op_max=<n|latest>&cursor=<c>&limit=<n>
//!     GET  /v1/row?table=<t>&id=<i>&as_of=<op>
//!     PUT  /v1/tables/<t>   {"name": "seats", "fields": [{"name": "price", "type": "u64"}, …]}
//!     GET  /v1/tables/<t>
//!     PUT  /v1/views/<name>  {"table": 5, "where": […], "group_by": […], "aggregates": […]}
//!     GET  /v1/views         (the views the state machine maintains)
//!     GET  /v1/views/<name>?min_op=<n|latest>|as_of=<op>
//!                            (the view, whole, as `nerva view` answers it: N66)
//!     GET  /v1/views/<name>/definition
//!     GET  /v1/views/<name>/groups?cursor=<c>&limit=<n>&as_of=<op>
//!                            (the view, maintained by the state machine: N52, N62)
//!     PUT  /v1/ledgers/<id>  {"fields": [{"table": 7, "field": "available", "floor": "0"}, …]}
//!     GET  /v1/ledgers/<id>  (conserved fields: N75)
//!     POST /v1/documents/get, POST /v1/documents/commit, GET /v1/documents/changes
//!                            (larger values, by key: `documents_routes.zig`)
//!
//! Conventions:
//! - 64-bit numbers (`id`, `op`, `op_seen`, cursors) are decimal strings: JSON numbers lose
//!   precision past 2^53 in JavaScript. `table` (32-bit) and `limit` are numbers.
//! - A value is `value_hex`: up to 80 bytes as hex, zero-padded on write, always the full 80
//!   bytes on read.
//! - A commit is one transaction: `200 {"status": "committed", "op"}`, or `409 {"status":
//!   "conflict", "index", "op"}` (the entry whose read was stale, and the row's current version),
//!   or `400 {"error", "index"}` for an invalid entry. Nothing applies unless it committed.
//! - An add (N42) changes one 64-bit field inside the commit, without a read: `field` (by name,
//!   with a layout) or `offset` and `type` (`u64` or `i64`); `delta` (or `delta_from`, the index
//!   of an earlier add whose applied amount it moves, negated); optional `min`, `max`, `clamp`
//!   and `create`. A committed reply lists `adds`: each add's `index`, `applied` and new
//!   `value`. An add that would cross a bound answers `409 {"status": "out_of_bounds", "index",
//!   "value"}`; one to an absent row without `create`, `409 {"status": "row_absent", "index"}`.
//! - A field of a ledger (N75) changes only by a pair: an add with `"pair": true` (which may
//!   clamp), then an add naming it in `delta_from` (which may not). Otherwise `409 {"status":
//!   "unpaired", "index"}`; a put, delete or overlapping add that would change it, `409
//!   {"status": "conserved_write", "index"}`.
//! - A table may have a layout (`catalog.zig`, N34): then puts may give `fields` instead of
//!   `value_hex`, and every row or change of that table also comes back with `fields`.
//! - Tables from `catalog.tables_reserved_min` up are Nerva's own: refused here, and left out of
//!   `changes`.
//! - Errors are `{"error": "<reason>"}` with 400, 401, 404, 405, 409 or 503.

const std = @import("std");
const assert = std.debug.assert;

const nerva = @import("../../nerva.zig");
const catalog = @import("../catalog.zig");
const declared_views = @import("../view/declared.zig");
const documents = @import("../documents.zig");
const documents_routes = @import("documents_routes.zig");
const ledgers_static = @import("../ledgers.zig");

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

const Route = enum {
    lookup,
    commit,
    changes,
    history,
    row,
    tables,
    views,
    documents_get,
    documents_commit,
    documents_changes,
    view_groups,
    view_definition,
    view_list,
    ledgers,
};

const routes = [_]struct { path: []const u8, route: Route, method: Method }{
    .{ .path = "/v1/lookup", .route = .lookup, .method = .post },
    .{ .path = "/v1/commit", .route = .commit, .method = .post },
    .{ .path = "/v1/changes", .route = .changes, .method = .get },
    .{ .path = "/v1/history", .route = .history, .method = .get },
    .{ .path = "/v1/row", .route = .row, .method = .get },
    .{ .path = "/v1/documents/get", .route = .documents_get, .method = .post },
    .{ .path = "/v1/documents/commit", .route = .documents_commit, .method = .post },
    .{ .path = "/v1/documents/changes", .route = .documents_changes, .method = .get },
};

const tables_prefix = "/v1/tables/";
const views_prefix = "/v1/views/";
const ledgers_prefix = "/v1/ledgers/";
const views_groups_suffix = "/groups";
const views_definition_suffix = "/definition";
/// The most groups `GET /v1/views/<name>` answers with at once (N66); larger views are read in
/// pages from `/groups`.
pub const view_answer_groups_max = 10_000;

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

    const route: Route = if (std.mem.startsWith(u8, path, ledgers_prefix)) route: {
        if (method != .get and method != .put) {
            return error_reply(arena, 405, "method not allowed");
        }
        if (query.len > 0) return error_reply(arena, 400, "unexpected query");
        break :route .ledgers;
    } else if (std.mem.eql(u8, path, "/v1/views")) route: {
        if (method != .get) return error_reply(arena, 405, "method not allowed");
        if (query.len > 0) return error_reply(arena, 400, "unexpected query");
        break :route .view_list;
    } else if (std.mem.startsWith(u8, path, tables_prefix) or
        std.mem.startsWith(u8, path, views_prefix))
    route: {
        if (method != .get and method != .put) {
            return error_reply(arena, 405, "method not allowed");
        }
        // `/v1/views/<name>/groups` and `/definition`, with a name: `/v1/views/groups` is the
        // view named `groups`.
        const view_suffix = struct {
            fn is(path_: []const u8, suffix: []const u8) bool {
                return std.mem.startsWith(u8, path_, views_prefix) and
                    std.mem.endsWith(u8, path_, suffix) and
                    path_.len > views_prefix.len + suffix.len;
            }
        }.is;
        const groups = view_suffix(path, views_groups_suffix);
        const definition = view_suffix(path, views_definition_suffix);
        const tables_route = std.mem.startsWith(u8, path, tables_prefix);
        if ((groups or definition) and method != .get) {
            return error_reply(arena, 405, "method not allowed");
        }
        // A view takes `as_of` and `min_op` (N66); a table or a definition takes none.
        const queried = groups or (!tables_route and !definition and method == .get);
        if (!queried and query.len > 0) return error_reply(arena, 400, "unexpected query");
        break :route if (tables_route)
            .tables
        else if (groups)
            .view_groups
        else if (definition)
            .view_definition
        else
            .views;
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
        .views => views(arena, client, layouts, method, path[views_prefix.len..], query, body),
        .view_definition => view_definition(
            arena,
            layouts,
            path[views_prefix.len .. path.len - views_definition_suffix.len],
        ),
        .view_list => view_list(arena, client),
        .ledgers => ledgers(arena, client, layouts, method, path[ledgers_prefix.len..], body),
        .view_groups => view_groups(
            arena,
            client,
            layouts,
            path[views_prefix.len .. path.len - views_groups_suffix.len],
            query,
        ),
        .documents_get => documents_routes.get(arena, client, body),
        .documents_commit => documents_routes.commit(arena, client, body),
        .documents_changes => documents_routes.changes(arena, client, query),
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

pub fn bad(reason: []const u8) error{BadRequest} {
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
        entries: []const EntryRequest,
    };
    const request = try json_parse(Request, arena, body);
    if (request.entries.len == 0) return bad("entries must not be empty");

    const entries = try arena.alloc(Entry, request.entries.len);
    // Per entry: an add's field type, for rendering its value.
    const add_fields = try arena.alloc(?nerva.Add.AddField, request.entries.len);
    for (entries, request.entries, add_fields, 0..) |*entry, entry_request, *add_field, index| {
        try table_check(entry_request.table);
        if (entry_request.kind != .put and entry_request.fields != null) {
            return bad("only a put has fields");
        }
        if (entry_request.kind != .add and entry_request.add_fields_present()) {
            return bad("only an add has field, offset, type, delta, min, max, clamp, create, " ++
                "delta_from or pair");
        }
        add_field.* = null;
        entry.* = .{
            .id = try u64_parse(entry_request.id, "id"),
            .table = entry_request.table,
            .kind = switch (entry_request.kind) {
                .read => .read,
                .put => .put,
                .delete => .delete,
                .add => .add,
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
            .add => {
                if (entry_request.op_seen != null) return bad("an add has no op_seen");
                if (entry_request.value_hex != null) return bad("an add has no value_hex");
                const add = try add_parse(layouts, &entry_request, entries[0..index]);
                entry.value = add.value();
                add_field.* = add.field;
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
                    "{{\"error\":\"a transaction writes a row at most once (adds aside)\"," ++
                        "\"index\":{}}}",
                    .{index},
                );
                return .{ .status = 400, .body = out.items() };
            },
            .out_of_bounds => {
                try out.print("{{\"status\":\"out_of_bounds\",\"index\":{},\"value\":", .{index});
                try out.field_value(add_fields[index].?, result.value);
                try out.raw("}");
                return .{ .status = 409, .body = out.items() };
            },
            .row_absent => {
                try out.print("{{\"status\":\"row_absent\",\"index\":{}}}", .{index});
                return .{ .status = 409, .body = out.items() };
            },
            // An add to a field a view filters or groups by (N52).
            .view_key_field => {
                try out.print("{{\"status\":\"view_key_field\",\"index\":{}}}", .{index});
                return .{ .status = 409, .body = out.items() };
            },
            // This op's views budget is spent; nothing applied, so retrying is safe (N52).
            .views_busy => {
                try out.print("{{\"status\":\"views_busy\",\"index\":{}}}", .{index});
                return .{ .status = 503, .body = out.items() };
            },
            // The transaction alone is too large for any op: nothing applied; split it (#32).
            .views_too_large => {
                try out.print("{{\"status\":\"views_too_large\",\"index\":{}}}", .{index});
                return .{ .status = 413, .body = out.items() };
            },
            // A conserved field changed other than by a pair (N75).
            .unpaired, .conserved_write => {
                try out.print("{{\"status\":\"{s}\",\"index\":{}}}", .{
                    @tagName(result.status),
                    index,
                });
                return .{ .status = 409, .body = out.items() };
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
    var adds: u32 = 0;
    for (results, add_fields, 0..) |result, add_field, index| {
        const field_type = add_field orelse continue;
        try out.raw(if (adds == 0) ",\"adds\":[" else ",");
        adds += 1;
        try out.print("{{\"index\":{},\"applied\":\"{}\",\"value\":", .{ index, result.applied });
        try out.field_value(field_type, result.value);
        try out.raw("}");
    }
    if (adds > 0) try out.raw("]");
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

const EntryRequest = struct {
    kind: enum { read, put, delete, add },
    table: u32,
    id: []const u8,
    op_seen: ?[]const u8 = null,
    value_hex: ?[]const u8 = null,
    fields: ?std.json.Value = null,
    // Adds only.
    field: ?[]const u8 = null,
    offset: ?u8 = null,
    type: ?enum { u64, i64 } = null,
    delta: ?[]const u8 = null,
    delta_from: ?u32 = null,
    min: ?[]const u8 = null,
    max: ?[]const u8 = null,
    clamp: bool = false,
    create: bool = false,
    pair: bool = false,

    fn add_fields_present(request: *const EntryRequest) bool {
        return request.field != null or request.offset != null or request.type != null or
            request.delta != null or request.delta_from != null or request.min != null or
            request.max != null or request.clamp or request.create or request.pair;
    }
};

/// An add's parameters, checked as the state machine would (`entry_validate`, and `delta_from`
/// against the entries before it).
fn add_parse(layouts: anytype, request: *const EntryRequest, previous: []const Entry) !nerva.Add {
    var add: nerva.Add = .{
        .delta = 0,
        .min = 0,
        .max = 0,
        .delta_from = 0,
        .offset = 0,
        .field = .u64,
        .flags = .{ .clamp = request.clamp, .create = request.create, .pair = request.pair },
    };
    if (request.field) |name| {
        if (request.offset != null or request.type != null) {
            return bad("an add has field, or offset and type, not both");
        }
        const layout = try layouts.get(request.table) orelse
            return bad("field needs a layout for the table (PUT /v1/tables/<t>)");
        const field = layout.field(name) orelse return bad("no such field");
        add.offset = field.offset;
        add.field = switch (field.type) {
            .u64 => .u64,
            .i64 => .i64,
            else => return bad("an add's field must be u64 or i64"),
        };
    } else {
        const offset = request.offset orelse return bad("an add needs field, or offset and type");
        if (offset > value_size - 8) return bad("offset must be at most 72");
        add.offset = offset;
        add.field = switch (request.type orelse return bad("an add needs a type with offset")) {
            .u64 => .u64,
            .i64 => .i64,
        };
    }

    if (request.delta_from) |index| {
        if (request.delta != null) return bad("an add has delta or delta_from, not both");
        if (index >= previous.len or previous[index].kind != .add) {
            return bad("delta_from must be the index of an earlier add");
        }
        add.flags.delta_from = true;
        add.delta_from = index;
    } else {
        const delta = request.delta orelse return bad("an add needs delta or delta_from");
        add.delta = try i64_parse(delta, "delta");
        if (add.delta == std.math.minInt(i64)) return bad("delta is out of range");
    }

    if (request.min) |text| {
        add.flags.min = true;
        add.min = try bound_parse(add.field, text, "min");
    }
    if (request.max) |text| {
        add.flags.max = true;
        add.max = try bound_parse(add.field, text, "max");
    }
    // The remaining checks (bounds in order) are `entry_validate`'s.
    if (nerva.entry_validate(&.{
        .id = 1,
        .table = 1,
        .kind = .add,
        .op_seen = 0,
        .value = add.value(),
    })) |status| return switch (status) {
        .field_invalid => bad("min must not exceed max"),
        else => unreachable,
    };
    return add;
}

const LedgerRequest = struct {
    fields: []const struct {
        table: u32,
        offset: ?u8 = null,
        field: ?[]const u8 = null,
        floor: ?[]const u8 = null,
    },
};

/// A ledger (N75): a set of conserved i64 fields that only pairs of adds change.
///
///     PUT /v1/ledgers/<id>  {"fields": [{"table": 7, "field": "available", "floor": "0"},
///                                       {"table": 7, "offset": 8, "floor": null}, …]}
///     GET /v1/ledgers/<id>
///
/// A field is named by layout (`field`) or by `offset`; `floor` (an i64 as a string, or null)
/// stops conserved adds that move it down. The fields are sent sorted, so their order in the
/// request does not matter.
fn ledgers(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    method: Method,
    id_text: []const u8,
    body: []const u8,
) !Reply {
    const id_wide = std.fmt.parseInt(u64, id_text, 10) catch return bad("invalid ledger id");
    if (id_wide == 0 or id_wide > std.math.maxInt(u32)) return bad("invalid ledger id");
    const id: u32 = @intCast(id_wide);
    var out = Writer.init(arena);
    switch (method) {
        .get => {
            const ledger = try client.get_ledger(id);
            if (ledger.slot == 0) return error_reply(arena, 404, "no such ledger");
            assert(ledger.definition.id == id);
            try out.print("{{\"ledger\":{},\"op\":", .{id});
            try out.number(ledger.op);
            try out.raw(",\"fields\":[");
            const definition = &ledger.definition;
            for (definition.fields[0..definition.field_count], 0..) |*field, index| {
                if (index > 0) try out.raw(",");
                try out.print("{{\"table\":{},\"offset\":{}", .{ field.table, field.offset });
                if (try layouts.layout(arena, field.table)) |layout| {
                    for (layout.fields) |*named| {
                        if (named.offset != field.offset or named.type != .i64) continue;
                        try out.raw(",\"field\":");
                        try std.json.stringify(named.name, .{}, out.list.writer());
                    }
                }
                try out.raw(",\"floor\":");
                if (field.flags.floor) {
                    try out.print("\"{}\"", .{field.floor});
                } else {
                    try out.raw("null");
                }
                try out.raw("}");
            }
            try out.raw("]}");
            return .{ .status = 200, .body = out.items() };
        },
        .put => {
            const definition = try ledger_parse(arena, layouts, id, body);
            const declared = try client.declare_ledger(&definition);
            const conflict: ?[]const u8 = switch (declared.status) {
                .created, .exists => null,
                .ledger_immutable => "ledger_immutable",
                .ledger_field_taken => "ledger_field_taken",
                .field_viewed => "field_viewed",
                .ledgers_full => "ledgers_full",
                // Checked here first: the state machine would agree.
                .invalid, .table_invalid => unreachable,
            };
            if (conflict) |status| {
                try out.print("{{\"status\":\"{s}\",\"ledger\":{}}}", .{ status, id });
                return .{ .status = 409, .body = out.items() };
            }
            try out.print("{{\"ledger\":{},\"declared\":\"{s}\",\"op\":", .{
                id,
                @tagName(declared.status),
            });
            try out.number(declared.op);
            try out.raw("}");
            return .{ .status = 200, .body = out.items() };
        },
        .post => unreachable,
    }
}

fn ledger_parse(
    arena: std.mem.Allocator,
    layouts: anytype,
    id: u32,
    body: []const u8,
) !nerva.LedgerDefinition {
    const request = try json_parse(LedgerRequest, arena, body);
    if (request.fields.len < 2 or request.fields.len > nerva.ledger_fields_max) {
        return bad("a ledger has 2 to 16 fields");
    }
    var definition = std.mem.zeroes(nerva.LedgerDefinition);
    definition.id = id;
    definition.field_count = @intCast(request.fields.len);
    for (request.fields, definition.fields[0..request.fields.len]) |field, *target| {
        try table_check(field.table);
        const offset: u8 = if (field.field) |name| offset: {
            if (field.offset != null) return bad("a ledger field has field or offset, not both");
            const layout = try layouts.layout(arena, field.table) orelse
                return bad("field needs a layout for the table (PUT /v1/tables/<t>)");
            const named = layout.field(name) orelse return bad("no such field");
            if (named.type != .i64) return bad("a ledger's fields must be i64");
            break :offset named.offset;
        } else field.offset orelse return bad("a ledger field needs field or offset");
        if (offset % 8 != 0 or offset > value_size - 8) {
            return bad("a ledger field's offset must be a multiple of 8, at most 72");
        }
        target.* = .{ .table = field.table, .offset = offset, .flags = .{}, .floor = 0 };
        if (field.floor) |text| {
            target.flags.floor = true;
            target.floor = try i64_parse(text, "floor");
        }
    }
    const fields = definition.fields[0..definition.field_count];
    std.mem.sortUnstable(nerva.LedgerField, fields, {}, struct {
        fn less_than(_: void, a: nerva.LedgerField, b: nerva.LedgerField) bool {
            if (a.table != b.table) return a.table < b.table;
            return a.offset < b.offset;
        }
    }.less_than);
    for (fields[1..], fields[0 .. fields.len - 1]) |field, previous| {
        if (field.table == previous.table and field.offset == previous.offset) {
            return bad("a ledger names each field once");
        }
    }
    assert(ledgers_static.definition_validate(&definition) == null);
    return definition;
}

fn bound_parse(field: nerva.Add.AddField, text: []const u8, comptime name: []const u8) !u64 {
    return switch (field) {
        .u64 => try u64_parse(text, name),
        .i64 => @bitCast(try i64_parse(text, name)),
        _ => unreachable,
    };
}

fn i64_parse(text: []const u8, comptime name: []const u8) error{BadRequest}!i64 {
    const negative = text.len > 0 and text[0] == '-';
    const magnitude = try u64_parse(if (negative) text[1..] else text, name);
    if (negative) {
        if (magnitude > @as(u64, std.math.maxInt(i64)) + 1) return bad(name ++ " is out of range");
        return @intCast(-@as(i128, magnitude));
    }
    if (magnitude > std.math.maxInt(i64)) return bad(name ++ " is out of range");
    return @intCast(magnitude);
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

    const found = try change_as_of(client, table, id, as_of);

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

/// The row's last change (a put or a delete) at or before `op`, or null if it had none.
pub fn change_as_of(client: anytype, table: u32, id: u64, op: u64) !?Change {
    assert(op != 0);
    var page: [65]Change = undefined;
    var cursor: u64 = 0;
    while (true) {
        const count = try client.get_history(.{
            .table = table,
            .id = id,
            .limit = page.len - 1,
            .op_max = op,
            .timestamp_max = cursor,
        }, &page);
        assert(count >= 1);
        const end = page[count - 1];
        assert(end.kind == .end);
        if (count > 1) {
            assert(page[0].op <= op);
            return page[0];
        }
        if (!end.flags.more) {
            assert(op < end.op);
            return null;
        }
        cursor = end.timestamp;
    }
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
    client: anytype,
    layouts: anytype,
    method: Method,
    name: []const u8,
    query: []const u8,
    body: []const u8,
) !Reply {
    try catalog.view_name_validate(name);
    var out = Writer.init(arena);
    switch (method) {
        .get => return view_answer(arena, client, layouts, name, query),
        .put => {
            const view = try catalog.view_parse(arena, body);
            try table_check(view.table);
            const layout = try layouts.layout(arena, view.table) orelse
                return bad("a view needs a layout for its table (PUT /v1/tables/<t>)");
            try catalog.view_check(&view, &layout);
            // A view declared differently is refused before the state machine sees it; one the
            // state machine refuses over a ledger's field is not written to the catalog (N75).
            var cataloged = false;
            if (try layouts.view(arena, name)) |existing| {
                const same = std.mem.eql(
                    u8,
                    try catalog.view_render(arena, &existing),
                    try catalog.view_render(arena, &view),
                );
                if (!same) return error_reply(
                    arena,
                    409,
                    "a view with this name is declared differently; views are immutable",
                );
                cataloged = true;
            }
            const definition = catalog.view_definition(name, &view, &layout);
            const declared = try client.declare_view(&definition);
            // Not yet in the catalog: the state machine decides the name. Another gateway may
            // have declared it, then stalled before writing its document; writing this one would
            // leave two definitions under one name for good (#70). That gateway's retry finds
            // `exists` and writes its document.
            if (!cataloged) switch (declared.status) {
                .ledger_field => return error_reply(
                    arena,
                    409,
                    "the view filters or groups by a field of a ledger",
                ),
                .different => return error_reply(
                    arena,
                    409,
                    "a view with this name is declared differently; views are immutable",
                ),
                else => {},
            };
            switch (try layouts.view_put(arena, name, &view)) {
                .different => return error_reply(
                    arena,
                    409,
                    "a view with this name is declared differently; views are immutable",
                ),
                inline else => |outcome| {
                    // The state machine maintains it from now on (N52), unless it refused it.
                    const reason: ?[]const u8 = switch (declared.status) {
                        .created, .exists => null,
                        .unsupported => unreachable, // No longer returned (N62).
                        .table_extremes_full => "the table's views have too many min and max " ++
                            "aggregates (at most 4)",
                        .views_full => "the cluster's views are full",
                        .table_views_full => "the table's views are full",
                        // Only for a document already in the catalog: one written before the
                        // state machine refused it, kept as it is (#70).
                        .different => "declared differently in the state machine",
                        .ledger_field => "the view filters or groups by a field of a ledger",
                        .invalid, .table_invalid => "refused by the state machine",
                    };
                    try out.print("{{\"view\":\"{s}\",\"declared\":\"{s}\",\"maintained\":{}", .{
                        name,
                        @tagName(outcome),
                        reason == null,
                    });
                    if (reason) |text| {
                        try out.raw(",\"reason\":");
                        try std.json.stringify(text, .{}, out.list.writer());
                    }
                    try out.raw("}");
                    return .{ .status = 200, .body = out.items() };
                },
            }
        },
        .post => unreachable,
    }
}

/// Groups of a view maintained by the state machine (N52), in storage order, with the view's
/// state, hash and group count as of the read's op.
///
///     GET /v1/views/<name>/groups?cursor=<c>&limit=<n>&as_of=<op>
///
/// With `as_of`, the view as that op left it (N62); `as_of` must already be committed, and a
/// page holds at most 128 groups.
fn view_groups(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    name: []const u8,
    query: []const u8,
) !Reply {
    try catalog.view_name_validate(name);
    const parameters = try query_parse(arena, query, &.{ "cursor", "limit", "as_of" });
    const cursor = if (parameters.get("cursor")) |text| try u64_parse(text, "cursor") else 0;
    const as_of: u64 = if (parameters.get("as_of")) |text| as_of: {
        const op = try u64_parse(text, "as_of");
        if (op == 0) return bad("as_of must be positive");
        break :as_of op;
    } else 0;
    const limit = if (parameters.get("limit")) |text|
        try limit_parse(text)
    else
        page_limit_max;

    const view = try layouts.view(arena, name) orelse return error_reply(arena, 404, "no such view");
    const layout = try layouts.layout(arena, view.table) orelse return error.Corrupt;

    var query_view: nerva.ViewQuery = .{
        .view_id = 0,
        .group_hash_min = cursor,
        .as_of = as_of,
        .limit = limit,
    };
    @memcpy(query_view.name[0..name.len], name);
    const records = try arena.alloc(nerva.ViewRecord, limit + 1);
    const count = try client.get_view(query_view, records);
    assert(count >= 1);
    const header = records[0];
    assert(header.kind == .header);
    if (as_of != 0 and as_of >= header.op) return bad("as_of is not yet committed");
    if (header.state == .missing) {
        if (as_of != 0) return error_reply(arena, 404, "the view was declared after as_of");
        return error_reply(arena, 404, "this view is not maintained by the state machine");
    }

    var out = Writer.init(arena);
    try out.print("{{\"view\":\"{s}\",\"id\":{},\"state\":\"{s}\",\"op\":", .{
        name,
        header.view_id,
        @tagName(header.state),
    });
    try out.number(header.op);
    try out.raw(",\"declared_op\":");
    try out.number(header.declared_op);
    if (as_of != 0) {
        try out.raw(",\"as_of\":");
        try out.number(as_of);
    }
    try out.raw(",\"view_hash\":");
    try out.hex(&header.hash);
    try out.raw(",\"group_count\":");
    try out.number(header.group_count);
    try out.raw(",\"groups\":[");
    for (records[1..count], 0..) |*record, index| {
        assert(record.kind == .group);
        if (index > 0) try out.raw(",");
        try out.raw("{");
        // The group key's fields, placed back at their offsets, render as the layout says.
        var value: [value_size]u8 = @splat(0);
        var key_offset: usize = 0;
        for (view.group_by) |field_name| {
            const field = layout.field(field_name).?;
            @memcpy(value[field.offset..][0..field.size], record.group_key[key_offset..][0..field.size]);
            key_offset += field.size;
            try out.print("\"{s}\":", .{field_name});
            try catalog.field_render(out.list.writer(), field, &value);
            try out.raw(",");
        }
        try out.raw("\"count\":");
        try out.number(record.count);
        for (view.aggregates, 0..) |aggregate, slot| {
            if (aggregate.function == .count) continue;
            try out.print(",\"{s}_{s}\":\"{}\"", .{
                @tagName(aggregate.function),
                aggregate.field.?,
                std.mem.readInt(i128, &record.sums[slot], .little),
            });
        }
        try out.raw("}");
    }
    try out.print("],\"more\":{},\"cursor\":", .{header.flags.more});
    if (header.flags.more) try out.number(header.cursor) else try out.raw("null");
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

// ---- Parsing ----

pub fn json_parse(comptime T: type, arena: std.mem.Allocator, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownField => bad("unknown field"),
        error.MissingField => bad("missing field"),
        else => bad("malformed JSON"),
    };
}

pub fn u64_parse(text: []const u8, comptime name: []const u8) error{BadRequest}!u64 {
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

/// A view's declaration (N34), as stored in the catalog.
///
///     GET /v1/views/<name>/definition
fn view_definition(arena: std.mem.Allocator, layouts: anytype, name: []const u8) !Reply {
    try catalog.view_name_validate(name);
    const view = try layouts.view(arena, name) orelse return error_reply(arena, 404, "no such view");
    return .{ .status = 200, .body = try catalog.view_render(arena, &view) };
}

/// The views the state machine maintains, in declaration order (N66).
///
///     GET /v1/views
fn view_list(arena: std.mem.Allocator, client: anytype) !Reply {
    var out = Writer.init(arena);
    try out.raw("{\"views\":[");
    var records: [2]nerva.ViewRecord = undefined;
    for (1..nerva.views_max + 1) |id| {
        const count = try client.get_view(.{ .view_id = id, .group_hash_min = 0, .limit = 1 }, &records);
        assert(count >= 1);
        const header = records[0];
        assert(header.kind == .header);
        if (header.state == .missing) break;
        if (id > 1) try out.raw(",");
        const name_size = std.mem.indexOfScalar(u8, &header.group_key, 0) orelse
            header.group_key.len;
        try out.print("{{\"name\":\"{s}\",\"id\":{},\"state\":\"{s}\",\"declared_op\":", .{
            header.group_key[0..name_size],
            id,
            @tagName(header.state),
        });
        try out.number(header.declared_op);
        try out.raw(",\"group_count\":");
        try out.number(header.group_count);
        try out.raw("}");
    }
    try out.raw("]}");
    return .{ .status = 200, .body = out.items() };
}

/// A view maintained by the state machine, whole, as `nerva view` answers it (N35, N66): the
/// groups sorted by key, and `hash`, the SHA-256 of the `groups` JSON as served, so that the two
/// can be compared byte for byte. Also `view_hash`, the replicated hash (N52), and
/// `declared_op`. Every page is read at one op: the first at the latest (or `as_of`), the rest
/// as of the first's. A view with more than `view_answer_groups_max` groups is read from
/// `/groups` instead.
///
///     GET /v1/views/<name>?min_op=<n|latest>
///     GET /v1/views/<name>?as_of=<op>
///
/// As in `nerva view`, an op not yet committed answers 504. A view still building, or failed,
/// answers 503: its groups are not yet the view's.
fn view_answer(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    name: []const u8,
    query: []const u8,
) !Reply {
    const parameters = try query_parse(arena, query, &.{ "min_op", "as_of" });
    const min_op: ?u64 = if (parameters.get("min_op")) |text|
        if (std.mem.eql(u8, text, "latest")) null else try u64_parse(text, "min_op")
    else
        null;
    const as_of: u64 = if (parameters.get("as_of")) |text| as_of: {
        const op = try u64_parse(text, "as_of");
        if (op == 0) return bad("as_of must be positive");
        break :as_of op;
    } else 0;
    if (as_of != 0 and parameters.get("min_op") != null) return bad("min_op or as_of, not both");

    const view = try layouts.view(arena, name) orelse return error_reply(arena, 404, "no such view");
    const layout = try layouts.layout(arena, view.table) orelse return error.Corrupt;

    const records = try arena.alloc(nerva.ViewRecord, page_limit_max + 1);
    var groups: std.ArrayListUnmanaged(declared_views.Group) = .{};
    var read_op: ?u64 = null;
    var view_hash: [32]u8 = undefined;
    var declared_op: u64 = 0;
    var cursor: u64 = 0;
    while (true) {
        var query_view: nerva.ViewQuery = .{
            .view_id = 0,
            .group_hash_min = cursor,
            .limit = page_limit_max,
            // Every page after the first as of the first's op: one answer, at one op.
            .as_of = if (read_op) |op| op else as_of,
        };
        @memcpy(query_view.name[0..name.len], name);
        const count = try client.get_view(query_view, records);
        assert(count >= 1);
        const header = records[0];
        assert(header.kind == .header);
        if (read_op == null) {
            read_op = header.op;
            // Committed ops are below the read's own.
            if (as_of >= header.op) return error_reply(arena, 504, "as_of is not yet committed");
            if (min_op) |op| {
                if (op >= header.op) return error_reply(arena, 504, "min_op is not yet committed");
            }
            switch (header.state) {
                .ready => {},
                .missing => return error_reply(arena, 404, if (as_of != 0)
                    "the view was declared after as_of"
                else
                    "this view is not maintained by the state machine"),
                .building => return error_reply(arena, 503, "the view is still building"),
                .failed => return error_reply(arena, 503, "the view failed (a hash collision)"),
            }
            view_hash = header.hash;
            declared_op = header.declared_op;
        } else {
            assert(header.state == .ready);
            assert(std.mem.eql(u8, &header.hash, &view_hash));
        }
        if (groups.items.len + count - 1 > view_answer_groups_max) {
            return bad("the view has more groups than one answer holds: read it from /groups");
        }
        for (records[1..count]) |*record| {
            assert(record.kind == .group);
            var group: declared_views.Group = .{
                .sample = @splat(0),
                .count = record.count,
                .values = @splat(0),
            };
            // The group key's fields, placed back at their offsets.
            var key_offset: usize = 0;
            for (view.group_by) |field_name| {
                const field = layout.field(field_name).?;
                @memcpy(
                    group.sample[field.offset..][0..field.size],
                    record.group_key[key_offset..][0..field.size],
                );
                key_offset += field.size;
            }
            for (view.aggregates, 0..) |_, slot| {
                group.values[slot] = std.mem.readInt(i128, &record.sums[slot], .little);
            }
            try groups.append(arena, group);
        }
        if (!header.flags.more) break;
        cursor = header.cursor;
    }

    const answer = try declared_views.render(arena, &view, &layout, groups.items);
    var out = Writer.init(arena);
    try out.print("{{\"view\":\"{s}\",\"op\":", .{name});
    try out.number(if (as_of != 0) as_of else read_op.?);
    try out.raw(",\"hash\":");
    try out.hex(&answer.hash);
    try out.raw(",\"view_hash\":");
    try out.hex(&view_hash);
    try out.raw(",\"declared_op\":");
    try out.number(declared_op);
    try out.raw(",\"groups\":");
    try out.raw(answer.groups);
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

pub fn limit_parse(text: ?[]const u8) error{BadRequest}!u32 {
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
pub fn query_parse(
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

pub const Writer = struct {
    list: std.ArrayList(u8),

    pub fn init(arena: std.mem.Allocator) Writer {
        return .{ .list = std.ArrayList(u8).init(arena) };
    }

    pub fn items(writer: *const Writer) []const u8 {
        return writer.list.items;
    }

    pub fn raw(writer: *Writer, text: []const u8) !void {
        try writer.list.appendSlice(text);
    }

    pub fn print(writer: *Writer, comptime format: []const u8, args: anytype) !void {
        try writer.list.writer().print(format, args);
    }

    /// A 64-bit number, as a decimal string.
    pub fn number(writer: *Writer, value: u64) !void {
        try writer.print("\"{}\"", .{value});
    }

    /// An add's field value, as a decimal string of its type.
    fn field_value(writer: *Writer, field: nerva.Add.AddField, bits: u64) !void {
        switch (field) {
            .u64 => try writer.number(bits),
            .i64 => try writer.print("\"{}\"", .{@as(i64, @bitCast(bits))}),
            _ => unreachable,
        }
    }

    pub fn hex(writer: *Writer, bytes: []const u8) !void {
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
    /// Answers `declare_view`, for the tests that set it; the rest are covered by
    /// `tests/views/maintained.py`.
    declared: ?nerva.DeclareStatus = null,

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

    pub fn declare_view(
        fake: *FakeClient,
        _: *const nerva.ViewDefinition,
    ) Error!nerva.DeclareResult {
        fake.op += 1;
        const status = fake.declared.?;
        const known = status == .created or status == .exists;
        return .{
            .status = status,
            .view_id = @intFromBool(known),
            .op = if (known) fake.op else 0,
        };
    }

    pub fn get_view(_: *FakeClient, _: nerva.ViewQuery, _: []nerva.ViewRecord) Error!usize {
        unreachable; // Covered by `tests/views/maintained.py`.
    }

    pub fn declare_ledger(
        _: *FakeClient,
        _: *const nerva.LedgerDefinition,
    ) Error!nerva.DeclareLedgerResult {
        unreachable; // Covered by `tests/api/ledgers.py`.
    }

    pub fn get_ledger(_: *FakeClient, _: u32) Error!nerva.Ledger {
        unreachable; // Covered by `tests/api/ledgers.py`.
    }
};

/// An in-memory catalog.
const FakeLayouts = struct {
    map: std.AutoHashMapUnmanaged(u32, catalog.Layout) = .{},
    views: std.StringHashMapUnmanaged(catalog.View) = .{},
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

    pub fn view(fake: *FakeLayouts, _: std.mem.Allocator, name: []const u8) !?catalog.View {
        return fake.views.get(name);
    }

    pub fn view_put(
        fake: *FakeLayouts,
        arena: std.mem.Allocator,
        name: []const u8,
        new: *const catalog.View,
    ) !ViewPut {
        if (fake.views.get(name)) |old| {
            const same = std.mem.eql(
                u8,
                try catalog.view_render(arena, &old),
                try catalog.view_render(arena, new),
            );
            return if (same) .unchanged else .different;
        }
        try fake.views.put(fake.allocator, name, new.*);
        return .created;
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

test "api: a view is cataloged only under the definition the state machine holds (#70)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    var layouts: FakeLayouts = .{ .allocator = arena };
    const table =
        \\{"name":"t","fields":[{"name":"kind","type":"i64"},{"name":"amount","type":"i64"}]}
    ;
    const declared = try handle(arena, &fake, &layouts, .put, "/v1/tables/60", table);
    try testing.expectEqual(@as(u16, 200), declared.status);
    const by_kind =
        \\{"table":60,"group_by":["kind"],"aggregates":[{"fn":"count"}]}
    ;
    const total =
        \\{"table":60,"aggregates":[{"fn":"sum","field":"amount"}]}
    ;

    // Another gateway declared `v` as `by_kind` and has not yet written its document: this one,
    // declaring `total`, is refused and writes nothing.
    fake.declared = .different;
    const refused = try handle(arena, &fake, &layouts, .put, "/v1/views/v", total);
    try testing.expectEqual(@as(u16, 409), refused.status);
    try testing.expect(layouts.views.get("v") == null);
    // So is a view over a ledger's field.
    fake.declared = .ledger_field;
    const viewed = try handle(arena, &fake, &layouts, .put, "/v1/views/v", total);
    try testing.expectEqual(@as(u16, 409), viewed.status);
    try testing.expect(layouts.views.get("v") == null);
    // The other gateway's retry finds its view in the state machine and writes the document.
    fake.declared = .exists;
    const written = try handle(arena, &fake, &layouts, .put, "/v1/views/v", by_kind);
    try testing.expectEqual(@as(u16, 200), written.status);
    try testing.expect(layouts.views.get("v") != null);

    // A document cataloged while the table's views were full; a ledger then took its field. The
    // same PUT again answers as before, with the state machine's reason.
    fake.declared = .table_views_full;
    const cataloged = try handle(arena, &fake, &layouts, .put, "/v1/views/w", by_kind);
    try testing.expectEqual(@as(u16, 200), cataloged.status);
    try testing.expect(std.mem.indexOf(u8, cataloged.body, "\"maintained\":false") != null);
    fake.declared = .ledger_field;
    const again = try handle(arena, &fake, &layouts, .put, "/v1/views/w", by_kind);
    try testing.expectEqual(@as(u16, 200), again.status);
    try testing.expect(std.mem.indexOf(u8, again.body, "\"maintained\":false") != null);
    try testing.expect(std.mem.indexOf(u8, again.body, "a field of a ledger") != null);
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

test "api: documents are written, read, conflict and deleted by key" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };

    // 300 bytes: four chunks.
    const value_hex = "ab" ** 300;
    const put = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit",
        \\{"namespace":"7","reads":[{"key":"cart/1","version":"0"}],
        \\ "writes":[{"key":"cart/1","value_hex":"
    ++ value_hex ++
        \\"}]}
    );
    try testing.expectEqualStrings(
        \\{"status":"committed","op":"1"}
    , put.body);

    const get_body =
        \\{"namespace":"7","keys":["cart/1","cart/2"]}
    ;
    const found = try handle(arena, &fake, no_layouts, .post, "/v1/documents/get", get_body);
    try testing.expectEqualStrings(
        \\{"op":"2","documents":[{"key":"cart/1","exists":true,"version":"1","value_hex":"
    ++ value_hex ++
        \\"},{"key":"cart/2","exists":false,"version":"0","value_hex":""}]}
    , found.body);

    // Another namespace holds other documents.
    const other = try handle(arena, &fake, no_layouts, .post, "/v1/documents/get",
        \\{"namespace":"8","keys":["cart/1"]}
    );
    try testing.expect(std.mem.indexOf(u8, other.body, "\"exists\":false") != null);

    // A read at an old version conflicts, naming the key and its version; nothing applies.
    const stale = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit",
        \\{"namespace":"7","reads":[{"key":"cart/2","version":"0"},
        \\                          {"key":"cart/1","version":"0"}],
        \\ "writes":[{"key":"cart/2","value_hex":"01"}]}
    );
    try testing.expectEqual(@as(u16, 409), stale.status);
    try testing.expectEqualStrings(
        \\{"status":"conflict","key":"cart/1","version":"1"}
    , stale.body);

    // A delete is a write: the version moves on, and a read at it can commit.
    const deleted = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit",
        \\{"namespace":"7","reads":[{"key":"cart/1","version":"1"}],
        \\ "writes":[{"key":"cart/1","delete":true}]}
    );
    try testing.expectEqualStrings(
        \\{"status":"committed","op":"6"}
    , deleted.body);
    const gone = try handle(arena, &fake, no_layouts, .post, "/v1/documents/get", get_body);
    try testing.expectEqualStrings(
        \\{"op":"7","documents":[{"key":"cart/1","exists":false,"version":"6","value_hex":""},
    ++
        \\{"key":"cart/2","exists":false,"version":"0","value_hex":""}]}
    , gone.body);

    const refused = [_][]const u8{
        \\{"namespace":"7","keys":[]}
        ,
        \\{"namespace":"7","keys":["a","a"]}
        ,
        \\{"namespace":"7","keys":[""]}
        ,
        \\{"namespace":"-1","keys":["a"]}
        ,
        \\{"namespace":"7","keys":["a"],"as_of":"0"}
        ,
        \\{"namespace":"7","keys":["a"],"as_of":"99"}
        ,
        \\{"namespace":"7","keys":["
        ++ "k" ** 1025 ++
            \\"]}
    };
    for (refused) |body| {
        const reply = try handle(arena, &fake, no_layouts, .post, "/v1/documents/get", body);
        try testing.expectEqual(@as(u16, 400), reply.status);
    }
    const commit_refused = [_][]const u8{
        \\{"namespace":"7"}
        ,
        \\{"namespace":"7","writes":[{"key":"a"}]}
        ,
        \\{"namespace":"7","writes":[{"key":"a","value_hex":"00","delete":true}]}
        ,
        \\{"namespace":"7","writes":[{"key":"a","value_hex":"0"}]}
        ,
        \\{"namespace":"7","writes":[{"key":"a","delete":true},{"key":"a","delete":true}]}
        ,
        \\{"namespace":"7","reads":[{"key":"a","version":"1"},{"key":"a","version":"1"}]}
        ,
        \\{"namespace":"7","writes":[{"key":"\ud800","delete":true}]}
        ,
        \\{"namespace":"7","writes":[{"key":"a","value_hex":"
        ++ "00" ** (documents.value_size_max + 1) ++
            \\"}]}
    };
    for (commit_refused) |body| {
        const reply = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit", body);
        try testing.expectEqual(@as(u16, 400), reply.status);
    }
    // Nothing above was written; only the unanswerable `as_of` reached the cluster (a lookup).
    try testing.expectEqual(@as(u64, 8), fake.op);
}
