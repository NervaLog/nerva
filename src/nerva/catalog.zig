//! The catalog: declared table layouts and views, stored in the log (docs/DECISIONS.md N34,
//! N35).
//!
//! A layout names the fields packed into a table's 80-byte values, so that the JSON API can take
//! and return `fields` and views can group and aggregate by field. The core never reads layouts:
//! it stores bytes. Layouts are metadata for readers and writers that choose to use them.
//!
//! Fields are packed in declaration order, each aligned to its own size (bytes fields to 1),
//! little-endian. A layout may only grow by appending fields, so data written under an earlier
//! layout reads the same under a later one (new fields read as zero).

const std = @import("std");
const assert = std.debug.assert;

const nerva = @import("../nerva.zig");

const value_size = nerva.value_size;

/// Tables at or above this are Nerva's own; the API refuses to read or write them directly.
pub const tables_reserved_min: u32 = 0xFFFF_0000;
/// Catalog documents (`documents.zig`, namespace 0), keyed `table.<id>` and `view.<name>`.
pub const table_catalog: u32 = 0xFFFF_0001;
/// Applications' documents (`documents.zig`, any namespace), through `/v1/documents/*` (N41).
pub const table_documents: u32 = 0xFFFF_0002;

pub const fields_max = 16;
pub const name_size_max = 32;

pub const FieldType = enum {
    u8,
    u16,
    u32,
    u64,
    i64,
    bool,
    /// Fixed-size raw bytes (`size`, 1..80), as hex in JSON.
    bytes,

    fn size(field_type: FieldType) ?u8 {
        return switch (field_type) {
            .u8, .bool => 1,
            .u16 => 2,
            .u32 => 4,
            .u64, .i64 => 8,
            .bytes => null,
        };
    }
};

pub const Field = struct {
    name: []const u8,
    type: FieldType,
    size: u8,
    offset: u8,
};

pub const Layout = struct {
    /// A label for people; not an identifier.
    name: []const u8,
    fields: []const Field,

    pub fn field(layout: *const Layout, name: []const u8) ?*const Field {
        for (layout.fields) |*candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }
};

pub const Error = error{ OutOfMemory, Invalid };

/// The reason for the last `error.Invalid` (one thread).
pub var invalid_reason: []const u8 = "";

fn invalid(reason: []const u8) error{Invalid} {
    invalid_reason = reason;
    return error.Invalid;
}

/// Parses a declaration, `{"name": "...", "fields": [{"name": "...", "type": "u64"}, …]}` (a
/// `bytes` field also has `"size"`), and computes offsets.
pub fn layout_parse(arena: std.mem.Allocator, json: []const u8) Error!Layout {
    const Declaration = struct {
        name: []const u8,
        fields: []const struct { name: []const u8, type: FieldType, size: ?u8 = null },
    };
    const declaration = std.json.parseFromSliceLeaky(Declaration, arena, json, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return invalid("a layout is {\"name\", \"fields\": [{\"name\", \"type\"}]}"),
        };
    if (declaration.name.len == 0 or declaration.name.len > 64) {
        return invalid("the layout name must be 1 to 64 bytes");
    }
    if (declaration.fields.len == 0) return invalid("a layout needs at least one field");
    if (declaration.fields.len > fields_max) return invalid("a layout has at most 16 fields");

    const fields = try arena.alloc(Field, declaration.fields.len);
    var offset: usize = 0;
    for (fields, declaration.fields, 0..) |*field, declared, index| {
        try name_validate(declared.name);
        for (declaration.fields[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, declared.name)) return invalid("duplicate field");
        }
        const size: u8 = if (declared.type.size()) |size| size: {
            if (declared.size != null) return invalid("only a bytes field has a size");
            break :size size;
        } else size: {
            const size = declared.size orelse return invalid("a bytes field needs a size");
            if (size == 0 or size > value_size) return invalid("a bytes field is 1 to 80 bytes");
            break :size size;
        };
        const alignment: usize = if (declared.type == .bytes) 1 else size;
        offset = std.mem.alignForward(usize, offset, alignment);
        if (offset + size > value_size) return invalid("the fields do not fit in 80 bytes");
        field.* = .{
            .name = declared.name,
            .type = declared.type,
            .size = size,
            .offset = @intCast(offset),
        };
        offset += size;
    }
    return .{ .name = declaration.name, .fields = fields };
}

