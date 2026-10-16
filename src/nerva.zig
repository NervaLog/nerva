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

/// Size of a record's payload, in bytes (P123b).
pub const record_value_size = 448;

/// Tables from here up are Nerva's own (the catalog, documents, commit keys).
pub const tables_reserved_min: u32 = 0xFFFF_0000;

/// Tables from here up to `tables_reserved_min` hold records (P123b): 128-bit ids and
/// `record_value_size`-byte values. Tables below hold rows.
pub const record_tables_min: u32 = 0x8000_0000;

/// Whether `table` holds records.
pub fn table_is_record(table: u32) bool {
    return table >= record_tables_min and table < tables_reserved_min;
}

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

    pub const Member = .{
        .timestamp = 9,
        .key = 10,
        // `Member.position` while present: a group's members of one min or max slot, by value.
        .order = 11,
    };

    pub const GroupVersion = .{
        .timestamp = 12,
        // `group_version_key`: a group's versions, by op (N62).
        .version = 13,
    };

    pub const ViewVersion = .{
        .timestamp = 14,
        // `view_version_key`: a view's versions, by op (N62).
        .version = 15,
    };

    pub const Ledger = .{
        .timestamp = 16,
        .slot = 17,
    };

    pub const Record = .{
        .timestamp = 18,
        .key = 19,
    };

    pub const RecordChange = .{
        .timestamp = 20,
        // `record_key(table, id)`: a record's history, in timestamp order (P123b).
        .record_key = 21,
    };

    pub const Index = .{
        .timestamp = 22,
        .id = 23,
    };

    pub const IndexEntry = .{
        .timestamp = 24,
        .key = 25,
        // `IndexEntry.position` while present: an index's records, by `eq` key then order
        // (P123c).
        .order = 26,
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

/// The LSM key of a record (P123b): `table` in the high 32 bits, then the first 96 bits of
/// SHA-256 of the table and the id, little-endian. A table's records are adjacent (a view or an
/// index backfills them in key order). Two ids of one table that share a key are refused
/// (`id_collision`), never merged. Persisted: never change the derivation.
pub fn record_key(table: u32, id: u128) u128 {
    assert(table_is_record(table));
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva.record.v1");
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, table)));
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u128, id)));
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var low: [16]u8 = @splat(0);
    low[0..12].* = digest[0..12].*;
    return @as(u128, table) << 96 | std.mem.readInt(u128, &low, .little);
}

/// A record as stored in the forest (P123b): a row with a 128-bit id and a 448-byte value. A
/// delete leaves a tombstone, as for rows.
pub const Record = extern struct {
    /// `record_key(table, id)`.
    key: u128,
    id: u128,
    table: u32,
    flags: Row.RowFlags,
    /// The op of the last write (put or delete). Never zero.
    op: u64,
    /// Assigned when the record is first inserted; fixed for its lifetime.
    timestamp: u64,
    reserved: [8]u8 = @splat(0),
    value: [record_value_size]u8,

    comptime {
        assert(@sizeOf(Record) == 512);
        assert(stdx.no_padding(Record));
    }
};

