//! Nerva's public types: the wire-level operations and persisted LSM tree identifiers.
//! Kept separate from the state machine so that the replica and tracing can reference them
//! without depending on the state machine implementation (mirrors TigerBeetle's tigerbeetle.zig).
//!
//! Model: a row is identified by (table, id) and versioned by `op`, the log position of its last
//! write. A transaction is one batch of `Entry`s: reads assert the version they saw, puts and
//! deletes are applied only if every read still holds. Every applied write appends a `Change`.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");
const vsr = @import("vsr.zig");
const constants = @import("constants.zig");

/// Size of a row's payload, in bytes. Fixed for v0.1.
pub const value_size = 80;

/// Stable, forest-unique LSM tree identifiers. Never reuse or renumber: they are persisted.
pub const tree_ids = struct {
    pub const Row = .{
        .timestamp = 1,
        .key = 2,
    };

    pub const Change = .{
        .timestamp = 3,
        // `row_key(table, id)`: a row's history, in timestamp order (`get_history`).
        .row_key = 4,
    };
};

/// The LSM key of a row: `table` in the high 64 bits, `id` in the low 64 bits.
pub fn row_key(table: u32, id: u64) u128 {
    assert(table != 0);
    return @as(u128, table) << 64 | id;
}

/// A row as stored in the forest. Rows are never physically removed: a delete leaves a
/// tombstone (`flags.deleted`) whose `op` records the delete, so versions stay exact.
pub const Row = extern struct {
    key: u128,
    value: [value_size]u8,
    /// The op of the last write (put or delete). Never zero.
    op: u64,
    /// Assigned when the row is first inserted; fixed for the row's lifetime.
    timestamp: u64,
    flags: RowFlags,
    reserved: [12]u8 = @splat(0),

    pub const RowFlags = packed struct(u32) {
        deleted: bool = false,
        padding: u31 = 0,
    };

    comptime {
        assert(@sizeOf(Row) == 128);
        assert(stdx.no_padding(Row));
    }
};

/// Non-exhaustive: entries arrive from the wire, and unknown kinds must be rejected, not trusted.
pub const EntryKind = enum(u8) {
    read = 1,
    put = 2,
    delete = 3,
    _,
};

/// The `commit` event. One batch is one transaction: all of its writes apply, or none do.
pub const Entry = extern struct {
    id: u64,
    /// Zero is invalid.
    table: u32,
    kind: EntryKind,
    reserved_a: [3]u8 = @splat(0),
    /// Reads only: the version observed. Zero means the row has never existed.
    op_seen: u64,
    reserved_b: u64 = 0,
    /// Puts only; must be zero for reads and deletes.
    value: [value_size]u8,
    reserved_c: [16]u8 = @splat(0),

    comptime {
        assert(@sizeOf(Entry) == 128);
        assert(stdx.no_padding(Entry));
    }
};

pub const EntryStatus = enum(u32) {
    ok = 0,
    /// A read's `op_seen` no longer matches the row's version.
    conflict = 1,
    /// Another entry of the same transaction failed; nothing was applied.
    aborted = 2,
    kind_invalid = 3,
    table_invalid = 4,
    reserved_not_zero = 5,
    /// A read or delete carries a value.
    value_not_zero = 6,
    /// A put or delete carries `op_seen`.
    op_seen_not_zero = 7,
    /// The same row is written twice in one transaction.
    write_duplicate = 8,
};

/// The `commit` result, one per entry.
pub const EntryResult = extern struct {
    status: EntryStatus,
    reserved: u32 = 0,
    /// `ok`: the op the transaction committed at. `conflict`: the row's current version.
    /// Otherwise zero.
    op: u64,

    comptime {
        assert(@sizeOf(EntryResult) == 16);
        assert(stdx.no_padding(EntryResult));
    }
};

/// The `lookup_rows` event.
pub const RowKey = extern struct {
    id: u64,
    table: u32,
    reserved: u32 = 0,

    comptime {
        assert(@sizeOf(RowKey) == 16);
        assert(stdx.no_padding(RowKey));
    }
};