fn name_validate(name: []const u8) error{Invalid}!void {
    if (name.len == 0 or name.len > name_size_max) {
        return invalid("a field name is 1 to 32 bytes");
    }
    for (name, 0..) |c, index| {
        const ok = c == '_' or (c >= 'a' and c <= 'z') or (index > 0 and c >= '0' and c <= '9');
        if (!ok) return invalid("a field name is lowercase letters, digits and _");
    }
}

/// The layout as stored: the declaration, re-rendered canonically.
pub fn layout_render(arena: std.mem.Allocator, layout: *const Layout) Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    const writer = out.writer();
    try writer.writeAll("{\"name\":");
    try std.json.stringify(layout.name, .{}, writer);
    try writer.writeAll(",\"fields\":[");
    for (layout.fields, 0..) |field, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"name\":\"{s}\",\"type\":\"{s}\"", .{
            field.name,
            @tagName(field.type),
        });
        if (field.type == .bytes) try writer.print(",\"size\":{}", .{field.size});
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
    return out.items;
}

/// Whether `new` keeps every field of `old` where it was (it may only append).
pub fn layout_extends(old: *const Layout, new: *const Layout) bool {
    if (new.fields.len < old.fields.len) return false;
    for (old.fields, new.fields[0..old.fields.len]) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or a.type != b.type or a.size != b.size) return false;
        assert(a.offset == b.offset);
    }
    return true;
}

/// Encodes a JSON object of fields. Absent fields are zero; unknown fields are refused.
/// 64-bit integers may be numbers or decimal strings; bytes are hex.
pub fn fields_encode(layout: *const Layout, object: std.json.Value) error{Invalid}![value_size]u8 {
    if (object != .object) return invalid("fields must be an object");
    var value: [value_size]u8 = @splat(0);
    var iterator = object.object.iterator();
    while (iterator.next()) |entry| {
        const field = layout.field(entry.key_ptr.*) orelse return invalid("unknown field");
        const slot = value[field.offset..][0..field.size];
        switch (field.type) {
            .bool => slot[0] = switch (entry.value_ptr.*) {
                .bool => |b| @intFromBool(b),
                else => return invalid("a bool field takes true or false"),
            },
            .bytes => {
                const text = switch (entry.value_ptr.*) {
                    .string => |s| s,
                    else => return invalid("a bytes field takes a hex string"),
                };
                if (text.len % 2 != 0 or text.len / 2 > field.size) {
                    return invalid("a bytes field takes at most its size in hex");
                }
                _ = std.fmt.hexToBytes(slot[0 .. text.len / 2], text) catch
                    return invalid("a bytes field takes a hex string");
            },
            inline .u8, .u16, .u32, .u64, .i64 => |tag| {
                const signedness: std.builtin.Signedness = if (tag == .i64) .signed else .unsigned;
                const Int = std.meta.Int(signedness, @as(u16, tag.size().?) * 8);
                const number = try integer_parse(Int, entry.value_ptr.*);
                std.mem.writeInt(Int, slot[0..@sizeOf(Int)], number, .little);
            },
        }
    }
    return value;
}

