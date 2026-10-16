//! Views maintained in the state machine (docs/DECISIONS.md N52): the pure parts, shared by the
//! state machine, the VOPR model and the tests. A view's definition names fields by offset; a
//! row belongs to at most one group of a view, the one its group_by fields' bytes name, if it
//! passes the view's where clauses. Each group keeps a count and per-aggregate sums, and a view
//! keeps the sum (modulo 2^256) of its non-empty groups' digests, so every replica agrees on it.
//! A `min` or `max` slot is kept by the state machine from its members' order (N62); this file
//! has their keys and ordering.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");

const nerva = @import("../nerva.zig");
const catalog = @import("catalog.zig");

const value_size = nerva.value_size;
const ViewDefinition = nerva.ViewDefinition;
const DeclareStatus = nerva.DeclareStatus;
const FieldRef = nerva.FieldRef;
const Group = nerva.Group;
const group_key_size_max = nerva.group_key_size_max;

/// The definition's static checks, or null if it is valid.
pub fn definition_validate(definition: *const ViewDefinition) ?DeclareStatus {
    const name = definition_name(definition);
    if (name.len == 0) return .invalid;
    for (name, 0..) |c, index| {
        const ok = c == '_' or (c >= 'a' and c <= 'z') or (index > 0 and c >= '0' and c <= '9');
        if (!ok) return .invalid;
    }
    // Zero padding only after the name.
    if (!stdx.zeroed(definition.name[name.len..])) return .invalid;
    if (definition.table == 0 or definition.table >= catalog.tables_reserved_min) {
        return .table_invalid;
    }
    // A record's value is wider than a row's (P123b).
    const value_size_max = nerva.table_value_size(definition.table);
    if (definition.reserved_a != 0 or !stdx.zeroed(&definition.reserved_b)) return .invalid;
    if (definition.where_count > nerva.view_where_max) return .invalid;
    if (definition.group_by_count > nerva.view_group_by_max) return .invalid;
    if (definition.aggregate_count == 0 or
        definition.aggregate_count > nerva.view_aggregates_max) return .invalid;

    for (&definition.where, 0..) |*clause, index| {
        if (index >= definition.where_count) {
            if (!stdx.zeroed(std.mem.asBytes(clause))) return .invalid;
            continue;
        }
        if (!field_valid(clause.field, value_size_max) or clause.field.kind == .bytes) return .invalid;
        switch (clause.comparison) {
            .eq, .ne, .lt, .le, .gt, .ge => {},
            _ => return .invalid,
        }
        if (!stdx.zeroed(&clause.reserved)) return .invalid;
    }

    var key_size: usize = 0;
    for (definition.group_by, 0..) |field, index| {
        if (index >= definition.group_by_count) {
            if (!stdx.zeroed(std.mem.asBytes(&field))) return .invalid;
            continue;
        }
        if (!field_valid(field, value_size_max)) return .invalid;
        key_size += field.size;
    }
    if (key_size > group_key_size_max) return .invalid;

    for (&definition.aggregates, 0..) |*aggregate, index| {
        if (index >= definition.aggregate_count) {
            if (!stdx.zeroed(std.mem.asBytes(aggregate))) return .invalid;
            continue;
        }
        if (!stdx.zeroed(&aggregate.reserved)) return .invalid;
        switch (aggregate.function) {
            .count => if (!stdx.zeroed(std.mem.asBytes(&aggregate.field))) return .invalid,
            .sum, .min, .max => {
                if (!field_valid(aggregate.field, value_size_max) or aggregate.field.kind == .bytes) {
                    return .invalid;
                }
                if (extreme(aggregate.function) and nerva.table_is_record(definition.table)) {
                    return .unsupported;
                }
            },
            _ => return .invalid,
        }
    }
    return null;
}

/// Whether a transaction's view group and member writes fit in its op (N52, N62).
pub const Admission = enum {
    fits,
    /// Not with the op's earlier transactions: `views_busy`.
    busy,
    /// Not in any op: `views_too_large` (#32).
    too_large,
};