/// The `lookup_rows` result, one per event.
pub const RowValue = extern struct {
    id: u64,
    table: u32,
    flags: RowValueFlags,
    /// The row's version: zero if it has never existed, else the op of its last write
    /// (including a delete). Use it as `Entry.op_seen`.
    op: u64,
    /// The op at which this lookup executed: the result reflects every commit before it (G2).
    op_read: u64,
    /// Zero unless `flags.exists`.
    value: [value_size]u8,
    reserved_b: [16]u8 = @splat(0),

    pub const RowValueFlags = packed struct(u32) {
        exists: bool = false,
        padding: u31 = 0,
    };

    comptime {
        assert(@sizeOf(RowValue) == 128);
        assert(stdx.no_padding(RowValue));
    }
};

/// The `get_changes` event.
pub const ChangesFilter = extern struct {
    /// Return changes with `timestamp >= timestamp_min`. Zero means from the beginning.
    timestamp_min: u64,
    /// The maximum number of changes to return, excluding the final `end` record.
    limit: u32,
    reserved: [52]u8 = @splat(0),

    comptime {
        assert(@sizeOf(ChangesFilter) == 64);
        assert(stdx.no_padding(ChangesFilter));
    }
};

/// The `get_history` event: one row's changes, newest first.
///
/// Changes are scanned newest first from `timestamp_max`, at most `limit` of them; those with
/// `op <= op_max` are returned. The first returned change is the row as of `op_max`: its value if
/// `put`, absent if `delete`; no change at all means the row did not exist at `op_max`.
pub const HistoryFilter = extern struct {
    id: u64,
    table: u32,
    /// The maximum number of changes to scan, excluding the final `end` record.
    limit: u32,
    /// Return changes with `op <= op_max`: `maxInt(u64)` for the latest. Zero is invalid (no op
    /// is zero), so that "as of op 0" cannot be mistaken for "no bound".
    op_max: u64,
    /// The cursor: scan changes with `timestamp <= timestamp_max`. Zero means from the newest.
    timestamp_max: u64,
    reserved: [32]u8 = @splat(0),

    comptime {
        assert(@sizeOf(HistoryFilter) == 64);
        assert(stdx.no_padding(HistoryFilter));
    }
};

pub const ChangeKind = enum(u8) {
    put = 1,
    delete = 2,
    /// The last record of every `get_changes` and `get_history` reply.
    end = 3,
};

/// A committed write, as stored in the forest and returned by `get_changes`.
///
/// Every `get_changes` reply ends with one `end` record: its `timestamp` is the cursor for the
/// next call. If `flags.more` is unset, the feed is complete through `op`, the op of the query.
/// `get_history` replies end the same way, except that the cursor counts down: the next call's
/// `timestamp_max`, or zero once the row's history is exhausted.
pub const Change = extern struct {
    id: u64,
    table: u32,
    kind: ChangeKind,
    flags: ChangeFlags,
    reserved_a: [2]u8 = @splat(0),
    op: u64,
    timestamp: u64,
    /// The new value for `put`; zero for `delete` and `end`.
    value: [value_size]u8,
    reserved_b: [16]u8 = @splat(0),

    pub const ChangeFlags = packed struct(u8) {
        /// `end` only: the limit was reached before the end of the feed.
        more: bool = false,
        padding: u7 = 0,
    };

    comptime {
        assert(@sizeOf(Change) == 128);
        assert(stdx.no_padding(Change));
    }
};