fn integer_parse(comptime Int: type, json: std.json.Value) error{Invalid}!Int {
    return switch (json) {
        .integer => |n| std.math.cast(Int, n) orelse invalid("a number is out of range"),
        .string => |text| text: {
            if (text.len == 0 or text.len > 20) break :text invalid("a number is malformed");
            for (text, 0..) |c, index| {
                if (!(c >= '0' and c <= '9') and !(c == '-' and index == 0 and text.len > 1)) {
                    break :text invalid("a number is malformed");
                }
            }
            break :text std.fmt.parseInt(Int, text, 10) catch invalid("a number is out of range");
        },
        // Larger than i64: only a decimal string can carry it.
        .number_string => |text| std.fmt.parseInt(Int, text, 10) catch
            invalid("a number is out of range"),
        else => invalid("an integer field takes a number or a decimal string"),
    };
}

/// Writes the fields of `value` as a JSON object. 64-bit integers are decimal strings (N33).
pub fn fields_render(writer: anytype, layout: *const Layout, value: *const [value_size]u8) !void {
    try writer.writeAll("{");
    for (layout.fields, 0..) |*field, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("\"{s}\":", .{field.name});
        try field_render(writer, field, value);
    }
    try writer.writeAll("}");
}

/// Writes one field's value as JSON.
pub fn field_render(writer: anytype, field: *const Field, value: *const [value_size]u8) !void {
    const slot = value[field.offset..][0..field.size];
    switch (field.type) {
        .bool => try writer.writeAll(if (slot[0] != 0) "true" else "false"),
        .u8 => try writer.print("{}", .{slot[0]}),
        .u16 => try writer.print("{}", .{std.mem.readInt(u16, slot[0..2], .little)}),
        .u32 => try writer.print("{}", .{std.mem.readInt(u32, slot[0..4], .little)}),
        .u64 => try writer.print("\"{}\"", .{std.mem.readInt(u64, slot[0..8], .little)}),
        .i64 => try writer.print("\"{}\"", .{std.mem.readInt(i64, slot[0..8], .little)}),
        .bytes => try writer.print("\"{s}\"", .{std.fmt.fmtSliceHexLower(slot)}),
    }
}

// ---- Views (N35) ----

pub const where_max = 4;
pub const group_by_max = 3;
pub const aggregates_max = 6;

pub const Comparison = enum { eq, ne, lt, le, gt, ge };
pub const Aggregate = enum { count, sum, min, max };

/// A declared view: over the rows of `table` as they are at an op, keep those matching every
/// `where`, group them by `group_by`, and compute `aggregates` per group.
pub const View = struct {
    table: u32,
    where: []const struct { field: []const u8, op: Comparison, value: i128 },
    group_by: []const []const u8,
    aggregates: []const struct { function: Aggregate, field: ?[]const u8 },
};

pub fn view_name_validate(name: []const u8) error{Invalid}!void {
    return name_validate(name);
}