/// The `min` and `max` aggregates of a definition.
pub fn extreme_count(definition: *const ViewDefinition) u32 {
    var count: u32 = 0;
    for (definition.aggregates[0..definition.aggregate_count]) |*aggregate| {
        if (extreme(aggregate.function)) count += 1;
    }
    return count;
}

pub fn extreme(function: nerva.AggregateFunction) bool {
    return function == .min or function == .max;
}

/// Whether `field` is a field of a `value_size_max`-byte value (a row's or a record's).
pub fn field_valid(field: FieldRef, value_size_max: u16) bool {
    const size_ok = switch (field.kind) {
        .unsigned => field.size == 1 or field.size == 2 or field.size == 4 or field.size == 8,
        .signed => field.size == 8,
        .boolean => field.size == 1,
        .bytes => field.size >= 1,
        _ => false,
    };
    return size_ok and @as(usize, field.offset_of()) + field.size <= value_size_max;
}

/// The definition's name, without its zero padding.
pub fn definition_name(definition: *const ViewDefinition) []const u8 {
    const size = std.mem.indexOfScalar(u8, &definition.name, 0) orelse definition.name.len;
    return definition.name[0..size];
}

/// A field's value as an integer (unsigned, signed or boolean fields).
pub fn field_integer(field: FieldRef, value: []const u8) i128 {
    assert(@as(usize, field.offset_of()) + field.size <= value.len);
    const bytes = value[field.offset_of()..][0..field.size];
    return switch (field.kind) {
        .unsigned, .boolean => std.mem.readVarInt(u64, bytes, .little),
        .signed => std.mem.readInt(i64, bytes[0..8], .little),
        else => unreachable,
    };
}

/// A field's value as a u64 that orders as the field does (N62): unsigned and boolean fields as
/// they are, signed fields with the sign bit flipped.
pub fn field_ordered(field: FieldRef, value: []const u8) u64 {
    return integer_ordered(field.kind, field_integer(field, value));
}

pub fn integer_ordered(kind: nerva.FieldKind, integer: i128) u64 {
    return switch (kind) {
        .unsigned, .boolean => @intCast(integer),
        .signed => @as(u64, @bitCast(@as(i64, @intCast(integer)))) ^ (1 << 63),
        else => unreachable,
    };
}

pub fn integer_from_ordered(kind: nerva.FieldKind, ordered: u64) i128 {
    return switch (kind) {
        .unsigned, .boolean => ordered,
        .signed => @as(i64, @bitCast(ordered ^ (1 << 63))),
        else => unreachable,
    };
}

/// The prefix of a group's members of one slot in the members' order (N62). Persisted: never
/// change the derivation. A collision is found when the order is read, and fails the view.
pub fn member_order_prefix(
    view_id: u64,
    slot: u8,
    key: *const [group_key_size_max]u8,
) u64 {
    assert(view_id >= 1 and view_id <= nerva.views_max);
    assert(slot < nerva.view_aggregates_max);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva.view.member.v1");
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, view_id)));
    hash.update(&.{slot});
    hash.update(key);
    const digest = hash.finalResult();
    return std.mem.readInt(u64, digest[0..8], .little);
}

/// Whether the row passes every where clause.
pub fn row_matches(definition: *const ViewDefinition, value: []const u8) bool {
    return where_matches(definition.where[0..definition.where_count], value);
}

/// Whether the value passes every clause (views' and indexes' `where`).
pub fn where_matches(clauses: []const nerva.Where, value: []const u8) bool {
    for (clauses) |*clause| {
        const actual = field_integer(clause.field, value);
        const expected = std.mem.readInt(i128, &clause.value, .little);
        const keep = switch (clause.comparison) {
            .eq => actual == expected,
            .ne => actual != expected,
            .lt => actual < expected,
            .le => actual <= expected,
            .gt => actual > expected,
            .ge => actual >= expected,
            _ => unreachable,
        };
        if (!keep) return false;
    }
    return true;
}

