//! Nerva's public types: the wire-level operations and persisted LSM tree identifiers.
//! Kept separate from the state machine so that the replica and tracing can reference them
//! without depending on the state machine implementation (mirrors TigerBeetle's tigerbeetle.zig).
//!
//! Model: a row is identified by (table, id) and versioned by `op`, the log position of its last
//! write. A transaction is one batch of `Entry`s: reads assert the version they saw, puts and
//! deletes are applied only if every read still holds. Every applied write appends a `Change`.
//!
//! An `add` changes one 64-bit field of a row inside the commit, without a read: adds to one row
//! never conflict, they apply in log order, within optional bounds (docs/DECISIONS.md N42).

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

    pub const View = .{
        .timestamp = 5,
        .id = 6,
    };

    pub const Group = .{
        .timestamp = 7,
        .key = 8,
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
    /// Adds a delta to one field of the row, inside the commit; parameters in `value` (`Add`).
    add = 4,
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
    /// Puts: the new value. Adds: the `Add` parameters. Zero for reads and deletes.
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
    /// The same row is written twice in one transaction (several adds to one row are allowed,
    /// but not mixed with a put or delete of it).
    write_duplicate = 8,
    /// An add would move its field past a bound (or out of its type's range), without `clamp`.
    out_of_bounds = 9,
    /// An add to a row that does not exist, without `create`.
    row_absent = 10,
    /// An add's field, bounds or delta are invalid.
    field_invalid = 11,
    /// An add's `delta_from` does not name an earlier add of the same transaction.
    delta_from_invalid = 12,
    /// An add to a field that a view on its table filters or groups by (N49): adds must not
    /// move a row between a view's groups.
    view_key_field = 13,
    /// This op's budget of view group writes (`StateMachine.groups_per_op_max`) is spent:
    /// nothing applied, retry in a later op (N49).
    views_busy = 14,
};

/// The `commit` result, one per entry.
pub const EntryResult = extern struct {
    status: EntryStatus,
    reserved_a: u32 = 0,
    /// `ok`: the op the transaction committed at. `conflict`: the row's current version.
    /// Otherwise zero.
    op: u64,
    /// `add`, when `ok`: the amount added, after clamping. Otherwise zero.
    applied: i64 = 0,
    /// `add`, when `ok`: the field after the add. `out_of_bounds`: the field before it.
    /// Otherwise zero. An `i64` field's value is its two's complement bits.
    value: u64 = 0,

    comptime {
        assert(@sizeOf(EntryResult) == 32);
        assert(stdx.no_padding(EntryResult));
    }
};

