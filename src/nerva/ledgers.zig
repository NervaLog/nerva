//! Ledgers (docs/DECISIONS.md N74): sets of conserved `i64` fields that only pairs of adds may
//! change. A definition's static checks, and the index the state machine finds conserved
//! fields with, from the ledger declarations alone: no layouts, no rows.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");
const nerva = @import("../nerva.zig");
const catalog = @import("catalog.zig");

const LedgerDefinition = nerva.LedgerDefinition;
const LedgerField = nerva.LedgerField;
const DeclareLedgerStatus = nerva.DeclareLedgerStatus;
const value_size = nerva.value_size;

/// A definition's static checks: everything but what other ledgers and views decide.
pub fn definition_validate(definition: *const LedgerDefinition) ?DeclareLedgerStatus {
    if (definition.id == 0) return .invalid;
    if (!stdx.zeroed(&definition.reserved)) return .invalid;
    if (definition.field_count < 2 or definition.field_count > nerva.ledger_fields_max) {
        return .invalid;
    }
    for (definition.fields[definition.field_count..]) |*field| {
        if (!stdx.zeroed(std.mem.asBytes(field))) return .invalid;
    }
    const fields = definition.fields[0..definition.field_count];
    for (fields, 0..) |*field, index| {
        if (!stdx.zeroed(&field.reserved) or field.flags.padding != 0) return .invalid;
        if (!field.flags.floor and field.floor != 0) return .invalid;
        if (field.offset % 8 != 0 or field.offset > value_size - 8) return .invalid;
        if (field.table == 0 or field.table >= catalog.tables_reserved_min) {
            return .table_invalid;
        }
        // Strictly ascending: one canonical form per set of fields, without duplicates.
        if (index > 0 and field_key(&fields[index - 1]) >= field_key(field)) return .invalid;
    }
    return null;
}

fn field_key(field: *const LedgerField) u64 {
    return key(field.table, field.offset);
}

fn key(table: u32, offset: u8) u64 {
    return @as(u64, table) << 8 | offset;
}

/// The conserved fields of every ledger, sorted by `(table, offset)`. Ledgers are immutable,
/// so the index changes only when one is declared.
pub const Index = struct {
    pub const Conserved = struct {
        table: u32,
        offset: u8,
        /// The ledger's index in declaration order (its slot minus one).
        ledger: u32,
        floor: ?i64,
    };

    const capacity = nerva.ledgers_max * nerva.ledger_fields_max;

    fields: [capacity]Conserved = undefined,
    count: u32 = 0,
    /// The ledgers indexed so far.
    ledger_count: u32 = 0,

    /// Adds the ledger declared next. Its fields must not be indexed yet.
    pub fn insert(index: *Index, definition: *const LedgerDefinition) void {
        assert(definition_validate(definition) == null);
        assert(index.ledger_count < nerva.ledgers_max);
        for (definition.fields[0..definition.field_count]) |*field| {
            assert(index.find(field.table, field.offset) == null);
            assert(index.count < capacity);
            index.fields[index.count] = .{
                .table = field.table,
                .offset = field.offset,
                .ledger = index.ledger_count,
                .floor = if (field.flags.floor) field.floor else null,
            };
            index.count += 1;
        }
        index.ledger_count += 1;
        std.mem.sortUnstable(Conserved, index.fields[0..index.count], {}, struct {
            fn less_than(_: void, a: Conserved, b: Conserved) bool {
                return key(a.table, a.offset) < key(b.table, b.offset);
            }
        }.less_than);
    }

    /// The conserved field at exactly `(table, offset)`, if any.
    pub fn find(index: *const Index, table: u32, offset: u8) ?Conserved {
        const fields = index.fields[0..index.count];
        const position = index.lower_bound(key(table, offset));
        if (position < fields.len and
            key(fields[position].table, fields[position].offset) == key(table, offset))
        {
            return fields[position];
        }
        return null;
    }

    /// Whether `size` bytes at `offset` in a row of `table` overlap a conserved field. The
    /// fields are 8-aligned and 8 bytes, so only those at the aligned offsets in the range can.
    pub fn touches(index: *const Index, table: u32, offset: u8, size: u8) bool {
        assert(size > 0);
        assert(@as(usize, offset) + size <= value_size);
        var aligned: usize = offset - offset % 8;
        while (aligned < @as(usize, offset) + size) : (aligned += 8) {
            if (index.find(table, @intCast(aligned)) != null) return true;
        }
        return false;
    }

    /// The conserved fields of `table`, by offset.
    pub fn table_fields(index: *const Index, table: u32) []const Conserved {
        const start = index.lower_bound(key(table, 0));
        const end = index.lower_bound((@as(u64, table) + 1) << 8);
        return index.fields[start..end];
    }

    fn lower_bound(index: *const Index, target: u64) usize {
        var low: usize = 0;
        var high: usize = index.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const field = &index.fields[middle];
            if (key(field.table, field.offset) < target) low = middle + 1 else high = middle;
        }
        return low;
    }
};