/// Non-exhaustive: entries arrive from the wire, and unknown kinds must be rejected, not trusted.
pub const EntryKind = enum(u8) {
    read = 1,
    put = 2,
    delete = 3,
    /// Adds a delta to one field of the row, inside the commit; parameters in `value` (`Add`).
    add = 4,
    /// The transaction's commit key (`CommitKey`): only as its first entry, with `table` and
    /// `id` zero and the key in `value`'s first 16 bytes.
    key = 5,
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

/// The `commit_wide` event (P123b): an entry for a row or a record. Every commit runs on these:
/// `commit`'s entries are widened (`from_entry`) and checked by the same rules.
///
/// For a row (a table below `record_tables_min`), `id` fits 64 bits and `value` past
/// `value_size` is zero. For a record, `id` is any 128 bits and `value` is all of it; a record
/// takes `read`, `put` and `delete`, not `add`.
pub const WideEntry = extern struct {
    id: u128,
    /// Zero is invalid.
    table: u32,
    kind: EntryKind,
    reserved_a: [3]u8 = @splat(0),
    /// Reads only: the version observed. Zero means the row has never existed.
    op_seen: u64,
    reserved_b: [32]u8 = @splat(0),
    /// Puts: the new value. Adds: the `Add` parameters. Zero for reads and deletes.
    value: [record_value_size]u8,

    comptime {
        assert(@sizeOf(WideEntry) == 512);
        assert(stdx.no_padding(WideEntry));
    }

    /// `commit`'s entry as `commit_wide` would carry it: its reserved fields in `reserved_b`, so
    /// that the same rules refuse the same entries.
    pub fn from_entry(entry: *const Entry) WideEntry {
        var wide: WideEntry = .{
            .id = entry.id,
            .table = entry.table,
            .kind = entry.kind,
            .reserved_a = entry.reserved_a,
            .op_seen = entry.op_seen,
            .value = @splat(0),
        };
        wide.reserved_b[0..8].* = std.mem.toBytes(entry.reserved_b);
        wide.reserved_b[8..24].* = entry.reserved_c;
        wide.value[0..value_size].* = entry.value;
        return wide;
    }

    /// A row's 80 bytes of value.
    pub fn row_value(entry: *const WideEntry) *const [value_size]u8 {
        assert(!table_is_record(entry.table));
        return entry.value[0..value_size];
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
    /// A read or delete carries a value, or a row's put or add carries bytes past `value_size`
    /// (P123b).
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
    /// An add's field, bounds or delta are invalid, or an add names a record (P123b).
    field_invalid = 11,
    /// An add's `delta_from` does not name an earlier add of the same transaction.
    delta_from_invalid = 12,
    /// An add to a field that a view on its table filters or groups by (N52): adds must not
    /// move a row between a view's groups.
    view_key_field = 13,
    /// This op's budget of view group writes (`StateMachine.groups_per_op_max`) is spent by
    /// other transactions of the same request: nothing applied, retry in a later op (N52).
    views_busy = 14,
    /// The transaction alone touches more view groups (or `min`/`max` members) than one op
    /// allows: nothing applied, and no retry can succeed; split it (#32).
    views_too_large = 15,
    /// A conserved add (N75) that is not one half of a pair: a `pair` add without its partner
    /// right after it, a partner that breaks the pair rules, or another add naming a pair's
    /// first half in `delta_from`.
    unpaired = 16,
    /// A write that would change a conserved field (N75) other than by a pair: a put that
    /// changes its bytes, a delete of a row where it is not zero, or an add that overlaps it
    /// without matching it.
    conserved_write = 17,
    /// The transaction's key was committed before, by these same entries, at `op`: nothing
    /// applied now. A resend of a transaction whose reply was lost (`CommitKey`).
    committed_before = 18,
    /// Other entries committed under this key, at `op`: nothing applied, and these entries can
    /// never commit under it.
    key_reused = 19,
    /// Another key holds this key's row (their row ids collide): nothing applied, and nothing
    /// ever committed under this key. Commit under another key.
    key_collision = 20,
    /// A `key` entry that is not the transaction's first entry.
    key_misplaced = 21,
    /// A `key` entry whose key is zero, or whose `table`, `id` or rest of `value` is not zero.
    key_invalid = 22,
    /// A row's id that does not fit 64 bits (`commit_wide`, P123b).
    id_invalid = 23,
    /// Another id of the record's table holds its key (`record_key`): nothing applied. The
    /// record can never be written under this id.
    id_collision = 24,
};

/// Commit keys make a resent transaction commit at most once (P123). A transaction may start
/// with a `key` entry naming a 128-bit key the client chose. When the transaction commits, the
/// state machine also writes the key's row: a row of `table_commit_keys`, at
/// `commit_key_id(key)`, holding a `CommitKey`. The row is written once and never changed. A
/// later transaction under the same key commits nothing: it reports `committed_before` (the
/// same entries, at the original op), `key_reused` (other entries) or `key_collision` (another
/// key's row) on its key entry, and `aborted` on the rest. A transaction that did not commit
/// writes no key, so resending it executes it again.
pub const table_commit_keys: u32 = 0xFFFF_0003;

/// A key row's value.
pub const CommitKey = extern struct {
    key: u128,
    /// `vsr.checksum` of the transaction's entries after its key entry, as `WideEntry`s (P123b).
    checksum: u128,
    /// The transaction's entries after its key entry.
    entry_count: u32,
    reserved: [44]u8 = @splat(0),

    comptime {
        assert(@sizeOf(CommitKey) == value_size);
        assert(stdx.no_padding(CommitKey));
    }

    /// The key a `key` entry (an `Entry` or a `WideEntry`) names.
    pub fn entry_key(entry: anytype) u128 {
        assert(entry.kind == .key);
        return std.mem.readInt(u128, entry.value[0..16], .little);
    }
};

/// The `key` entry that starts a transaction committed under `key`.
pub fn commit_key_entry(key: u128) Entry {
    assert(key != 0);
    var entry: Entry = .{ .id = 0, .table = 0, .kind = .key, .op_seen = 0, .value = @splat(0) };
    std.mem.writeInt(u128, entry.value[0..16], key, .little);
    return entry;
}

/// The id of `key`'s row in `table_commit_keys`: the first 8 bytes of SHA-256, little-endian.
/// Persisted: never change the derivation.
pub fn commit_key_id(key: u128) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva.commit_key.v1");
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u128, key)));
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