/// Operations exported by Nerva.
pub const Operation = enum(u8) {
    lookup_rows = constants.vsr_operations_reserved + 0,
    commit = constants.vsr_operations_reserved + 1,
    get_changes = constants.vsr_operations_reserved + 2,
    get_history = constants.vsr_operations_reserved + 3,

    pub fn EventType(comptime operation: Operation) type {
        return switch (operation) {
            .lookup_rows => RowKey,
            .commit => Entry,
            .get_changes => ChangesFilter,
            .get_history => HistoryFilter,
        };
    }

    pub fn ResultType(comptime operation: Operation) type {
        return switch (operation) {
            .lookup_rows => RowValue,
            .commit => EntryResult,
            .get_changes, .get_history => Change,
        };
    }

    pub fn event_size(operation: Operation) u32 {
        return switch (operation) {
            inline else => |operation_comptime| @sizeOf(operation_comptime.EventType()),
        };
    }

    pub fn result_size(operation: Operation) u32 {
        return switch (operation) {
            inline else => |operation_comptime| @sizeOf(operation_comptime.ResultType()),
        };
    }

    /// Whether the operation takes multiple events per batch (one result per event).
    pub inline fn is_batchable(operation: Operation) bool {
        return switch (operation) {
            .lookup_rows, .commit => true,
            .get_changes, .get_history => false,
        };
    }

    /// Whether the operation is multi-batch encoded.
    pub inline fn is_multi_batch(operation: Operation) bool {
        return switch (operation) {
            .lookup_rows, .commit => true,
            .get_changes, .get_history => false,
        };
    }

    /// The maximum number of events per batch.
    pub inline fn event_max(operation: Operation, batch_size_limit: u32) u32 {
        return vsr.multi_batch.event_max(Operation, operation, batch_size_limit);
    }

    /// The maximum number of results per batch.
    pub inline fn result_max(operation: Operation, batch_size_limit: u32) u32 {
        return vsr.multi_batch.result_max(Operation, operation, batch_size_limit);
    }

    /// The number of results a batch produces at most.
    /// For multi-batch requests, this function expects a single, already decoded batch.
    pub inline fn result_count_expected(operation: Operation, batch: []const u8) u32 {
        return switch (operation) {
            inline .lookup_rows, .commit => |operation_comptime| @intCast(@divExact(
                batch.len,
                @sizeOf(operation_comptime.EventType()),
            )),
            inline .get_changes, .get_history => |operation_comptime| count: {
                const Filter = operation_comptime.EventType();
                const filter = std.mem.bytesAsValue(Filter, batch[0..@sizeOf(Filter)]);
                // +1 for the `end` record.
                break :count @min(
                    filter.limit +| 1,
                    operation.result_max(constants.message_body_size_max),
                );
            },
        };
    }

    pub fn from_vsr(operation: vsr.Operation) ?Operation {
        if (operation.vsr_reserved()) return null;
        return vsr.Operation.to(Operation, operation);
    }

    pub fn to_vsr(operation: Operation) vsr.Operation {
        return vsr.Operation.from(Operation, operation);
    }
};

/// Static checks on one entry, independent of state. Returns null if the entry is valid.
pub fn entry_validate(entry: *const Entry) ?EntryStatus {
    if (entry.table == 0) return .table_invalid;
    if (!stdx.zeroed(&entry.reserved_a) or entry.reserved_b != 0 or
        !stdx.zeroed(&entry.reserved_c))
    {
        return .reserved_not_zero;
    }
    switch (entry.kind) {
        .read => {
            if (!stdx.zeroed(&entry.value)) return .value_not_zero;
        },
        .put => {
            if (entry.op_seen != 0) return .op_seen_not_zero;
        },
        .delete => {
            if (!stdx.zeroed(&entry.value)) return .value_not_zero;
            if (entry.op_seen != 0) return .op_seen_not_zero;
        },
        _ => return .kind_invalid,
    }
    return null;
}

test entry_validate {
    const valid_read: Entry = .{
        .id = 1,
        .table = 1,
        .kind = .read,
        .op_seen = 7,
        .value = @splat(0),
    };
    try std.testing.expectEqual(null, entry_validate(&valid_read));

    var put = valid_read;
    put.kind = .put;
    put.op_seen = 0;
    put.value[0] = 1;
    try std.testing.expectEqual(null, entry_validate(&put));

    var entry = valid_read;
    entry.table = 0;
    try std.testing.expectEqual(EntryStatus.table_invalid, entry_validate(&entry).?);

    entry = valid_read;
    entry.reserved_c[15] = 1;
    try std.testing.expectEqual(EntryStatus.reserved_not_zero, entry_validate(&entry).?);

    entry = valid_read;
    entry.value[3] = 1;
    try std.testing.expectEqual(EntryStatus.value_not_zero, entry_validate(&entry).?);

    entry = put;
    entry.op_seen = 1;
    try std.testing.expectEqual(EntryStatus.op_seen_not_zero, entry_validate(&entry).?);

    entry = valid_read;
    entry.kind = .delete;
    entry.op_seen = 0;
    try std.testing.expectEqual(null, entry_validate(&entry));
    entry.value[0] = 1;
    try std.testing.expectEqual(EntryStatus.value_not_zero, entry_validate(&entry).?);

    entry = valid_read;
    entry.kind = @enumFromInt(9);
    try std.testing.expectEqual(EntryStatus.kind_invalid, entry_validate(&entry).?);
}

test row_key {
    try std.testing.expectEqual(@as(u128, 1) << 64 | 5, row_key(1, 5));
    try std.testing.expect(row_key(1, std.math.maxInt(u64)) < row_key(2, 0));
}