/// The row's group key: its group_by fields' bytes, then zeros.
pub fn group_key(
    definition: *const ViewDefinition,
    value: []const u8,
) [group_key_size_max]u8 {
    return fields_key(definition.group_by[0..definition.group_by_count], value);
}

/// The fields' bytes, one after another, then zeros (a group's key, an index's `eq` key).
pub fn fields_key(fields: []const FieldRef, value: []const u8) [group_key_size_max]u8 {
    var key: [group_key_size_max]u8 = @splat(0);
    var size: usize = 0;
    for (fields) |field| {
        @memcpy(key[size..][0..field.size], value[field.offset_of()..][0..field.size]);
        size += field.size;
    }
    assert(size <= group_key_size_max);
    return key;
}

/// A group's place in the groups tree: `view_id << 64 | group_hash`. Persisted: never change
/// the derivation.
pub fn group_tree_key(view_id: u64, key: *const [group_key_size_max]u8) u128 {
    assert(view_id >= 1 and view_id <= nerva.views_max);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva.view.group.v1");
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, view_id)));
    hash.update(key);
    const digest = hash.finalResult();
    const group_hash = std.mem.readInt(u64, digest[0..8], .little);
    return @as(u128, view_id) << 64 | group_hash;
}

/// Adds the row to, or removes it from, the group: its count and sums. `min` and `max` slots are
/// left as they are: they need the group's other members (the state machine, N62).
pub fn group_apply(
    definition: *const ViewDefinition,
    group: *Group,
    value: []const u8,
    sign: enum { add, remove },
) void {
    switch (sign) {
        .add => group.count += 1,
        .remove => {
            assert(group.count > 0);
            group.count -= 1;
        },
    }
    for (definition.aggregates[0..definition.aggregate_count], 0..) |*aggregate, index| {
        switch (aggregate.function) {
            .count => {},
            .sum => {
                const slot = &group.sums[index];
                const number = field_integer(aggregate.field, value);
                const sum = std.mem.readInt(i128, slot, .little);
                // A sum of at most 2^64 rows of 64-bit fields cannot overflow an i128.
                const updated = switch (sign) {
                    .add => sum + number,
                    .remove => sum - number,
                };
                std.mem.writeInt(i128, slot, updated, .little);
            },
            .min, .max => {},
            _ => unreachable,
        }
    }
}

/// A group's contribution to its view's hash: zero for an empty group. Persisted (the hash is
/// replicated state): never change the derivation.
pub fn group_digest(view_id: u64, group: *const Group) [32]u8 {
    if (group.count == 0) return @splat(0);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva.view.digest.v1");
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, view_id)));
    hash.update(&group.group_key);
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, group.count)));
    for (&group.sums) |*sum| hash.update(sum);
    return hash.finalResult();
}

/// `hash += digest` (or `-=`), modulo 2^256, little-endian.
pub fn hash_update(hash: *[32]u8, digest: *const [32]u8, sign: enum { add, remove }) void {
    const a = std.mem.readInt(u256, hash, .little);
    const b = std.mem.readInt(u256, digest, .little);
    std.mem.writeInt(u256, hash, switch (sign) {
        .add => a +% b,
        .remove => a -% b,
    }, .little);
}

/// The row values a write may leave behind or start from, for the groups it may touch: the old
/// row's value, and a put's new value or a creating add's empty row (a superset: an add keeps
/// its row in its group, `view_key_field`). `Value` is a row's or a record's value array.
pub fn entry_values(
    comptime Value: type,
    entry: anytype,
    value_old: ?Value,
) [2]?Value {
    const size = @typeInfo(Value).array.len;
    var values: [2]?Value = .{ value_old, null };
    switch (entry.kind) {
        .put => values[1] = entry.value[0..size].*,
        .add => if (nerva.Add.from_entry(entry).flags.create) {
            values[1] = @as(Value, @splat(0));
        },
        else => {},
    }
    return values;
}

