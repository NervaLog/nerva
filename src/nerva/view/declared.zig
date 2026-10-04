//! Declared views (docs/DECISIONS.md N35): views whose definition is data in the catalog, not
//! code. Maintained from the change feed by `nerva view`.
//!
//! The process keeps, in memory, the catalog (layouts and view declarations), every row of every
//! application table, and every change that produced them. A view is computed when read: over
//! the current rows for the latest answer, or over the rows replayed up to an op for an answer
//! as of that op. So a view declared now answers for any op, including ops before it existed.
//! Each answer carries the SHA-256 of its groups, so two processes can show they agree.
//!
//! v0 recomputes on read; incremental maintenance is a later step, and this stays its oracle.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.declared_views);

const nerva = @import("../../nerva.zig");
const catalog = @import("../catalog.zig");
const documents = @import("../documents.zig");

const Change = nerva.Change;
const value_size = nerva.value_size;

/// Changes kept in memory, across all tables. Past this the process stops (N35).
pub const history_max = 2_000_000;

pub const DeclaredViews = struct {
    allocator: std.mem.Allocator,

    /// Catalog rows (chunks), by id, and what they decode to.
    catalog_rows: std.AutoHashMapUnmanaged(u64, [value_size]u8) = .{},
    catalog_arena: std.heap.ArenaAllocator,
    layouts: std.AutoHashMapUnmanaged(u32, catalog.Layout) = .{},
    views: std.StringHashMapUnmanaged(catalog.View) = .{},

    tables: std.AutoHashMapUnmanaged(u32, *Table) = .{},
    change_count: u64 = 0,

    const Table = struct {
        /// Rows that exist now, by id.
        rows: std.AutoHashMapUnmanaged(u64, [value_size]u8) = .{},
        /// Every change, in op order.
        changes: std.ArrayListUnmanaged(Stored) = .{},
    };

    const Stored = struct { op: u64, id: u64, put: bool, value: [value_size]u8 };

    pub const Error = error{ OutOfMemory, HistoryFull };

    pub fn init(allocator: std.mem.Allocator) DeclaredViews {
        return .{
            .allocator = allocator,
            .catalog_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(views: *DeclaredViews) void {
        var tables = views.tables.valueIterator();
        while (tables.next()) |table| {
            table.*.rows.deinit(views.allocator);
            table.*.changes.deinit(views.allocator);
            views.allocator.destroy(table.*);
        }
        views.tables.deinit(views.allocator);
        views.views.deinit(views.allocator);
        views.layouts.deinit(views.allocator);
        views.catalog_rows.deinit(views.allocator);
        views.catalog_arena.deinit();
    }

    /// Applies one complete op (called by the follower, in op order).
    pub fn apply(views: *DeclaredViews, op: u64, changes: []const Change) Error!void {
        for (changes) |*change| {
            assert(change.op == op);
            if (change.table == catalog.table_catalog) {
                switch (change.kind) {
                    .put => try views.catalog_rows.put(views.allocator, change.id, change.value),
                    .delete => _ = views.catalog_rows.remove(change.id),
                    .end => unreachable,
                }
            } else if (table_viewable(change.table)) {
                try views.row_apply(change);
            }
        }
        // Then catalog documents, once all their chunks of this op are in.
        for (changes) |*change| {
            if (change.table != catalog.table_catalog or change.kind != .put) continue;
            try views.catalog_apply(change.id);
        }
    }

    fn row_apply(views: *DeclaredViews, change: *const Change) Error!void {
        if (views.change_count == history_max) {
            log.err("more than {} changes: declared views stop here (N35)", .{history_max});
            return error.HistoryFull;
        }
        const entry = try views.tables.getOrPut(views.allocator, change.table);
        if (!entry.found_existing) {
            entry.value_ptr.* = try views.allocator.create(Table);
            entry.value_ptr.*.* = .{};
        }
        const table = entry.value_ptr.*;
        switch (change.kind) {
            .put => try table.rows.put(views.allocator, change.id, change.value),
            .delete => _ = table.rows.remove(change.id),
            .end => unreachable,
        }
        try table.changes.append(views.allocator, .{
            .op = change.op,
            .id = change.id,
            .put = change.kind == .put,
            .value = change.value,
        });
        views.change_count += 1;
    }

    /// Decodes the catalog document whose chunk 0 is row `id`, if it is one.
    fn catalog_apply(views: *DeclaredViews, id: u64) Error!void {
        const arena = views.catalog_arena.allocator();
        const chunk0 = views.catalog_rows.get(id) orelse return;
        const count = documents.chunk0_count(&chunk0) catch return;
        const chunks = try arena.alloc([value_size]u8, count);
        chunks[0] = chunk0;
        for (chunks[1..], 1..) |*chunk, index| {
            chunk.* = views.catalog_rows.get(documents.tail_id(id, @intCast(index))) orelse
                return;
        }
        const decoded = documents.chunks_decode(arena, chunks) catch return;
        // A tail chunk can look like a header; only a true chunk 0 hashes back to its own id.
        if (documents.row_id(decoded.namespace, decoded.key) != id) return;
        // The catalog never deletes; a tombstone is not a declaration.
        const value = decoded.value orelse return;

        if (std.mem.startsWith(u8, decoded.key, "table.")) {
            const table = std.fmt.parseInt(u32, decoded.key["table.".len..], 10) catch return;
            const layout = catalog.layout_parse(arena, value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => return log.warn("{s}: invalid layout", .{decoded.key}),
            };
            try views.layouts.put(views.allocator, table, layout);
        } else if (std.mem.startsWith(u8, decoded.key, "view.")) {
            const view = catalog.view_parse(arena, value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => return log.warn("{s}: invalid view", .{decoded.key}),
            };
            try views.views.put(views.allocator, decoded.key["view.".len..], view);
        }
    }

    pub const Result = struct {
        /// A JSON array of groups, sorted by group key.
        groups: []const u8,
        /// SHA-256 of `groups`.
        hash: [32]u8,
    };

    pub const ComputeError = error{ OutOfMemory, NoSuchView, NoLayout, Invalid };

    /// The view as of `as_of` (null: the latest op applied).
    pub fn compute(
        views: *const DeclaredViews,
        arena: std.mem.Allocator,
        name: []const u8,
        as_of: ?u64,
    ) ComputeError!Result {
        const view = views.views.getPtr(name) orelse return error.NoSuchView;
        const layout = views.layouts.getPtr(view.table) orelse return error.NoLayout;
        try catalog.view_check(view, layout);

        const empty: Table = .{};
        const table = views.tables.get(view.table) orelse &empty;
        var replayed: std.AutoHashMapUnmanaged(u64, [value_size]u8) = .{};
        const rows = if (as_of) |op| rows: {
            for (table.changes.items) |*stored| {
                if (stored.op > op) break;
                if (stored.put) {
                    try replayed.put(arena, stored.id, stored.value);
                } else {
                    _ = replayed.remove(stored.id);
                }
            }
            break :rows &replayed;
        } else &table.rows;

        return aggregate(arena, view, layout, rows);
    }

    pub fn view_names(views: *const DeclaredViews, arena: std.mem.Allocator) ![]const []const u8 {
        const names = try arena.alloc([]const u8, views.views.count());
        var iterator = views.views.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |name| : (index += 1) names[index] = name.*;
        std.mem.sortUnstable([]const u8, names, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        return names;
    }
};

/// Tables a declared view may read: any but Nerva's own.
fn table_viewable(table: u32) bool {
    return table < catalog.tables_reserved_min;
}

const Group = struct {
    /// A row of the group: its key fields are the group's key.
    sample: [value_size]u8,
    count: u64,
    /// Per aggregate: the running sum, min or max (count uses `count`).
    values: [catalog.aggregates_max]i128,
};

fn aggregate(
    arena: std.mem.Allocator,
    view: *const catalog.View,
    layout: *const catalog.Layout,
    rows: *const std.AutoHashMapUnmanaged(u64, [value_size]u8),
) !DeclaredViews.Result {
    // The order rows are visited in does not matter: every aggregate is commutative, and groups
    // are sorted before they are rendered.
    var groups: std.StringArrayHashMapUnmanaged(Group) = .{};
    var key_buffer: [value_size * catalog.group_by_max]u8 = undefined;
    var iterator = rows.valueIterator();
    rows: while (iterator.next()) |value| {
        for (view.where) |clause| {
            const field = layout.field(clause.field).?;
            const actual = catalog.field_integer(field, value).?;
            const keep = switch (clause.op) {
                .eq => actual == clause.value,
                .ne => actual != clause.value,
                .lt => actual < clause.value,
                .le => actual <= clause.value,
                .gt => actual > clause.value,
                .ge => actual >= clause.value,
            };
            if (!keep) continue :rows;
        }
        var key_size: usize = 0;
        for (view.group_by) |name| {
            const field = layout.field(name).?;
            @memcpy(key_buffer[key_size..][0..field.size], value[field.offset..][0..field.size]);
            key_size += field.size;
        }
        const entry = try groups.getOrPut(arena, key_buffer[0..key_size]);
        if (!entry.found_existing) {
            entry.key_ptr.* = try arena.dupe(u8, key_buffer[0..key_size]);
            entry.value_ptr.* = .{ .sample = value.*, .count = 0, .values = @splat(0) };
        }
        const group = entry.value_ptr;
        group.count += 1;
        for (view.aggregates, 0..) |aggregate_, index| {
            const field = layout.field(aggregate_.field orelse continue).?;
            const number = catalog.field_integer(field, value).?;
            const slot = &group.values[index];
            switch (aggregate_.function) {
                .count => unreachable,
                .sum => slot.* += number,
                .min => slot.* = if (group.count == 1) number else @min(slot.*, number),
                .max => slot.* = if (group.count == 1) number else @max(slot.*, number),
            }
        }
    }

    const Context = struct {
        view: *const catalog.View,
        layout: *const catalog.Layout,
        groups: []const Group,

        pub fn lessThan(context: @This(), a: usize, b: usize) bool {
            for (context.view.group_by) |name| {
                const field = context.layout.field(name).?;
                const sample_a = &context.groups[a].sample;
                const sample_b = &context.groups[b].sample;
                const order = if (field.type == .bytes) std.mem.order(
                    u8,
                    sample_a[field.offset..][0..field.size],
                    sample_b[field.offset..][0..field.size],
                ) else std.math.order(
                    catalog.field_integer(field, sample_a).?,
                    catalog.field_integer(field, sample_b).?,
                );
                if (order != .eq) return order == .lt;
            }
            return false;
        }
    };
    // Unstable is fine (group keys are unique), and `sort` is insertion sort: O(n²).
    groups.sortUnstable(Context{ .view = view, .layout = layout, .groups = groups.values() });

    var out = std.ArrayList(u8).init(arena);
    const writer = out.writer();
    try writer.writeAll("[");
    for (groups.values(), 0..) |*group, group_index| {
        if (group_index > 0) try writer.writeAll(",");
        try writer.writeAll("{");
        for (view.group_by) |name| {
            try writer.print("\"{s}\":", .{name});
            try catalog.field_render(writer, layout.field(name).?, &group.sample);
            try writer.writeAll(",");
        }
        for (view.aggregates, 0..) |aggregate_, index| {
            if (index > 0) try writer.writeAll(",");
            if (aggregate_.field) |name| {
                try writer.print("\"{s}_{s}\":\"{}\"", .{
                    @tagName(aggregate_.function),
                    name,
                    group.values[index],
                });
            } else {
                try writer.print("\"count\":\"{}\"", .{group.count});
            }
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.items, &hash, .{});
    return .{ .groups = out.items, .hash = hash };
}

const testing = std.testing;

test "declared views: group, filter, aggregate, as of, catalog from chunked rows" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var views = DeclaredViews.init(testing.allocator);
    defer views.deinit();

    const layout_json =
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},
        \\  {"name":"sold","type":"bool"}]}
    ;
    const view_json =
        \\{"table":5,"where":[{"field":"sold","op":"eq","value":true}],"group_by":["section"],
        \\ "aggregates":[{"fn":"count"},{"fn":"sum","field":"price"},{"fn":"max","field":"price"}]}
    ;
    const layout = try catalog.layout_parse(arena, layout_json);

    var op: u64 = 1;
    var timestamp: u64 = 1;
    // Catalog documents, written as the API writes them (chunked, chunk 0 last).
    for ([_][2][]const u8{
        .{ "table.5", try catalog.layout_render(arena, &layout) },
        .{ "view.revenue", view_json },
    }) |document| {
        const chunks = try documents.chunks_encode(arena, 0, document[0], document[1]);
        var changes = std.ArrayList(Change).init(arena);
        var index = chunks.len;
        while (index > 0) {
            index -= 1;
            try changes.append(.{
                .id = documents.chunk_id(0, document[0], @intCast(index)),
                .table = catalog.table_catalog,
                .kind = .put,
                .flags = .{},
                .op = op,
                .timestamp = timestamp,
                .value = chunks[index],
            });
            timestamp += 1;
        }
        try views.apply(op, changes.items);
        op += 1;
    }

    const Seat = struct { id: u64, section: u8, price: u64, sold: bool };
    const seat = struct {
        fn change(layout_: *const catalog.Layout, s: Seat, op_: u64, ts: u64) !Change {
            var buffer: [128]u8 = undefined;
            const json = try std.fmt.bufPrint(
                &buffer,
                "{{\"section\":{},\"price\":\"{}\",\"sold\":{}}}",
                .{ s.section, s.price, s.sold },
            );
            var arena_ = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena_.deinit();
            const allocator = arena_.allocator();
            const object = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
            return .{
                .id = s.id,
                .table = 5,
                .kind = .put,
                .flags = .{},
                .op = op_,
                .timestamp = ts,
                .value = try catalog.fields_encode(layout_, object),
            };
        }
    }.change;

    // op 3: four seats, two sold. op 4: one more sold, one unsold deleted.
    const op_first = op;
    try views.apply(op, &.{
        try seat(&layout, .{ .id = 1, .section = 2, .price = 100, .sold = true }, op, 10),
        try seat(&layout, .{ .id = 2, .section = 1, .price = 50, .sold = true }, op, 11),
        try seat(&layout, .{ .id = 3, .section = 2, .price = 70, .sold = false }, op, 12),
        try seat(&layout, .{ .id = 4, .section = 1, .price = 60, .sold = false }, op, 13),
    });
    op += 1;
    const unsold: Seat = .{ .id = 4, .section = 1, .price = 60, .sold = false };
    var delete: Change = try seat(&layout, unsold, op, 15);
    delete.kind = .delete;
    delete.value = @splat(0);
    try views.apply(op, &.{
        try seat(&layout, .{ .id = 3, .section = 2, .price = 70, .sold = true }, op, 14),
        delete,
    });

    const latest = try views.compute(arena, "revenue", null);
    try testing.expectEqualStrings(
        \\[{"section":1,"count":"1","sum_price":"50","max_price":"50"},
    ++
        \\{"section":2,"count":"2","sum_price":"170","max_price":"100"}]
    , latest.groups);
    const before = try views.compute(arena, "revenue", op_first);
    try testing.expectEqualStrings(
        \\[{"section":1,"count":"1","sum_price":"50","max_price":"50"},
    ++
        \\{"section":2,"count":"1","sum_price":"100","max_price":"100"}]
    , before.groups);
    // Before any seat: no groups; and the view answers there though declared later.
    const empty = try views.compute(arena, "revenue", 1);
    try testing.expectEqualStrings("[]", empty.groups);

    // As of the latest op equals the latest; the hash is a function of the groups.
    const replayed = try views.compute(arena, "revenue", op);
    try testing.expectEqualSlices(u8, &latest.hash, &replayed.hash);
    try testing.expect(!std.mem.eql(u8, &latest.hash, &before.hash));
    try testing.expectError(error.NoSuchView, views.compute(arena, "nope", null));
}