/// The `commit` result, one per entry.
pub const EntryResult = extern struct {
    status: EntryStatus,
    reserved_a: u32 = 0,
    /// `ok`: the op the transaction committed at. `conflict`: the row's current version.
    /// `committed_before`, `key_reused`, `key_collision`: the op the key's row was written at.
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
        /// The first half of a pair (N75): the next entry is its partner.
        pair: bool = false,
        padding: u2 = 0,
    };

    comptime {
        assert(@sizeOf(Add) == value_size);
        assert(stdx.no_padding(Add));
    }

    /// An add's parameters, from an `Entry` or a row's `WideEntry`.
    pub fn from_entry(entry: anytype) Add {
        assert(entry.kind == .add);
        return std.mem.bytesToValue(Add, entry.value[0..value_size]);
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

/// The `lookup_records` event (P123b).
pub const RecordKey = extern struct {
    id: u128,
    table: u32,
    reserved: [12]u8 = @splat(0),

    comptime {
        assert(@sizeOf(RecordKey) == 32);
        assert(stdx.no_padding(RecordKey));
    }
};

/// The `lookup_records` result, one per event.
pub const RecordValue = extern struct {
    id: u128,
    table: u32,
    flags: RecordValueFlags,
    /// The record's version: zero if it has never existed, else the op of its last write
    /// (including a delete). Use it as `WideEntry.op_seen`.
    op: u64,
    /// The op at which this lookup executed.
    op_read: u64,
    reserved: [24]u8 = @splat(0),
    /// Zero unless `flags.exists`.
    value: [record_value_size]u8,

    pub const RecordValueFlags = packed struct(u32) {
        exists: bool = false,
        /// Another id holds this record's key (`id_collision`): it can never be written.
        collision: bool = false,
        padding: u30 = 0,
    };

    comptime {
        assert(@sizeOf(RecordValue) == 512);
        assert(stdx.no_padding(RecordValue));
    }
};

/// A committed write of a record, as stored and as `get_record_changes` and
/// `get_record_history` return it (P123b). Replies end with an `end` record, as `Change`'s do.
pub const RecordChange = extern struct {
    id: u128,
    table: u32,
    kind: ChangeKind,
    flags: Change.ChangeFlags,
    reserved_a: [2]u8 = @splat(0),
    op: u64,
    timestamp: u64,
    reserved_b: [24]u8 = @splat(0),
    /// The new value for `put`; zero for `delete` and `end`.
    value: [record_value_size]u8,

    comptime {
        assert(@sizeOf(RecordChange) == 512);
        assert(stdx.no_padding(RecordChange));
    }
};

/// The `get_record_history` event: one record's changes, newest first, as `HistoryFilter`.
pub const RecordHistoryFilter = extern struct {
    id: u128,
    table: u32,
    /// The maximum number of changes to scan, excluding the final `end` record.
    limit: u32,
    /// Return changes with `op <= op_max`: `maxInt(u64)` for the latest. Zero is invalid.
    op_max: u64,
    /// The cursor: scan changes with `timestamp <= timestamp_max`. Zero means from the newest.
    timestamp_max: u64,
    reserved: [24]u8 = @splat(0),

    comptime {
        assert(@sizeOf(RecordHistoryFilter) == 64);
        assert(stdx.no_padding(RecordHistoryFilter));
    }
};

// ---- Views maintained in the state machine (docs/DECISIONS.md N52) ----

/// Views, cluster-wide. View ids are 1..views_max, in declaration order.
pub const views_max = 64;
/// Views over one table.
pub const views_per_table_max = 4;
/// The bytes of a view's group_by fields, concatenated.
pub const group_key_size_max = 64;
// The budget of group writes per op, and the rows a pulse backfills, depend on the message
// size: `StateMachine.groups_per_op_max`.

/// `min` and `max` aggregates over one table, counted across its views (N62): each is a member
/// of its group's order for every row in the view.
pub const view_extremes_per_table_max = 4;

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

/// A field of a row's or record's value, resolved from the table's layout by the gateway.
pub const FieldRef = extern struct {
    /// The offset's low byte (`offset_of`).
    offset: u8,
    size: u8,
    kind: FieldKind,
    /// The offset's high byte: zero for a row's field, up to 1 for a record's (P123b). It was a
    /// reserved byte, always zero, before records.
    offset_high: u8 = 0,

    comptime {
        assert(@sizeOf(FieldRef) == 4);
        assert(stdx.no_padding(FieldRef));
    }

    pub fn offset_of(field: FieldRef) u16 {
        return @as(u16, field.offset_high) << 8 | field.offset;
    }

    pub fn at(offset: u16, size: u8, kind: FieldKind) FieldRef {
        return .{
            .offset = @truncate(offset),
            .size = size,
            .kind = kind,
            .offset_high = @intCast(offset >> 8),
        };
    }
};

/// The size of a value of `table`: a record's or a row's.
pub fn table_value_size(table: u32) u16 {
    return if (table_is_record(table)) record_value_size else value_size;
}

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
    /// `min` or `max` over a record table (P123b): a record's member would need its 128-bit
    /// id. (Over rows, maintained since N62.)
    unsupported = 8,
    /// The table's views would have more than `view_extremes_per_table_max` `min` and `max`
    /// aggregates.
    table_extremes_full = 9,
    /// The view filters or groups by a field of a ledger (N75).
    ledger_field = 10,
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
    /// Two group keys hashed alike; the view stops being maintained (N52).
    failed = 3,
};