/// Parses a declaration: `{"table": 5, "where": [{"field", "op", "value"}], "group_by": […],
/// "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"}]}`. `where` and `group_by`
/// may be omitted. Field names are checked against a layout by `view_check`.
pub fn view_parse(arena: std.mem.Allocator, json: []const u8) Error!View {
    const Declaration = struct {
        table: u32,
        where: []const struct { field: []const u8, op: Comparison, value: std.json.Value } = &.{},
        group_by: []const []const u8 = &.{},
        aggregates: []const struct { @"fn": Aggregate, field: ?[]const u8 = null },
    };
    const declaration = std.json.parseFromSliceLeaky(Declaration, arena, json, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return invalid(
                "a view is {\"table\", \"where\": [{\"field\", \"op\", \"value\"}], " ++
                    "\"group_by\": [field], \"aggregates\": [{\"fn\", \"field\"}]}",
            ),
        };
    if (declaration.table == 0 or declaration.table >= tables_reserved_min) {
        return invalid("the view's table is out of range");
    }
    if (declaration.where.len > where_max) return invalid("a view has at most 4 where clauses");
    if (declaration.group_by.len > group_by_max) {
        return invalid("a view groups by at most 3 fields");
    }
    if (declaration.aggregates.len == 0 or declaration.aggregates.len > aggregates_max) {
        return invalid("a view has 1 to 6 aggregates");
    }

    const Clause = @typeInfo(@FieldType(View, "where")).pointer.child;
    const where = try arena.alloc(Clause, declaration.where.len);
    for (where, declaration.where) |*clause, declared| {
        clause.* = .{
            .field = declared.field,
            .op = declared.op,
            .value = switch (declared.value) {
                .bool => |b| @intFromBool(b),
                else => try integer_parse(i128, declared.value),
            },
        };
    }
    for (declaration.group_by, 0..) |name, index| {
        for (declaration.group_by[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, name)) return invalid("a view groups by a field once");
        }
    }
    const aggregates = try arena.alloc(
        @typeInfo(@FieldType(View, "aggregates")).pointer.child,
        declaration.aggregates.len,
    );
    for (aggregates, declaration.aggregates, 0..) |*aggregate, declared, index| {
        if ((declared.@"fn" == .count) != (declared.field == null)) {
            return invalid("count has no field; sum, min and max need one");
        }
        aggregate.* = .{ .function = declared.@"fn", .field = declared.field };
        for (aggregates[0..index]) |earlier| {
            const same_field = if (earlier.field) |a|
                (if (aggregate.field) |b| std.mem.eql(u8, a, b) else false)
            else
                aggregate.field == null;
            if (earlier.function == aggregate.function and same_field) {
                return invalid("a view computes each aggregate once");
            }
        }
    }
    return .{
        .table = declaration.table,
        .where = where,
        .group_by = declaration.group_by,
        .aggregates = aggregates,
    };
}

/// Checks a view's fields against its table's layout: `where`, `sum`, `min` and `max` need
/// numeric (or bool) fields; `group_by` takes any field.
pub fn view_check(view: *const View, layout: *const Layout) error{Invalid}!void {
    for (view.where) |clause| {
        const field = layout.field(clause.field) orelse return invalid("unknown field in where");
        if (field.type == .bytes) return invalid("where compares numbers and bools only");
    }
    for (view.group_by) |name| {
        _ = layout.field(name) orelse return invalid("unknown field in group_by");
    }
    for (view.aggregates) |aggregate| {
        const name = aggregate.field orelse continue;
        const field = layout.field(name) orelse return invalid("unknown field in aggregates");
        if (field.type == .bytes) return invalid("sum, min and max take numbers only");
    }
}

/// The view as stored: canonical JSON.
pub fn view_render(arena: std.mem.Allocator, view: *const View) Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    const writer = out.writer();
    try writer.print("{{\"table\":{},\"where\":[", .{view.table});
    for (view.where, 0..) |clause, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"field\":\"{s}\",\"op\":\"{s}\",\"value\":\"{}\"}}", .{
            clause.field,
            @tagName(clause.op),
            clause.value,
        });
    }
    try writer.writeAll("],\"group_by\":[");
    for (view.group_by, 0..) |name, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("\"{s}\"", .{name});
    }
    try writer.writeAll("],\"aggregates\":[");
    for (view.aggregates, 0..) |aggregate, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"fn\":\"{s}\"", .{@tagName(aggregate.function)});
        if (aggregate.field) |name| try writer.print(",\"field\":\"{s}\"", .{name});
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
    return out.items;
}

/// A field's value as a signed 128-bit integer, for views to compare and sum. Bytes fields have
/// no numeric value.
pub fn field_integer(field: *const Field, value: *const [value_size]u8) ?i128 {
    const slot = value[field.offset..][0..field.size];
    return switch (field.type) {
        .bool, .u8 => slot[0],
        .u16 => std.mem.readInt(u16, slot[0..2], .little),
        .u32 => std.mem.readInt(u32, slot[0..4], .little),
        .u64 => std.mem.readInt(u64, slot[0..8], .little),
        .i64 => std.mem.readInt(i64, slot[0..8], .little),
        .bytes => null,
    };
}

const testing = std.testing;