test "declared views: invalid declarations are refused" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const layout = try catalog.layout_parse(arena,
        \\{"name":"t","fields":[{"name":"a","type":"u8"},{"name":"b","type":"bytes","size":4}]}
    );
    const refused_at_parse = [_][]const u8{
        \\{"table":0,"aggregates":[{"fn":"count"}]}
        ,
        \\{"table":5,"aggregates":[]}
        ,
        \\{"table":5,"aggregates":[{"fn":"count","field":"a"}]}
        ,
        \\{"table":5,"aggregates":[{"fn":"sum"}]}
        ,
        \\{"table":5,"aggregates":[{"fn":"count"},{"fn":"count"}]}
        ,
        \\{"table":5,"group_by":["a","a"],"aggregates":[{"fn":"count"}]}
        ,
        \\{"table":5,"where":[{"field":"a","op":"like","value":1}],"aggregates":[{"fn":"count"}]}
        ,
        \\{"table":5,"aggregates":[{"fn":"avg","field":"a"}]}
    };
    for (refused_at_parse) |json| {
        try testing.expectError(error.Invalid, catalog.view_parse(arena, json));
    }
    const refused_at_check = [_][]const u8{
        \\{"table":5,"where":[{"field":"z","op":"eq","value":1}],"aggregates":[{"fn":"count"}]}
        ,
        \\{"table":5,"where":[{"field":"b","op":"eq","value":1}],"aggregates":[{"fn":"count"}]}
        ,
        \\{"table":5,"group_by":["z"],"aggregates":[{"fn":"count"}]}
        ,
        \\{"table":5,"aggregates":[{"fn":"sum","field":"b"}]}
    };
    for (refused_at_check) |json| {
        const view = try catalog.view_parse(arena, json);
        try testing.expectError(error.Invalid, catalog.view_check(&view, &layout));
    }
    // Grouping by bytes is fine; the canonical form parses back to itself.
    const view = try catalog.view_parse(arena,
        \\{"table":5,"where":[{"field":"a","op":"ge","value":"2"}],"group_by":["b"],
        \\ "aggregates":[{"fn":"count"},{"fn":"min","field":"a"}]}
    );
    try catalog.view_check(&view, &layout);
    const stored = try catalog.view_render(arena, &view);
    const reparsed = try catalog.view_parse(arena, stored);
    try testing.expectEqualStrings(stored, try catalog.view_render(arena, &reparsed));
}