/// A view as the forest stores it.
pub const View = extern struct {
    id: u64,
    timestamp: u64,
    declared_op: u64,
    /// While building: rows with a smaller id are already in the groups. Over a record table
    /// (P123b): the low 64 of the 96 bits of the record keys below which records are.
    backfill_cursor: u64,
    /// Groups with a count above zero.
    group_count: u64,
    state: ViewState,
    reserved_a: [7]u8 = @splat(0),
    /// The sum, modulo 2^256 (little-endian), of the digests of the non-empty groups.
    hash: [32]u8,
    definition: ViewDefinition,
    /// Over a record table, while building: the high 32 bits of the cursor (P123b).
    backfill_cursor_high: u32 = 0,
    reserved_b: [172]u8 = @splat(0),

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
    /// Per aggregate slot, an i128, little-endian: the sum (`sum`), the smallest or largest
    /// value (`min`, `max`; zero while the group is empty), or zero (`count`).
    sums: [view_aggregates_max][16]u8,
    /// The last op that changed the group (N66): a read as of a later op needs no version.
    op: u64 = 0,
    reserved: [56]u8 = @splat(0),

    comptime {
        assert(@sizeOf(Group) == 256);
        assert(stdx.no_padding(Group));
    }
};

/// A row's place in one `min` or `max` slot of a view (N62): one per view, slot and row the
/// view has seen. Never removed: a row that leaves the view is kept, absent (out of `order`).
pub const Member = extern struct {
    /// `member_key(view_id, slot, row id)`.
    key: u128,
    /// While present, `member_order(order prefix, value)`, indexed as `order`: the members of a
    /// group's slot, by value. Zero while absent.
    position: u128,
    timestamp: u64,
    view_id: u32,
    slot: u8,
    flags: Flags,
    reserved: [2]u8 = @splat(0),
    /// While present, the group's key (compared when the order is read: a prefix collision
    /// fails the view). Zero while absent.
    group_key: [group_key_size_max]u8,
    /// While present, the row's value of the slot's field, an i128, little-endian.
    value: [16]u8,

    pub const Flags = packed struct(u8) {
        present: bool = false,
        padding: u7 = 0,
    };

    comptime {
        assert(@sizeOf(Member) == 128);
        assert(stdx.no_padding(Member));
    }
};

/// A group as one op left it (N62): written once for every group an op changes, so a view can
/// be read as of a past op.
pub const GroupVersion = extern struct {
    /// `group_version_key(group key, op)`.
    version: u128,
    timestamp: u64,
    op: u64,
    /// The group's `Group.key`.
    key: u128,
    count: u64,
    group_key: [group_key_size_max]u8,
    sums: [view_aggregates_max][16]u8,
    reserved: [40]u8 = @splat(0),

    comptime {
        assert(@sizeOf(GroupVersion) == 256);
        assert(stdx.no_padding(GroupVersion));
    }
};

/// A view's header as one op left it (N62): written once for every view an op changes.
pub const ViewVersion = extern struct {
    /// `view_version_key(view_id, op)`.
    version: u128,
    timestamp: u64,
    op: u64,
    group_count: u64,
    state: ViewState,
    reserved_a: [7]u8 = @splat(0),
    hash: [32]u8,
    reserved_b: [48]u8 = @splat(0),

    comptime {
        assert(@sizeOf(ViewVersion) == 128);
        assert(stdx.no_padding(ViewVersion));
    }
};

/// Ops are below 2^57 (`group_version_key`), about 4,500 years at a million ops a second.
pub const version_op_bits = 57;

/// A member's place in the members tree: unique per view, slot and row.
pub fn member_key(view_id: u64, slot: u8, id: u64) u128 {
    assert(view_id >= 1 and view_id <= views_max);
    assert(slot < view_aggregates_max);
    return @as(u128, view_id) << 72 | @as(u128, slot) << 64 | id;
}

/// A member's place in its group's order: the group's prefix, then the value, ordered.
pub fn member_order(prefix: u64, value_ordered: u64) u128 {
    return @as(u128, prefix) << 64 | value_ordered;
}

/// A group's version at `op`: `view_id`, then the group hash, then the op, so that a group's
/// versions are adjacent and ordered by op.
pub fn group_version_key(group_key: u128, op: u64) u128 {
    const view_id: u64 = @intCast(group_key >> 64);
    const group_hash: u64 = @truncate(group_key);
    assert(view_id >= 1 and view_id <= views_max);
    assert(op < 1 << version_op_bits);
    return @as(u128, view_id) << (64 + version_op_bits) |
        @as(u128, group_hash) << version_op_bits | op;
}

