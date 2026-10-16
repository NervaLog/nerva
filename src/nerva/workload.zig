//! The VOPR workload for Nerva: random transactions over a small key space (so that conflicts
//! are common), point lookups, change-feed scans and row histories (as-of reads).
//!
//! It also plays a receipt race: several clients (daemons) race to claim the same few
//! receipts, each claim being a read at the version seen plus a write of the next sequence. The
//! checker asserts, independently of the model, that every receipt's sequence advances by exactly
//! one per winning claim, so no (receipt, seq) is ever claimed twice.
//!
//! And it plays hot budgets (G8, N42): clients fund, reserve and release against a few shared
//! budgets with adds only (no reads), never conflicting. The checker asserts, independently of
//! the model, that each budget's available plus held equals what was funded, after every add.
//!
//! And a declared ledger (N75): pairs fund, reserve, post and void between accounts and a
//! source, among unpaired halves, puts and deletes of balances and straddling adds, which must
//! all fail. The checker asserts, independently of the row model, that the ledger's total stays
//! what it was at its declaration (zero), and that no floored field goes below its floor.
//!
//! And commit keys (P123): some transactions start with a key, and some are sent again, as
//! sent or with other entries. The model keeps each committed key's entries, so a resend must
//! report `committed_before` at the op its transaction committed at, and apply nothing.
//!
//! And records and indexes (P123b, P123c): transactions of records (128-bit ids, 448-byte
//! values) read, put and delete a small set of records; others move money by ledger pairs and
//! write a new fact record in the same transaction, which must commit exactly when the money
//! moves. Four indexes are declared at random times, so pulses build them over records already
//! written. Lookups, the records' feed and histories, and every index scan (pages, cursors, both
//! directions, as the index orders ties) and index count are checked against a model of the
//! records.
//!
//! The simulator delivers replies in op order, so the workload checks each reply against an
//! in-memory model of the committed state at that op: every status, version, value and change
//! must match exactly. This checks strict serializability of commits and the change feed.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.workload);

const stdx = @import("stdx");
const constants = @import("../constants.zig");
const vsr = @import("../vsr.zig");
const nerva = @import("../nerva.zig");
const MultiBatchDecoder = vsr.multi_batch.MultiBatchDecoder;
const MultiBatchEncoder = vsr.multi_batch.MultiBatchEncoder;
const TimestampRange = @import("../lsm/timestamp_range.zig").TimestampRange;

const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const EntryStatus = nerva.EntryStatus;
const Add = nerva.Add;
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
const Change = nerva.Change;
const ChangesFilter = nerva.ChangesFilter;
const HistoryFilter = nerva.HistoryFilter;
const value_size = nerva.value_size;
const ViewDefinition = nerva.ViewDefinition;
const ViewRecord = nerva.ViewRecord;
const DeclareResult = nerva.DeclareResult;
const views = @import("views.zig");
const ledgers = @import("ledgers.zig");
const indexes = @import("indexes.zig");
const WideEntry = nerva.WideEntry;
const record_value_size = nerva.record_value_size;

/// The table holding receipts. Random transactions never touch it.
pub const receipts_table: u32 = 100;

/// The payload of a receipt row.
pub const Receipt = extern struct {
    /// A per-agent sequence: advances by one per claim.
    seq: u64,
    /// The client (daemon) that made the last claim.
    owner: u64,
    reserved: [64]u8 = @splat(0),

    comptime {
        assert(@sizeOf(Receipt) == value_size);
        assert(stdx.no_padding(Receipt));
    }

    pub fn from_value(value: *const [value_size]u8) Receipt {
        return std.mem.bytesToValue(Receipt, value);
    }

    pub fn to_value(receipt: Receipt) [value_size]u8 {
        return std.mem.toBytes(receipt);
    }
};

/// A claim: read the receipt at the version seen, write the next sequence with a new owner.
pub fn receipt_claim(id: u64, op_seen: u64, seq_seen: u64, owner: u64) [2]Entry {
    return .{
        .{
            .id = id,
            .table = receipts_table,
            .kind = .read,
            .op_seen = op_seen,
            .value = @splat(0),
        },
        .{
            .id = id,
            .table = receipts_table,
            .kind = .put,
            .op_seen = 0,
            .value = (Receipt{ .seq = seq_seen + 1, .owner = owner }).to_value(),
        },
    };
}

/// The table holding hot budgets: `available` at offset 0, `held` at offset 8 (u64s).
pub const budgets_table: u32 = 101;

fn budget_add(id: u64, offset: u8, delta: i64, delta_from: ?u32) Entry {
    const parameters: Add = .{
        .delta = delta,
        .min = 0,
        .max = 0,
        .delta_from = delta_from orelse 0,
        .offset = offset,
        .field = .u64,
        // Clamped at the type's minimum (zero): a reservation takes what there is.
        .flags = .{ .clamp = true, .create = true, .delta_from = delta_from != null },
    };
    return .{
        .id = id,
        .table = budgets_table,
        .kind = .add,
        .op_seen = 0,
        .value = parameters.value(),
    };
}

/// Ledger 1 (N75): accounts in one table (`available` at 0 and `held` at 8, i64s floored at
/// 0) and one unfloored source in another, which funds them and so goes negative. Only ledger
/// traffic touches these tables, and only once the ledger is declared: their total stays 0.
pub const ledger_accounts_table: u32 = 102;
pub const ledger_sources_table: u32 = 103;
/// Ledger probes name a field of this table, which no ledger holds.
const ledger_probe_table: u32 = 104;

fn ledger_main() nerva.LedgerDefinition {
    var definition = std.mem.zeroes(nerva.LedgerDefinition);
    definition.id = 1;
    definition.field_count = 3;
    definition.fields[0] = .{
        .table = ledger_accounts_table,
        .offset = 0,
        .flags = .{ .floor = true },
        .floor = 0,
    };
    definition.fields[1] = .{
        .table = ledger_accounts_table,
        .offset = 8,
        .flags = .{ .floor = true },
        .floor = 0,
    };
    definition.fields[2] = .{
        .table = ledger_sources_table,
        .offset = 0,
        .flags = .{},
        .floor = 0,
    };
    return definition;
}

/// An add to the i64 at `offset`: a pair's first half (`pair`), or its partner (`partner_of`).
fn ledger_add(table: u32, id: u64, offset: u8, delta: i64, options: struct {
    pair: bool = false,
    clamp: bool = false,
    partner_of: ?u32 = null,
}) Entry {
    const parameters: Add = .{
        .delta = delta,
        .min = 0,
        .max = 0,
        .delta_from = options.partner_of orelse 0,
        .offset = offset,
        .field = .i64,
        .flags = .{
            .clamp = options.clamp,
            .create = true,
            .delta_from = options.partner_of != null,
            .pair = options.pair,
        },
    };
    return .{ .id = id, .table = table, .kind = .add, .op_seen = 0, .value = parameters.value() };
}

fn ledger_is(entries: []const Entry) bool {
    for (entries) |*entry| {
        if (entry.table != ledger_accounts_table and entry.table != ledger_sources_table) {
            return false;
        }
    }
    return entries.len > 0;
}

/// A signed integer in `[min, max]` (the PRNG draws unsigned ones).
fn signed_range(prng: *stdx.PRNG, min: i64, max: i64) i64 {
    assert(min <= max);
    const span: u64 = @intCast(@as(i128, max) - min);
    return @intCast(@as(i128, min) + prng.int_inclusive(u64, span));
}

/// A filter limit: usually `[0, small_max]` (zero is invalid, and returns nothing); sometimes at
/// the largest a reply holds, just past it, or `maxInt(u32)`, which must be clamped (N49).
fn limit_random(prng: *stdx.PRNG, small_max: u32, limit_max: u32) u32 {
    return switch (prng.chances(.{ .small = 20, .max = 1, .past = 1, .huge = 1 })) {
        .small => prng.int_inclusive(u32, small_max),
        .max => limit_max,
        .past => limit_max + 1,
        .huge => std.math.maxInt(u32),
    };
}

/// A timestamp past the largest valid one (`maxInt(u63)`): a filter holding it is invalid.
fn timestamp_invalid(prng: *stdx.PRNG) u64 {
    return prng.range_inclusive(u64, TimestampRange.timestamp_max + 1, std.math.maxInt(u64));
}

/// Checks `entry_validate`'s answer against the rules `EntryStatus` documents, written apart
/// from it (N49): the entry is valid exactly when it breaks none of them, and otherwise the
/// status names one it breaks. (Which one wins when several are broken is `entry_validate`'s
/// choice.) An add's own parameters are `nerva_adds`'s to fuzz: when only they are wrong, any of
/// the add statuses may be named.
fn entry_status_check(entry: *const Entry, status: ?EntryStatus) void {
    var broken = std.EnumSet(EntryStatus).initEmpty();
    const kind_known = switch (entry.kind) {
        .read, .put, .delete, .add, .key => true,
        _ => false,
    };
    if (!kind_known) broken.insert(.kind_invalid);
    if (entry.kind == .key) {
        // A key names no row: the state machine derives its row from the key.
        if (entry.table != 0 or entry.id != 0 or entry.op_seen != 0 or
            !stdx.zeroed(entry.value[16..]) or stdx.zeroed(entry.value[0..16]))
        {
            broken.insert(.key_invalid);
        }
    } else if (entry.table == 0 or entry.table == nerva.table_commit_keys) {
        broken.insert(.table_invalid);
    }
    if (!stdx.zeroed(&entry.reserved_a) or entry.reserved_b != 0 or
        !stdx.zeroed(&entry.reserved_c))
    {
        broken.insert(.reserved_not_zero);
    }
    if ((entry.kind == .read or entry.kind == .delete) and !stdx.zeroed(&entry.value)) {
        broken.insert(.value_not_zero);
    }
    if ((entry.kind == .put or entry.kind == .delete or entry.kind == .add) and
        entry.op_seen != 0)
    {
        broken.insert(.op_seen_not_zero);
    }

    if (status) |status_| {
        const add_status = entry.kind == .add and switch (status_) {
            .reserved_not_zero, .field_invalid, .delta_from_invalid => true,
            else => false,
        };
        if (!broken.contains(status_) and !add_status) {
            std.debug.panic("entry_validate: {s}, but the entry breaks {}: {}", .{
                @tagName(status_),
                broken,
                entry.*,
            });
        }
    } else if (broken.count() > 0) {
        std.debug.panic("entry_validate: valid, but the entry breaks {}: {}", .{
            broken,
            entry.*,
        });
    }
}

fn budget_is(entries: []const Entry) bool {
    for (entries) |*entry| {
        if (entry.table != budgets_table) return false;
    }
    return entries.len > 0;
}

fn receipt_claim_is(entries: []const Entry) bool {
    return entries.len == 2 and
        entries[0].table == receipts_table and entries[0].kind == .read and
        entries[1].table == receipts_table and entries[1].kind == .put and
        entries[0].id == entries[1].id;
}

/// Records of the workload (P123b): a small set, read, put and deleted at random.
pub const records_table: u32 = nerva.record_tables_min + 1;
/// Facts: each written once by a ledger transaction (and sometimes rewritten or deleted).
pub const facts_table: u32 = nerva.record_tables_min + 2;

/// The `n`th record's id: all 128 bits in use.
fn record_id(n: u64) u128 {
    return (@as(u128, n) + 1) *% 0x9E3779B97F4A7C15F39CC0605CEDC835;
}

fn fact_id(n: u64) u128 {
    return @as(u128, 0xFAC7) << 112 | n;
}

const record_agents = 3;
const record_created_max = 15;

/// A record's value: a status (byte 0, 0 to 3), when it was created (bytes 8..16, a small
/// number, so that indexes tie), an agent (bytes 16..32), then random bytes.
fn record_value(prng: *stdx.PRNG) [record_value_size]u8 {
    var value: [record_value_size]u8 = @splat(0);
    value[0] = prng.int_inclusive(u8, 3);
    std.mem.writeInt(u64, value[8..16], prng.int_inclusive(u64, record_created_max), .little);
    value[16..32].* = @splat(0xA0 | prng.int_inclusive(u8, record_agents - 1));
    prng.fill(value[32..][0..prng.int_inclusive(usize, record_value_size - 32)]);
    return value;
}

const index_definitions = 4;

/// The workload's indexes (P123c): by status and when created; reserved records (status 1) by
/// op; by agent and when created; facts by agent, by op.
fn index_definition(which: u8) nerva.IndexDefinition {
    var definition = std.mem.zeroes(nerva.IndexDefinition);
    const name: []const u8 = switch (which) {
        0 => "by_status",
        1 => "open",
        2 => "by_agent",
        3 => "facts",
        else => unreachable,
    };
    @memcpy(definition.name[0..name.len], name);
    definition.table = if (which == 3) facts_table else records_table;
    switch (which) {
        0, 2 => {
            definition.eq_count = 1;
            definition.eq[0] = if (which == 0)
                nerva.FieldRef.at(0, 1, .unsigned)
            else
                nerva.FieldRef.at(16, 16, .bytes);
            definition.flags.order = true;
            definition.order = nerva.FieldRef.at(8, 8, .unsigned);
        },
        1 => {
            definition.where_count = 1;
            definition.where[0] = .{
                .field = nerva.FieldRef.at(0, 1, .unsigned),
                .comparison = .eq,
                .value = std.mem.toBytes(std.mem.nativeToLittle(i128, 1)),
            };
        },
        3 => {
            definition.eq_count = 1;
            definition.eq[0] = nerva.FieldRef.at(16, 16, .bytes);
        },
        else => unreachable,
    }
    return definition;
}

/// A row's wide entry as `commit` carries it.
fn entry_narrow(wide: *const WideEntry) Entry {
    assert(!nerva.table_is_record(wide.table));
    assert(stdx.zeroed(&wide.reserved_b));
    assert(stdx.zeroed(wide.value[value_size..]));
    return .{
        .id = @intCast(wide.id),
        .table = wide.table,
        .kind = wide.kind,
        .reserved_a = wide.reserved_a,
        .op_seen = wide.op_seen,
        .value = wide.value[0..value_size].*,
    };
}