const testing = std.testing;

/// Accounts in table 7 (`available` at 0, floor 0; `held` at 8, floor 0) and an unfloored
/// source in table 9 at 16.
fn accounts_ledger() LedgerDefinition {
    var definition = std.mem.zeroes(LedgerDefinition);
    definition.id = 1;
    definition.field_count = 3;
    definition.fields[0] = .{ .table = 7, .offset = 0, .flags = .{ .floor = true }, .floor = 0 };
    definition.fields[1] = .{ .table = 7, .offset = 8, .flags = .{ .floor = true }, .floor = 0 };
    definition.fields[2] = .{ .table = 9, .offset = 16, .flags = .{}, .floor = 0 };
    return definition;
}

test "ledgers: definition_validate" {
    const valid = accounts_ledger();
    try testing.expectEqual(null, definition_validate(&valid));

    const Case = struct { status: DeclareLedgerStatus, mutate: *const fn (*LedgerDefinition) void };
    const cases = [_]Case{
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                d.id = 0;
            }
        }.f },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                d.field_count = 1;
            }
        }.f },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                d.field_count = nerva.ledger_fields_max + 1;
            }
        }.f },
        // A field left past `field_count`.
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                d.field_count = 2;
            }
        }.f },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                d.fields[1].offset = 12;
            }
        }.f },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                d.fields[2].offset = value_size;
            }
        }.f },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                d.fields[2].floor = 5;
            }
        }.f },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                d.fields[0].reserved[1] = 1;
            }
        }.f },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                d.reserved[0] = 1;
            }
        }.f },
        // Out of order, and duplicated.
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                std.mem.swap(LedgerField, &d.fields[0], &d.fields[1]);
            }
        }.f },
        .{ .status = .invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                d.fields[1] = d.fields[0];
            }
        }.f },
        .{ .status = .table_invalid, .mutate = struct {
            fn f(d: *LedgerDefinition) void {
                d.fields[2].table = catalog.table_catalog;
            }
        }.f },
    };
    for (cases) |case| {
        var definition = accounts_ledger();
        case.mutate(&definition);
        try testing.expectEqual(case.status, definition_validate(&definition).?);
    }
}

test "ledgers: Index" {
    var index: Index = .{};
    var first = accounts_ledger();
    index.insert(&first);
    var second = std.mem.zeroes(LedgerDefinition);
    second.id = 8;
    second.field_count = 2;
    second.fields[0] = .{ .table = 3, .offset = 72, .flags = .{}, .floor = 0 };
    second.fields[1] = .{ .table = 7, .offset = 40, .flags = .{ .floor = true }, .floor = -5 };
    index.insert(&second);

    try testing.expectEqual(5, index.count);
    try testing.expectEqual(0, index.find(7, 8).?.ledger);
    try testing.expectEqual(0, index.find(7, 8).?.floor.?);
    try testing.expectEqual(null, index.find(9, 16).?.floor);
    try testing.expectEqual(-5, index.find(7, 40).?.floor.?);
    try testing.expectEqual(1, index.find(3, 72).?.ledger);
    try testing.expectEqual(null, index.find(7, 16));
    try testing.expectEqual(null, index.find(8, 0));

    // An add straddling `available@0` and `held@8`; one that ends just before a field; one
    // that starts in the last.
    try testing.expect(index.touches(7, 4, 8));
    try testing.expect(!index.touches(7, 16, 8));
    try testing.expect(!index.touches(7, 32, 8));
    try testing.expect(!index.touches(7, 33, 7));
    try testing.expect(index.touches(7, 33, 8));
    try testing.expect(index.touches(3, 72, 1));
    try testing.expect(!index.touches(3, 64, 8));
    // A one-byte view key inside a field.
    try testing.expect(index.touches(9, 23, 1));

    const fields = index.table_fields(7);
    try testing.expectEqual(3, fields.len);
    try testing.expectEqual(0, fields[0].offset);
    try testing.expectEqual(40, fields[2].offset);
    try testing.expectEqual(0, index.table_fields(4).len);
    try testing.expectEqual(1, index.table_fields(9).len);
}