/// The view as the state machine maintains it (N49): its fields resolved to offsets through the
/// table's layout. `view_check` must have passed.
pub fn view_definition(
    name: []const u8,
    view: *const View,
    layout: *const Layout,
) nerva.ViewDefinition {
    assert(name.len > 0 and name.len <= name_size_max);
    var definition = std.mem.zeroes(nerva.ViewDefinition);
    @memcpy(definition.name[0..name.len], name);
    definition.table = view.table;
    definition.where_count = @intCast(view.where.len);
    for (view.where, 0..) |clause, index| {
        definition.where[index] = .{
            .field = field_ref(layout.field(clause.field).?),
            .comparison = switch (clause.op) {
                inline else => |comparison| @field(nerva.Comparison, @tagName(comparison)),
            },
            .value = std.mem.toBytes(std.mem.nativeToLittle(i128, clause.value)),
        };
    }
    definition.group_by_count = @intCast(view.group_by.len);
    for (view.group_by, 0..) |field_name, index| {
        definition.group_by[index] = field_ref(layout.field(field_name).?);
    }
    definition.aggregate_count = @intCast(view.aggregates.len);
    for (view.aggregates, 0..) |aggregate, index| {
        definition.aggregates[index] = .{
            .function = switch (aggregate.function) {
                inline else => |function| @field(nerva.AggregateFunction, @tagName(function)),
            },
            .field = if (aggregate.field) |field_name|
                field_ref(layout.field(field_name).?)
            else
                std.mem.zeroes(nerva.FieldRef),
        };
    }
    return definition;
}

fn field_ref(field: *const Field) nerva.FieldRef {
    return .{
        .offset = field.offset,
        .size = field.size,
        .kind = switch (field.type) {
            .u8, .u16, .u32, .u64 => .unsigned,
            .i64 => .signed,
            .bool => .boolean,
            .bytes => .bytes,
        },
    };
}

test "catalog: layouts pack, align, extend and round-trip" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const seats = try layout_parse(arena,
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},
        \\  {"name":"sold","type":"bool"},{"name":"holder","type":"bytes","size":16}]}
    );
    try testing.expectEqual(@as(u8, 0), seats.fields[0].offset);
    try testing.expectEqual(@as(u8, 8), seats.fields[1].offset); // Aligned to 8.
    try testing.expectEqual(@as(u8, 16), seats.fields[2].offset);
    try testing.expectEqual(@as(u8, 17), seats.fields[3].offset); // Bytes are not aligned.

    // Stored canonically, and the stored form parses to the same layout.
    const stored = try layout_render(arena, &seats);
    const again = try layout_parse(arena, stored);
    try testing.expectEqualStrings(stored, try layout_render(arena, &again));

    // Appending is an extension; anything else is not.
    const more = try layout_parse(arena,
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},
        \\  {"name":"sold","type":"bool"},{"name":"holder","type":"bytes","size":16},
        \\  {"name":"row","type":"u16"}]}
    );
    try testing.expect(layout_extends(&seats, &more));
    try testing.expect(!layout_extends(&more, &seats));
    const changed = try layout_parse(arena,
        \\{"name":"seats","fields":[{"name":"section","type":"u16"}]}
    );
    try testing.expect(!layout_extends(&seats, &changed));

    // Fields round-trip; absent fields are zero; 64-bit as strings or numbers.
    const object = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"section":3,"price":"18446744073709551615","holder":"abcd","sold":true}
    , .{});
    const value = try fields_encode(&seats, object);
    var out = std.ArrayList(u8).init(arena);
    try fields_render(out.writer(), &seats, &value);
    try testing.expectEqualStrings(
        \\{"section":3,"price":"18446744073709551615","sold":true,"holder":"abcd
    ++ "00" ** 14 ++
        \\"}
    , out.items);
    try testing.expectEqual(@as(?i128, 3), field_integer(seats.field("section").?, &value));
    try testing.expectEqual(null, field_integer(seats.field("holder").?, &value));
}

