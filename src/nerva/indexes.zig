//! Declared indexes (P123c): the pure parts, shared by the state machine, the VOPR model and the
//! tests. An index lists the records of one table that pass its `where`, by the bytes of their
//! `eq` fields, then by their `order` field (or the op of their last write), then by the time
//! they entered it. The state machine keeps one entry per index and record (`IndexEntry`),
//! present while the record is in the index, at its position; a scan reads the positions of one
//! `eq` key in order, as a view's `min` reads its members (N62).

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");

const nerva = @import("../nerva.zig");
const views = @import("views.zig");

const IndexDefinition = nerva.IndexDefinition;
const DeclareIndexStatus = nerva.DeclareIndexStatus;
const FieldRef = nerva.FieldRef;
const group_key_size_max = nerva.group_key_size_max;
const record_value_size = nerva.record_value_size;

/// The definition's static checks, or null if it is valid.
pub fn definition_validate(definition: *const IndexDefinition) ?DeclareIndexStatus {
    const name = definition_name(definition);
    if (name.len == 0) return .invalid;
    for (name, 0..) |c, index| {
        const ok = c == '_' or (c >= 'a' and c <= 'z') or (index > 0 and c >= '0' and c <= '9');
        if (!ok) return .invalid;
    }
    if (!stdx.zeroed(definition.name[name.len..])) return .invalid;
    if (!nerva.table_is_record(definition.table)) return .table_invalid;
    if (definition.reserved_a != 0 or !stdx.zeroed(&definition.reserved_b)) return .invalid;
    if (definition.flags.padding != 0) return .invalid;
    if (definition.eq_count > nerva.index_eq_max) return .invalid;
    if (definition.where_count > nerva.index_where_max) return .invalid;

    var key_size: usize = 0;
    for (definition.eq, 0..) |field, index| {
        if (index >= definition.eq_count) {
            if (!stdx.zeroed(std.mem.asBytes(&field))) return .invalid;
            continue;
        }
        if (!views.field_valid(field, record_value_size)) return .invalid;
        key_size += field.size;
    }
    if (key_size > group_key_size_max) return .invalid;

    if (definition.flags.order) {
        const order = definition.order;
        if (!views.field_valid(order, record_value_size) or order.kind == .bytes) return .invalid;
    } else {
        if (!stdx.zeroed(std.mem.asBytes(&definition.order))) return .invalid;
    }

    for (&definition.where, 0..) |*clause, index| {
        if (index >= definition.where_count) {
            if (!stdx.zeroed(std.mem.asBytes(clause))) return .invalid;
            continue;
        }
        if (!views.field_valid(clause.field, record_value_size) or clause.field.kind == .bytes) {
            return .invalid;
        }
        switch (clause.comparison) {
            .eq, .ne, .lt, .le, .gt, .ge => {},
            _ => return .invalid,
        }
        if (!stdx.zeroed(&clause.reserved)) return .invalid;
    }
    return null;
}

/// The definition's name, without its zero padding.
pub fn definition_name(definition: *const IndexDefinition) []const u8 {
    const size = std.mem.indexOfScalar(u8, &definition.name, 0) orelse definition.name.len;
    return definition.name[0..size];
}

/// Where a record with `value`, last written at `op`, sits in the index: its `eq` key and order
/// value, or null if it does not pass `where`.
pub const Place = struct { eq_key: [group_key_size_max]u8, order: u64 };

pub fn place(definition: *const IndexDefinition, value: []const u8, op: u64) ?Place {
    assert(value.len == record_value_size);
    if (!views.where_matches(definition.where[0..definition.where_count], value)) return null;
    return .{
        .eq_key = views.fields_key(definition.eq[0..definition.eq_count], value),
        .order = if (definition.flags.order)
            views.field_ordered(definition.order, value)
        else
            op,
    };
}