/// An `add` entry's parameters, carried in `Entry.value`.
///
/// The field is the 8 bytes at `offset` of the row's value, little-endian, as `field`. The new
/// value is the field plus `delta` (or, with `flags.delta_from`, minus the amount the earlier
/// add at entry index `delta_from` applied). An add never moves the field past a bound in the
/// direction it moves (`min` when the delta is negative, `max` when positive; absent bounds are
/// the type's range): it fails with `out_of_bounds`, or with `flags.clamp` adds as much as fits,
/// possibly nothing. A row that does not exist fails with `row_absent`, or with `flags.create`
/// starts as all zeros.
pub const Add = extern struct {
    delta: i64,
    /// As the field's type (an `i64` bound is its two's complement bits). Zero unless
    /// `flags.min` (respectively `flags.max`).
    min: u64,
    max: u64,
    /// Zero unless `flags.delta_from`.
    delta_from: u32,
    /// At most `value_size - 8`.
    offset: u8,
    field: AddField,
    flags: AddFlags,
    reserved_a: u8 = 0,
    reserved_b: [48]u8 = @splat(0),

    pub const AddField = enum(u8) {
        u64 = 1,
        i64 = 2,
        _,
    };

    pub const AddFlags = packed struct(u8) {
        min: bool = false,
        max: bool = false,
        clamp: bool = false,
        create: bool = false,
        /// `delta` must be zero.
        delta_from: bool = false,
        padding: u3 = 0,
    };

    comptime {
        assert(@sizeOf(Add) == value_size);
        assert(stdx.no_padding(Add));
    }

    pub fn from_entry(entry: *const Entry) Add {
        assert(entry.kind == .add);
        return std.mem.bytesToValue(Add, &entry.value);
    }

    pub fn value(add: *const Add) [value_size]u8 {
        return std.mem.toBytes(add.*);
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

// ---- Views maintained in the state machine (docs/DECISIONS.md N49) ----

/// Views, cluster-wide. View ids are 1..views_max, in declaration order.
pub const views_max = 64;
/// Views over one table.
pub const views_per_table_max = 4;
/// The bytes of a view's group_by fields, concatenated.
pub const group_key_size_max = 64;
// The budget of group writes per op, and the rows a pulse backfills, depend on the message
// size: `StateMachine.groups_per_op_max`.

pub const view_where_max = 4;
pub const view_group_by_max = 3;
pub const view_aggregates_max = 6;

pub const FieldKind = enum(u8) {
    /// Little-endian, 1, 2, 4 or 8 bytes.
    unsigned = 1,
    /// Little-endian two's complement, 8 bytes.
    signed = 2,
    /// One byte, 0 or 1.
    boolean = 3,
    /// Raw bytes, 1..80; may be grouped by, not compared or aggregated.
    bytes = 4,
    _,
};

/// A field of a row's value, resolved from the table's layout by the gateway.
pub const FieldRef = extern struct {
    offset: u8,
    size: u8,
    kind: FieldKind,
    reserved: u8 = 0,

    comptime {
        assert(@sizeOf(FieldRef) == 4);
        assert(stdx.no_padding(FieldRef));
    }
};

pub const Comparison = enum(u8) { eq = 1, ne = 2, lt = 3, le = 4, gt = 5, ge = 6, _ };

pub const AggregateFunction = enum(u8) { count = 1, sum = 2, min = 3, max = 4, _ };

pub const Where = extern struct {
    field: FieldRef,
    comparison: Comparison,
    reserved: [11]u8 = @splat(0),
    /// i128, little-endian.
    value: [16]u8,

    comptime {
        assert(@sizeOf(Where) == 32);
        assert(stdx.no_padding(Where));
    }
};

pub const AggregateRef = extern struct {
    function: AggregateFunction,
    reserved: [3]u8 = @splat(0),
    /// All zero for `count`.
    field: FieldRef,

    comptime {
        assert(@sizeOf(AggregateRef) == 8);
        assert(stdx.no_padding(AggregateRef));
    }
};

/// The `declare_view` event. A view is immutable once declared.
pub const ViewDefinition = extern struct {
    /// The catalog name rules (`catalog.zig`), zero-padded.
    name: [32]u8,
    table: u32,
    where_count: u8,
    group_by_count: u8,
    aggregate_count: u8,
    reserved_a: u8 = 0,
    /// Unused slots are all zero.
    where: [view_where_max]Where,
    group_by: [view_group_by_max]FieldRef,
    aggregates: [view_aggregates_max]AggregateRef,
    reserved_b: [28]u8 = @splat(0),

    comptime {
        assert(@sizeOf(ViewDefinition) == 256);
        assert(stdx.no_padding(ViewDefinition));
    }
};

pub const DeclareStatus = enum(u32) {
    /// Declared now; `View.state` says whether it is still building.
    created = 1,
    /// Already declared with this definition (the result names it).
    exists = 2,
    /// The name is declared with another definition.
    different = 3,
    /// The definition breaks a static rule (`views.definition_validate`).
    invalid = 4,
    /// The table is zero or reserved.
    table_invalid = 5,
    views_full = 6,
    table_views_full = 7,
    /// `min` or `max` (maintained from a later change, N49).
    unsupported = 8,
};

/// The `declare_view` result.
pub const DeclareResult = extern struct {
    status: DeclareStatus,
    reserved_a: u32 = 0,
    /// `created` and `exists`: the view's id. Otherwise zero.
    view_id: u64,
    /// `created`: this op. `exists`: the op it was declared at. Otherwise zero.
    op: u64,
    reserved_b: u64 = 0,

    comptime {
        assert(@sizeOf(DeclareResult) == 32);
        assert(stdx.no_padding(DeclareResult));
    }
};

pub const ViewState = enum(u8) {
    /// Answers for `get_view` of an id never declared.
    missing = 0,
    /// Rows written before the declaration are still being added (by pulses).
    building = 1,
    ready = 2,
    /// Two group keys hashed alike; the view stops being maintained (N49).
    failed = 3,
};

/// A view as the forest stores it.
pub const View = extern struct {
    id: u64,
    timestamp: u64,
    declared_op: u64,
    /// While building: rows with a smaller id are already in the groups.
    backfill_cursor: u64,
    /// Groups with a count above zero.
    group_count: u64,
    state: ViewState,
    reserved_a: [7]u8 = @splat(0),
    /// The sum, modulo 2^256 (little-endian), of the digests of the non-empty groups.
    hash: [32]u8,
    definition: ViewDefinition,
    reserved_b: [176]u8 = @splat(0),

    comptime {
        assert(@sizeOf(View) == 512);
        assert(stdx.no_padding(View));
    }
};

/// A group of a view as the forest stores it. Never removed: a group whose count falls to zero
/// is kept, empty, so that its history stays readable.
pub const Group = extern struct {
    /// `view_id << 64 | group_hash`.
    key: u128,
    timestamp: u64,
    count: u64,
    /// The group_by fields' bytes, then zeros; compared on every update (a hash collision fails
    /// the view).
    group_key: [group_key_size_max]u8,
    /// Per aggregate slot: an i128 sum, little-endian (zero for `count`).
    sums: [view_aggregates_max][16]u8,
    reserved: [64]u8 = @splat(0),

    comptime {
        assert(@sizeOf(Group) == 256);
        assert(stdx.no_padding(Group));
    }
};

/// The `get_view` event: the latest state of one view, and a page of its groups in storage
/// order (by group hash).
pub const ViewQuery = extern struct {
    /// The view, by id; or zero, and the view by `name`.
    view_id: u64,
    /// Groups with `group_hash >= group_hash_min`. Zero: from the first.
    group_hash_min: u64,
    /// Groups per page, at most; zero is invalid.
    limit: u32,
    /// With `view_id` zero: the view's name, zero-padded. Otherwise all zero.
    name: [32]u8 = @splat(0),
    reserved: [12]u8 = @splat(0),

    comptime {
        assert(@sizeOf(ViewQuery) == 64);
        assert(stdx.no_padding(ViewQuery));
    }
};

/// The `get_view` result: a header record, then the page's groups.
pub const ViewRecord = extern struct {
    kind: Kind,
    /// Header only.
    state: ViewState,
    flags: Flags,
    reserved_a: [5]u8 = @splat(0),
    view_id: u64,
    /// Header: the op the read executed at.
    op: u64,
    /// Header: the op the view was declared at.
    declared_op: u64,
    /// Header: groups with a count above zero.
    group_count: u64,
    /// Header, with `flags.more`: the next page's `group_hash_min`.
    cursor: u64,
    /// Group only.
    group_hash: u64,
    /// Group only.
    count: u64,
    /// Header: the view's hash.
    hash: [32]u8,
    /// Group only.
    group_key: [group_key_size_max]u8,
    /// Group only.
    sums: [view_aggregates_max][16]u8,

    pub const Kind = enum(u8) { header = 1, group = 2 };

    pub const Flags = packed struct(u8) {
        /// Header: groups remain after this page.
        more: bool = false,
        padding: u7 = 0,
    };

    comptime {
        assert(@sizeOf(ViewRecord) == 256);
        assert(stdx.no_padding(ViewRecord));
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
    /// A view's latest state and a page of its groups (N49).
    get_view = constants.vsr_operations_reserved + 4,
    /// Declares a view, maintained from then on in every commit (N49).
    declare_view = constants.vsr_operations_reserved + 5,
    /// `vsr.Operation.pulse`, mapped: backfills building views (N49).
    pulse = constants.vsr_operations_reserved + 6,

    pub fn EventType(comptime operation: Operation) type {
        return switch (operation) {
            .lookup_rows => RowKey,
            .commit => Entry,
            .get_changes => ChangesFilter,
            .get_history => HistoryFilter,
            .get_view => ViewQuery,
            .declare_view => ViewDefinition,
            .pulse => void,
        };
    }

    pub fn ResultType(comptime operation: Operation) type {
        return switch (operation) {
            .lookup_rows => RowValue,
            .commit => EntryResult,
            .get_changes, .get_history => Change,
            .get_view => ViewRecord,
            .declare_view => DeclareResult,
            .pulse => void,
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
            .get_changes, .get_history, .get_view, .declare_view, .pulse => false,
        };
    }

    /// Whether the operation is multi-batch encoded.
    pub inline fn is_multi_batch(operation: Operation) bool {
        return switch (operation) {
            .lookup_rows, .commit => true,
            .get_changes, .get_history, .get_view, .declare_view, .pulse => false,
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
            .get_view => count: {
                const query = std.mem.bytesAsValue(ViewQuery, batch[0..@sizeOf(ViewQuery)]);
                // +1 for the header.
                break :count @min(
                    query.limit +| 1,
                    operation.result_max(constants.message_body_size_max),
                );
            },
            .declare_view => 1,
            .pulse => 0,
        };
    }

    pub fn from_vsr(operation: vsr.Operation) ?Operation {
        if (operation == .pulse) return .pulse;
        if (operation.vsr_reserved()) return null;
        return vsr.Operation.to(Operation, operation);
    }

    pub fn to_vsr(operation: Operation) vsr.Operation {
        if (operation == .pulse) return .pulse;
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
        .add => {
            if (entry.op_seen != 0) return .op_seen_not_zero;
            return add_validate(&Add.from_entry(entry));
        },
        _ => return .kind_invalid,
    }
    return null;
}

/// An add's static checks; `delta_from`'s index is checked against the transaction at commit.
fn add_validate(add: *const Add) ?EntryStatus {
    if (add.reserved_a != 0 or !stdx.zeroed(&add.reserved_b) or add.flags.padding != 0) {
        return .reserved_not_zero;
    }
    if (add.field != .u64 and add.field != .i64) return .field_invalid;
    if (add.offset > value_size - 8) return .field_invalid;
    if (!add.flags.min and add.min != 0) return .field_invalid;
    if (!add.flags.max and add.max != 0) return .field_invalid;
    if (add.flags.min and add.flags.max) {
        const ordered = switch (add.field) {
            .u64 => add.min <= add.max,
            .i64 => @as(i64, @bitCast(add.min)) <= @as(i64, @bitCast(add.max)),
            _ => unreachable,
        };
        if (!ordered) return .field_invalid;
    }
    // So that any amount applied can be negated (`delta_from`).
    if (add.delta == std.math.minInt(i64)) return .field_invalid;
    if (add.flags.delta_from) {
        if (add.delta != 0) return .delta_from_invalid;
    } else {
        if (add.delta_from != 0) return .delta_from_invalid;
    }
    return null;
}

/// The amount an add applies to a field holding `old`, given its (resolved) `delta`, or null if
/// it would cross a bound without `clamp`. Pure: the state machine, the VOPR model and tests
/// share it.
pub fn add_amount(add: *const Add, old: u64, delta: i64) ?i64 {
    assert(delta != std.math.minInt(i64));
    if (delta == 0) return 0;
    const old_wide: i128 = switch (add.field) {
        .u64 => old,
        .i64 => @as(i64, @bitCast(old)),
        _ => unreachable,
    };
    // The bound in the direction of the move.
    const bound: i128 = if (delta > 0) switch (add.field) {
        .u64 => if (add.flags.max) add.max else std.math.maxInt(u64),
        .i64 => if (add.flags.max) @as(i64, @bitCast(add.max)) else std.math.maxInt(i64),
        _ => unreachable,
    } else switch (add.field) {
        .u64 => if (add.flags.min) add.min else 0,
        .i64 => if (add.flags.min) @as(i64, @bitCast(add.min)) else std.math.minInt(i64),
        _ => unreachable,
    };
    // Room left before the bound, never negative: a field already past it can move back.
    const room: i128 = @max(0, if (delta > 0) bound - old_wide else old_wide - bound);
    const magnitude: i128 = @abs(delta);
    if (magnitude <= room) return delta;
    if (!add.flags.clamp) return null;
    const applied: i64 = @intCast(room);
    return if (delta > 0) applied else -applied;
}

/// The field's bits after adding `applied` (as returned by `add_amount`).
pub fn add_apply(add: *const Add, old: u64, applied: i64) u64 {
    return switch (add.field) {
        .u64 => @intCast(@as(i128, old) + applied),
        .i64 => @bitCast(@as(i64, @intCast(@as(i128, @as(i64, @bitCast(old))) + applied))),
        _ => unreachable,
    };
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

test add_validate {
    const valid: Add = .{
        .delta = 5,
        .min = 0,
        .max = 0,
        .delta_from = 0,
        .offset = 72,
        .field = .u64,
        .flags = .{},
    };
    const entry_valid: Entry = .{
        .id = 1,
        .table = 1,
        .kind = .add,
        .op_seen = 0,
        .value = valid.value(),
    };
    try std.testing.expectEqual(null, entry_validate(&entry_valid));

    var entry = entry_valid;
    entry.op_seen = 1;
    try std.testing.expectEqual(EntryStatus.op_seen_not_zero, entry_validate(&entry).?);

    const Case = struct { add: Add, status: EntryStatus };
    var cases: [9]Case = @splat(.{ .add = valid, .status = .field_invalid });
    cases[0].add.offset = 73;
    cases[1].add.field = @enumFromInt(3);
    cases[2].add.min = 1; // Without `flags.min`.
    cases[3].add.flags = .{ .min = true, .max = true };
    cases[3].add.min = 2;
    cases[3].add.max = 1;
    cases[4].add.field = .i64;
    cases[4].add.flags = .{ .min = true, .max = true };
    cases[4].add.min = @bitCast(@as(i64, 1));
    cases[4].add.max = @bitCast(@as(i64, -1));
    cases[5].add.delta = std.math.minInt(i64);
    cases[6].add.flags = .{ .delta_from = true }; // With a delta.
    cases[6].status = .delta_from_invalid;
    cases[7].add.delta_from = 1; // Without `flags.delta_from`.
    cases[7].status = .delta_from_invalid;
    cases[8].add.reserved_b[47] = 1;
    cases[8].status = .reserved_not_zero;
    for (cases) |case| {
        entry.op_seen = 0;
        entry.value = case.add.value();
        try std.testing.expectEqual(case.status, entry_validate(&entry).?);
    }
}

test add_amount {
    const u: Add = .{
        .delta = 0,
        .min = 0,
        .max = 0,
        .delta_from = 0,
        .offset = 0,
        .field = .u64,
        .flags = .{},
    };
    // Within range, and past the type's range.
    try std.testing.expectEqual(@as(?i64, 5), add_amount(&u, 10, 5));
    try std.testing.expectEqual(@as(?i64, -10), add_amount(&u, 10, -10));
    try std.testing.expectEqual(@as(?i64, null), add_amount(&u, 10, -11));
    try std.testing.expectEqual(@as(?i64, null), add_amount(&u, std.math.maxInt(u64), 1));
    try std.testing.expectEqual(@as(?i64, 0), add_amount(&u, 3, 0));

    // "Reserve up to 30 from 20": clamped at the minimum.
    var reserve = u;
    reserve.flags = .{ .min = true, .clamp = true };
    try std.testing.expectEqual(@as(?i64, -20), add_amount(&reserve, 20, -30));
    try std.testing.expectEqual(@as(?i64, -5), add_amount(&reserve, 20, -5));
    try std.testing.expectEqual(@as(?i64, 0), add_amount(&reserve, 0, -5));

    // Only the bound in the direction of the move applies: a field below its minimum can rise.
    var bounded = u;
    bounded.flags = .{ .min = true, .max = true };
    bounded.min = 10;
    bounded.max = 20;
    try std.testing.expectEqual(@as(?i64, 3), add_amount(&bounded, 2, 3));
    try std.testing.expectEqual(@as(?i64, null), add_amount(&bounded, 2, -1));
    try std.testing.expectEqual(@as(?i64, null), add_amount(&bounded, 18, 3));
    bounded.flags.clamp = true;
    try std.testing.expectEqual(@as(?i64, 2), add_amount(&bounded, 18, 3));
    try std.testing.expectEqual(@as(?i64, 0), add_amount(&bounded, 25, 3));

    // i64: negative values, and both ends of the range.
    var signed = u;
    signed.field = .i64;
    const minus_five: u64 = @bitCast(@as(i64, -5));
    try std.testing.expectEqual(@as(?i64, -10), add_amount(&signed, minus_five, -10));
    const minus_fifteen: u64 = @bitCast(@as(i64, -15));
    try std.testing.expectEqual(minus_fifteen, add_apply(&signed, minus_five, -10));
    const max: u64 = @bitCast(@as(i64, std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(?i64, null), add_amount(&signed, max, 1));
    const min: u64 = @bitCast(@as(i64, std.math.minInt(i64)));
    try std.testing.expectEqual(@as(?i64, null), add_amount(&signed, min, -1));
    signed.flags = .{ .min = true, .clamp = true };
    signed.min = @bitCast(@as(i64, -100));
    try std.testing.expectEqual(@as(?i64, -95), add_amount(&signed, minus_five, -1000));
}

test row_key {
    try std.testing.expectEqual(@as(u128, 1) << 64 | 5, row_key(1, 5));
    try std.testing.expect(row_key(1, std.math.maxInt(u64)) < row_key(2, 0));
}