test "catalog: invalid layouts and fields are refused" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const layouts = [_][]const u8{
        \\{"name":"t","fields":[]}
        ,
        \\{"name":"","fields":[{"name":"a","type":"u8"}]}
        ,
        \\{"name":"t","fields":[{"name":"a","type":"u8"},{"name":"a","type":"u8"}]}
        ,
        \\{"name":"t","fields":[{"name":"A","type":"u8"}]}
        ,
        \\{"name":"t","fields":[{"name":"1a","type":"u8"}]}
        ,
        \\{"name":"t","fields":[{"name":"a","type":"f64"}]}
        ,
        \\{"name":"t","fields":[{"name":"a","type":"bytes"}]}
        ,
        \\{"name":"t","fields":[{"name":"a","type":"u8","size":1}]}
        ,
        \\{"name":"t","fields":[{"name":"a","type":"bytes","size":80},{"name":"b","type":"u8"}]}
        ,
        \\{"name":"t","fields":[{"name":"a","type":"u8"}],"x":1}
    };
    for (layouts) |json| {
        try testing.expectError(error.Invalid, layout_parse(arena, json));
    }

    const layout = try layout_parse(arena,
        \\{"name":"t","fields":[{"name":"a","type":"u8"},{"name":"b","type":"bytes","size":2},
        \\  {"name":"c","type":"i64"},{"name":"d","type":"bool"}]}
    );
    const objects = [_][]const u8{
        \\[]
        ,
        \\{"z":1}
        ,
        \\{"a":256}
        ,
        \\{"a":-1}
        ,
        \\{"a":"1x"}
        ,
        \\{"a":1.5}
        ,
        \\{"b":"abcdef"}
        ,
        \\{"b":"zz"}
        ,
        \\{"c":"9223372036854775808"}
        ,
        \\{"d":1}
    };
    for (objects) |json| {
        const object = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
        try testing.expectError(error.Invalid, fields_encode(&layout, object));
    }
    const negative = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"c":"-5"}
    , .{});
    const value = try fields_encode(&layout, negative);
    try testing.expectEqual(@as(?i128, -5), field_integer(layout.field("c").?, &value));
}

test "catalog: a view resolves to the state machine's definition through its layout" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const layout = try layout_parse(arena,
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},
        \\{"name":"sold","type":"bool"},{"name":"balance","type":"i64"}]}
    );
    const view = try view_parse(arena,
        \\{"table":5,"where":[{"field":"sold","op":"eq","value":true},
        \\{"field":"balance","op":"lt","value":-3}],"group_by":["section"],
        \\"aggregates":[{"fn":"count"},{"fn":"sum","field":"price"}]}
    );
    try view_check(&view, &layout);
    const definition = view_definition("revenue", &view, &layout);

    try testing.expectEqualStrings("revenue", definition.name[0..7]);
    try testing.expectEqual(@as(u32, 5), definition.table);
    try testing.expectEqual(@as(u8, 2), definition.where_count);
    try testing.expectEqual(nerva.FieldRef{ .offset = 16, .size = 1, .kind = .boolean }, definition.where[0].field);
    try testing.expectEqual(nerva.Comparison.lt, definition.where[1].comparison);
    try testing.expectEqual(nerva.FieldKind.signed, definition.where[1].field.kind);
    try testing.expectEqual(@as(i128, -3), std.mem.readInt(i128, &definition.where[1].value, .little));
    try testing.expectEqual(nerva.FieldRef{ .offset = 0, .size = 1, .kind = .unsigned }, definition.group_by[0]);
    try testing.expectEqual(nerva.AggregateFunction.sum, definition.aggregates[1].function);
    try testing.expectEqual(@as(u8, 8), definition.aggregates[1].field.offset);
    // The state machine accepts what the catalog accepted.
    try testing.expectEqual(null, @import("views.zig").definition_validate(&definition));
}