/// Whether an add to the 8 bytes at `offset` would change a field the view filters or groups
/// by (refused: `view_key_field`).
pub fn add_touches_key(definition: *const ViewDefinition, offset: u8) bool {
    assert(@as(usize, offset) + 8 <= value_size);
    for (definition.where[0..definition.where_count]) |*clause| {
        if (overlap(clause.field, offset)) return true;
    }
    for (definition.group_by[0..definition.group_by_count]) |field| {
        if (overlap(field, offset)) return true;
    }
    return false;
}

fn overlap(field: FieldRef, offset: u8) bool {
    const start: usize = field.offset_of();
    const end: usize = start + field.size;
    return offset < end and start < @as(usize, offset) + 8;
}

const testing = std.testing;

/// Seats: `section` u8 at 0, `price` u64 at 8, `sold` bool at 16. The view: sold seats by
/// section, with their count and the sum of their prices.
fn seats_view() ViewDefinition {
    var definition = std.mem.zeroes(ViewDefinition);
    @memcpy(definition.name[0..7], "revenue");
    definition.table = 5;
    definition.where_count = 1;
    definition.where[0] = .{
        .field = .{ .offset = 16, .size = 1, .kind = .boolean },
        .comparison = .eq,
        .value = std.mem.toBytes(std.mem.nativeToLittle(i128, 1)),
    };
    definition.group_by_count = 1;
    definition.group_by[0] = .{ .offset = 0, .size = 1, .kind = .unsigned };
    definition.aggregate_count = 2;
    definition.aggregates[0] = .{ .function = .count, .field = std.mem.zeroes(FieldRef) };
    definition.aggregates[1] = .{
        .function = .sum,
        .field = .{ .offset = 8, .size = 8, .kind = .unsigned },
    };
    return definition;
}

fn seat(section: u8, price: u64, sold: bool) [value_size]u8 {
    var value: [value_size]u8 = @splat(0);
    value[0] = section;
    std.mem.writeInt(u64, value[8..16], price, .little);
    value[16] = @intFromBool(sold);
    return value;
}

test "views: definitions are checked statically" {
    const valid = seats_view();
    try testing.expectEqual(null, definition_validate(&valid));

    const Case = struct { status: DeclareStatus, mutate: *const fn (*ViewDefinition) void };
    const cases = [_]Case{
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *ViewDefinition) void {
                d.name = @splat(0);
            }
        }.f },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *ViewDefinition) void {
                d.name[0] = 'R';
            }
        }.f },
        .{
            .status = .invalid,
            .mutate = struct {
                fn f(d: *ViewDefinition) void {
                    d.name[9] = 'x'; // After the zero padding began.
                }
            }.f,
        },
        .{ .status = .table_invalid, .mutate = struct {
            fn f(d: *ViewDefinition) void {
                d.table = 0;
            }
        }.f },
        .{ .status = .table_invalid, .mutate = struct {
            fn f(d: *ViewDefinition) void {
                d.table = catalog.tables_reserved_min;
            }
        }.f },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *ViewDefinition) void {
                d.aggregate_count = 0;
                d.aggregates = @splat(std.mem.zeroes(nerva.AggregateRef));
            }
        }.f },
        .{
            .status = .invalid,
            .mutate = struct {
                fn f(d: *ViewDefinition) void {
                    d.where[0].field.kind = .bytes; // Bytes are grouped by, not compared.
                }
            }.f,
        },
        .{
            .status = .invalid,
            .mutate = struct {
                fn f(d: *ViewDefinition) void {
                    d.aggregates[1].field.offset = 73; // Past the value's 80 bytes.
                }
            }.f,
        },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *ViewDefinition) void {
                d.aggregates[1].field.size = 3;
            }
        }.f },
        .{
            .status = .invalid,
            .mutate = struct {
                fn f(d: *ViewDefinition) void {
                    d.group_by[2].offset = 1; // A slot past `group_by_count`.
                }
            }.f,
        },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *ViewDefinition) void {
                d.group_by_count = 3;
                for (&d.group_by) |*field| field.* = .{ .offset = 0, .size = 30, .kind = .bytes };
            }
        }.f },
        .{
            .status = .invalid,
            .mutate = struct {
                fn f(d: *ViewDefinition) void {
                    d.aggregates[1].function = .max;
                    d.aggregates[1].field.kind = .bytes; // Bytes are not compared.
                }
            }.f,
        },
    };
    for (cases) |case| {
        var definition = valid;
        case.mutate(&definition);
        try testing.expectEqual(case.status, definition_validate(&definition).?);
    }

    var extremes = valid;
    extremes.aggregate_count = 3;
    extremes.aggregates[1].function = .max;
    extremes.aggregates[2] = extremes.aggregates[1];
    extremes.aggregates[2].function = .min;
    try testing.expectEqual(null, definition_validate(&extremes));
    try testing.expectEqual(@as(u32, 2), extreme_count(&extremes));
    try testing.expectEqual(@as(u32, 0), extreme_count(&valid));
}

