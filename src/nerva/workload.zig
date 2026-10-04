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

/// A signed integer in `[min, max]` (the PRNG draws unsigned ones).
fn signed_range(prng: *stdx.PRNG, min: i64, max: i64) i64 {
    assert(min <= max);
    const span: u64 = @intCast(@as(i128, max) - min);
    return @intCast(@as(i128, min) + prng.int_inclusive(u64, span));
}

/// A filter limit: usually `[0, small_max]` (zero is invalid, and returns nothing); sometimes at
/// the largest a reply holds, just past it, or `maxInt(u32)`, which must be clamped (N48).
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
/// from it (N48): the entry is valid exactly when it breaks none of them, and otherwise the
/// status names one it breaks. (Which one wins when several are broken is `entry_validate`'s
/// choice.) An add's own parameters are `nerva_adds`'s to fuzz: when only they are wrong, any of
/// the add statuses may be named.
fn entry_status_check(entry: *const Entry, status: ?EntryStatus) void {
    var broken = std.EnumSet(EntryStatus).initEmpty();
    const kind_known = switch (entry.kind) {
        .read, .put, .delete, .add => true,
        _ => false,
    };
    if (!kind_known) broken.insert(.kind_invalid);
    if (entry.table == 0) broken.insert(.table_invalid);
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

        const Failure = struct { index: usize, status: EntryStatus, op: u64, value: u64 = 0 };
        /// An add's expected result.
        const Expected = struct { applied: i64 = 0, value: u64 = 0 };
        const transaction_entries_max = 64;

        /// Per hot budget, from the adds' results alone: what was funded, and where it is.
        const Budget = struct { funded: u64 = 0, available: u64 = 0, held: u64 = 0 };

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

        budgets: std.AutoHashMapUnmanaged(u64, Budget) = .{},
        budget_transactions: u64 = 0,
        adds_applied: u64 = 0,
        adds_clamped: u64 = 0,
        /// Scratch: the expected results of the transaction being checked (any size, up to a full
        /// batch).
        expected: []Expected,

        /// The cursor an incomplete `get_changes` reply returned, to continue from (N48).
        changes_cursor: ?u64 = null,
        /// The row and cursor an incomplete `get_history` reply returned, to continue from.
        history_cursor: ?struct { table: u32, id: u64, timestamp_max: u64 } = null,

        /// Coverage of the inputs and limits added in N48.
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
                };
            }
        };

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
            assert(options.entries_per_transaction_max <= transaction_entries_max);
            assert(options.table_count < receipts_table);
            const expected = try allocator.alloc(Expected, StateMachine.commit_entries_max);
            errdefer allocator.free(expected);
            return .{
                .allocator = allocator,
                .prng = prng,
                .options = options,
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
            log.info("full batches={} invalid entries={} future reads={} invalid filters={} " ++
                "limits clamped={} cursors continued={}", .{
                workload.full_batches,
                workload.invalid_entries,
                workload.future_reads,
                workload.invalid_filters,
                workload.limits_clamped,
                workload.cursors_continued,
            });
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
        ) struct { operation: Operation, size: usize } {
            workload.requests_sent += 1;

            const body_limited = body[0..workload.options.batch_size_limit];
            return switch (workload.prng.chances(.{
                .commit = 8,
                .claim = 4,
                .budget = 4,
                .lookup_rows = 3,
                .get_changes = 2,
                .get_history = 2,
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
            };
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
                // Rarely, one transaction as large as the request allows (N48): prefetch and the
                // state machine's scratch space at capacity.
                const full = workload.prng.chance(stdx.PRNG.ratio(1, 100));
                const entries = if (full) entries_free else entries_free[0..workload.prng.int_inclusive(
                    usize,
                    @min(entries_free.len, workload.options.entries_per_transaction_max),
                )];
                if (full) workload.full_batches += 1;
                workload.build_transaction(entries);
                encoder.add(@intCast(entries.len * @sizeOf(Entry)));
                if (full) break;
            }
            return encoder.finish();
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
                        .op_seen = 1,
                    })) {
                        .table => entry.table = 0,
                        .reserved_a => entry.reserved_a[prng.index(&entry.reserved_a)] = 1,
                        .reserved_b => entry.reserved_b = 1,
                        .reserved_c => entry.reserved_c[prng.index(&entry.reserved_c)] = 1,
                        .value => entry.value[prng.index(&entry.value)] = 1,
                        .kind => entry.kind = @enumFromInt(prng.range_inclusive(u8, 5, 255)),
                        .kind_zero => entry.kind = @enumFromInt(0),
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
                    // A version no row has yet (N48): it must conflict too.
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
                // Usually a few keys; sometimes as many as the reply can hold (N48).
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
                    // Where an incomplete reply said to continue (N48).
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
            // Or continue where an incomplete reply said to (N48).
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
            // the ops before it (N48).
            switch (operation) {
                .commit => workload.check_commit(op, timestamp, request_body, reply_body),
                .lookup_rows => workload.check_lookup_rows(op, request_body, reply_body),
                .get_changes => workload.check_get_changes(op, request_body, reply_body),
                .get_history => workload.check_get_history(op, request_body, reply_body),
            }
        }

        pub fn on_pulse(workload: *Workload, operation: Operation, timestamp: u64) void {
            _ = workload;
            _ = operation;
            _ = timestamp;
            unreachable; // Nerva never pulses.
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
            var batch_timestamp = timestamp - @divExact(request.payload.len, @sizeOf(Entry));
            while (request.pop()) |batch| {
                const entries = stdx.bytes_as_slice(.exact, Entry, batch);
                const results = stdx.bytes_as_slice(.exact, EntryResult, reply.pop().?);
                assert(results.len == entries.len);
                batch_timestamp += entries.len;
                if (entries.len == 0) continue;

                const claim = receipt_claim_is(entries);
                const budget = budget_is(entries);
                if (workload.commit_failure(entries)) |failure| {
                    // Adds alone, clamped and creating, never fail (G8).
                    assert(!budget);
                    workload.transactions_failed += 1;
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

                for (entries, results, 0..) |*entry, *result, index| {
                    const entry_timestamp = batch_timestamp - entries.len + index + 1;
                    workload.apply(op, entry_timestamp, entry, result);
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

        /// The model's expectation, computed independently of the state machine. On success,
        /// fills `expected` with each entry's result.
        fn commit_failure(workload: *Workload, entries: []const Entry) ?Failure {
            assert(entries.len <= workload.expected.len);
            for (entries, 0..) |*entry, index| {
                const status = nerva.entry_validate(entry);
                entry_status_check(entry, status);
                if (status) |status_| {
                    return .{ .index = index, .status = status_, .op = 0 };
                }
                if (entry.kind == .add) {
                    const add = Add.from_entry(entry);
                    if (add.flags.delta_from and (add.delta_from >= index or
                        entries[add.delta_from].kind != .add))
                    {
                        return .{ .index = index, .status = .delta_from_invalid, .op = 0 };
                    }
                }
            }
            // The earliest write whose row an earlier write already wrote (adds may share one).
            for (entries, 0..) |*entry, index| {
                if (entry.kind == .read) continue;
                for (entries[0..index]) |*previous| {
                    if (previous.kind != .read and previous.table == entry.table and
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
                if (entry.kind != .add) continue;
                const add = Add.from_entry(entry);
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
    };
}