pub fn view_version_key(view_id: u64, op: u64) u128 {
    assert(view_id >= 1 and view_id <= views_max);
    return @as(u128, view_id) << 64 | op;
}

/// The `get_view` event: the state of one view, latest or as of a past op, and a page of its
/// groups in storage order (by group hash).
pub const ViewQuery = extern struct {
    /// The view, by id; or zero, and the view by `name`.
    view_id: u64,
    /// Groups with `group_hash >= group_hash_min`. Zero: from the first.
    group_hash_min: u64,
    /// Groups per page, at most; zero is invalid.
    limit: u32,
    /// With `view_id` zero: the view's name, zero-padded. Otherwise all zero.
    name: [32]u8 = @splat(0),
    reserved: [4]u8 = @splat(0),
    /// Zero: the latest. Otherwise the view as the op `as_of` left it (N62). A page then ends
    /// early after `StateMachine.view_as_of_scans_max` groups changed since `as_of` (N66). Taken from v0.3.0's reserved
    /// bytes, which its clients send as zeros: their queries read the latest, as they did.
    as_of: u64 = 0,

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
    /// Group: the group's key. Header (N66): the view's name, zero-padded (zero for an id never
    /// declared).
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

// ---- Declared indexes (P123c) ----

/// Indexes, cluster-wide. Index ids are 1..indexes_max, in declaration order.
pub const indexes_max = 64;
/// Indexes over one table: each takes one of a record's `min`/`max` timestamps, which records
/// do not use (`StateMachine.entry_timestamps`).
pub const indexes_per_table_max = view_extremes_per_table_max;
pub const index_eq_max = 3;
pub const index_where_max = 4;

/// The `declare_index` event: an index over a record table, immutable once declared. It lists
/// the table's records whose value passes `where`, by the bytes of their `eq` fields (scanned
/// for one `eq` key at a time), then by their `order` field (or, without one, the op of their
/// last write), then by when they entered the index.
pub const IndexDefinition = extern struct {
    /// The catalog name rules (`catalog.zig`), zero-padded.
    name: [32]u8,
    /// A record table.
    table: u32,
    eq_count: u8,
    where_count: u8,
    flags: Flags,
    reserved_a: u8 = 0,
    /// Any kind; at most `group_key_size_max` bytes between them. Unused slots are zero.
    eq: [index_eq_max]FieldRef,
    /// An unsigned, signed or boolean field when `flags.order`; zero otherwise.
    order: FieldRef,
    where: [index_where_max]Where,
    reserved_b: [72]u8 = @splat(0),

    pub const Flags = packed struct(u8) {
        order: bool = false,
        padding: u7 = 0,
    };

    comptime {
        assert(@sizeOf(IndexDefinition) == 256);
        assert(stdx.no_padding(IndexDefinition));
    }
};

pub const DeclareIndexStatus = enum(u32) {
    /// Declared now; it builds (pulses add the records already written) before it answers.
    created = 1,
    /// Already declared with this definition (the result names it).
    exists = 2,
    /// The name is declared with another definition.
    different = 3,
    /// The definition breaks a static rule (`indexes.definition_validate`).
    invalid = 4,
    /// The table is not a record table.
    table_invalid = 5,
    indexes_full = 6,
    table_indexes_full = 7,
};

/// The `declare_index` result.
pub const DeclareIndexResult = extern struct {
    status: DeclareIndexStatus,
    reserved_a: u32 = 0,
    /// `created` and `exists`: the index's id. Otherwise zero.
    index_id: u64,
    /// `created`: this op. `exists`: the op it was declared at. Otherwise zero.
    op: u64,
    reserved_b: u64 = 0,

    comptime {
        assert(@sizeOf(DeclareIndexResult) == 32);
        assert(stdx.no_padding(DeclareIndexResult));
    }
};

pub const IndexState = enum(u8) {
    /// Answers for a query of an id or name never declared.
    missing = 0,
    /// Records written before the declaration are still being added (by pulses).
    building = 1,
    ready = 2,
};

/// An index as the forest stores it.
pub const Index = extern struct {
    id: u64,
    timestamp: u64,
    /// While building: the table's records whose key's low 96 bits are below are indexed.
    backfill_cursor: u128,
    declared_op: u64,
    /// The records in the index.
    entry_count: u64,
    state: IndexState,
    reserved_a: [15]u8 = @splat(0),
    definition: IndexDefinition,
    reserved_b: [192]u8 = @splat(0),

    comptime {
        assert(@sizeOf(Index) == 512);
        assert(stdx.no_padding(Index));
    }
};

/// A record's place in one index (P123c): one per index and record the index has seen. Never
/// removed: a record that leaves the index is kept, absent (out of `order`).
pub const IndexEntry = extern struct {
    /// `index_entry_key(index_id, record key)`.
    key: u128,
    /// While present, `index_position(prefix, order)`, indexed as `order`. Zero while absent.
    position: u128,
    /// The record's id.
    id: u128,
    timestamp: u64,
    index_id: u32,
    flags: Flags,
    reserved: [3]u8 = @splat(0),
    /// While present, the `eq` fields' bytes, then zeros: compared when the index is read (a
    /// prefix collision is skipped). Zero while absent.
    eq_key: [group_key_size_max]u8,

    pub const Flags = packed struct(u8) {
        present: bool = false,
        padding: u7 = 0,
    };

    comptime {
        assert(@sizeOf(IndexEntry) == 128);
        assert(stdx.no_padding(IndexEntry));
    }
};

/// An entry's place in the entries tree: unique per index and record (a record's key is its
/// table, which the index names, and 96 bits).
pub fn index_entry_key(index_id: u64, record_key_: u128) u128 {
    assert(index_id >= 1 and index_id <= indexes_max);
    return @as(u128, index_id) << 96 | (record_key_ & std.math.maxInt(u96));
}

/// An entry's place in its index's order: the `eq` key's prefix, then the order value.
pub fn index_position(prefix: u64, order: u64) u128 {
    return @as(u128, prefix) << 64 | order;
}

/// The `get_index` event: an index by id (P123c). The result is its `Index`, all zero (state
/// `missing`) if no index has the id.
pub const IndexGet = extern struct {
    id: u64,
    reserved: [24]u8 = @splat(0),

    comptime {
        assert(@sizeOf(IndexGet) == 32);
        assert(stdx.no_padding(IndexGet));
    }
};

/// The `scan_index` event: a page of one index's records with one `eq` key, by order, within
/// `[order_min, order_max]` (order values as `views.integer_ordered` encodes them).
pub const IndexQuery = extern struct {
    /// Zero to name the index by `name`.
    index_id: u64,
    /// The `eq` fields' bytes, one after another, then zeros.
    eq_key: [group_key_size_max]u8,
    order_min: u64,
    order_max: u64,
    /// Continue after the record at this order and timestamp (a reply's header names them).
    /// Zero timestamp: from the start of the range.
    cursor_order: u64,
    cursor_timestamp: u64,
    /// The most records to return.
    limit: u32,
    flags: Flags,
    reserved_a: [3]u8 = @splat(0),
    /// When `index_id` is zero.
    name: [32]u8,
    reserved_b: [48]u8 = @splat(0),

    pub const Flags = packed struct(u8) {
        descending: bool = false,
        padding: u7 = 0,
    };

    comptime {
        assert(@sizeOf(IndexQuery) == 192);
        assert(stdx.no_padding(IndexQuery));
    }
};

/// The `scan_index` result: a header, then one record per entry found.
pub const IndexRecord = extern struct {
    /// `record`: the record's id.
    id: u128,
    /// `record`: its table. `header`: the index's table.
    table: u32,
    kind: Kind,
    flags: Flags,
    /// `header`: the index's state.
    state: IndexState,
    reserved_a: u8 = 0,
    /// `header`: the op the scan read at. `record`: the record's version.
    op: u64,
    /// `record`: its order value. `header`, with `flags.more`: the next query's
    /// `cursor_order`.
    order: u64,
    /// `record`: when it entered the index. `header`, with `flags.more`: the next query's
    /// `cursor_timestamp`.
    timestamp: u64,
    /// `header`: the index's id (zero if missing).
    index_id: u64,
    reserved_b: [8]u8 = @splat(0),
    /// `record`: its value.
    value: [record_value_size]u8,

    pub const Kind = enum(u8) { header = 1, record = 2 };

    pub const Flags = packed struct(u8) {
        /// `header`: the range holds more records after this page.
        more: bool = false,
        padding: u7 = 0,
    };

    comptime {
        assert(@sizeOf(IndexRecord) == 512);
        assert(stdx.no_padding(IndexRecord));
    }
};

/// Operations exported by Nerva.
// ---- Ledgers: conserved fields (docs/DECISIONS.md N75) ----

/// Ledgers, cluster-wide.
pub const ledgers_max = 64;
pub const ledger_fields_max = 16;

/// A conserved field: an `i64` at `offset` in every row of `table`.
pub const LedgerField = extern struct {
    table: u32,
    /// 8-aligned, at most `value_size - 8`.
    offset: u8,
    flags: Flags,
    reserved: [2]u8 = @splat(0),
    /// No conserved add moves the field down past it, when `flags.floor`. Zero otherwise.
    floor: i64,

    pub const Flags = packed struct(u8) {
        floor: bool = false,
        padding: u7 = 0,
    };

    comptime {
        assert(@sizeOf(LedgerField) == 16);
        assert(stdx.no_padding(LedgerField));
    }
};

/// The `declare_ledger` event. A ledger is immutable once declared: its fields change only by
/// pairs of adds that move one amount from one of them to another.
pub const LedgerDefinition = extern struct {
    /// At least 1, chosen by the client.
    id: u32,
    field_count: u8,
    reserved: [3]u8 = @splat(0),
    /// Strictly ascending by `(table, offset)`; unused slots are all zero.
    fields: [ledger_fields_max]LedgerField,

    comptime {
        assert(@sizeOf(LedgerDefinition) == 264);
        assert(stdx.no_padding(LedgerDefinition));
    }
};

pub const DeclareLedgerStatus = enum(u32) {
    created = 1,
    /// Already declared with this definition.
    exists = 2,
    /// The id is declared with another definition.
    ledger_immutable = 3,
    /// A field is already in another ledger.
    ledger_field_taken = 4,
    /// The definition breaks a static rule (`ledgers.definition_validate`).
    invalid = 5,
    /// A field's table is zero or reserved.
    table_invalid = 6,
    ledgers_full = 7,
    /// A maintained view filters or groups by one of the fields.
    field_viewed = 8,
};

/// The `declare_ledger` result.
pub const DeclareLedgerResult = extern struct {
    status: DeclareLedgerStatus,
    reserved: u32 = 0,
    /// `created`: this op. `exists`: the op it was declared at. Otherwise zero.
    op: u64,

    comptime {
        assert(@sizeOf(DeclareLedgerResult) == 16);
        assert(stdx.no_padding(DeclareLedgerResult));
    }
};

/// The `get_ledger` event: a ledger by `id`, or by `slot` (its place in declaration order, from
/// 1) when `id` is zero, so that every ledger can be listed (`nerva export`, N80). Not both.
pub const LedgerQuery = extern struct {
    id: u32,
    reserved: [4]u8 = @splat(0),
    /// Taken from 0.0.4's reserved bytes before it shipped.
    slot: u64 = 0,

    comptime {
        assert(@sizeOf(LedgerQuery) == 16);
        assert(stdx.no_padding(LedgerQuery));
    }
};

/// A ledger as the forest stores it, and the `get_ledger` result (all zero if not declared).
pub const Ledger = extern struct {
    /// 1..ledgers_max, in declaration order: the groove's key, so that every ledger can be
    /// prefetched by slot.
    slot: u64,
    timestamp: u64,
    /// The op the ledger was declared at.
    op: u64,
    reserved_a: u64 = 0,
    definition: LedgerDefinition,
    reserved_b: [216]u8 = @splat(0),

    comptime {
        assert(@sizeOf(Ledger) == 512);
        assert(stdx.no_padding(Ledger));
    }
};

pub const Operation = enum(u8) {
    lookup_rows = constants.vsr_operations_reserved + 0,
    commit = constants.vsr_operations_reserved + 1,
    get_changes = constants.vsr_operations_reserved + 2,
    get_history = constants.vsr_operations_reserved + 3,
    /// A view's latest state and a page of its groups (N52).
    get_view = constants.vsr_operations_reserved + 4,
    /// Declares a view, maintained from then on in every commit (N52).
    declare_view = constants.vsr_operations_reserved + 5,
    /// `vsr.Operation.pulse`, mapped: backfills building views (N52).
    pulse = constants.vsr_operations_reserved + 6,
    /// Declares a ledger: a set of conserved fields (N75).
    declare_ledger = constants.vsr_operations_reserved + 7,
    get_ledger = constants.vsr_operations_reserved + 8,
    /// `commit` with wide entries: rows and records in one transaction (P123b).
    commit_wide = constants.vsr_operations_reserved + 9,
    lookup_records = constants.vsr_operations_reserved + 10,
    get_record_changes = constants.vsr_operations_reserved + 11,
    get_record_history = constants.vsr_operations_reserved + 12,
    /// Declares an index over a record table, maintained from then on (P123c).
    declare_index = constants.vsr_operations_reserved + 13,
    scan_index = constants.vsr_operations_reserved + 14,
    get_index = constants.vsr_operations_reserved + 15,

    pub fn EventType(comptime operation: Operation) type {
        return switch (operation) {
            .lookup_rows => RowKey,
            .commit => Entry,
            .get_changes => ChangesFilter,
            .get_history => HistoryFilter,
            .get_view => ViewQuery,
            .declare_view => ViewDefinition,
            .pulse => void,
            .declare_ledger => LedgerDefinition,
            .get_ledger => LedgerQuery,
            .commit_wide => WideEntry,
            .lookup_records => RecordKey,
            .get_record_changes => ChangesFilter,
            .get_record_history => RecordHistoryFilter,
            .declare_index => IndexDefinition,
            .scan_index => IndexQuery,
            .get_index => IndexGet,
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
            .declare_ledger => DeclareLedgerResult,
            .get_ledger => Ledger,
            .commit_wide => EntryResult,
            .lookup_records => RecordValue,
            .get_record_changes, .get_record_history => RecordChange,
            .declare_index => DeclareIndexResult,
            .scan_index => IndexRecord,
            .get_index => Index,
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
            .lookup_rows, .commit, .commit_wide, .lookup_records => true,
            .get_changes,
            .get_history,
            .get_view,
            .declare_view,
            .pulse,
            .declare_ledger,
            .get_ledger,
            .get_record_changes,
            .get_record_history,
            .declare_index,
            .scan_index,
            .get_index,
            => false,
        };
    }

    /// Whether the operation is multi-batch encoded.
    pub inline fn is_multi_batch(operation: Operation) bool {
        return switch (operation) {
            .lookup_rows, .commit, .commit_wide, .lookup_records => true,
            .get_changes,
            .get_history,
            .get_view,
            .declare_view,
            .pulse,
            .declare_ledger,
            .get_ledger,
            .get_record_changes,
            .get_record_history,
            .declare_index,
            .scan_index,
            .get_index,
            => false,
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
            inline .lookup_rows,
            .commit,
            .commit_wide,
            .lookup_records,
            => |operation_comptime| @intCast(@divExact(
                batch.len,
                @sizeOf(operation_comptime.EventType()),
            )),
            inline .get_changes,
            .get_history,
            .get_record_changes,
            .get_record_history,
            => |operation_comptime| count: {
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
            .scan_index => count: {
                const query = std.mem.bytesAsValue(IndexQuery, batch[0..@sizeOf(IndexQuery)]);
                // +1 for the header.
                break :count @min(
                    query.limit +| 1,
                    operation.result_max(constants.message_body_size_max),
                );
            },
            .declare_view, .declare_ledger, .get_ledger, .declare_index, .get_index => 1,
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

/// Static checks on one `commit_wide` entry, independent of state, by `entry_validate`'s rules,
/// and for records' and rows' ids and values (P123b). Returns null if the entry is valid.
pub fn wide_entry_validate(entry: *const WideEntry) ?EntryStatus {
    const record = table_is_record(entry.table);
    if (entry.kind == .key) {
        if (entry.table != 0 or entry.id != 0 or entry.op_seen != 0 or
            !stdx.zeroed(entry.value[16..]) or CommitKey.entry_key(entry) == 0)
        {
            return .key_invalid;
        }
    } else {
        if (entry.table == 0) return .table_invalid;
        // Only the state machine writes key rows, for `key` entries.
        if (entry.table == table_commit_keys) return .table_invalid;
        if (!record and entry.id > std.math.maxInt(u64)) return .id_invalid;
    }
    if (!stdx.zeroed(&entry.reserved_a) or !stdx.zeroed(&entry.reserved_b)) {
        return .reserved_not_zero;
    }
    switch (entry.kind) {
        .read => {
            if (!stdx.zeroed(&entry.value)) return .value_not_zero;
        },
        .put => {
            if (entry.op_seen != 0) return .op_seen_not_zero;
            if (!record and !stdx.zeroed(entry.value[value_size..])) return .value_not_zero;
        },
        .delete => {
            if (!stdx.zeroed(&entry.value)) return .value_not_zero;
            if (entry.op_seen != 0) return .op_seen_not_zero;
        },
        .add => {
            if (entry.op_seen != 0) return .op_seen_not_zero;
            // Records take no adds: their fields are written whole.
            if (record) return .field_invalid;
            if (!stdx.zeroed(entry.value[value_size..])) return .value_not_zero;
            return add_validate(&Add.from_entry(entry));
        },
        .key => {},
        _ => return .kind_invalid,
    }
    return null;
}

/// Static checks on one entry, independent of state. Returns null if the entry is valid.
pub fn entry_validate(entry: *const Entry) ?EntryStatus {
    if (entry.kind == .key) {
        if (entry.table != 0 or entry.id != 0 or entry.op_seen != 0 or
            !stdx.zeroed(entry.value[16..]) or CommitKey.entry_key(entry) == 0)
        {
            return .key_invalid;
        }
    } else {
        if (entry.table == 0) return .table_invalid;
        // Only the state machine writes key rows, for `key` entries.
        if (entry.table == table_commit_keys) return .table_invalid;
    }
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
        .key => {},
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

/// The add as it applies to a conserved field with `floor` (N75): its `min` is raised to the
/// floor, so that it never moves the field down past it. Pure, like `add_amount`, which takes
/// the result; a field already below its floor can still move up.
pub fn ledger_bounds(add: *const Add, floor: ?i64) Add {
    assert(add.field == .i64);
    var bounded = add.*;
    if (floor) |value| {
        const min: i64 = if (add.flags.min) @max(@as(i64, @bitCast(add.min)), value) else value;
        bounded.flags.min = true;
        bounded.min = @bitCast(min);
    }
    return bounded;
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