test "views: ordered values sort as their fields do" {
    const signed: FieldRef = .{ .offset = 0, .size = 8, .kind = .signed };
    const numbers = [_]i64{ std.math.minInt(i64), -5, -1, 0, 1, 7, std.math.maxInt(i64) };
    var previous: ?u64 = null;
    for (numbers) |number| {
        var value: [value_size]u8 = @splat(0);
        std.mem.writeInt(i64, value[0..8], number, .little);
        const ordered = field_ordered(signed, &value);
        if (previous) |p| try testing.expect(p < ordered);
        previous = ordered;
        try testing.expectEqual(@as(i128, number), integer_from_ordered(.signed, ordered));
    }
    const unsigned: FieldRef = .{ .offset = 0, .size = 2, .kind = .unsigned };
    var value: [value_size]u8 = @splat(0);
    std.mem.writeInt(u16, value[0..2], 513, .little);
    try testing.expectEqual(@as(u64, 513), field_ordered(unsigned, &value));
    try testing.expectEqual(@as(i128, 513), integer_from_ordered(.unsigned, 513));
}

test "views: member keys and orders keep views, slots and rows apart" {
    const a = nerva.member_key(1, 0, 7);
    try testing.expect(a != nerva.member_key(1, 1, 7));
    try testing.expect(a != nerva.member_key(2, 0, 7));
    try testing.expect(a != nerva.member_key(1, 0, 8));
    try testing.expectEqual(@as(u64, 7), @as(u64, @truncate(a)));
    try testing.expectEqual(@as(u128, 64), nerva.member_key(64, 5, std.math.maxInt(u64)) >> 72);

    const key: [group_key_size_max]u8 = @splat(0);
    const prefix = member_order_prefix(1, 0, &key);
    try testing.expect(prefix != member_order_prefix(1, 1, &key));
    try testing.expect(prefix != member_order_prefix(2, 0, &key));
    // The order of a group's members is the order of their values.
    try testing.expect(nerva.member_order(prefix, 3) < nerva.member_order(prefix, 4));

    // A group's versions are adjacent and ordered by op, whatever the group hash.
    const group = group_tree_key(1, &key);
    const v1 = nerva.group_version_key(group, 1);
    const v2 = nerva.group_version_key(group, 2);
    try testing.expect(v1 < v2);
    try testing.expectEqual(v1 + 1, v2);
    try testing.expect(nerva.group_version_key(group_tree_key(2, &key), 0) > v2);
}