/// The prefix of one `eq` key's entries in an index's order. Persisted: never change the
/// derivation. A collision is found when the index is read (`IndexEntry.eq_key`) and skipped.
pub fn position_prefix(index_id: u64, eq_key: *const [group_key_size_max]u8) u64 {
    assert(index_id >= 1 and index_id <= nerva.indexes_max);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva.index.position.v1");
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, index_id)));
    hash.update(eq_key);
    const digest = hash.finalResult();
    return std.mem.readInt(u64, digest[0..8], .little);
}

/// Whether an `eq` key is one the definition's fields could give: zeros past their size.
pub fn eq_key_valid(definition: *const IndexDefinition, eq_key: *const [group_key_size_max]u8) bool {
    var size: usize = 0;
    for (definition.eq[0..definition.eq_count]) |field| size += field.size;
    return stdx.zeroed(eq_key[size..]);
}

const testing = std.testing;

fn executions_index() IndexDefinition {
    var definition = std.mem.zeroes(IndexDefinition);
    @memcpy(definition.name[0..9], "by_status");
    definition.table = nerva.record_tables_min;
    definition.eq_count = 1;
    definition.eq[0] = FieldRef.at(300, 1, .unsigned);
    definition.flags.order = true;
    definition.order = FieldRef.at(16, 8, .unsigned);
    definition.where_count = 1;
    definition.where[0] = .{
        .field = FieldRef.at(440, 8, .signed),
        .comparison = .ge,
        .value = std.mem.toBytes(std.mem.nativeToLittle(i128, 0)),
    };
    return definition;
}

test "indexes: definitions are checked statically" {
    const valid = executions_index();
    try testing.expectEqual(null, definition_validate(&valid));

    var row_table = valid;
    row_table.table = 7;
    try testing.expectEqual(DeclareIndexStatus.table_invalid, definition_validate(&row_table).?);
    var past_value = valid;
    past_value.eq[0] = FieldRef.at(447, 2, .unsigned);
    try testing.expectEqual(DeclareIndexStatus.invalid, definition_validate(&past_value).?);
    var bytes_order = valid;
    bytes_order.order.kind = .bytes;
    try testing.expectEqual(DeclareIndexStatus.invalid, definition_validate(&bytes_order).?);
    var order_unflagged = valid;
    order_unflagged.flags.order = false;
    try testing.expectEqual(DeclareIndexStatus.invalid, definition_validate(&order_unflagged).?);
    var by_op = valid;
    by_op.flags.order = false;
    by_op.order = std.mem.zeroes(FieldRef);
    try testing.expectEqual(null, definition_validate(&by_op));
    var eq_large = valid;
    eq_large.eq_count = 3;
    for (&eq_large.eq, 0..) |*field, i| field.* = FieldRef.at(@intCast(i * 30), 30, .bytes);
    try testing.expectEqual(DeclareIndexStatus.invalid, definition_validate(&eq_large).?);
    var name = valid;
    name.name[0] = 'B';
    try testing.expectEqual(DeclareIndexStatus.invalid, definition_validate(&name).?);
}

test "indexes: a record's place: its eq key and order, if it passes where" {
    const definition = executions_index();
    var value: [record_value_size]u8 = @splat(0);
    value[300] = 2;
    std.mem.writeInt(u64, value[16..24], 77, .little);
    const in = place(&definition, &value, 5).?;
    try testing.expectEqual(@as(u8, 2), in.eq_key[0]);
    try testing.expect(stdx.zeroed(in.eq_key[1..]));
    try testing.expectEqual(@as(u64, 77), in.order);
    std.mem.writeInt(i64, value[440..448], -1, .little);
    try testing.expectEqual(null, place(&definition, &value, 5));

    var by_op = definition;
    by_op.flags.order = false;
    by_op.order = std.mem.zeroes(FieldRef);
    std.mem.writeInt(i64, value[440..448], 1, .little);
    try testing.expectEqual(@as(u64, 5), place(&by_op, &value, 5).?.order);
}