pub fn WorkloadType(comptime StateMachine: type) type {
    return struct {
        const Workload = @This();
        const Operation = StateMachine.Operation;

        const Version = struct {
            /// The op of the last write; zero if never written.
            op: u64,
            exists: bool,
            value: [value_size]u8,
        };

        const RecordVersion = struct {
            id: u128,
            table: u32,
            /// The op of the last write (a delete included); zero if never written.
            op: u64,
            exists: bool,
            /// When the record was first written: it orders the record among equal positions
            /// in an index.
            timestamp: u64,
            value: [record_value_size]u8,
        };
        const record_absent: RecordVersion = .{
            .id = 0,
            .table = 0,
            .op = 0,
            .exists = false,
            .timestamp = 0,
            .value = @splat(0),
        };
        const ModelIndex = struct {
            id: u64,
            declared_op: u64,
            definition: nerva.IndexDefinition,
            /// The first op a reply found the index ready at: ready as of every op since.
            ready_op: ?u64,
        };
        const fact_ids_max = 256;

        const Request = struct { operation: Operation, size: usize };
        const Failure = struct { index: usize, status: EntryStatus, op: u64, value: u64 = 0 };
        /// An add's expected result.
        const Expected = struct { applied: i64 = 0, value: u64 = 0 };
        const transaction_entries_max = 64;
        const keyed_sent_max = 16;

        /// Per hot budget, from the adds' results alone: what was funded, and where it is.
        const Budget = struct { funded: u64 = 0, available: u64 = 0, held: u64 = 0 };

        const ModelLedger = struct { op: u64, definition: nerva.LedgerDefinition };
        /// A conserved field, as the model's ledgers declare it.
        const ModelConserved = struct { ledger: usize, floor: ?i64 };
        /// A conserved field of one row.
        const LedgerFieldKey = struct { row: u128, offset: u8 };

        allocator: std.mem.Allocator,
        prng: *stdx.PRNG,
        options: Options,

        /// The committed state, as of the last reply checked.
        rows: std.AutoHashMapUnmanaged(u128, Version) = .{},
        /// Every applied write, in commit order: the expected change feed.
        changes: std.ArrayListUnmanaged(Change) = .{},
        /// The highest op observed in any reply. Every later op must exceed it.
        op_max: u64 = 0,

        requests_sent: usize = 0,
        requests_delivered: usize = 0,
        transactions_committed: u64 = 0,
        transactions_failed: u64 = 0,

        /// Receipt id → the sequence of its last winning claim, kept apart from `rows`.
        receipt_seqs: std.AutoHashMapUnmanaged(u64, u64) = .{},
        claims_won: u64 = 0,
        claims_lost: u64 = 0,
        /// Changes returned by `get_history`, and those skipped for being after `op_max`.
        history_returned: u64 = 0,
        history_skipped: u64 = 0,
        pulses: u64 = 0,

        /// Views declared (N52), in id order, and whether each was seen ready (never undone).
        model_views: std.ArrayListUnmanaged(ModelView) = .{},
        /// Scratch for admission (N52): the request's distinct groups, the transaction's, and
        /// which transactions were refused (`views_busy`).
        view_op_keys: std.AutoHashMapUnmanaged(u128, void) = .{},
        view_txn_keys: std.ArrayListUnmanaged(u128) = .{},
        view_txn_admission: std.ArrayListUnmanaged(views.Admission) = .{},
        /// The same for members (N62).
        view_op_members: std.AutoHashMapUnmanaged(u128, void) = .{},
        view_txn_members: std.ArrayListUnmanaged(u128) = .{},
        views_busy_members: u64 = 0,
        view_reads_ready: u64 = 0,
        view_reads_building: u64 = 0,
        views_busy: u64 = 0,
        /// Of those, transactions too large for any op (#32).
        views_too_large: u64 = 0,
        /// Coverage of N62: reads as of a past op, groups with a min or max checked, and
        /// declarations refused for too many of them.
        view_reads_as_of: u64 = 0,
        view_extremes_checked: u64 = 0,
        table_extremes_full: u64 = 0,

        budgets: std.AutoHashMapUnmanaged(u64, Budget) = .{},
        budget_transactions: u64 = 0,

        /// Ledgers declared (N75), in declaration order; whether ledger 1 is (ledger traffic
        /// starts once a reply says so, and so commits after it).
        model_ledgers: std.ArrayListUnmanaged(ModelLedger) = .{},
        ledger_declared: bool = false,
        /// Every conserved field written since, from the adds' results alone (not the row
        /// model): the checker's view of the ledger.
        ledger_values: std.AutoHashMapUnmanaged(LedgerFieldKey, i64) = .{},
        ledger_moves: u64 = 0,
        ledger_refused: std.EnumArray(EntryStatus, u64) = .initFill(0),
        ledger_reads: u64 = 0,
        adds_applied: u64 = 0,
        adds_clamped: u64 = 0,
        /// Commit keys (P123): each committed key's entries after its key entry, to tell a resend
        /// (`committed_before`) from other entries under the key (`key_reused`).
        committed_keys: std.AutoHashMapUnmanaged(u128, []const Entry) = .{},
        /// Transactions sent under a key, to send again; at most `keyed_sent_max`.
        keyed_sent: std.ArrayListUnmanaged([]const Entry) = .{},
        keyed_committed: u64 = 0,
        keyed_resent: u64 = 0,
        key_refused: std.EnumArray(EntryStatus, u64) = .initFill(0),
        /// Records (P123b), by `record_key`, as of the last reply checked; their feed.
        records: std.AutoHashMapUnmanaged(u128, RecordVersion) = .{},
        record_changes: std.ArrayListUnmanaged(nerva.RecordChange) = .{},
        /// Indexes declared (P123c), in id order.
        model_indexes: std.ArrayListUnmanaged(ModelIndex) = .{},
        /// Facts committed, to read and rewrite; at most `fact_ids_max`.
        fact_ids: std.ArrayListUnmanaged(u128) = .{},
        facts_sent: u64 = 0,
        facts_committed: u64 = 0,
        facts_failed: u64 = 0,
        record_transactions_committed: u64 = 0,
        records_refused: std.EnumArray(EntryStatus, u64) = .initFill(0),
        record_reads: u64 = 0,
        record_changes_returned: u64 = 0,
        record_history_returned: u64 = 0,
        record_changes_cursor: ?u64 = null,
        record_history_cursor: ?struct { table: u32, id: u128, timestamp_max: u64 } = null,
        index_declared: std.EnumArray(nerva.DeclareIndexStatus, u64) = .initFill(0),
        index_scans_ready: u64 = 0,
        index_scans_building: u64 = 0,
        index_records_checked: u64 = 0,
        index_counts_checked: u64 = 0,
        scans_continued: u64 = 0,
        /// The query for the page after the last incomplete scan.
        scan_cursor: ?nerva.IndexQuery = null,
        /// Scratch: a facts request's ledger pairs as `commit` would carry them.
        narrow_body: []align(constants.cache_line_size) u8,
        /// Scratch: the expected results of the transaction being checked (any size, up to a full
        /// batch).
        expected: []Expected,

        /// The cursor an incomplete `get_changes` reply returned, to continue from (N49).
        changes_cursor: ?u64 = null,
        /// The row and cursor an incomplete `get_history` reply returned, to continue from.
        history_cursor: ?struct { table: u32, id: u64, timestamp_max: u64 } = null,

        /// Coverage of the inputs and limits added in N49.
        full_batches: u64 = 0,
        invalid_entries: u64 = 0,
        future_reads: u64 = 0,
        invalid_filters: u64 = 0,
        limits_clamped: u64 = 0,
        cursors_continued: u64 = 0,

        pub const Options = struct {
            batch_size_limit: u32,
            multi_batch_per_request_limit: u32,
            /// Rows are drawn from `table_count × id_count` keys.
            table_count: u32,
            id_count: u64,
            entries_per_transaction_max: u32,
            /// Reads that deliberately present a stale version.
            stale_read_probability: stdx.PRNG.Ratio,
            invalid_entry_probability: stdx.PRNG.Ratio,
            /// Few receipts, so that claims contend.
            receipt_count: u64,
            /// Few budgets, so that adds contend.
            budget_count: u64,
            /// Accounts of the ledger (N75).
            ledger_account_count: u64,
            /// Records are drawn from this many ids (P123b).
            record_id_count: u64,

            pub fn generate(prng: *stdx.PRNG, options: struct {
                batch_size_limit: u32,
                multi_batch_per_request_limit: u32,
                client_count: usize,
                in_flight_max: usize,
            }) Options {
                return .{
                    .batch_size_limit = options.batch_size_limit,
                    .multi_batch_per_request_limit = options.multi_batch_per_request_limit,
                    .table_count = prng.range_inclusive(u32, 1, 3),
                    .id_count = prng.range_inclusive(u64, 1, 64),
                    .entries_per_transaction_max = prng.range_inclusive(u32, 1, 32),
                    .stale_read_probability = stdx.PRNG.ratio(prng.int_inclusive(u64, 20), 100),
                    .invalid_entry_probability = stdx.PRNG.ratio(prng.int_inclusive(u64, 3), 100),
                    .receipt_count = prng.range_inclusive(u64, 1, 4),
                    .budget_count = prng.range_inclusive(u64, 1, 3),
                    .ledger_account_count = prng.range_inclusive(u64, 2, 5),
                    .record_id_count = prng.range_inclusive(u64, 1, 48),
                };
            }
        };

        const ModelView = struct {
            id: u64,
            declared_op: u64,
            definition: ViewDefinition,
            /// The first op a read found the view ready at: it is ready as of every op since.
            ready_op: ?u64,
        };

        /// The state machine's `group_writes_limit` for this batch size.
        fn group_writes_limit(workload: *const Workload) u32 {
            return @max(1, @divFloor(Operation.commit.event_max(workload.options.batch_size_limit), 2));
        }

        /// The state machine's `member_writes_limit` (N62): a request's entries.
        fn member_writes_limit(workload: *const Workload) u32 {
            return Operation.commit.event_max(workload.options.batch_size_limit);
        }

        pub fn init(
            allocator: std.mem.Allocator,
            prng: *stdx.PRNG,
            options: Options,
        ) !Workload {
            assert(options.table_count > 0);
            assert(options.id_count > 0);
            assert(options.entries_per_transaction_max > 0);
            assert(options.receipt_count > 0);
            assert(options.budget_count > 0);
            assert(options.ledger_account_count >= 2);
            assert(options.entries_per_transaction_max <= transaction_entries_max);
            assert(options.table_count < receipts_table);
            assert(options.record_id_count > 0);
            const expected = try allocator.alloc(Expected, StateMachine.commit_entries_max);
            errdefer allocator.free(expected);
            const narrow_body = try allocator.alignedAlloc(
                u8,
                constants.cache_line_size,
                constants.message_body_size_max,
            );
            errdefer allocator.free(narrow_body);
            return .{
                .allocator = allocator,
                .prng = prng,
                .options = options,
                .narrow_body = narrow_body,
                .expected = expected,
            };
        }

        pub fn deinit(workload: *Workload, allocator: std.mem.Allocator) void {
            log.info("transactions committed={} failed={} changes={} claims won={} lost={} " ++
                "history returned={} skipped={} budget transactions={} adds={} clamped={}", .{
                workload.transactions_committed,
                workload.transactions_failed,
                workload.changes.items.len,
                workload.claims_won,
                workload.claims_lost,
                workload.history_returned,
                workload.history_skipped,
                workload.budget_transactions,
                workload.adds_applied,
                workload.adds_clamped,
            });
            log.info("views declared={} reads ready={} building={} pulses={} views_busy={} " ++
                "of which too large={}", .{
                workload.model_views.items.len,
                workload.view_reads_ready,
                workload.view_reads_building,
                workload.pulses,
                workload.views_busy,
                workload.views_too_large,
            });
            log.info("views as_of reads={} extremes checked={} table_extremes_full={} " ++
                "views_busy for members={}", .{
                workload.view_reads_as_of,
                workload.view_extremes_checked,
                workload.table_extremes_full,
                workload.views_busy_members,
            });
            workload.model_views.deinit(allocator);
            workload.view_op_keys.deinit(allocator);
            workload.view_txn_keys.deinit(allocator);
            workload.view_txn_admission.deinit(allocator);
            workload.view_op_members.deinit(allocator);
            workload.view_txn_members.deinit(allocator);
            log.info("full batches={} invalid entries={} future reads={} invalid filters={} " ++
                "limits clamped={} cursors continued={}", .{
                workload.full_batches,
                workload.invalid_entries,
                workload.future_reads,
                workload.invalid_filters,
                workload.limits_clamped,
                workload.cursors_continued,
            });
            log.info("ledger moves={} unpaired={} conserved_write={} out_of_bounds={} " ++
                "row_absent={} reads={}", .{
                workload.ledger_moves,
                workload.ledger_refused.get(.unpaired),
                workload.ledger_refused.get(.conserved_write),
                workload.ledger_refused.get(.out_of_bounds),
                workload.ledger_refused.get(.row_absent),
                workload.ledger_reads,
            });
            log.info("commit keys committed={} resent={} committed_before={} key_reused={} " ++
                "key_misplaced={} key_invalid={}", .{
                workload.keyed_committed,
                workload.keyed_resent,
                workload.key_refused.get(.committed_before),
                workload.key_refused.get(.key_reused),
                workload.key_refused.get(.key_misplaced),
                workload.key_refused.get(.key_invalid),
            });
            log.info("records committed={} refused conflict={} write_duplicate={} " ++
                "invalid={} reads={} changes={} history={}", .{
                workload.record_transactions_committed,
                workload.records_refused.get(.conflict),
                workload.records_refused.get(.write_duplicate),
                workload.invalid_entries,
                workload.record_reads,
                workload.record_changes_returned,
                workload.record_history_returned,
            });
            log.info("facts committed={} failed={} indexes created={} exists={} different={} " ++
                "scans ready={} building={} records checked={} counts checked={} continued={}", .{
                workload.facts_committed,
                workload.facts_failed,
                workload.index_declared.get(.created),
                workload.index_declared.get(.exists),
                workload.index_declared.get(.different),
                workload.index_scans_ready,
                workload.index_scans_building,
                workload.index_records_checked,
                workload.index_counts_checked,
                workload.scans_continued,
            });
            workload.records.deinit(allocator);
            workload.record_changes.deinit(allocator);
            workload.model_indexes.deinit(allocator);
            workload.fact_ids.deinit(allocator);
            allocator.free(workload.narrow_body);
            var committed_keys = workload.committed_keys.valueIterator();
            while (committed_keys.next()) |entries| allocator.free(entries.*);
            workload.committed_keys.deinit(allocator);
            for (workload.keyed_sent.items) |entries| allocator.free(entries);
            workload.keyed_sent.deinit(allocator);
            workload.model_ledgers.deinit(allocator);
            workload.ledger_values.deinit(allocator);
            allocator.free(workload.expected);
            workload.budgets.deinit(allocator);
            workload.receipt_seqs.deinit(allocator);
            workload.rows.deinit(allocator);
            workload.changes.deinit(allocator);
        }

        pub fn done(workload: *const Workload) bool {
            return workload.requests_sent == workload.requests_delivered;
        }

        pub fn build_request(
            workload: *Workload,
            client_index: usize,
            body: []align(constants.cache_line_size) u8,
        ) Request {
            workload.requests_sent += 1;

            const body_limited = body[0..workload.options.batch_size_limit];
            return switch (workload.prng.chances(.{
                .commit = 8,
                .claim = 4,
                .budget = 4,
                .lookup_rows = 3,
                .get_changes = 2,
                .get_history = 2,
                .declare_view = 1,
                .get_view = 6,
                .ledger = 4,
                .records = 5,
                .facts = 2,
                .lookup_records = 2,
                .get_record_changes = 1,
                .get_record_history = 1,
                .declare_index = 1,
                .scan_index = 4,
                .get_index = 1,
            })) {
                .commit => .{ .operation = .commit, .size = workload.build_commit(body_limited) },
                .claim => .{
                    .operation = .commit,
                    .size = workload.build_claims(body_limited, client_index),
                },
                .budget => .{
                    .operation = .commit,
                    .size = workload.build_budgets(body_limited),
                },
                .lookup_rows => .{
                    .operation = .lookup_rows,
                    .size = workload.build_lookup_rows(body_limited),
                },
                .get_changes => .{
                    .operation = .get_changes,
                    .size = workload.build_get_changes(body),
                },
                .get_history => .{
                    .operation = .get_history,
                    .size = workload.build_get_history(body),
                },
                .declare_view => .{
                    .operation = .declare_view,
                    .size = workload.build_declare_view(body),
                },
                .get_view => .{
                    .operation = .get_view,
                    .size = workload.build_get_view(body),
                },
                .ledger => workload.build_ledger(body_limited),
                .records => .{
                    .operation = .commit_wide,
                    .size = workload.build_records(body_limited),
                },
                // Facts move money: once the ledger is declared.
                .facts => .{
                    .operation = .commit_wide,
                    .size = if (workload.ledger_declared)
                        workload.build_facts(body_limited)
                    else
                        workload.build_records(body_limited),
                },
                .lookup_records => .{
                    .operation = .lookup_records,
                    .size = workload.build_lookup_records(body_limited),
                },
                .get_record_changes => .{
                    .operation = .get_record_changes,
                    .size = workload.build_get_record_changes(body),
                },
                .get_record_history => .{
                    .operation = .get_record_history,
                    .size = workload.build_get_record_history(body),
                },
                .declare_index => .{
                    .operation = .declare_index,
                    .size = workload.build_declare_index(body),
                },
                .scan_index => .{
                    .operation = .scan_index,
                    .size = workload.build_scan_index(body),
                },
                .get_index => .{
                    .operation = .get_index,
                    .size = workload.build_get_index(body),
                },
            };
        }

        /// A random view over one of the random tables: filters and groups on byte fields (so
        /// that groups are few), sums a 64-bit field; sometimes a name already declared, or an
        /// invalid definition.
        fn build_declare_view(workload: *Workload, body: []align(constants.cache_line_size) u8) usize {
            const prng = workload.prng;
            const definition: *ViewDefinition =
                @alignCast(std.mem.bytesAsValue(ViewDefinition, body[0..@sizeOf(ViewDefinition)]));
            definition.* = std.mem.zeroes(ViewDefinition);
            const name_index = prng.int_inclusive(u8, @intCast(@min(workload.model_views.items.len + 1, 70)));
            _ = std.fmt.bufPrint(&definition.name, "v{}", .{name_index}) catch unreachable;
            definition.table = prng.range_inclusive(u32, 1, workload.options.table_count);
            definition.where_count = prng.int_inclusive(u8, 2);
            for (definition.where[0..definition.where_count]) |*clause| {
                clause.* = .{
                    .field = .{ .offset = prng.int_inclusive(u8, value_size - 1), .size = 1, .kind = .unsigned },
                    .comparison = @enumFromInt(prng.range_inclusive(u8, 1, 6)),
                    .value = std.mem.toBytes(std.mem.nativeToLittle(i128, prng.int_inclusive(u8, 255))),
                };
            }
            definition.group_by_count = prng.int_inclusive(u8, 2);
            for (definition.group_by[0..definition.group_by_count]) |*field| {
                field.* = .{ .offset = prng.int_inclusive(u8, value_size - 1), .size = 1, .kind = .unsigned };
            }
            // A count, then sums, mins and maxes (N62) of 64-bit fields, unsigned or signed.
            definition.aggregate_count = prng.range_inclusive(u8, 2, 3);
            definition.aggregates[0] = .{ .function = .count, .field = std.mem.zeroes(nerva.FieldRef) };
            for (definition.aggregates[1..definition.aggregate_count]) |*aggregate| {
                aggregate.* = .{
                    .function = switch (prng.int_inclusive(u8, 2)) {
                        0 => .sum,
                        1 => .min,
                        else => .max,
                    },
                    .field = .{
                        .offset = 8 * prng.int_inclusive(u8, 9),
                        .size = 8,
                        .kind = if (prng.boolean()) .unsigned else .signed,
                    },
                };
            }
            if (prng.chance(stdx.PRNG.ratio(1, 20))) definition.reserved_b[0] = 1;
            return @sizeOf(ViewDefinition);
        }

        fn build_get_view(workload: *Workload, body: []align(constants.cache_line_size) u8) usize {
            const prng = workload.prng;
            const query: *nerva.ViewQuery =
                @alignCast(std.mem.bytesAsValue(nerva.ViewQuery, body[0..@sizeOf(nerva.ViewQuery)]));
            const views_count = workload.model_views.items.len;
            query.* = .{
                // Mostly a declared view; sometimes zero, or one not yet declared.
                .view_id = if (views_count > 0 and prng.chance(stdx.PRNG.ratio(7, 8)))
                    prng.range_inclusive(u64, 1, views_count)
                else
                    prng.int_inclusive(u64, views_count + 1),
                .group_hash_min = if (prng.chance(stdx.PRNG.ratio(3, 4))) 0 else prng.int(u64),
                // Zero is an invalid limit, and must return nothing.
                .limit = if (prng.chance(stdx.PRNG.ratio(1, 10))) 0 else prng.range_inclusive(u32, 1, 32),
                // As of a past op (N62), sometimes one not yet committed (the latest, then).
                .as_of = switch (prng.int_inclusive(u8, 3)) {
                    0, 1 => 0,
                    2 => prng.range_inclusive(u64, 1, workload.op_max + 1),
                    else => workload.op_max + prng.range_inclusive(u64, 1, 1000),
                },
            };
            return @sizeOf(nerva.ViewQuery);
        }

        fn build_commit(workload: *Workload, body: []align(constants.cache_line_size) u8) usize {
            var encoder = MultiBatchEncoder.init(body, .{ .element_size = @sizeOf(Entry) });
            const batch_count = workload.prng.range_inclusive(
                u32,
                1,
                workload.options.multi_batch_per_request_limit,
            );
            for (0..batch_count) |_| {
                const writable = encoder.writable() orelse break;
                const entries_free = stdx.bytes_as_slice(.inexact, Entry, writable);
                if (workload.build_resend(entries_free)) |count| {
                    encoder.add(@intCast(count * @sizeOf(Entry)));
                    continue;
                }
                // Rarely, one transaction as large as the request allows (N49): prefetch and the
                // state machine's scratch space at capacity.
                const full = workload.prng.chance(stdx.PRNG.ratio(1, 100));
                const entries = if (full) entries_free else entries_free[0..workload.prng.int_inclusive(
                    usize,
                    @min(entries_free.len, workload.options.entries_per_transaction_max),
                )];
                if (full) workload.full_batches += 1;
                if (entries.len > 0 and workload.prng.chance(stdx.PRNG.ratio(1, 6))) {
                    entries[0] = nerva.commit_key_entry(workload.prng.range_inclusive(
                        u128,
                        1,
                        std.math.maxInt(u128),
                    ));
                    workload.build_transaction(entries[1..]);
                    workload.keyed_remember(entries);
                } else {
                    workload.build_transaction(entries);
                }
                encoder.add(@intCast(entries.len * @sizeOf(Entry)));
                if (full) break;
            }
            return encoder.finish();
        }

        /// Sometimes, a transaction sent under a key before, into `entries_free`: as it was sent
        /// (a resend after a lost reply), or with other entries under the same key. Returns its
        /// entry count.
        fn build_resend(workload: *Workload, entries_free: []Entry) ?usize {
            const prng = workload.prng;
            const sent_all = workload.keyed_sent.items;
            if (sent_all.len == 0 or !prng.chance(stdx.PRNG.ratio(1, 10))) return null;
            const sent = sent_all[prng.index(sent_all)];
            if (sent.len > entries_free.len) return null;
            const entries = entries_free[0..sent.len];
            stdx.copy_disjoint(.exact, Entry, entries, sent);
            if (prng.chance(stdx.PRNG.ratio(1, 4))) workload.build_transaction(entries[1..]);
            workload.keyed_resent += 1;
            return entries.len;
        }

        /// Keeps a copy of a transaction sent under a key, to send again.
        fn keyed_remember(workload: *Workload, entries: []const Entry) void {
            assert(entries[0].kind == .key);
            if (entries.len > transaction_entries_max) return;
            const copy = workload.allocator.dupe(Entry, entries) catch @panic("OOM");
            if (workload.keyed_sent.items.len < keyed_sent_max) {
                workload.keyed_sent.append(workload.allocator, copy) catch @panic("OOM");
            } else {
                const slot = &workload.keyed_sent.items[workload.prng.index(workload.keyed_sent.items)];
                workload.allocator.free(slot.*);
                slot.* = copy;
            }
        }

        /// One claim per batch, against what this client last knew of the receipt. Claims from
        /// several clients (or several batches of one request) on one receipt race each other.
        fn build_claims(
            workload: *Workload,
            body: []align(constants.cache_line_size) u8,
            client_index: usize,
        ) usize {
            var encoder = MultiBatchEncoder.init(body, .{ .element_size = @sizeOf(Entry) });
            const batch_count = workload.prng.range_inclusive(
                u32,
                1,
                workload.options.multi_batch_per_request_limit,
            );
            for (0..batch_count) |_| {
                const writable = encoder.writable() orelse break;
                const entries_free = stdx.bytes_as_slice(.inexact, Entry, writable);
                if (entries_free.len < 2) {
                    encoder.add(0);
                    break;
                }
                const id = workload.prng.int_inclusive(u64, workload.options.receipt_count - 1);
                const version = workload.row_version(nerva.row_key(receipts_table, id));
                const claim = receipt_claim(
                    id,
                    version.op,
                    Receipt.from_value(&version.value).seq,
                    client_index,
                );
                stdx.copy_disjoint(.exact, Entry, entries_free[0..2], &claim);
                encoder.add(2 * @sizeOf(Entry));
            }
            return encoder.finish();
        }

        /// One budget transaction per batch: fund, reserve (take up to X from available, hold
        /// what was taken) or release (the reverse). Adds only: they never conflict.
        fn build_budgets(workload: *Workload, body: []align(constants.cache_line_size) u8) usize {
            const prng = workload.prng;
            var encoder = MultiBatchEncoder.init(body, .{ .element_size = @sizeOf(Entry) });
            const batch_count = prng.range_inclusive(
                u32,
                1,
                workload.options.multi_batch_per_request_limit,
            );
            for (0..batch_count) |_| {
                const writable = encoder.writable() orelse break;
                const entries_free = stdx.bytes_as_slice(.inexact, Entry, writable);
                if (entries_free.len < 2) {
                    encoder.add(0);
                    break;
                }
                const id = prng.int_inclusive(u64, workload.options.budget_count - 1);
                const amount: i64 = @intCast(prng.range_inclusive(u64, 1, 1000));
                const entries: []const Entry = switch (prng.chances(.{
                    .fund = 1,
                    .reserve = 4,
                    .release = 3,
                })) {
                    .fund => &.{budget_add(id, 0, amount, null)},
                    .reserve => &.{ budget_add(id, 0, -amount, null), budget_add(id, 8, 0, 0) },
                    .release => &.{ budget_add(id, 8, -amount, null), budget_add(id, 0, 0, 0) },
                };
                stdx.copy_disjoint(.inexact, Entry, entries_free, entries);
                encoder.add(@intCast(entries.len * @sizeOf(Entry)));
            }
            return encoder.finish();
        }

        fn build_transaction(workload: *Workload, entries: []Entry) void {
            const prng = workload.prng;
            for (entries, 0..) |*entry, index| {
                const table = prng.range_inclusive(u32, 1, workload.options.table_count);
                const id = prng.int_inclusive(u64, workload.options.id_count - 1);
                const kind: nerva.EntryKind = switch (prng.chances(.{
                    .read = 4,
                    .put = 4,
                    .delete = 1,
                    .add = 3,
                })) {
                    .read => .read,
                    .put => .put,
                    .delete => .delete,
                    .add => .add,
                };

                // Keep duplicate writes rare: they abort the whole transaction. (Several adds to
                // one row are not duplicates.)
                if (kind != .read and !prng.chance(stdx.PRNG.ratio(1, 50))) {
                    for (entries[0..index]) |*previous| {
                        // Not `row_key()`: an earlier entry may have been made invalid.
                        if (previous.kind != .read and previous.table == table and
                            previous.id == id and !(previous.kind == .add and kind == .add))
                        {
                            entry.* = workload.entry_read(table, id);
                            break;
                        }
                    } else entry.* = workload.entry_write(kind, table, id, entries[0..index]);
                } else {
                    entry.* = if (kind == .read)
                        workload.entry_read(table, id)
                    else
                        workload.entry_write(kind, table, id, entries[0..index]);
                }

                if (prng.chance(workload.options.invalid_entry_probability)) {
                    workload.invalid_entries += 1;
                    switch (prng.chances(.{
                        .table = 1,
                        .reserved_a = 1,
                        .reserved_b = 1,
                        .reserved_c = 1,
                        .value = 1,
                        .kind = 1,
                        .kind_zero = 1,
                        .kind_key = 1,
                        .op_seen = 1,
                    })) {
                        .table => entry.table = 0,
                        .reserved_a => entry.reserved_a[prng.index(&entry.reserved_a)] = 1,
                        .reserved_b => entry.reserved_b = 1,
                        .reserved_c => entry.reserved_c[prng.index(&entry.reserved_c)] = 1,
                        .value => entry.value[prng.index(&entry.value)] = 1,
                        .kind => entry.kind = @enumFromInt(prng.range_inclusive(u8, 6, 255)),
                        .kind_zero => entry.kind = @enumFromInt(0),
                        // Misplaced, or invalid as a key.
                        .kind_key => entry.kind = .key,
                        // Valid for a read (a version, maybe stale); invalid for any write.
                        .op_seen => entry.op_seen = prng.range_inclusive(u64, 1, 1 << 40),
                    }
                }
            }
        }

        fn entry_read(workload: *Workload, table: u32, id: u64) Entry {
            const version = workload.row_version(nerva.row_key(table, id));
            const op_seen = if (workload.prng.chance(workload.options.stale_read_probability))
                switch (workload.prng.chances(.{ .stale = 4, .future = 1 })) {
                    .stale => workload.prng.int_inclusive(u64, workload.op_max),
                    // A version no row has yet (N49): it must conflict too.
                    .future => future: {
                        workload.future_reads += 1;
                        break :future workload.op_max + workload.prng.range_inclusive(u64, 1, 100);
                    },
                }
            else
                version.op;
            return .{
                .id = id,
                .table = table,
                .kind = .read,
                .op_seen = op_seen,
                .value = @splat(0),
            };
        }

        fn entry_write(
            workload: *Workload,
            kind: nerva.EntryKind,
            table: u32,
            id: u64,
            previous: []const Entry,
        ) Entry {
            assert(kind == .put or kind == .delete or kind == .add);
            var entry: Entry = .{
                .id = id,
                .table = table,
                .kind = kind,
                .op_seen = 0,
                .value = @splat(0),
            };
            switch (kind) {
                .put => workload.prng.fill(&entry.value),
                .add => entry.value = workload.add_random(previous).value(),
                else => {},
            }
            return entry;
        }

        /// Random parameters, valid unless `entry_write`'s caller corrupts them: small deltas
        /// near small bounds (so that bounds bind), sometimes huge ones (overflow).
        fn add_random(workload: *Workload, previous: []const Entry) Add {
            const prng = workload.prng;
            const field: Add.AddField = if (prng.boolean()) .u64 else .i64;
            var add: Add = .{
                .delta = switch (prng.chances(.{ .small = 8, .huge = 1, .zero = 1 })) {
                    .small => signed_range(prng, -100, 100),
                    .huge => if (prng.boolean())
                        std.math.maxInt(i64)
                    else
                        std.math.minInt(i64) + 1,
                    .zero => 0,
                },
                .min = 0,
                .max = 0,
                .delta_from = 0,
                // Mostly the first two fields, so that adds in a transaction meet.
                .offset = if (prng.boolean())
                    8 * prng.int_inclusive(u8, 1)
                else
                    prng.int_inclusive(u8, value_size - 8),
                .field = field,
                .flags = .{ .clamp = prng.boolean(), .create = prng.chance(stdx.PRNG.ratio(3, 4)) },
            };
            if (prng.chance(stdx.PRNG.ratio(1, 2))) {
                add.flags.min = true;
                add.min = switch (field) {
                    .u64 => prng.int_inclusive(u64, 50),
                    .i64 => @bitCast(signed_range(prng, -50, 0)),
                    _ => unreachable,
                };
            }
            if (prng.chance(stdx.PRNG.ratio(1, 2))) {
                add.flags.max = true;
                add.max = switch (field) {
                    .u64 => prng.range_inclusive(u64, 50, 300),
                    .i64 => @bitCast(signed_range(prng, 1, 300)),
                    _ => unreachable,
                };
            }
            // Move what an earlier add applied, mostly naming an add (else `delta_from_invalid`).
            if (previous.len > 0 and prng.chance(stdx.PRNG.ratio(1, 4))) {
                add.flags.delta_from = true;
                add.delta = 0;
                add.delta_from = @intCast(prng.index(previous));
                for (previous, 0..) |*entry, index| {
                    if (entry.kind == .add and prng.boolean()) add.delta_from = @intCast(index);
                }
            }
            return add;
        }

        fn build_lookup_rows(
            workload: *Workload,
            body: []align(constants.cache_line_size) u8,
        ) usize {
            var encoder = MultiBatchEncoder.init(body, .{ .element_size = @sizeOf(RowKey) });
            const batch_count = workload.prng.range_inclusive(
                u32,
                1,
                workload.options.multi_batch_per_request_limit,
            );
            // Each 16-byte key produces a 128-byte result: the reply, not the request, is the
            // binding limit, so budget every batch against it.
            var keys_total: usize = 0;
            for (0..batch_count) |batch_index| {
                const writable = encoder.writable() orelse break;
                const keys_free = stdx.bytes_as_slice(.inexact, RowKey, writable);
                const reply_trailer_size = vsr.multi_batch.trailer_total_size(.{
                    .element_size = @sizeOf(RowValue),
                    .batch_count = @intCast(batch_index + 1),
                });
                const reply_keys_free = @divFloor(
                    constants.message_body_size_max - reply_trailer_size,
                    @sizeOf(RowValue),
                ) - keys_total;
                // Usually a few keys; sometimes as many as the reply can hold (N49).
                const keys_max = @min(keys_free.len, reply_keys_free);
                const keys = keys_free[0..workload.prng.int_inclusive(
                    usize,
                    if (workload.prng.chance(stdx.PRNG.ratio(1, 20))) keys_max else @min(keys_max, 16),
                )];
                keys_total += keys.len;
                for (keys) |*key| {
                    key.* = .{
                        .id = workload.prng.int_inclusive(u64, workload.options.id_count - 1),
                        // Table zero is invalid, and must come back as not found.
                        .table = workload.prng.int_inclusive(u32, workload.options.table_count),
                        // As must a key with reserved bits set.
                        .reserved = if (workload.prng.chance(stdx.PRNG.ratio(1, 50)))
                            workload.prng.range_inclusive(u32, 1, std.math.maxInt(u32))
                        else
                            0,
                    };
                }
                encoder.add(@intCast(keys.len * @sizeOf(RowKey)));
            }
            return encoder.finish();
        }

        fn build_get_changes(
            workload: *Workload,
            body: []align(constants.cache_line_size) u8,
        ) usize {
            const prng = workload.prng;
            const changes = workload.changes.items;
            const filter: *ChangesFilter = @alignCast(
                std.mem.bytesAsValue(ChangesFilter, body[0..@sizeOf(ChangesFilter)]),
            );
            filter.* = .{
                .timestamp_min = switch (prng.chances(.{
                    .start = 1,
                    .known = 3,
                    .after = 1,
                    .cursor = 2,
                    .invalid = 1,
                })) {
                    .start => 0,
                    .known => if (changes.len == 0) 0 else changes[prng.index(changes)].timestamp,
                    .after => if (changes.len == 0) 0 else changes[changes.len - 1].timestamp + 1,
                    // Where an incomplete reply said to continue (N49).
                    .cursor => if (workload.changes_cursor) |cursor| cursor: {
                        workload.cursors_continued += 1;
                        break :cursor cursor;
                    } else 0,
                    // Past the largest timestamp: the filter is invalid, and returns nothing.
                    .invalid => if (prng.chance(stdx.PRNG.ratio(1, 4)))
                        timestamp_invalid(prng)
                    else
                        0,
                },
                .limit = limit_random(prng, 64, StateMachine.changes_limit_max),
            };
            // Reserved bytes set: the filter is invalid, and returns nothing.
            if (prng.chance(stdx.PRNG.ratio(1, 50))) {
                filter.reserved[prng.index(&filter.reserved)] = 1;
            }
            return @sizeOf(ChangesFilter);
        }

        fn build_get_history(
            workload: *Workload,
            body: []align(constants.cache_line_size) u8,
        ) usize {
            const prng = workload.prng;
            const changes = workload.changes.items;
            const filter: *HistoryFilter = @alignCast(
                std.mem.bytesAsValue(HistoryFilter, body[0..@sizeOf(HistoryFilter)]),
            );
            const known: ?*const Change = if (changes.len == 0) null else &changes[
                prng.index(changes)
            ];
            filter.* = .{
                // Table zero is invalid, and must return nothing.
                .table = if (prng.chance(stdx.PRNG.ratio(1, 4)))
                    receipts_table
                else
                    prng.int_inclusive(u32, workload.options.table_count),
                .id = prng.int_inclusive(u64, @max(
                    workload.options.id_count,
                    workload.options.receipt_count,
                ) - 1),
                .limit = limit_random(prng, 16, StateMachine.changes_limit_max),
                .op_max = switch (prng.chances(.{ .latest = 2, .past = 4, .invalid = 1 })) {
                    .latest => std.math.maxInt(u64),
                    .past => prng.range_inclusive(u64, 1, @max(1, workload.op_max)),
                    .invalid => 0,
                },
                .timestamp_max = switch (prng.chances(.{ .newest = 3, .known = 2, .invalid = 1 })) {
                    .newest => 0,
                    .known => if (known) |change| change.timestamp else 0,
                    // Past the largest timestamp: the filter is invalid, and returns nothing.
                    .invalid => if (prng.chance(stdx.PRNG.ratio(1, 4)))
                        timestamp_invalid(prng)
                    else
                        0,
                },
            };
            // Mostly ask about rows that have a history.
            if (known != null and prng.chance(stdx.PRNG.ratio(1, 2))) {
                filter.table = known.?.table;
                filter.id = known.?.id;
            }
            // Or continue where an incomplete reply said to (N49).
            if (workload.history_cursor) |cursor| {
                if (prng.chance(stdx.PRNG.ratio(1, 4))) {
                    filter.table = cursor.table;
                    filter.id = cursor.id;
                    filter.timestamp_max = cursor.timestamp_max;
                    workload.cursors_continued += 1;
                }
            }
            // Reserved bytes set: the filter is invalid, and returns nothing.
            if (prng.chance(stdx.PRNG.ratio(1, 50))) {
                filter.reserved[prng.index(&filter.reserved)] = 1;
            }
            return @sizeOf(HistoryFilter);
        }

        pub fn on_reply(
            workload: *Workload,
            client_index: usize,
            operation: Operation,
            op: u64,
            timestamp: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            _ = client_index;
            workload.requests_delivered += 1;
            assert(workload.requests_delivered <= workload.requests_sent);

            // Every reply is checked against the op its request executed at, not only against
            // the ops before it (N49).
            switch (operation) {
                .commit => workload.check_commit(op, timestamp, request_body, reply_body),
                .lookup_rows => workload.check_lookup_rows(op, request_body, reply_body),
                .get_changes => workload.check_get_changes(op, request_body, reply_body),
                .get_history => workload.check_get_history(op, request_body, reply_body),
                .declare_view => workload.check_declare_view(request_body, reply_body),
                .get_view => workload.check_get_view(op, request_body, reply_body),
                .pulse => unreachable, // Sent by the replica, reported to `on_pulse`.
                .declare_ledger => workload.check_declare_ledger(op, request_body, reply_body),
                .get_ledger => workload.check_get_ledger(request_body, reply_body),
                .commit_wide => workload.check_commit_wide(op, timestamp, request_body, reply_body),
                .lookup_records => workload.check_lookup_records(op, request_body, reply_body),
                .get_record_changes => workload.check_get_record_changes(op, request_body, reply_body),
                .get_record_history => workload.check_get_record_history(op, request_body, reply_body),
                .declare_index => workload.check_declare_index(op, request_body, reply_body),
                .scan_index => workload.check_scan_index(op, request_body, reply_body),
                .get_index => workload.check_get_index(op, request_body, reply_body),
            }
        }

        /// Pulses backfill building views (N52); the model applies them when it reads a view.
        pub fn on_pulse(workload: *Workload, operation: Operation, timestamp: u64) void {
            _ = timestamp;
            assert(operation == .pulse);
            workload.pulses += 1;
        }

        fn check_commit(
            workload: *Workload,
            op_executed: u64,
            timestamp: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            var request = MultiBatchDecoder.init(request_body, .{
                .element_size = @sizeOf(Entry),
            }) catch unreachable;
            var reply = MultiBatchDecoder.init(reply_body, .{
                .element_size = @sizeOf(EntryResult),
            }) catch unreachable;
            assert(request.batch_count() == reply.batch_count());

            var op_request: ?u64 = null;
            workload.views_admit(request_body);
            var batch_index: usize = 0;
            // Each entry takes a block of `entry_timestamps`: its change takes the first (N52).
            const block = StateMachine.entry_timestamps;
            var batch_timestamp =
                timestamp - @divExact(request.payload.len, @sizeOf(Entry)) * block;
            while (request.pop()) |batch| : (batch_index += 1) {
                const entries = stdx.bytes_as_slice(.exact, Entry, batch);
                const results = stdx.bytes_as_slice(.exact, EntryResult, reply.pop().?);
                assert(results.len == entries.len);
                batch_timestamp += entries.len * block;
                if (entries.len == 0) continue;

                const claim = receipt_claim_is(entries);
                const budget = budget_is(entries);
                const ledger = ledger_is(entries);
                const admission = workload.view_txn_admission.items[batch_index];
                if (workload.commit_failure(entries, admission)) |failure| {
                    // Adds alone, clamped and creating, never fail (G8).
                    assert(!budget);
                    workload.transactions_failed += 1;
                    if (ledger) workload.ledger_refused.getPtr(failure.status).* += 1;
                    workload.key_refused.getPtr(failure.status).* += 1;
                    if (claim) {
                        // Claims are always well-formed: they lose only to another claim.
                        assert(failure.status == .conflict);
                        assert(failure.index == 0);
                        workload.claims_lost += 1;
                    }
                    for (results, 0..) |result, index| {
                        if (index == failure.index) {
                            assert(result.status == failure.status);
                            assert(result.op == failure.op);
                            assert(result.value == failure.value);
                        } else {
                            assert(result.status == .aborted);
                            assert(result.op == 0);
                            assert(result.value == 0);
                        }
                        assert(result.applied == 0);
                    }
                    continue;
                }

                workload.transactions_committed += 1;
                const op = results[0].op;
                assert(op == op_executed);
                for (results, workload.expected[0..results.len]) |result, expected| {
                    assert(result.status == .ok);
                    assert(result.op == op);
                    assert(result.applied == expected.applied);
                    assert(result.value == expected.value);
                }
                if (op_request) |op_request_| assert(op == op_request_);
                assert(op > workload.op_max);
                op_request = op;

                if (claim) workload.check_claim_won(&entries[1]);
                if (budget) workload.check_budget(entries, results);
                if (ledger) workload.check_ledger(entries, results);

                for (entries, results, 0..) |*entry, *result, index| {
                    const entry_timestamp =
                        batch_timestamp - entries.len * block + index * block + 1;
                    if (entry.kind == .key) {
                        assert(index == 0);
                        workload.apply_key(op, entry_timestamp, entries);
                    } else {
                        workload.apply(op, entry_timestamp, entry, result);
                    }
                }
            }
            assert(reply.pop() == null);
            assert(batch_timestamp == timestamp);
            if (op_request) |op| workload.op_max = op;
        }

        /// The claim invariant, checked against `receipt_seqs` rather than the row model: a
        /// winning claim advances the receipt's sequence by exactly one.
        fn check_claim_won(workload: *Workload, put: *const Entry) void {
            assert(put.table == receipts_table);
            const receipt = Receipt.from_value(&put.value);
            const seq_previous = workload.receipt_seqs.get(put.id) orelse 0;
            assert(receipt.seq == seq_previous + 1);
            workload.receipt_seqs.put(workload.allocator, put.id, receipt.seq) catch @panic("OOM");
            workload.claims_won += 1;
        }

        /// The invariant of hot budgets, from the adds' results alone (independent of the row
        /// model): every add moves money within one budget, or funds it, and available plus
        /// held is always what was funded.
        fn check_budget(
            workload: *Workload,
            entries: []const Entry,
            results: []const EntryResult,
        ) void {
            workload.budget_transactions += 1;
            const id = entries[0].id;
            const entry = workload.budgets.getOrPut(workload.allocator, id) catch @panic("OOM");
            if (!entry.found_existing) entry.value_ptr.* = .{};
            const budget = entry.value_ptr;
            for (entries, results) |*add_entry, result| {
                assert(add_entry.id == id);
                const add = Add.from_entry(add_entry);
                const field = if (add.offset == 0) &budget.available else &budget.held;
                field.* = nerva.add_apply(&add, field.*, result.applied);
                assert(result.value == field.*);
                if (entries.len == 1) budget.funded += @intCast(result.applied);
            }
            if (entries.len == 2) {
                // What one side lost, the other gained.
                assert(results[0].applied <= 0);
                assert(results[1].applied == -results[0].applied);
            }
            assert(budget.available + budget.held == budget.funded);
        }

        // ---- Ledgers (N75) ----

        /// Before ledger 1 is known declared: its declaration. Then mostly moves (each batch
        /// one transaction of pairs), some transactions that must fail, reads, and declarations
        /// that must be refused.
        fn build_ledger(
            workload: *Workload,
            body: []align(constants.cache_line_size) u8,
        ) Request {
            const prng = workload.prng;
            if (!workload.ledger_declared) {
                return .{
                    .operation = .declare_ledger,
                    .size = ledger_declare_body(body, ledger_main()),
                };
            }
            switch (prng.chances(.{ .moves = 12, .refused = 4, .read = 1, .probe = 1 })) {
                .moves, .refused => |kind| {
                    var encoder = MultiBatchEncoder.init(body, .{ .element_size = @sizeOf(Entry) });
                    const batch_count = prng.range_inclusive(
                        u32,
                        1,
                        workload.options.multi_batch_per_request_limit,
                    );
                    for (0..batch_count) |_| {
                        const writable = encoder.writable() orelse break;
                        const entries_free = stdx.bytes_as_slice(.inexact, Entry, writable);
                        const count = if (kind == .moves)
                            workload.build_ledger_moves(entries_free)
                        else
                            workload.build_ledger_refused(entries_free);
                        encoder.add(@intCast(count * @sizeOf(Entry)));
                        if (count == 0) break;
                    }
                    return .{ .operation = .commit, .size = encoder.finish() };
                },
                .read => {
                    const query: *nerva.LedgerQuery = @alignCast(std.mem.bytesAsValue(
                        nerva.LedgerQuery,
                        body[0..@sizeOf(nerva.LedgerQuery)],
                    ));
                    // By id, or by slot (N80).
                    query.* = if (prng.boolean())
                        .{ .id = prng.range_inclusive(u32, 1, 2) }
                    else
                        .{ .id = 0, .slot = prng.range_inclusive(u64, 1, 2) };
                    return .{ .operation = .get_ledger, .size = @sizeOf(nerva.LedgerQuery) };
                },
                .probe => {
                    // Ledger 1 again, identically or not; or a field of it in another ledger.
                    var definition = ledger_main();
                    switch (prng.chances(.{ .again = 1, .different = 1, .taken = 1 })) {
                        .again => {},
                        .different => definition.fields[2].flags.floor = true,
                        .taken => {
                            definition.id = 2;
                            definition.field_count = 2;
                            definition.fields[0] = definition.fields[prng.int_inclusive(usize, 2)];
                            definition.fields[1] = .{
                                .table = ledger_probe_table,
                                .offset = 0,
                                .flags = .{},
                                .floor = 0,
                            };
                            definition.fields[2] = std.mem.zeroes(nerva.LedgerField);
                        },
                    }
                    return .{
                        .operation = .declare_ledger,
                        .size = ledger_declare_body(body, definition),
                    };
                },
            }
        }

        fn ledger_declare_body(
            body: []align(constants.cache_line_size) u8,
            definition: nerva.LedgerDefinition,
        ) usize {
            const target: *nerva.LedgerDefinition = @alignCast(std.mem.bytesAsValue(
                nerva.LedgerDefinition,
                body[0..@sizeOf(nerva.LedgerDefinition)],
            ));
            target.* = definition;
            return @sizeOf(nerva.LedgerDefinition);
        }

        /// One transaction of one to three pairs: fund (source to an account's `available`),
        /// reserve (`available` to `held`), post (`held` to another account's `available`) or
        /// void (`held` back to `available`). Returns the entries written.
        fn build_ledger_moves(workload: *Workload, entries: []Entry) usize {
            const prng = workload.prng;
            const pairs = @min(prng.range_inclusive(usize, 1, 3), entries.len / 2);
            const accounts = workload.options.ledger_account_count;
            for (0..pairs) |pair| {
                const first: u32 = @intCast(2 * pair);
                const account = prng.int_inclusive(u64, accounts - 1);
                const other = (account + prng.range_inclusive(u64, 1, accounts - 1)) % accounts;
                const amount: i64 = @intCast(prng.range_inclusive(u64, 1, 500));
                // A first half that does not clamp may fail the transaction: out_of_bounds.
                const clamp = prng.chance(stdx.PRNG.ratio(4, 5));
                const accounts_table = ledger_accounts_table;
                const halves: [2]Entry = switch (prng.chances(.{
                    .fund = 2,
                    .reserve = 4,
                    .post = 3,
                    .void = 2,
                })) {
                    .fund => .{
                        ledger_add(ledger_sources_table, 0, 0, -amount, .{ .pair = true }),
                        ledger_add(ledger_accounts_table, account, 0, 0, .{ .partner_of = first }),
                    },
                    .reserve => .{
                        ledger_add(accounts_table, account, 0, -amount, .{
                            .pair = true,
                            .clamp = clamp,
                        }),
                        ledger_add(accounts_table, account, 8, 0, .{ .partner_of = first }),
                    },
                    .post => .{
                        ledger_add(accounts_table, account, 8, -amount, .{
                            .pair = true,
                            .clamp = clamp,
                        }),
                        ledger_add(accounts_table, other, 0, 0, .{ .partner_of = first }),
                    },
                    .void => .{
                        ledger_add(accounts_table, account, 8, -amount, .{
                            .pair = true,
                            .clamp = clamp,
                        }),
                        ledger_add(accounts_table, account, 0, 0, .{ .partner_of = first }),
                    },
                };
                entries[first] = halves[0];
                entries[first + 1] = halves[1];
            }
            return 2 * pairs;
        }

        /// A transaction that must not change the ledger: an unpaired half, a partner that
        /// clamps, a put or delete of an account, an add straddling `available` and `held`. A
        /// put that changes no balance, or a delete of an empty account, may commit.
        fn build_ledger_refused(workload: *Workload, entries: []Entry) usize {
            const prng = workload.prng;
            if (entries.len < 2) return 0;
            const account = prng.int_inclusive(u64, workload.options.ledger_account_count - 1);
            const amount: i64 = @intCast(prng.range_inclusive(u64, 1, 500));
            switch (prng.chances(.{
                .half = 2,
                .partner_alone = 1,
                .partner_clamps = 1,
                .put = 2,
                .delete = 1,
                .straddle = 1,
            })) {
                .half => {
                    entries[0] = ledger_add(ledger_sources_table, 0, 0, -amount, .{ .pair = true });
                    return 1;
                },
                .partner_alone => {
                    entries[0] = ledger_add(ledger_accounts_table, account, 0, amount, .{});
                    return 1;
                },
                .partner_clamps => {
                    entries[0] = ledger_add(ledger_sources_table, 0, 0, -amount, .{ .pair = true });
                    entries[1] = ledger_add(ledger_accounts_table, account, 0, 0, .{
                        .partner_of = 0,
                        .clamp = true,
                    });
                    return 2;
                },
                .put => {
                    // Zero balances, so it commits only if the account holds none.
                    var value: [value_size]u8 = @splat(0);
                    @memset(value[16..], prng.int(u8));
                    entries[0] = .{
                        .id = account,
                        .table = ledger_accounts_table,
                        .kind = .put,
                        .op_seen = 0,
                        .value = value,
                    };
                    return 1;
                },
                .delete => {
                    entries[0] = .{
                        .id = account,
                        .table = ledger_accounts_table,
                        .kind = .delete,
                        .op_seen = 0,
                        .value = @splat(0),
                    };
                    return 1;
                },
                .straddle => {
                    entries[0] = ledger_add(ledger_accounts_table, account, 0, amount, .{});
                    var add = Add.from_entry(&entries[0]);
                    add.offset = prng.range_inclusive(u8, 1, 7);
                    entries[0].value = add.value();
                    return 1;
                },
            }
        }

        fn check_declare_ledger(
            workload: *Workload,
            op: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const definition: *const nerva.LedgerDefinition = @alignCast(std.mem.bytesAsValue(
                nerva.LedgerDefinition,
                request_body[0..@sizeOf(nerva.LedgerDefinition)],
            ));
            const results = stdx.bytes_as_slice(.exact, nerva.DeclareLedgerResult, reply_body);
            assert(results.len == 1);
            const result = results[0];

            const expected: nerva.DeclareLedgerStatus = expected: {
                if (ledgers.definition_validate(definition)) |status| break :expected status;
                for (workload.model_ledgers.items) |*ledger| {
                    if (ledger.definition.id != definition.id) continue;
                    if (stdx.equal_bytes(nerva.LedgerDefinition, &ledger.definition, definition)) {
                        assert(result.op == ledger.op);
                        break :expected .exists;
                    }
                    break :expected .ledger_immutable;
                }
                if (workload.model_ledgers.items.len == nerva.ledgers_max) {
                    break :expected .ledgers_full;
                }
                for (definition.fields[0..definition.field_count]) |*field| {
                    if (workload.model_conserved(field.table, field.offset) != null) {
                        break :expected .ledger_field_taken;
                    }
                    for (workload.model_views.items) |*view| {
                        if (view.definition.table != field.table) continue;
                        if (views.add_touches_key(&view.definition, field.offset)) {
                            break :expected .field_viewed;
                        }
                    }
                }
                break :expected .created;
            };
            assert(result.status == expected);
            if (expected == .created) {
                assert(result.op == op);
                assert(op > workload.op_max);
                workload.op_max = op;
                workload.model_ledgers.append(workload.allocator, .{
                    .op = op,
                    .definition = definition.*,
                }) catch @panic("OOM");
            } else if (expected != .exists) {
                assert(result.op == 0);
            }
            if (expected == .created or expected == .exists) {
                if (definition.id == 1) workload.ledger_declared = true;
            }
        }

        fn check_get_ledger(
            workload: *Workload,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const query: *const nerva.LedgerQuery = @alignCast(std.mem.bytesAsValue(
                nerva.LedgerQuery,
                request_body[0..@sizeOf(nerva.LedgerQuery)],
            ));
            const results = stdx.bytes_as_slice(.exact, nerva.Ledger, reply_body);
            assert(results.len == 1);
            const result = &results[0];
            workload.ledger_reads += 1;
            for (workload.model_ledgers.items, 1..) |*ledger, slot| {
                if (query.id == 0) {
                    if (query.slot != slot) continue;
                } else {
                    if (ledger.definition.id != query.id) continue;
                }
                assert(result.slot == slot);
                assert(result.op == ledger.op);
                assert(result.timestamp > 0);
                assert(stdx.equal_bytes(
                    nerva.LedgerDefinition,
                    &result.definition,
                    &ledger.definition,
                ));
                return;
            }
            assert(stdx.zeroed(std.mem.asBytes(result)));
        }

        /// The ledger's invariant after a committed ledger transaction, from the adds' results
        /// alone (independent of the row model): every conserved add moved its field from what
        /// it was to what the result says, a transaction's conserved adds sum to zero, puts and
        /// deletes left balances as they were, the ledger's total is still zero, and no floored
        /// field is below its floor.
        fn check_ledger(
            workload: *Workload,
            entries: []const Entry,
            results: []const EntryResult,
        ) void {
            var moved: i128 = 0;
            for (entries, results) |*entry, result| {
                const row = nerva.row_key(entry.table, entry.id);
                switch (entry.kind) {
                    .add => {
                        const add = Add.from_entry(entry);
                        const field = workload.model_conserved(entry.table, add.offset).?;
                        const value = workload.ledger_values.getOrPut(
                            workload.allocator,
                            .{ .row = row, .offset = add.offset },
                        ) catch @panic("OOM");
                        if (!value.found_existing) value.value_ptr.* = 0;
                        const after: i64 = @bitCast(result.value);
                        assert(@as(i128, value.value_ptr.*) + result.applied == after);
                        value.value_ptr.* = after;
                        if (field.floor) |floor| assert(after >= floor);
                        moved += result.applied;
                        workload.ledger_moves += 1;
                    },
                    .put, .delete => {
                        for (workload.model_ledgers.items) |*ledger| {
                            const definition = &ledger.definition;
                            for (definition.fields[0..definition.field_count]) |*field| {
                                if (field.table != entry.table) continue;
                                const held = workload.ledger_values.get(
                                    .{ .row = row, .offset = field.offset },
                                ) orelse 0;
                                const written: i64 = if (entry.kind == .put)
                                    std.mem.readInt(i64, entry.value[field.offset..][0..8], .little)
                                else
                                    0;
                                assert(written == held);
                            }
                        }
                    },
                    else => unreachable,
                }
            }
            assert(moved == 0);
            var total: i128 = 0;
            var values = workload.ledger_values.valueIterator();
            while (values.next()) |value| total += value.*;
            assert(total == 0);
        }

        /// The conserved field at exactly `(table, offset)` in the model's ledgers, if any.
        fn model_conserved(workload: *const Workload, table: u32, offset: u8) ?ModelConserved {
            for (workload.model_ledgers.items, 0..) |*ledger, index| {
                for (ledger.definition.fields[0..ledger.definition.field_count]) |*field| {
                    if (field.table == table and field.offset == offset) {
                        return .{
                            .ledger = index,
                            .floor = if (field.flags.floor) field.floor else null,
                        };
                    }
                }
            }
            return null;
        }

        /// Whether an add writes a conserved field other than whole, as an i64: its 8 bytes
        /// overlap one that it does not match exactly, or it matches one as a u64.
        fn model_conserved_write(workload: *const Workload, table: u32, add: *const Add) bool {
            for (workload.model_ledgers.items) |*ledger| {
                for (ledger.definition.fields[0..ledger.definition.field_count]) |*field| {
                    if (field.table != table) continue;
                    if (field.offset == add.offset) return add.field != .i64;
                    const overlaps = add.offset < @as(u16, field.offset) + 8 and
                        field.offset < @as(u16, add.offset) + 8;
                    if (overlaps) return true;
                }
            }
            return false;
        }

        /// The lowest index of an entry that breaks a pair rule (written apart from the state
        /// machine's scan): a `pair` add outside every ledger, or without the next entry naming
        /// it; a partner (an add naming the `pair` add just before it) outside the first half's
        /// ledger, on its field, or with bounds, `clamp` or `pair`; any other add naming a
        /// `pair` add; a conserved add that is neither half of a pair.
        fn model_unpaired(workload: *const Workload, entries: []const Entry) ?usize {
            for (entries, 0..) |*entry, index| {
                if (entry.kind != .add) continue;
                const add = Add.from_entry(entry);
                const conserved = workload.model_conserved(entry.table, add.offset);
                const names_pair = add.flags.delta_from and
                    Add.from_entry(&entries[add.delta_from]).flags.pair;
                const partner = names_pair and add.delta_from + 1 == index;
                if (names_pair and !partner) return index;
                if (partner) {
                    const first_entry = &entries[index - 1];
                    // A first half outside every ledger was refused at its own index.
                    const first = workload.model_conserved(
                        first_entry.table,
                        Add.from_entry(first_entry).offset,
                    ).?;
                    const field = conserved orelse return index;
                    if (field.ledger != first.ledger) return index;
                    if (add.flags.pair or add.flags.clamp or add.flags.min or add.flags.max) {
                        return index;
                    }
                    if (first_entry.table == entry.table and first_entry.id == entry.id and
                        Add.from_entry(first_entry).offset == add.offset)
                    {
                        return index;
                    }
                    continue;
                }
                if (add.flags.pair) {
                    if (conserved == null) return index;
                    if (index + 1 == entries.len) return index;
                    const next = &entries[index + 1];
                    if (next.kind != .add) return index;
                    const next_add = Add.from_entry(next);
                    if (!next_add.flags.delta_from or next_add.delta_from != index) return index;
                    continue;
                }
                if (conserved != null) return index;
            }
            return null;
        }

        /// Whether a put or delete leaves its row's conserved fields as the model holds them
        /// (zeros for a row that does not exist).
        fn model_conserved_unchanged(workload: *const Workload, entry: *const Entry) bool {
            const version = workload.row_version(nerva.row_key(entry.table, entry.id));
            const current: [value_size]u8 = if (version.exists) version.value else @splat(0);
            const new: [value_size]u8 = if (entry.kind == .put) entry.value else @splat(0);
            for (workload.model_ledgers.items) |*ledger| {
                for (ledger.definition.fields[0..ledger.definition.field_count]) |*field| {
                    if (field.table != entry.table) continue;
                    const at = field.offset;
                    if (!std.mem.eql(u8, current[at..][0..8], new[at..][0..8])) return false;
                }
            }
            return true;
        }

        /// The model's expectation, computed independently of the state machine. On success,
        /// fills `expected` with each entry's result.
        fn commit_failure(
            workload: *Workload,
            entries: []const Entry,
            admission: views.Admission,
        ) ?Failure {
            assert(entries.len <= workload.expected.len);
            // A key already committed comes first, whatever else changed since.
            if (workload.key_failure(entries)) |failure| return failure;
            // Then admission (`views_admit`).
            if (admission != .fits) {
                if (admission == .too_large) workload.views_too_large += 1;
                workload.views_busy += 1;
                const index = for (entries, 0..) |*entry, index| {
                    if (workload.entry_viewed(entry)) break index;
                } else unreachable;
                return .{
                    .index = index,
                    .status = if (admission == .too_large) .views_too_large else .views_busy,
                    .op = 0,
                };
            }
            for (entries, 0..) |*entry, index| {
                if (entry.kind == .key and index > 0) {
                    return .{ .index = index, .status = .key_misplaced, .op = 0 };
                }
                const status = nerva.entry_validate(entry);
                entry_status_check(entry, status);
                if (status) |status_| {
                    return .{ .index = index, .status = status_, .op = 0 };
                }
                if (entry.kind == .add) {
                    const add = Add.from_entry(entry);
                    for (workload.model_views.items) |*view| {
                        if (view.definition.table != entry.table) continue;
                        if (views.add_touches_key(&view.definition, add.offset)) {
                            return .{ .index = index, .status = .view_key_field, .op = 0 };
                        }
                    }
                }
                if (entry.kind == .add) {
                    const add = Add.from_entry(entry);
                    if (add.flags.delta_from and (add.delta_from >= index or
                        entries[add.delta_from].kind != .add))
                    {
                        return .{ .index = index, .status = .delta_from_invalid, .op = 0 };
                    }
                    if (workload.model_conserved_write(entry.table, &add)) {
                        return .{ .index = index, .status = .conserved_write, .op = 0 };
                    }
                }
            }
            if (workload.model_unpaired(entries)) |index| {
                return .{ .index = index, .status = .unpaired, .op = 0 };
            }
            // The earliest write whose row an earlier write already wrote (adds may share one).
            for (entries, 0..) |*entry, index| {
                if (entry.kind == .read or entry.kind == .key) continue;
                for (entries[0..index]) |*previous| {
                    if (previous.kind != .read and previous.kind != .key and
                        previous.table == entry.table and
                        previous.id == entry.id and
                        !(previous.kind == .add and entry.kind == .add))
                    {
                        return .{ .index = index, .status = .write_duplicate, .op = 0 };
                    }
                }
            }
            for (entries, 0..) |*entry, index| {
                if (entry.kind != .read) continue;
                const version = workload.row_version(nerva.row_key(entry.table, entry.id));
                if (version.op != entry.op_seen) {
                    return .{ .index = index, .status = .conflict, .op = version.op };
                }
            }
            // Adds in order, each seeing the earlier adds of the transaction to its row.
            const expected = workload.expected[0..entries.len];
            @memset(expected, .{});
            for (entries, 0..) |*entry, index| {
                if (entry.kind == .put or entry.kind == .delete) {
                    if (!workload.model_conserved_unchanged(entry)) {
                        return .{ .index = index, .status = .conserved_write, .op = 0 };
                    }
                }
                if (entry.kind != .add) continue;
                // A conserved add stops at its field's floor (N75).
                const add_entry = Add.from_entry(entry);
                const add = if (workload.model_conserved(entry.table, add_entry.offset)) |field|
                    nerva.ledger_bounds(&add_entry, field.floor)
                else
                    add_entry;
                // The row before this add: the last earlier add to it, else the model.
                const earlier: ?usize = for (0..index) |i| {
                    const j = index - 1 - i;
                    if (entries[j].kind == .add and entries[j].table == entry.table and
                        entries[j].id == entry.id) break j;
                } else null;
                var row: [value_size]u8 = if (earlier) |j|
                    workload.add_row(entries[0 .. j + 1], j)
                else row: {
                    const version = workload.row_version(nerva.row_key(entry.table, entry.id));
                    if (!version.exists and !add.flags.create) {
                        return .{ .index = index, .status = .row_absent, .op = 0 };
                    }
                    break :row version.value;
                };
                const old = std.mem.readInt(u64, row[add.offset..][0..8], .little);
                const delta = if (add.flags.delta_from)
                    -expected[add.delta_from].applied
                else
                    add.delta;
                const applied = nerva.add_amount(&add, old, delta) orelse
                    return .{ .index = index, .status = .out_of_bounds, .op = 0, .value = old };
                expected[index] = .{
                    .applied = applied,
                    .value = nerva.add_apply(&add, old, applied),
                };
                std.mem.writeInt(u64, row[add.offset..][0..8], expected[index].value, .little);
            }
            return null;
        }

        /// The model's key row for a transaction that starts with a key (valid or not).
        fn key_row(entries: []const Entry) ?u128 {
            if (entries.len == 0 or entries[0].kind != .key) return null;
            const key = std.mem.readInt(u128, entries[0].value[0..16], .little);
            return nerva.row_key(nerva.table_commit_keys, nerva.commit_key_id(key));
        }

        /// Why a transaction under a valid key whose row exists commits nothing: its own entries
        /// again (`committed_before`), other entries (`key_reused`), or the row of another key
        /// (`key_collision`), at the op that wrote the row.
        fn key_failure(workload: *Workload, entries: []const Entry) ?Failure {
            const row = key_row(entries) orelse return null;
            if (nerva.entry_validate(&entries[0]) != null) return null;
            const version = workload.row_version(row);
            if (!version.exists) return null;
            const key = std.mem.readInt(u128, entries[0].value[0..16], .little);
            const committed = workload.committed_keys.get(key) orelse
                return .{ .index = 0, .status = .key_collision, .op = version.op };
            const same = committed.len == entries.len - 1 and
                std.mem.eql(u8, std.mem.sliceAsBytes(committed), std.mem.sliceAsBytes(entries[1..]));
            return .{
                .index = 0,
                .status = if (same) .committed_before else .key_reused,
                .op = version.op,
            };
        }

        /// A transaction committed under a key: its key's row, and the entries it committed.
        fn apply_key(workload: *Workload, op: u64, timestamp: u64, entries: []const Entry) void {
            const key = std.mem.readInt(u128, entries[0].value[0..16], .little);
            assert(!workload.row_version(key_row(entries).?).exists);
            // The state machine checksums the entries as `commit_wide` would carry them.
            const wide = workload.allocator.alloc(nerva.WideEntry, entries.len - 1) catch
                @panic("OOM");
            defer workload.allocator.free(wide);
            for (entries[1..], wide) |*entry, *entry_wide| {
                entry_wide.* = nerva.WideEntry.from_entry(entry);
            }
            const stored: nerva.CommitKey = .{
                .key = key,
                .checksum = vsr.checksum(std.mem.sliceAsBytes(wide)),
                .entry_count = @intCast(entries.len - 1),
            };
            const entry: Entry = .{
                .id = nerva.commit_key_id(key),
                .table = nerva.table_commit_keys,
                .kind = .put,
                .op_seen = 0,
                .value = std.mem.toBytes(stored),
            };
            workload.apply(op, timestamp, &entry, &.{ .status = .ok, .op = op });
            const copy = workload.allocator.dupe(Entry, entries[1..]) catch @panic("OOM");
            workload.committed_keys.putNoClobber(workload.allocator, key, copy) catch
                @panic("OOM");
            workload.keyed_committed += 1;
        }

        /// The row as the adds `entries[..=last]` to its row left it (`expected` filled in for
        /// them), starting from the model.
        fn add_row(workload: *Workload, entries: []const Entry, last: usize) [value_size]u8 {
            const table = entries[last].table;
            const id = entries[last].id;
            var row = workload.row_version(nerva.row_key(table, id)).value;
            for (entries, 0..) |*entry, index| {
                if (entry.kind != .add or entry.table != table or entry.id != id) continue;
                const add = Add.from_entry(entry);
                const field = row[add.offset..][0..8];
                std.mem.writeInt(u64, field, workload.expected[index].value, .little);
            }
            return row;
        }

        fn apply(
            workload: *Workload,
            op: u64,
            timestamp: u64,
            entry: *const Entry,
            result: *const EntryResult,
        ) void {
            const key = nerva.row_key(entry.table, entry.id);
            const change_kind: nerva.ChangeKind = switch (entry.kind) {
                .read => return,
                .put, .add => .put,
                .delete => kind: {
                    if (!workload.row_version(key).exists) return; // No-op.
                    break :kind .delete;
                },
                .key => unreachable, // A key's row is `apply_key`'s.
                _ => unreachable,
            };
            const value: [value_size]u8 = switch (entry.kind) {
                .put => entry.value,
                .delete => @splat(0),
                .add => value: {
                    const add = Add.from_entry(entry);
                    var value = workload.row_version(key).value;
                    std.mem.writeInt(u64, value[add.offset..][0..8], result.value, .little);
                    workload.adds_applied += 1;
                    if (result.applied != add.delta and !add.flags.delta_from) {
                        workload.adds_clamped += 1;
                    }
                    break :value value;
                },
                else => unreachable,
            };
            workload.rows.put(workload.allocator, key, .{
                .op = op,
                .exists = change_kind == .put,
                .value = value,
            }) catch @panic("OOM");

            const changes = workload.changes.items;
            if (changes.len > 0) assert(changes[changes.len - 1].timestamp < timestamp);
            workload.changes.append(workload.allocator, .{
                .id = entry.id,
                .table = entry.table,
                .kind = change_kind,
                .flags = .{},
                .op = op,
                .timestamp = timestamp,
                .value = value,
            }) catch @panic("OOM");
        }

        /// Admission (N52), for every transaction of the request before any applies: in order,
        /// a transaction is admitted while the request's distinct groups fit in
        /// `group_writes_limit`. Its groups are, for every write to a table with views, in each
        /// of those views, the group of the row as it was before the request and that of the
        /// put's value (or a creating add's empty row), where they match the view's filter.
        fn views_admit(
            workload: *Workload,
            request_body: []align(constants.cache_line_size) const u8,
        ) void {
            var request = MultiBatchDecoder.init(request_body, .{
                .element_size = @sizeOf(Entry),
            }) catch unreachable;
            const allocator = workload.allocator;
            workload.view_op_keys.clearRetainingCapacity();
            workload.view_op_members.clearRetainingCapacity();
            workload.view_txn_admission.clearRetainingCapacity();
            while (request.pop()) |batch| {
                const entries = stdx.bytes_as_slice(.exact, Entry, batch);
                workload.view_txn_keys.clearRetainingCapacity();
                workload.view_txn_members.clearRetainingCapacity();
                // One whose key's row exists writes nothing (`key_failure`).
                if (key_row(entries)) |row| {
                    if (workload.row_version(row).exists) {
                        workload.view_txn_admission.append(allocator, .fits) catch @panic("OOM");
                        continue;
                    }
                }
                const admission: views.Admission = admit: for (entries) |*entry| {
                    if (!workload.entry_viewed(entry)) continue;
                    const version = workload.row_version(nerva.row_key(entry.table, entry.id));
                    const value_old: ?[value_size]u8 = if (version.exists) version.value else null;
                    for (workload.model_views.items) |*view| {
                        if (view.definition.table != entry.table) continue;
                        var matched = false;
                        for (views.entry_values([value_size]u8, entry, value_old)) |candidate| {
                            const value = candidate orelse continue;
                            if (!views.row_matches(&view.definition, &value)) continue;
                            matched = true;
                            const group_key = views.group_key(&view.definition, &value);
                            const key = views.group_tree_key(view.id, &group_key);
                            if (workload.view_op_keys.contains(key)) continue;
                            if (workload.view_op_keys.count() == workload.group_writes_limit()) {
                                const own = workload.view_txn_keys.items.len ==
                                    workload.view_op_keys.count();
                                break :admit if (own) .too_large else .busy;
                            }
                            workload.view_op_keys.put(allocator, key, {}) catch @panic("OOM");
                            workload.view_txn_keys.append(allocator, key) catch @panic("OOM");
                        }
                        // And its member in each `min` or `max` slot, if either value is in the
                        // view (N62).
                        if (!matched) continue;
                        const definition = &view.definition;
                        const aggregates = definition.aggregates[0..definition.aggregate_count];
                        for (aggregates, 0..) |*aggregate, slot| {
                            if (!views.extreme(aggregate.function)) continue;
                            const key = nerva.member_key(view.id, @intCast(slot), entry.id);
                            if (workload.view_op_members.contains(key)) continue;
                            if (workload.view_op_members.count() == workload.member_writes_limit()) {
                                workload.views_busy_members += 1;
                                const own = workload.view_txn_members.items.len ==
                                    workload.view_op_members.count();
                                break :admit if (own) .too_large else .busy;
                            }
                            workload.view_op_members.put(allocator, key, {}) catch @panic("OOM");
                            workload.view_txn_members.append(allocator, key) catch @panic("OOM");
                        }
                    }
                } else .fits;
                if (admission != .fits) {
                    for (workload.view_txn_keys.items) |key| {
                        assert(workload.view_op_keys.remove(key));
                    }
                    for (workload.view_txn_members.items) |key| {
                        assert(workload.view_op_members.remove(key));
                    }
                }
                workload.view_txn_admission.append(allocator, admission) catch @panic("OOM");
            }
        }

        /// Whether the entry writes a table with a view (in any state).
        fn entry_viewed(workload: *const Workload, entry: *const Entry) bool {
            if (entry.table == 0) return false;
            switch (entry.kind) {
                .put, .delete, .add => {},
                else => return false,
            }
            for (workload.model_views.items) |*view| {
                if (view.definition.table == entry.table) return true;
            }
            return false;
        }

        fn check_declare_view(
            workload: *Workload,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const definition: *const ViewDefinition = @alignCast(
                std.mem.bytesAsValue(ViewDefinition, request_body[0..@sizeOf(ViewDefinition)]),
            );
            const results = stdx.bytes_as_slice(.exact, DeclareResult, reply_body);
            assert(results.len == 1);
            const result = results[0];

            const expected: nerva.DeclareStatus = expected: {
                if (views.definition_validate(definition)) |status| break :expected status;
                var table_views: u32 = 0;
                var table_extremes: u32 = views.extreme_count(definition);
                for (workload.model_views.items) |*view| {
                    const name = views.definition_name(&view.definition);
                    if (std.mem.eql(u8, name, views.definition_name(definition))) {
                        if (stdx.equal_bytes(ViewDefinition, &view.definition, definition)) {
                            assert(result.view_id == view.id);
                            assert(result.op == view.declared_op);
                            break :expected .exists;
                        }
                        break :expected .different;
                    }
                    if (view.definition.table == definition.table) {
                        table_views += 1;
                        table_extremes += views.extreme_count(&view.definition);
                    }
                }
                if (workload.model_views.items.len == nerva.views_max) break :expected .views_full;
                if (table_views == nerva.views_per_table_max) break :expected .table_views_full;
                // As the state machine's `table_extremes_max` (#68).
                const extremes_max = @min(
                    nerva.view_extremes_per_table_max,
                    workload.member_writes_limit(),
                );
                if (table_extremes > extremes_max) {
                    workload.table_extremes_full += 1;
                    break :expected .table_extremes_full;
                }
                break :expected .created;
            };
            assert(result.status == expected);
            if (expected == .created) {
                assert(result.view_id == workload.model_views.items.len + 1);
                assert(result.op > workload.op_max);
                workload.op_max = result.op;
                workload.model_views.append(workload.allocator, .{
                    .id = result.view_id,
                    .declared_op = result.op,
                    .definition = definition.*,
                    .ready_op = null,
                }) catch @panic("OOM");
            } else if (expected != .exists) {
                assert(result.view_id == 0 and result.op == 0);
            }
        }

        /// A ready view's groups must be the model's, computed from the rows; a building view's
        /// reply need only agree with itself.
        fn check_get_view(
            workload: *Workload,
            op_executed: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const query: *const nerva.ViewQuery = @alignCast(
                std.mem.bytesAsValue(nerva.ViewQuery, request_body[0..@sizeOf(nerva.ViewQuery)]),
            );
            const records = stdx.bytes_as_slice(.exact, ViewRecord, reply_body);
            if (query.limit == 0) {
                assert(records.len == 0);
                return;
            }
            assert(records.len >= 1);
            const header = records[0];
            assert(header.kind == .header);
            assert(header.view_id == query.view_id);
            assert(header.op == op_executed);
            assert(header.op > workload.op_max);
            workload.op_max = header.op;
            if (query.view_id == 0 or query.view_id > workload.model_views.items.len) {
                assert(header.state == .missing);
                assert(records.len == 1);
                return;
            }
            const view = &workload.model_views.items[query.view_id - 1];
            assert(header.declared_op == view.declared_op);
            // As of an op, clamped to the read's: no version is newer.
            const as_of: u64 = if (query.as_of == 0) op_executed else @min(query.as_of, op_executed);
            if (query.as_of != 0) workload.view_reads_as_of += 1;
            if (as_of < view.declared_op) {
                assert(header.state == .missing);
                assert(records.len == 1);
                return;
            }
            // As of an op, a page may end early, when its scans ran out (N66).
            const limit_max = StateMachine.view_groups_limit_max;
            assert(records.len - 1 <= @min(query.limit, limit_max));
            for (records[1..]) |*record| {
                assert(record.kind == .group);
                assert(record.count > 0);
                assert(record.group_hash >= query.group_hash_min);
                if (header.flags.more) assert(record.group_hash < header.cursor);
            }
            switch (header.state) {
                .building => {
                    // A ready view never builds again.
                    if (view.ready_op) |ready_op| assert(as_of < ready_op);
                    workload.view_reads_building += 1;
                    return;
                },
                .ready => {},
                .missing, .failed => unreachable, // No collisions among a few hundred groups.
            }
            view.ready_op = @min(view.ready_op orelse as_of, as_of);
            workload.view_reads_ready += 1;

            // The model's groups, from the rows as of `as_of`.
            var rows_then = workload.rows_as_of(as_of);
            defer rows_then.deinit(workload.allocator);
            var groups: std.AutoArrayHashMapUnmanaged([nerva.group_key_size_max]u8, nerva.Group) = .{};
            defer groups.deinit(workload.allocator);
            var rows = rows_then.iterator();
            while (rows.next()) |row| {
                if (@as(u32, @intCast(row.key_ptr.* >> 64)) != view.definition.table) continue;
                if (!views.row_matches(&view.definition, row.value_ptr)) continue;
                const key = views.group_key(&view.definition, row.value_ptr);
                const entry = groups.getOrPut(workload.allocator, key) catch @panic("OOM");
                if (!entry.found_existing) {
                    entry.value_ptr.* = std.mem.zeroes(nerva.Group);
                    entry.value_ptr.group_key = key;
                }
                model_group_add(&view.definition, entry.value_ptr, row.value_ptr);
            }

            var hash: [32]u8 = @splat(0);
            for (groups.values()) |*group| {
                views.hash_update(&hash, &views.group_digest(view.id, group), .add);
            }
            assert(std.mem.eql(u8, &header.hash, &hash));
            assert(header.group_count == groups.count());

            // The page: exactly the model's groups between the query's cursor and the next.
            const end: u64 = if (header.flags.more) header.cursor else std.math.maxInt(u64);
            var in_range: usize = 0;
            for (groups.keys(), groups.values()) |*key, *group| {
                const group_hash: u64 = @truncate(views.group_tree_key(view.id, key));
                if (group_hash < query.group_hash_min) continue;
                if (header.flags.more and group_hash >= end) continue;
                in_range += 1;
                const record = for (records[1..]) |*record| {
                    if (record.group_hash == group_hash) break record;
                } else unreachable; // A group the page left out.
                assert(std.mem.eql(u8, &record.group_key, &group.group_key));
                assert(record.count == group.count);
                assert(std.mem.eql(u8, std.mem.sliceAsBytes(&record.sums), std.mem.sliceAsBytes(&group.sums)));
                if (views.extreme_count(&view.definition) > 0) workload.view_extremes_checked += 1;
            }
            assert(in_range == records.len - 1);
        }

        /// Adds a row to a model group: its count and sums with `views.group_apply`, and its
        /// `min` and `max` slots here, apart from the state machine's members (N62).
        fn model_group_add(
            definition: *const ViewDefinition,
            group: *nerva.Group,
            value: *const [value_size]u8,
        ) void {
            const first = group.count == 0;
            views.group_apply(definition, group, value, .add);
            for (definition.aggregates[0..definition.aggregate_count], 0..) |*aggregate, slot| {
                const number = switch (aggregate.function) {
                    .min, .max => views.field_integer(aggregate.field, value),
                    else => continue,
                };
                const current = std.mem.readInt(i128, &group.sums[slot], .little);
                const best = if (first) number else switch (aggregate.function) {
                    .min => @min(current, number),
                    .max => @max(current, number),
                    else => unreachable,
                };
                std.mem.writeInt(i128, &group.sums[slot], best, .little);
            }
        }

        /// The rows that existed after `op`, replayed from the change feed.
        fn rows_as_of(workload: *const Workload, op: u64) std.AutoHashMapUnmanaged(u128, [value_size]u8) {
            var rows: std.AutoHashMapUnmanaged(u128, [value_size]u8) = .{};
            for (workload.changes.items) |*change| {
                if (change.op > op) break;
                const key = nerva.row_key(change.table, change.id);
                switch (change.kind) {
                    .put => rows.put(workload.allocator, key, change.value) catch @panic("OOM"),
                    .delete => _ = rows.remove(key),
                    else => unreachable,
                }
            }
            return rows;
        }

        fn row_version(workload: *const Workload, key: u128) Version {
            return workload.rows.get(key) orelse .{ .op = 0, .exists = false, .value = @splat(0) };
        }

        fn check_lookup_rows(
            workload: *Workload,
            op_executed: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            var request = MultiBatchDecoder.init(request_body, .{
                .element_size = @sizeOf(RowKey),
            }) catch unreachable;
            var reply = MultiBatchDecoder.init(reply_body, .{
                .element_size = @sizeOf(RowValue),
            }) catch unreachable;

            var op_read: ?u64 = null;
            while (request.pop()) |batch| {
                const keys = stdx.bytes_as_slice(.exact, RowKey, batch);
                const results = stdx.bytes_as_slice(.exact, RowValue, reply.pop().?);
                assert(results.len == keys.len);
                for (keys, results) |*key, *result| {
                    assert(result.id == key.id);
                    assert(result.table == key.table);
                    // Every result of one request was read at the same op, after every op
                    // checked so far (G2).
                    if (op_read) |op| assert(result.op_read == op);
                    assert(result.op_read > workload.op_max);
                    assert(result.op_read == op_executed);
                    op_read = result.op_read;
                    assert(stdx.zeroed(&result.reserved_b));
                    const expected: Version = if (key.table == 0 or key.reserved != 0)
                        .{ .op = 0, .exists = false, .value = @splat(0) }
                    else
                        workload.row_version(nerva.row_key(key.table, key.id));
                    assert(result.op == expected.op);
                    assert(result.flags.exists == expected.exists);
                    assert(std.mem.eql(u8, &result.value, &expected.value));
                }
            }
            assert(reply.pop() == null);
            if (op_read) |op| workload.op_max = op;
        }

        fn check_get_changes(
            workload: *Workload,
            op_executed: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const filter: *const ChangesFilter = @alignCast(
                std.mem.bytesAsValue(ChangesFilter, request_body[0..@sizeOf(ChangesFilter)]),
            );
            const results = stdx.bytes_as_slice(.exact, Change, reply_body);
            // Invalid filters return nothing.
            if (filter.limit == 0 or !stdx.zeroed(&filter.reserved) or
                filter.timestamp_min > TimestampRange.timestamp_max)
            {
                if (filter.limit != 0) workload.invalid_filters += 1;
                assert(results.len == 0);
                return;
            }
            const limit = @min(filter.limit, StateMachine.changes_limit_max);
            if (filter.limit > limit) workload.limits_clamped += 1;

            const changes = workload.changes.items;
            var start: usize = 0;
            while (start < changes.len and changes[start].timestamp < filter.timestamp_min) {
                start += 1;
            }
            const count = @min(limit, changes.len - start);
            assert(results.len == count + 1);
            for (results[0..count], changes[start..][0..count]) |actual, expected| {
                assert(stdx.equal_bytes(Change, &actual, &expected));
            }

            const end = results[count];
            assert(end.kind == .end);
            assert(end.id == 0 and end.table == 0);
            assert(stdx.zeroed(&end.value));
            assert(end.flags.more == (count == limit));
            if (end.flags.more) {
                assert(end.op == 0);
            } else {
                assert(end.op > workload.op_max);
                assert(end.op == op_executed);
                workload.op_max = end.op;
            }
            assert(end.timestamp == if (count == 0)
                filter.timestamp_min
            else
                results[count - 1].timestamp + 1);
            if (end.flags.more) workload.changes_cursor = end.timestamp;
        }

        /// The model's history of the row: its changes newest first, from `timestamp_max`, at most
        /// `limit` scanned; those after `op_max` are scanned but not returned (G6).
        fn check_get_history(
            workload: *Workload,
            op_executed: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const filter: *const HistoryFilter = @alignCast(
                std.mem.bytesAsValue(HistoryFilter, request_body[0..@sizeOf(HistoryFilter)]),
            );
            const results = stdx.bytes_as_slice(.exact, Change, reply_body);
            // Invalid filters return nothing.
            if (filter.table == 0 or filter.limit == 0 or filter.op_max == 0 or
                !stdx.zeroed(&filter.reserved) or
                filter.timestamp_max > TimestampRange.timestamp_max)
            {
                if (!stdx.zeroed(&filter.reserved) or
                    filter.timestamp_max > TimestampRange.timestamp_max)
                {
                    workload.invalid_filters += 1;
                }
                assert(results.len == 0);
                return;
            }
            const limit = @min(filter.limit, StateMachine.changes_limit_max);
            if (filter.limit > limit) workload.limits_clamped += 1;
            assert(results.len >= 1);

            var scanned: u32 = 0;
            var returned: usize = 0;
            var timestamp_last: u64 = 0;
            var index = workload.changes.items.len;
            while (index > 0 and scanned < limit) {
                index -= 1;
                const expected = &workload.changes.items[index];
                if (expected.table != filter.table or expected.id != filter.id) continue;
                if (filter.timestamp_max != 0 and expected.timestamp > filter.timestamp_max) {
                    continue;
                }
                scanned += 1;
                timestamp_last = expected.timestamp;
                if (expected.op > filter.op_max) {
                    workload.history_skipped += 1;
                    continue;
                }
                assert(returned < results.len - 1);
                assert(stdx.equal_bytes(Change, &results[returned], expected));
                returned += 1;
                workload.history_returned += 1;
            }
            assert(results.len == returned + 1);

            const end = results[returned];
            assert(end.kind == .end);
            assert(end.id == 0 and end.table == 0);
            assert(stdx.zeroed(&end.value));
            assert(end.flags.more == (scanned == limit));
            if (end.flags.more) {
                assert(end.op == 0);
                assert(end.timestamp == timestamp_last - 1);
                workload.history_cursor = .{
                    .table = filter.table,
                    .id = filter.id,
                    .timestamp_max = end.timestamp,
                };
            } else {
                assert(end.op > workload.op_max);
                assert(end.op == op_executed);
                assert(end.timestamp == 0);
                workload.op_max = end.op;
            }
        }

        // ---- Records and indexes (P123b, P123c) ----

        /// Records-only transactions over the records table (and sometimes a fact), one per
        /// batch: reads at the version seen (or stale, or ahead), puts and deletes; rarely
        /// invalid entries.
        fn build_records(workload: *Workload, body: []align(constants.cache_line_size) u8) usize {
            var encoder = MultiBatchEncoder.init(body, .{ .element_size = @sizeOf(WideEntry) });
            const batch_count = workload.prng.range_inclusive(
                u32,
                1,
                workload.options.multi_batch_per_request_limit,
            );
            for (0..batch_count) |_| {
                const writable = encoder.writable() orelse break;
                const entries_free = stdx.bytes_as_slice(.inexact, WideEntry, writable);
                const entries = entries_free[0..workload.prng.int_inclusive(
                    usize,
                    @min(entries_free.len, workload.options.entries_per_transaction_max),
                )];
                workload.build_record_transaction(entries);
                encoder.add(@intCast(entries.len * @sizeOf(WideEntry)));
            }
            return encoder.finish();
        }

        fn build_record_transaction(workload: *Workload, entries: []WideEntry) void {
            const prng = workload.prng;
            for (entries, 0..) |*entry, index| {
                const fact = workload.fact_ids.items.len > 0 and prng.chance(stdx.PRNG.ratio(1, 8));
                const table = if (fact) facts_table else records_table;
                const id = if (fact)
                    workload.fact_ids.items[prng.index(workload.fact_ids.items)]
                else
                    record_id(prng.int_inclusive(u64, workload.options.record_id_count - 1));
                const kind: nerva.EntryKind = switch (prng.chances(.{
                    .read = 4,
                    .put = 4,
                    .delete = 2,
                })) {
                    .read => .read,
                    .put => .put,
                    .delete => .delete,
                };
                const duplicate = kind != .read and for (entries[0..index]) |*previous| {
                    if (previous.kind != .read and previous.table == table and previous.id == id) {
                        break true;
                    }
                } else false;
                // Keep duplicate writes rare: they abort the whole transaction.
                entry.* = if (kind == .read or (duplicate and !prng.chance(stdx.PRNG.ratio(1, 50))))
                    workload.record_read(table, id)
                else
                    .{
                        .id = id,
                        .table = table,
                        .kind = kind,
                        .op_seen = 0,
                        .value = if (kind == .put) record_value(prng) else @splat(0),
                    };

                if (prng.chance(workload.options.invalid_entry_probability)) {
                    workload.invalid_entries += 1;
                    switch (prng.chances(.{
                        .table = 1,
                        .reserved_a = 1,
                        .reserved_b = 1,
                        .value = 1,
                        .kind = 1,
                        .add = 1,
                        .key = 1,
                        .op_seen = 1,
                    })) {
                        .table => entry.table = 0,
                        .reserved_a => entry.reserved_a[prng.index(&entry.reserved_a)] = 1,
                        .reserved_b => entry.reserved_b[prng.index(&entry.reserved_b)] = 1,
                        // Invalid for a read or a delete; a put's value is any bytes.
                        .value => entry.value[prng.index(&entry.value)] = 1,
                        .kind => entry.kind = @enumFromInt(prng.range_inclusive(u8, 6, 255)),
                        // Records take no adds (`field_invalid`).
                        .add => entry.kind = .add,
                        // Misplaced, or invalid as a key.
                        .key => entry.kind = .key,
                        .op_seen => entry.op_seen = prng.range_inclusive(u64, 1, 1 << 40),
                    }
                }
            }
        }

        fn record_read(workload: *Workload, table: u32, id: u128) WideEntry {
            const prng = workload.prng;
            const version = workload.record_version(nerva.record_key(table, id));
            const op_seen = if (prng.chance(workload.options.stale_read_probability))
                switch (prng.chances(.{ .stale = 4, .future = 1 })) {
                    .stale => prng.int_inclusive(u64, workload.op_max),
                    .future => future: {
                        workload.future_reads += 1;
                        break :future workload.op_max + prng.range_inclusive(u64, 1, 100);
                    },
                }
            else
                version.op;
            return .{ .id = id, .table = table, .kind = .read, .op_seen = op_seen, .value = @splat(0) };
        }

        /// Money with its fact (the first application's case, G1): one transaction per batch of
        /// ledger pairs (which may fail, `out_of_bounds`), then the put of a new record of the
        /// facts table. The fact commits exactly when the money moves.
        fn build_facts(workload: *Workload, body: []align(constants.cache_line_size) u8) usize {
            var encoder = MultiBatchEncoder.init(body, .{ .element_size = @sizeOf(WideEntry) });
            const batch_count = workload.prng.range_inclusive(
                u32,
                1,
                workload.options.multi_batch_per_request_limit,
            );
            for (0..batch_count) |_| {
                const writable = encoder.writable() orelse break;
                const entries_free = stdx.bytes_as_slice(.inexact, WideEntry, writable);
                if (entries_free.len < 3) {
                    encoder.add(0);
                    break;
                }
                var moves: [6]Entry = undefined;
                const count = workload.build_ledger_moves(moves[0..@min(6, entries_free.len - 1)]);
                assert(count >= 2);
                for (moves[0..count], entries_free[0..count]) |*entry, *wide| {
                    wide.* = WideEntry.from_entry(entry);
                }
                entries_free[count] = .{
                    .id = fact_id(workload.facts_sent),
                    .table = facts_table,
                    .kind = .put,
                    .op_seen = 0,
                    .value = record_value(workload.prng),
                };
                workload.facts_sent += 1;
                encoder.add(@intCast((count + 1) * @sizeOf(WideEntry)));
            }
            return encoder.finish();
        }

        /// A `commit_wide` request is facts (ledger pairs then a fact) when it writes a row.
        fn wide_request_facts(request_body: []align(constants.cache_line_size) const u8) bool {
            var request = MultiBatchDecoder.init(request_body, .{
                .element_size = @sizeOf(WideEntry),
            }) catch unreachable;
            while (request.pop()) |batch| {
                for (stdx.bytes_as_slice(.exact, WideEntry, batch)) |*entry| {
                    if (entry.table == ledger_accounts_table or entry.table == ledger_sources_table) {
                        return true;
                    }
                }
            }
            return false;
        }

        fn check_commit_wide(
            workload: *Workload,
            op_executed: u64,
            timestamp: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const facts = wide_request_facts(request_body);
            var request = MultiBatchDecoder.init(request_body, .{
                .element_size = @sizeOf(WideEntry),
            }) catch unreachable;
            var reply = MultiBatchDecoder.init(reply_body, .{
                .element_size = @sizeOf(EntryResult),
            }) catch unreachable;
            assert(request.batch_count() == reply.batch_count());
            // Facts: the ledger pairs' admission (N52), as `commit` would admit them.
            if (facts) workload.views_admit(workload.facts_narrow(request_body));

            var op_request: ?u64 = null;
            var batch_index: usize = 0;
            const block = StateMachine.entry_timestamps;
            var batch_timestamp =
                timestamp - @divExact(request.payload.len, @sizeOf(WideEntry)) * block;
            while (request.pop()) |batch| : (batch_index += 1) {
                const entries = stdx.bytes_as_slice(.exact, WideEntry, batch);
                const results = stdx.bytes_as_slice(.exact, EntryResult, reply.pop().?);
                assert(results.len == entries.len);
                batch_timestamp += entries.len * block;
                if (entries.len == 0) continue;

                var narrow: [6]Entry = undefined;
                const moves = narrow[0..if (facts) entries.len - 1 else 0];
                if (facts) {
                    assert(entries[entries.len - 1].table == facts_table);
                    for (entries[0..moves.len], moves) |*wide, *entry| entry.* = entry_narrow(wide);
                }
                const failure = if (facts)
                    workload.commit_failure(moves, workload.view_txn_admission.items[batch_index])
                else
                    workload.record_failure(entries);
                if (failure) |f| {
                    workload.transactions_failed += 1;
                    if (facts) {
                        workload.facts_failed += 1;
                        workload.ledger_refused.getPtr(f.status).* += 1;
                    } else {
                        workload.records_refused.getPtr(f.status).* += 1;
                    }
                    for (results, 0..) |result, index| {
                        if (index == f.index) {
                            assert(result.status == f.status);
                            assert(result.op == f.op);
                            assert(result.value == f.value);
                        } else {
                            assert(result.status == .aborted);
                            assert(result.op == 0);
                            assert(result.value == 0);
                        }
                        assert(result.applied == 0);
                    }
                    continue;
                }

                workload.transactions_committed += 1;
                const op = results[0].op;
                assert(op == op_executed);
                assert(op > workload.op_max);
                if (op_request) |op_request_| assert(op == op_request_);
                op_request = op;
                for (results, 0..) |result, index| {
                    assert(result.status == .ok);
                    assert(result.op == op);
                    const expected: Expected = if (index < moves.len) workload.expected[index] else .{};
                    assert(result.applied == expected.applied);
                    assert(result.value == expected.value);
                }
                if (facts) {
                    workload.check_ledger(moves, results[0..moves.len]);
                    workload.facts_committed += 1;
                } else {
                    workload.record_transactions_committed += 1;
                }
                for (entries, results, 0..) |*entry, *result, index| {
                    const entry_timestamp =
                        batch_timestamp - entries.len * block + index * block + 1;
                    if (index < moves.len) {
                        workload.apply(op, entry_timestamp, &moves[index], result);
                    } else {
                        workload.record_apply(op, entry_timestamp, entry);
                    }
                }
            }
            assert(reply.pop() == null);
            assert(batch_timestamp == timestamp);
            if (op_request) |op| workload.op_max = op;
        }

        /// The facts request's ledger pairs, as `commit` would carry them, for `views_admit`.
        fn facts_narrow(
            workload: *Workload,
            request_body: []align(constants.cache_line_size) const u8,
        ) []align(constants.cache_line_size) const u8 {
            var request = MultiBatchDecoder.init(request_body, .{
                .element_size = @sizeOf(WideEntry),
            }) catch unreachable;
            var encoder = MultiBatchEncoder.init(workload.narrow_body, .{
                .element_size = @sizeOf(Entry),
            });
            while (request.pop()) |batch| {
                const entries = stdx.bytes_as_slice(.exact, WideEntry, batch);
                const writable = encoder.writable().?;
                const count = if (entries.len == 0) 0 else entries.len - 1;
                const narrow = stdx.bytes_as_slice(.inexact, Entry, writable)[0..count];
                for (entries[0..count], narrow) |*wide, *entry| entry.* = entry_narrow(wide);
                encoder.add(@intCast(count * @sizeOf(Entry)));
            }
            return workload.narrow_body[0..encoder.finish()];
        }

        /// Why a records-only transaction cannot commit, in the state machine's order: static
        /// checks, duplicate writes, then stale reads (`commit_failure`, P123b). No key, add or
        /// view applies to a record here.
        fn record_failure(workload: *Workload, entries: []const WideEntry) ?Failure {
            for (entries, 0..) |*entry, index| {
                if (entry.kind == .key and index > 0) {
                    return .{ .index = index, .status = .key_misplaced, .op = 0 };
                }
                if (nerva.wide_entry_validate(entry)) |status| {
                    return .{ .index = index, .status = status, .op = 0 };
                }
                // A valid entry here is a record's read, put or delete.
                assert(entry.kind != .key and entry.kind != .add);
            }
            for (entries, 0..) |*entry, index| {
                if (entry.kind == .read) continue;
                for (entries[0..index]) |*previous| {
                    if (previous.kind != .read and previous.table == entry.table and
                        previous.id == entry.id)
                    {
                        return .{ .index = index, .status = .write_duplicate, .op = 0 };
                    }
                }
            }
            for (entries, 0..) |*entry, index| {
                if (entry.kind != .read) continue;
                const version = workload.record_version(nerva.record_key(entry.table, entry.id));
                if (version.op != entry.op_seen) {
                    return .{ .index = index, .status = .conflict, .op = version.op };
                }
            }
            @memset(workload.expected[0..entries.len], .{});
            return null;
        }

        fn record_apply(workload: *Workload, op: u64, timestamp: u64, entry: *const WideEntry) void {
            assert(nerva.table_is_record(entry.table));
            const key = nerva.record_key(entry.table, entry.id);
            const stored = workload.records.get(key);
            const kind: nerva.ChangeKind = switch (entry.kind) {
                .read => return,
                .put => .put,
                // Deleting an absent or deleted record is a no-op.
                .delete => if (stored != null and stored.?.exists) .delete else return,
                else => unreachable,
            };
            const value: [record_value_size]u8 = if (kind == .put) entry.value else @splat(0);
            workload.records.put(workload.allocator, key, .{
                .id = entry.id,
                .table = entry.table,
                .op = op,
                .exists = kind == .put,
                .value = value,
                // Fixed when the record is first written, and kept by its tombstone.
                .timestamp = if (stored) |record| record.timestamp else timestamp,
            }) catch @panic("OOM");
            const changes = workload.record_changes.items;
            if (changes.len > 0) assert(changes[changes.len - 1].timestamp < timestamp);
            workload.record_changes.append(workload.allocator, .{
                .id = entry.id,
                .table = entry.table,
                .kind = kind,
                .flags = .{},
                .op = op,
                .timestamp = timestamp,
                .value = value,
            }) catch @panic("OOM");
            if (entry.table == facts_table and stored == null) {
                if (workload.fact_ids.items.len < fact_ids_max) {
                    workload.fact_ids.append(workload.allocator, entry.id) catch @panic("OOM");
                } else {
                    workload.fact_ids.items[workload.prng.index(workload.fact_ids.items)] = entry.id;
                }
            }
        }

        fn record_version(workload: *const Workload, key: u128) RecordVersion {
            return workload.records.get(key) orelse record_absent;
        }

        /// A record's id for a read: one the workload writes, a fact, or one never written.
        fn record_id_random(workload: *Workload) struct { table: u32, id: u128 } {
            const prng = workload.prng;
            return switch (prng.chances(.{ .record = 6, .fact = 2, .row_table = 1 })) {
                .record => .{
                    .table = records_table,
                    .id = record_id(prng.int_inclusive(u64, workload.options.record_id_count)),
                },
                .fact => .{
                    .table = facts_table,
                    .id = if (workload.fact_ids.items.len == 0)
                        fact_id(0)
                    else
                        workload.fact_ids.items[prng.index(workload.fact_ids.items)],
                },
                // Not a record table: must come back as nothing.
                .row_table => .{ .table = 1, .id = record_id(0) },
            };
        }

        fn build_lookup_records(
            workload: *Workload,
            body: []align(constants.cache_line_size) u8,
        ) usize {
            const prng = workload.prng;
            var encoder = MultiBatchEncoder.init(body, .{ .element_size = @sizeOf(nerva.RecordKey) });
            const batch_count = prng.range_inclusive(
                u32,
                1,
                workload.options.multi_batch_per_request_limit,
            );
            // Each 32-byte key produces a 512-byte result: budget every batch against the reply.
            var keys_total: usize = 0;
            for (0..batch_count) |batch_index| {
                const writable = encoder.writable() orelse break;
                const keys_free = stdx.bytes_as_slice(.inexact, nerva.RecordKey, writable);
                const reply_trailer_size = vsr.multi_batch.trailer_total_size(.{
                    .element_size = @sizeOf(nerva.RecordValue),
                    .batch_count = @intCast(batch_index + 1),
                });
                const reply_keys_free = @divFloor(
                    constants.message_body_size_max - reply_trailer_size,
                    @sizeOf(nerva.RecordValue),
                ) -| keys_total;
                const keys_max = @min(keys_free.len, reply_keys_free);
                const keys = keys_free[0..prng.int_inclusive(usize, @min(keys_max, 8))];
                keys_total += keys.len;
                for (keys) |*key| {
                    const random = workload.record_id_random();
                    key.* = .{ .id = random.id, .table = random.table };
                    // Reserved bytes set: not found.
                    if (prng.chance(stdx.PRNG.ratio(1, 50))) key.reserved[prng.index(&key.reserved)] = 1;
                }
                encoder.add(@intCast(keys.len * @sizeOf(nerva.RecordKey)));
            }
            return encoder.finish();
        }

        fn check_lookup_records(
            workload: *Workload,
            op_executed: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            var request = MultiBatchDecoder.init(request_body, .{
                .element_size = @sizeOf(nerva.RecordKey),
            }) catch unreachable;
            var reply = MultiBatchDecoder.init(reply_body, .{
                .element_size = @sizeOf(nerva.RecordValue),
            }) catch unreachable;
            assert(op_executed > workload.op_max);
            while (request.pop()) |batch| {
                const keys = stdx.bytes_as_slice(.exact, nerva.RecordKey, batch);
                const results = stdx.bytes_as_slice(.exact, nerva.RecordValue, reply.pop().?);
                assert(results.len == keys.len);
                for (keys, results) |*key, *result| {
                    assert(result.id == key.id);
                    assert(result.table == key.table);
                    assert(result.op_read == op_executed);
                    assert(stdx.zeroed(&result.reserved));
                    assert(!result.flags.collision);
                    const valid = nerva.table_is_record(key.table) and stdx.zeroed(&key.reserved);
                    const expected = if (valid)
                        workload.record_version(nerva.record_key(key.table, key.id))
                    else
                        record_absent;
                    assert(result.op == expected.op);
                    assert(result.flags.exists == expected.exists);
                    assert(stdx.equal_bytes([record_value_size]u8, &result.value, &expected.value));
                    workload.record_reads += 1;
                }
            }
            assert(reply.pop() == null);
            workload.op_max = op_executed;
        }

        fn build_get_record_changes(
            workload: *Workload,
            body: []align(constants.cache_line_size) u8,
        ) usize {
            const prng = workload.prng;
            const changes = workload.record_changes.items;
            const filter: *ChangesFilter = @alignCast(
                std.mem.bytesAsValue(ChangesFilter, body[0..@sizeOf(ChangesFilter)]),
            );
            filter.* = .{
                .timestamp_min = switch (prng.chances(.{
                    .start = 1,
                    .known = 3,
                    .after = 1,
                    .cursor = 2,
                    .invalid = 1,
                })) {
                    .start => 0,
                    .known => if (changes.len == 0) 0 else changes[prng.index(changes)].timestamp,
                    .after => if (changes.len == 0) 0 else changes[changes.len - 1].timestamp + 1,
                    .cursor => workload.record_changes_cursor orelse 0,
                    .invalid => if (prng.chance(stdx.PRNG.ratio(1, 4))) timestamp_invalid(prng) else 0,
                },
                .limit = limit_random(prng, 16, StateMachine.record_changes_limit_max),
            };
            if (prng.chance(stdx.PRNG.ratio(1, 50))) {
                filter.reserved[prng.index(&filter.reserved)] = 1;
            }
            return @sizeOf(ChangesFilter);
        }

        fn check_get_record_changes(
            workload: *Workload,
            op_executed: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const filter: *const ChangesFilter = @alignCast(
                std.mem.bytesAsValue(ChangesFilter, request_body[0..@sizeOf(ChangesFilter)]),
            );
            const results = stdx.bytes_as_slice(.exact, nerva.RecordChange, reply_body);
            if (filter.limit == 0 or !stdx.zeroed(&filter.reserved) or
                filter.timestamp_min > TimestampRange.timestamp_max)
            {
                assert(results.len == 0);
                return;
            }
            const limit = @min(filter.limit, StateMachine.record_changes_limit_max);
            const changes = workload.record_changes.items;
            var start: usize = 0;
            while (start < changes.len and changes[start].timestamp < filter.timestamp_min) {
                start += 1;
            }
            const count = @min(limit, changes.len - start);
            assert(results.len == count + 1);
            for (results[0..count], changes[start..][0..count]) |*actual, *expected| {
                assert(stdx.equal_bytes(nerva.RecordChange, actual, expected));
            }
            const end = results[count];
            assert(end.kind == .end);
            assert(end.id == 0 and end.table == 0);
            assert(stdx.zeroed(&end.value));
            assert(end.flags.more == (count == limit));
            if (end.flags.more) {
                assert(end.op == 0);
                workload.record_changes_cursor = end.timestamp;
            } else {
                assert(end.op > workload.op_max);
                assert(end.op == op_executed);
                workload.op_max = end.op;
            }
            assert(end.timestamp == if (count == 0)
                filter.timestamp_min
            else
                results[count - 1].timestamp + 1);
            workload.record_changes_returned += count;
        }

        fn build_get_record_history(
            workload: *Workload,
            body: []align(constants.cache_line_size) u8,
        ) usize {
            const prng = workload.prng;
            const changes = workload.record_changes.items;
            const filter: *nerva.RecordHistoryFilter = @alignCast(std.mem.bytesAsValue(
                nerva.RecordHistoryFilter,
                body[0..@sizeOf(nerva.RecordHistoryFilter)],
            ));
            const random = workload.record_id_random();
            const known: ?*const nerva.RecordChange =
                if (changes.len == 0) null else &changes[prng.index(changes)];
            filter.* = .{
                .table = random.table,
                .id = random.id,
                .limit = limit_random(prng, 8, StateMachine.record_changes_limit_max),
                .op_max = switch (prng.chances(.{ .latest = 2, .past = 4, .invalid = 1 })) {
                    .latest => std.math.maxInt(u64),
                    .past => prng.range_inclusive(u64, 1, @max(1, workload.op_max)),
                    .invalid => 0,
                },
                .timestamp_max = switch (prng.chances(.{ .newest = 3, .known = 2, .invalid = 1 })) {
                    .newest => 0,
                    .known => if (known) |change| change.timestamp else 0,
                    .invalid => if (prng.chance(stdx.PRNG.ratio(1, 4))) timestamp_invalid(prng) else 0,
                },
            };
            if (known != null and prng.chance(stdx.PRNG.ratio(1, 2))) {
                filter.table = known.?.table;
                filter.id = known.?.id;
            }
            if (workload.record_history_cursor) |cursor| {
                if (prng.chance(stdx.PRNG.ratio(1, 4))) {
                    filter.table = cursor.table;
                    filter.id = cursor.id;
                    filter.timestamp_max = cursor.timestamp_max;
                }
            }
            if (prng.chance(stdx.PRNG.ratio(1, 50))) {
                filter.reserved[prng.index(&filter.reserved)] = 1;
            }
            return @sizeOf(nerva.RecordHistoryFilter);
        }

        /// As `check_get_history`, for a record (P123b).
        fn check_get_record_history(
            workload: *Workload,
            op_executed: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const filter: *const nerva.RecordHistoryFilter = @alignCast(std.mem.bytesAsValue(
                nerva.RecordHistoryFilter,
                request_body[0..@sizeOf(nerva.RecordHistoryFilter)],
            ));
            const results = stdx.bytes_as_slice(.exact, nerva.RecordChange, reply_body);
            if (!nerva.table_is_record(filter.table) or filter.limit == 0 or filter.op_max == 0 or
                !stdx.zeroed(&filter.reserved) or
                filter.timestamp_max > TimestampRange.timestamp_max)
            {
                assert(results.len == 0);
                return;
            }
            const limit = @min(filter.limit, StateMachine.record_changes_limit_max);
            assert(results.len >= 1);

            var scanned: u32 = 0;
            var returned: usize = 0;
            var timestamp_last: u64 = 0;
            var index = workload.record_changes.items.len;
            while (index > 0 and scanned < limit) {
                index -= 1;
                const expected = &workload.record_changes.items[index];
                if (expected.table != filter.table or expected.id != filter.id) continue;
                if (filter.timestamp_max != 0 and expected.timestamp > filter.timestamp_max) {
                    continue;
                }
                scanned += 1;
                timestamp_last = expected.timestamp;
                if (expected.op > filter.op_max) continue;
                assert(returned < results.len - 1);
                assert(stdx.equal_bytes(nerva.RecordChange, &results[returned], expected));
                returned += 1;
            }
            assert(results.len == returned + 1);
            workload.record_history_returned += returned;

            const end = results[returned];
            assert(end.kind == .end);
            assert(end.id == 0 and end.table == 0);
            assert(stdx.zeroed(&end.value));
            assert(end.flags.more == (scanned == limit));
            if (end.flags.more) {
                assert(end.op == 0);
                assert(end.timestamp == timestamp_last - 1);
                workload.record_history_cursor = .{
                    .table = filter.table,
                    .id = filter.id,
                    .timestamp_max = end.timestamp,
                };
            } else {
                assert(end.op > workload.op_max);
                assert(end.op == op_executed);
                assert(end.timestamp == 0);
                workload.op_max = end.op;
            }
        }

        /// One of the workload's indexes, or one under a declared name with another definition
        /// (`different`), or one the state machine refuses.
        fn build_declare_index(
            workload: *Workload,
            body: []align(constants.cache_line_size) u8,
        ) usize {
            const prng = workload.prng;
            const definition: *nerva.IndexDefinition = @alignCast(std.mem.bytesAsValue(
                nerva.IndexDefinition,
                body[0..@sizeOf(nerva.IndexDefinition)],
            ));
            definition.* = index_definition(prng.int_inclusive(u8, index_definitions - 1));
            switch (prng.chances(.{ .valid = 12, .different = 1, .row_table = 1, .name = 1 })) {
                .valid => {},
                .different => definition.where_count = 0,
                .row_table => definition.table = 1,
                .name => definition.name[0] = 'A',
            }
            if (definition.where_count == 0) definition.where = std.mem.zeroes(@TypeOf(definition.where));
            return @sizeOf(nerva.IndexDefinition);
        }

        fn check_declare_index(
            workload: *Workload,
            op_executed: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const definition = std.mem.bytesToValue(
                nerva.IndexDefinition,
                request_body[0..@sizeOf(nerva.IndexDefinition)],
            );
            const result = std.mem.bytesToValue(nerva.DeclareIndexResult, reply_body);
            assert(reply_body.len == @sizeOf(nerva.DeclareIndexResult));
            const expected: nerva.DeclareIndexResult = expected: {
                if (indexes.definition_validate(&definition)) |status| {
                    break :expected .{ .status = status, .index_id = 0, .op = 0 };
                }
                const name = indexes.definition_name(&definition);
                for (workload.model_indexes.items) |*index| {
                    if (!std.mem.eql(u8, indexes.definition_name(&index.definition), name)) continue;
                    break :expected if (stdx.equal_bytes(nerva.IndexDefinition, &index.definition, &definition))
                        .{ .status = .exists, .index_id = index.id, .op = index.declared_op }
                    else
                        .{ .status = .different, .index_id = 0, .op = 0 };
                }
                // At most `index_definitions` names: never full.
                assert(workload.model_indexes.items.len < nerva.indexes_max);
                const id = workload.model_indexes.items.len + 1;
                workload.model_indexes.append(workload.allocator, .{
                    .id = id,
                    .declared_op = op_executed,
                    .definition = definition,
                    .ready_op = null,
                }) catch @panic("OOM");
                break :expected .{ .status = .created, .index_id = id, .op = op_executed };
            };
            assert(result.status == expected.status);
            assert(result.index_id == expected.index_id);
            assert(result.op == expected.op);
            assert(op_executed > workload.op_max);
            workload.op_max = op_executed;
            workload.index_declared.getPtr(result.status).* += 1;
        }

        /// The index's state at `op`, from a reply: once ready, ready ever after.
        fn index_state_seen(index: *ModelIndex, op: u64, state: nerva.IndexState) void {
            if (index.ready_op != null) {
                assert(state == .ready);
            } else if (state == .ready) {
                index.ready_op = op;
            } else {
                assert(state == .building);
            }
        }

        fn build_get_index(workload: *Workload, body: []align(constants.cache_line_size) u8) usize {
            const prng = workload.prng;
            const query: *nerva.IndexGet = @alignCast(
                std.mem.bytesAsValue(nerva.IndexGet, body[0..@sizeOf(nerva.IndexGet)]),
            );
            query.* = .{ .id = prng.int_inclusive(u64, workload.model_indexes.items.len + 1) };
            if (prng.chance(stdx.PRNG.ratio(1, 20))) query.reserved[prng.index(&query.reserved)] = 1;
            return @sizeOf(nerva.IndexGet);
        }

        fn check_get_index(
            workload: *Workload,
            op_executed: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const query = std.mem.bytesToValue(nerva.IndexGet, request_body[0..@sizeOf(nerva.IndexGet)]);
            const result = std.mem.bytesToValue(nerva.Index, reply_body);
            assert(reply_body.len == @sizeOf(nerva.Index));
            const indexes_ = workload.model_indexes.items;
            if (!stdx.zeroed(&query.reserved) or query.id == 0 or query.id > indexes_.len) {
                assert(stdx.zeroed(std.mem.asBytes(&result)));
                return;
            }
            const index = &indexes_[query.id - 1];
            assert(result.id == index.id);
            assert(result.declared_op == index.declared_op);
            assert(stdx.equal_bytes(nerva.IndexDefinition, &result.definition, &index.definition));
            index_state_seen(index, op_executed, result.state);
            if (result.state == .ready) {
                // Every record that passes `where`, and no other.
                var count: u64 = 0;
                var records = workload.records.valueIterator();
                while (records.next()) |record| {
                    if (!record.exists or record.table != index.definition.table) continue;
                    if (indexes.place(&index.definition, &record.value, record.op) != null) {
                        count += 1;
                    }
                }
                assert(result.entry_count == count);
                workload.index_counts_checked += 1;
            }
        }

        /// A page of one index: an `eq` key the index's records have (or might), an order
        /// range, either direction; often the next page of the last incomplete one.
        fn build_scan_index(workload: *Workload, body: []align(constants.cache_line_size) u8) usize {
            const prng = workload.prng;
            const query: *nerva.IndexQuery = @alignCast(
                std.mem.bytesAsValue(nerva.IndexQuery, body[0..@sizeOf(nerva.IndexQuery)]),
            );
            if (workload.scan_cursor) |cursor| {
                if (prng.chance(stdx.PRNG.ratio(1, 2))) {
                    query.* = cursor;
                    workload.scans_continued += 1;
                    return @sizeOf(nerva.IndexQuery);
                }
            }
            query.* = std.mem.zeroes(nerva.IndexQuery);
            const indexes_ = workload.model_indexes.items;
            query.index_id = prng.int_inclusive(u64, indexes_.len) + 1; // The last: missing.
            const definition: ?*const nerva.IndexDefinition = if (query.index_id <= indexes_.len)
                &indexes_[query.index_id - 1].definition
            else
                null;
            if (definition) |known| {
                // By name, sometimes.
                if (prng.chance(stdx.PRNG.ratio(1, 8))) {
                    query.index_id = 0;
                    query.name = known.name;
                }
                var value = record_value(prng);
                query.eq_key = views.fields_key(known.eq[0..known.eq_count], &value);
                if (prng.chance(stdx.PRNG.ratio(1, 30))) {
                    query.eq_key[nerva.group_key_size_max - 1] = 1; // No record has it.
                }
            }
            query.order_max = std.math.maxInt(u64);
            if (prng.chance(stdx.PRNG.ratio(1, 3))) {
                const range_max: u64 = if (definition != null and definition.?.flags.order)
                    record_created_max
                else
                    @max(1, workload.op_max);
                query.order_min = prng.int_inclusive(u64, range_max);
                query.order_max = query.order_min + prng.int_inclusive(u64, range_max);
            }
            query.limit = limit_random(prng, 8, StateMachine.index_hits_max);
            query.flags.descending = prng.boolean();
            if (prng.chance(stdx.PRNG.ratio(1, 50))) {
                switch (prng.chances(.{ .reserved = 1, .range = 1, .padding = 1 })) {
                    .reserved => query.reserved_b[prng.index(&query.reserved_b)] = 1,
                    .range => query.order_min = query.order_max +| 1,
                    .padding => query.flags.padding = 1,
                }
            }
            return @sizeOf(nerva.IndexQuery);
        }

        fn check_scan_index(
            workload: *Workload,
            op_executed: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const query = std.mem.bytesToValue(nerva.IndexQuery, request_body[0..@sizeOf(nerva.IndexQuery)]);
            const results = stdx.bytes_as_slice(.exact, nerva.IndexRecord, reply_body);
            // Malformed: no reply.
            if (query.limit == 0 or query.flags.padding != 0 or
                !stdx.zeroed(&query.reserved_a) or !stdx.zeroed(&query.reserved_b) or
                query.order_min > query.order_max or
                (query.index_id == 0 and query.name[0] == 0) or
                (query.index_id != 0 and !stdx.zeroed(&query.name)))
            {
                assert(results.len == 0);
                return;
            }
            const limit = @min(query.limit, StateMachine.index_hits_max);
            assert(results.len >= 1);
            const header = &results[0];
            assert(header.kind == .header);
            assert(header.op == op_executed);
            assert(op_executed > workload.op_max);
            workload.op_max = op_executed;

            const index: *ModelIndex = for (workload.model_indexes.items) |*index| {
                if (query.index_id == index.id) break index;
                if (query.index_id == 0 and stdx.equal_bytes([32]u8, &query.name, &index.definition.name)) {
                    break index;
                }
            } else {
                assert(header.state == .missing);
                assert(header.index_id == 0);
                assert(results.len == 1);
                return;
            };
            assert(header.index_id == index.id);
            assert(header.table == index.definition.table);
            index_state_seen(index, op_executed, header.state);
            if (header.state == .building or
                !indexes.eq_key_valid(&index.definition, &query.eq_key))
            {
                assert(results.len == 1);
                assert(!header.flags.more);
                workload.index_scans_building += @intFromBool(header.state == .building);
                return;
            }

            // The model's entries for this key and range, in the index's order.
            var slot: u64 = 0;
            for (workload.model_indexes.items[0 .. index.id - 1]) |*other| {
                if (other.definition.table == index.definition.table) slot += 1;
            }
            const Hit = struct { order: u64, timestamp: u64, record: *const RecordVersion };
            var hits: std.ArrayListUnmanaged(Hit) = .{};
            defer hits.deinit(workload.allocator);
            var records = workload.records.valueIterator();
            while (records.next()) |record| {
                if (!record.exists or record.table != index.definition.table) continue;
                const place = indexes.place(&index.definition, &record.value, record.op) orelse continue;
                if (!stdx.equal_bytes([nerva.group_key_size_max]u8, &place.eq_key, &query.eq_key)) continue;
                if (place.order < query.order_min or place.order > query.order_max) continue;
                const timestamp = record.timestamp + 1 + nerva.views_per_table_max + slot;
                const descending = query.flags.descending;
                if (query.cursor_timestamp != 0 and query.cursor_order >= query.order_min and
                    query.cursor_order <= query.order_max)
                {
                    const after = if (place.order != query.cursor_order)
                        (place.order > query.cursor_order) != descending
                    else
                        (timestamp > query.cursor_timestamp) != descending and
                            timestamp != query.cursor_timestamp;
                    if (!after) continue;
                }
                hits.append(workload.allocator, .{
                    .order = place.order,
                    .timestamp = timestamp,
                    .record = record,
                }) catch @panic("OOM");
            }
            std.mem.sortUnstable(Hit, hits.items, query.flags.descending, struct {
                fn less_than(descending: bool, a: Hit, b: Hit) bool {
                    // Timestamps are distinct: no two hits are equal.
                    const less = if (a.order != b.order) a.order < b.order else a.timestamp < b.timestamp;
                    return less != descending;
                }
            }.less_than);
            const listed = @min(hits.items.len, limit);
            assert(results.len == 1 + listed);
            for (results[1..], hits.items[0..listed]) |*actual, *hit| {
                assert(actual.kind == .record);
                assert(actual.id == hit.record.id);
                assert(actual.table == index.definition.table);
                assert(actual.op == hit.record.op);
                assert(actual.order == hit.order);
                assert(actual.timestamp == hit.timestamp);
                assert(actual.index_id == index.id);
                assert(stdx.equal_bytes([record_value_size]u8, &actual.value, &hit.record.value));
            }
            workload.index_records_checked += listed;
            workload.index_scans_ready += 1;
            assert(header.flags.more == (hits.items.len > listed));
            if (header.flags.more) {
                assert(header.order == hits.items[listed - 1].order);
                assert(header.timestamp == hits.items[listed - 1].timestamp);
                var next = query;
                next.cursor_order = header.order;
                next.cursor_timestamp = header.timestamp;
                workload.scan_cursor = next;
            } else {
                assert(header.order == 0 and header.timestamp == 0);
                workload.scan_cursor = null;
            }
        }
    };
}