test "views: rows fall into groups, and leave them" {
    const definition = seats_view();
    try testing.expect(row_matches(&definition, &seat(2, 100, true)));
    try testing.expect(!row_matches(&definition, &seat(2, 100, false)));
    // The group key is the section's byte alone: the price does not matter.
    const section_2 = group_key(&definition, &seat(2, 100, true));
    try testing.expectEqual(section_2, group_key(&definition, &seat(2, 7, true)));
    const section_3 = group_key(&definition, &seat(3, 1, true));
    try testing.expect(!std.mem.eql(u8, &section_2, &section_3));

    var group = std.mem.zeroes(Group);
    group_apply(&definition, &group, &seat(2, 100, true), .add);
    group_apply(&definition, &group, &seat(2, 250, true), .add);
    try testing.expectEqual(@as(u64, 2), group.count);
    try testing.expectEqual(@as(i128, 350), std.mem.readInt(i128, &group.sums[1], .little));
    try testing.expectEqual(@as(i128, 0), std.mem.readInt(i128, &group.sums[0], .little));
    group_apply(&definition, &group, &seat(2, 100, true), .remove);
    group_apply(&definition, &group, &seat(2, 250, true), .remove);
    try testing.expectEqual(std.mem.zeroes(Group), group);

    // Signed fields, and comparisons against negative values.
    var signed = definition;
    signed.where[0] = .{
        .field = .{ .offset = 24, .size = 8, .kind = .signed },
        .comparison = .lt,
        .value = std.mem.toBytes(std.mem.nativeToLittle(i128, -5)),
    };
    var value = seat(1, 1, false);
    std.mem.writeInt(i64, value[24..32], -6, .little);
    try testing.expect(row_matches(&signed, &value));
    std.mem.writeInt(i64, value[24..32], -5, .little);
    try testing.expect(!row_matches(&signed, &value));
}

test "views: the hash depends on the groups, not on the order they changed in" {
    const definition = seats_view();
    var a = std.mem.zeroes(Group);
    a.group_key = group_key(&definition, &seat(1, 0, true));
    group_apply(&definition, &a, &seat(1, 10, true), .add);
    var b = std.mem.zeroes(Group);
    b.group_key = group_key(&definition, &seat(2, 0, true));
    group_apply(&definition, &b, &seat(2, 20, true), .add);

    var forward: [32]u8 = @splat(0);
    hash_update(&forward, &group_digest(1, &a), .add);
    hash_update(&forward, &group_digest(1, &b), .add);
    var backward: [32]u8 = @splat(0);
    hash_update(&backward, &group_digest(1, &b), .add);
    hash_update(&backward, &group_digest(1, &a), .add);
    try testing.expectEqual(forward, backward);
    // Another view with the same groups hashes differently.
    try testing.expect(!std.mem.eql(u8, &group_digest(1, &a), &group_digest(2, &a)));

    hash_update(&forward, &group_digest(1, &a), .remove);
    hash_update(&forward, &group_digest(1, &b), .remove);
    try testing.expectEqual(@as([32]u8, @splat(0)), forward);

    const empty = std.mem.zeroes(Group);
    try testing.expectEqual(@as([32]u8, @splat(0)), group_digest(1, &empty));
}

test "views: group tree keys are stable and separate views and keys" {
    const key: [group_key_size_max]u8 = @splat(0);
    var other = key;
    other[0] = 1;
    const tree_key = group_tree_key(1, &key);
    try testing.expectEqual(@as(u64, 1), @as(u64, @intCast(tree_key >> 64)));
    try testing.expect(tree_key != group_tree_key(2, &key));
    try testing.expect(tree_key != group_tree_key(1, &other));
    // A fixed vector (computed with Python's hashlib): changing the derivation would orphan
    // every stored group.
    try testing.expectEqual(@as(u64, 17400499127971693294), @as(u64, @truncate(tree_key)));
}

test "views: adds may not touch a field a view filters or groups by" {
    const definition = seats_view();
    try testing.expect(add_touches_key(&definition, 0)); // section, grouped by.
    try testing.expect(add_touches_key(&definition, 9)); // Overlaps sold at 16.
    try testing.expect(!add_touches_key(&definition, 8)); // price: only summed.
    try testing.expect(!add_touches_key(&definition, 24));
}
