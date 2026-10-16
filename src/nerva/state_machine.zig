//! Nerva's state machine: the commit core.
//!
//! - `lookup_rows`: point reads, returning each row's value and version.
//! - `commit`: one batch = one transaction. Reads assert the version they saw; if any read is
//!   stale, or any entry is invalid, nothing is applied. Otherwise every write is applied at
//!   this op and appended to the change feed.
//! - `get_changes`: the change feed, scanned in timestamp (and therefore op) order.
//! - `get_history`: one row's changes, newest first, through an index on the change feed: the
//!   row as of any op (G6).
//!
//! All IO happens in `prefetch`; `commit` is synchronous and deterministic.

const std = @import("std");
const assert = std.debug.assert;
const maybe = stdx.maybe;
const log = std.log.scoped(.state_machine);

const stdx = @import("stdx");
const vsr = @import("../vsr.zig");
const constants = @import("../constants.zig");
const nerva = @import("../nerva.zig");
const GrooveType = @import("../lsm/groove.zig").GrooveType;
const ForestType = @import("../lsm/forest.zig").ForestType;
const ScanTreeType = @import("../lsm/scan_tree.zig").ScanTreeType;
const ScanLookupType = @import("../lsm/scan_lookup.zig").ScanLookupType;
const TimestampRange = @import("../lsm/timestamp_range.zig").TimestampRange;
const MultiBatchDecoder = vsr.multi_batch.MultiBatchDecoder;
const MultiBatchEncoder = vsr.multi_batch.MultiBatchEncoder;

const Row = nerva.Row;
const Entry = nerva.Entry;
const WideEntry = nerva.WideEntry;
const EntryResult = nerva.EntryResult;
const EntryStatus = nerva.EntryStatus;
const Add = nerva.Add;
const View = nerva.View;
const Group = nerva.Group;
const Member = nerva.Member;
const GroupVersion = nerva.GroupVersion;
const ViewVersion = nerva.ViewVersion;
const ViewDefinition = nerva.ViewDefinition;
const ViewQuery = nerva.ViewQuery;
const ViewRecord = nerva.ViewRecord;
const DeclareResult = nerva.DeclareResult;
const DeclareLedgerResult = nerva.DeclareLedgerResult;
const Ledger = nerva.Ledger;
const LedgerDefinition = nerva.LedgerDefinition;
const LedgerQuery = nerva.LedgerQuery;
const views = @import("views.zig");
const ledgers = @import("ledgers.zig");
const indexes = @import("indexes.zig");
const Index = nerva.Index;
const IndexEntry = nerva.IndexEntry;
const IndexDefinition = nerva.IndexDefinition;
const IndexQuery = nerva.IndexQuery;
const IndexRecord = nerva.IndexRecord;
const DeclareIndexResult = nerva.DeclareIndexResult;
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
const Record = nerva.Record;
const RecordKey = nerva.RecordKey;
const RecordValue = nerva.RecordValue;
const RecordChange = nerva.RecordChange;
const RecordHistoryFilter = nerva.RecordHistoryFilter;
const CommitKey = nerva.CommitKey;
const Change = nerva.Change;
const ChangesFilter = nerva.ChangesFilter;
const HistoryFilter = nerva.HistoryFilter;
const tree_ids = nerva.tree_ids;

pub fn StateMachineType(comptime Storage: type) type {
    return struct {
        const StateMachine = @This();
        const Grid = @import("../vsr/grid.zig").GridType(Storage);

        pub const Operation = nerva.Operation;
        pub const Workload = @import("workload.zig").WorkloadType(StateMachine);

        /// Upper bounds over every runtime `batch_size_limit`.
        pub const commit_entries_max = Operation.commit.event_max(constants.message_body_size_max);
        pub const lookup_rows_max =
            Operation.lookup_rows.event_max(constants.message_body_size_max);
        /// -1 for the `end` record.
        pub const changes_limit_max =
            Operation.get_changes.result_max(constants.message_body_size_max) - 1;
        /// Records (P123b): the most one op writes, looks up, or returns as changes.
        pub const commit_wide_entries_max =
            Operation.commit_wide.event_max(constants.message_body_size_max);
        pub const lookup_records_max =
            Operation.lookup_records.event_max(constants.message_body_size_max);
        /// -1 for the `end` record.
        pub const record_changes_limit_max =
            Operation.get_record_changes.result_max(constants.message_body_size_max) - 1;
        /// Index entries one op may write (P123c): every record write, in every index of its
        /// table. A pulse's backfill writes fewer (`group_writes_limit`).
        pub const index_entries_per_op_max: u32 =
            nerva.indexes_per_table_max * commit_wide_entries_max;
        /// -1 for the header.
        pub const index_hits_max = Operation.scan_index.result_max(constants.message_body_size_max) - 1;

        /// Timestamps a commit entry takes: its change, then one per view of its table, for a
        /// group the entry creates (N52), then one per `min` or `max` slot of its table, for a
        /// member the entry creates (N62).
        pub const entry_timestamps =
            1 + nerva.views_per_table_max + nerva.view_extremes_per_table_max;
        /// Distinct members one op may write, each once (N62): admission refuses a transaction
        /// that would take its op past this, as it does for groups. A write takes a member in
        /// each `min` or `max` slot of its table: with one or two such slots, any request fits.
        pub const members_per_op_max: u32 = commit_entries_max;
        /// Groups per `get_view` page read as of a past op: each takes a scan (N62).
        /// Scans a `get_view` page read as of a past op may take (N66): one per listed group
        /// changed since `as_of`. The page ends at the group that would take one more.
        /// 128 in production; few with the small messages of tests, so that pages end early.
        pub const view_as_of_scans_max = @max(1, @min(128, @divFloor(view_groups_limit_max, 8)));
        /// Distinct groups one op may write (N52), each once: admission refuses a transaction
        /// that would take its op past this. Groups are twice the size of rows, so this bounds
        /// the groups tree's tables to the rows tree's size.
        pub const groups_per_op_max: u32 = @max(1, @divFloor(commit_entries_max, 2));
        /// -1 for the header record.
        pub const view_groups_limit_max =
            Operation.get_view.result_max(constants.message_body_size_max) - 1;

        comptime {
            assert(commit_entries_max > 0);
            assert(lookup_rows_max > 0);
            assert(changes_limit_max > 0);
            assert(commit_wide_entries_max > 0);
            assert(commit_wide_entries_max <= commit_entries_max);
            assert(lookup_records_max > 0);
            assert(record_changes_limit_max > 0);
            assert(index_hits_max > 0);
            assert(groups_per_op_max <= index_entries_per_op_max);
            assert(view_groups_limit_max > 0);
            assert(view_as_of_scans_max > 0);
        }

        pub const Options = struct {
            batch_size_limit: u32,
            lsm_forest_compaction_block_count: u32 = Forest.Options.compaction_block_count_min,
            lsm_forest_node_count: u32,
            cache_entries_rows: u32 = cache_entries_rows_multiple,
            cache_entries_groups: u32 = GroupsGroove.ObjectsCache.Cache.value_count_max_multiple,
            cache_entries_members: u32 =
                MembersGroove.ObjectsCache.Cache.value_count_max_multiple,
            cache_entries_records: u32 =
                RecordsGroove.ObjectsCache.Cache.value_count_max_multiple,
            cache_entries_index_entries: u32 =
                IndexEntriesGroove.ObjectsCache.Cache.value_count_max_multiple,
        };

        /// The row cache holds a multiple of this many rows (its set size), and at least one.
        pub const cache_entries_rows_multiple: u32 =
            RowsGroove.ObjectsCache.Cache.value_count_max_multiple;

        const RowsGroove = GrooveType(
            Storage,
            Row,
            .{
                .ids = tree_ids.Row,
                .batch_value_count_max = .{
                    .timestamp = commit_entries_max,
                    .key = commit_entries_max,
                },
                .primary_key = "key",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{"key"},
                .ignored = &[_][:0]const u8{ "value", "op", "flags", "reserved" },
                .optional = &[_][:0]const u8{},
                .derived = .{},
                .objects_cache = true,
            },
        );

        const ChangesGroove = GrooveType(
            Storage,
            Change,
            .{
                .ids = tree_ids.Change,
                .batch_value_count_max = .{
                    .timestamp = commit_entries_max,
                    .row_key = commit_entries_max,
                },
                .primary_key = "timestamp",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{},
                .ignored = &[_][:0]const u8{
                    "id",
                    "table",
                    "kind",
                    "flags",
                    "reserved_a",
                    "op",
                    "value",
                    "reserved_b",
                },
                .optional = &[_][:0]const u8{},
                .derived = .{
                    .row_key = struct {
                        fn row_key(change: *const Change) ?u128 {
                            return nerva.row_key(change.table, change.id);
                        }
                    }.row_key,
                },
                // Append only: never looked up by key or updated; scans read it from storage.
                .objects_cache = false,
            },
        );

        const ViewsGroove = GrooveType(
            Storage,
            View,
            .{
                .ids = tree_ids.View,
                .batch_value_count_max = .{
                    .timestamp = nerva.views_max,
                    .id = nerva.views_max,
                },
                .primary_key = "id",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{"id"},
                .ignored = &[_][:0]const u8{
                    "declared_op",
                    "backfill_cursor",
                    "group_count",
                    "state",
                    "reserved_a",
                    "hash",
                    "definition",
                    "reserved_b",
                },
                .optional = &[_][:0]const u8{},
                .derived = .{},
                .objects_cache = true,
            },
        );

        const GroupsGroove = GrooveType(
            Storage,
            Group,
            .{
                .ids = tree_ids.Group,
                .batch_value_count_max = .{
                    .timestamp = groups_per_op_max,
                    .key = groups_per_op_max,
                },
                .primary_key = "key",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{"key"},
                .ignored = &[_][:0]const u8{ "count", "group_key", "sums", "op", "reserved" },
                .optional = &[_][:0]const u8{},
                .derived = .{},
                .objects_cache = true,
            },
        );

        const MembersGroove = GrooveType(
            Storage,
            Member,
            .{
                .ids = tree_ids.Member,
                .batch_value_count_max = .{
                    .timestamp = members_per_op_max,
                    .key = members_per_op_max,
                    // An update moves a member: out of its old position, into its new one.
                    .order = 2 * members_per_op_max,
                },
                .primary_key = "key",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{"key"},
                .ignored = &[_][:0]const u8{
                    "position",
                    "view_id",
                    "slot",
                    "flags",
                    "reserved",
                    "group_key",
                    "value",
                },
                .optional = &[_][:0]const u8{},
                .derived = .{
                    .order = struct {
                        fn order(member: *const Member) ?u128 {
                            return if (member.flags.present) member.position else null;
                        }
                    }.order,
                },
                .objects_cache = true,
            },
        );

        const GroupVersionsGroove = GrooveType(
            Storage,
            GroupVersion,
            .{
                .ids = tree_ids.GroupVersion,
                .batch_value_count_max = .{
                    .timestamp = groups_per_op_max,
                    .version = groups_per_op_max,
                },
                .primary_key = "timestamp",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{},
                .ignored = &[_][:0]const u8{
                    "op",
                    "key",
                    "count",
                    "group_key",
                    "sums",
                    "reserved",
                },
                .optional = &[_][:0]const u8{},
                .derived = .{},
                // Append only, like changes.
                .objects_cache = false,
            },
        );

        const ViewVersionsGroove = GrooveType(
            Storage,
            ViewVersion,
            .{
                .ids = tree_ids.ViewVersion,
                .batch_value_count_max = .{
                    .timestamp = nerva.views_max,
                    .version = nerva.views_max,
                },
                .primary_key = "timestamp",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{},
                .ignored = &[_][:0]const u8{
                    "op",
                    "group_count",
                    "state",
                    "reserved_a",
                    "hash",
                    "reserved_b",
                },
                .optional = &[_][:0]const u8{},
                .derived = .{},
                .objects_cache = false,
            },
        );

        const LedgersGroove = GrooveType(
            Storage,
            Ledger,
            .{
                .ids = tree_ids.Ledger,
                .batch_value_count_max = .{
                    .timestamp = 1,
                    .slot = 1,
                },
                .primary_key = "slot",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{"slot"},
                .ignored = &[_][:0]const u8{
                    "op",
                    "reserved_a",
                    "definition",
                    "reserved_b",
                },
                .optional = &[_][:0]const u8{},
                .derived = .{},
                .objects_cache = true,
            },
        );

        const RecordsGroove = GrooveType(
            Storage,
            Record,
            .{
                .ids = tree_ids.Record,
                .batch_value_count_max = .{
                    .timestamp = commit_wide_entries_max,
                    .key = commit_wide_entries_max,
                },
                .primary_key = "key",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{"key"},
                .ignored = &[_][:0]const u8{
                    "id",
                    "table",
                    "flags",
                    "op",
                    "reserved",
                    "value",
                },
                .optional = &[_][:0]const u8{},
                .derived = .{},
                .objects_cache = true,
            },
        );

        const RecordChangesGroove = GrooveType(
            Storage,
            RecordChange,
            .{
                .ids = tree_ids.RecordChange,
                .batch_value_count_max = .{
                    .timestamp = commit_wide_entries_max,
                    .record_key = commit_wide_entries_max,
                },
                .primary_key = "timestamp",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{},
                .ignored = &[_][:0]const u8{
                    "id",
                    "table",
                    "kind",
                    "flags",
                    "reserved_a",
                    "op",
                    "reserved_b",
                    "value",
                },
                .optional = &[_][:0]const u8{},
                .derived = .{
                    .record_key = struct {
                        fn record_key(change: *const RecordChange) ?u128 {
                            return nerva.record_key(change.table, change.id);
                        }
                    }.record_key,
                },
                // Append only, like changes.
                .objects_cache = false,
            },
        );

        const IndexesGroove = GrooveType(
            Storage,
            Index,
            .{
                .ids = tree_ids.Index,
                .batch_value_count_max = .{
                    .timestamp = nerva.indexes_max,
                    .id = nerva.indexes_max,
                },
                .primary_key = "id",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{"id"},
                .ignored = &[_][:0]const u8{
                    "backfill_cursor",
                    "declared_op",
                    "entry_count",
                    "state",
                    "reserved_a",
                    "definition",
                    "reserved_b",
                },
                .optional = &[_][:0]const u8{},
                .derived = .{},
                .objects_cache = true,
            },
        );

        const IndexEntriesGroove = GrooveType(
            Storage,
            IndexEntry,
            .{
                .ids = tree_ids.IndexEntry,
                .batch_value_count_max = .{
                    .timestamp = index_entries_per_op_max,
                    .key = index_entries_per_op_max,
                    // An update moves an entry: out of its old position, into its new one.
                    .order = 2 * index_entries_per_op_max,
                },
                .primary_key = "key",
                .primary_key_orphaned = false,
                .unique_keys = &[_][:0]const u8{"key"},
                .ignored = &[_][:0]const u8{
                    "position",
                    "id",
                    "index_id",
                    "flags",
                    "reserved",
                    "eq_key",
                },
                .optional = &[_][:0]const u8{},
                .derived = .{
                    .order = struct {
                        fn order(entry: *const IndexEntry) ?u128 {
                            return if (entry.flags.present) entry.position else null;
                        }
                    }.order,
                },
                .objects_cache = true,
            },
        );

        pub const Forest = ForestType(Storage, .{
            .rows = RowsGroove,
            .changes = ChangesGroove,
            .views = ViewsGroove,
            .groups = GroupsGroove,
            .members = MembersGroove,
            .group_versions = GroupVersionsGroove,
            .view_versions = ViewVersionsGroove,
            .ledgers = LedgersGroove,
            .records = RecordsGroove,
            .record_changes = RecordChangesGroove,
            .indexes = IndexesGroove,
            .index_entries = IndexEntriesGroove,
        });

        const RowsScanLookup = ScanLookupType(
            RowsGroove,
            RowsGroove.ScanBuilder.Scan,
            Storage,
        );
        const GroupsScanLookup = ScanLookupType(
            GroupsGroove,
            GroupsGroove.ScanBuilder.Scan,
            Storage,
        );
        const MembersScanLookup = ScanLookupType(
            MembersGroove,
            MembersGroove.ScanBuilder.Scan,
            Storage,
        );
        const GroupVersionsScanLookup = ScanLookupType(
            GroupVersionsGroove,
            GroupVersionsGroove.ScanBuilder.Scan,
            Storage,
        );
        const ViewVersionsScanLookup = ScanLookupType(
            ViewVersionsGroove,
            ViewVersionsGroove.ScanBuilder.Scan,
            Storage,
        );

        const ChangesScanTree = ScanTreeType(void, ChangesGroove.ObjectTree, Storage);
        const RecordChangesScanTree = ScanTreeType(void, RecordChangesGroove.ObjectTree, Storage);
        const RecordsScanLookup = ScanLookupType(
            RecordsGroove,
            RecordsGroove.ScanBuilder.Scan,
            Storage,
        );
        const IndexEntriesScanLookup = ScanLookupType(
            IndexEntriesGroove,
            IndexEntriesGroove.ScanBuilder.Scan,
            Storage,
        );
        const IndexEntryScratch = struct { entry: IndexEntry, stored: ?IndexEntry };
        const RecordHistoryScanLookup = ScanLookupType(
            RecordChangesGroove,
            RecordChangesGroove.ScanBuilder.Scan,
            Storage,
        );
        const HistoryScanLookup = ScanLookupType(
            ChangesGroove,
            ChangesGroove.ScanBuilder.Scan,
            Storage,
        );

        /// The first write of a transaction that duplicates an earlier write's row.
        const WriteKey = struct { key: u128, index: u32 };

        const Failure = struct { index: u32, status: EntryStatus, op: u64, value: u64 = 0 };

        const GroupScratch = struct { group: Group, stored: ?Group };
        const MemberScratch = struct { member: Member, stored: ?Member };

        /// One `min` or `max` slot of one group.
        const ExtremeKey = struct { group: u128, slot: u8 };

        /// What an op did to one `min` or `max` slot of a group (N62), gathered from the
        /// members it touched before the slot's new value is computed.
        const ExtremeScratch = struct {
            /// The best value among the touched members now in the group.
            best: ?i128 = null,
            /// Whether a touched member held the group's value before the op: the slot must
            /// then be read from the members' order, as prefetched.
            stored_left: bool = false,
        };

        /// The start of a group's members' order of one slot, as prefetched (N62): the first
        /// `removals_max + 1` members, or all of them.
        const ExtremeScan = struct {
            key: ExtremeKey,
            prefix: u64,
            function: nerva.AggregateFunction,
            /// An upper bound on the members of the slot the op may move or remove.
            removals_max: u32,
            /// Whether the op may take away the member holding the group's value: only then is
            /// the order read.
            read: bool = false,
            /// Where its members are in `extreme_members`, once read.
            start: u32 = 0,
            count: u32 = 0,
        };

        /// Batches one multi-batch request may carry.
        const request_batches_max = std.math.maxInt(u16);

        batch_size_limit: u32,
        /// `groups_per_op_max` for this `batch_size_limit`: the distinct groups an op may write,
        /// and the rows a pulse backfills (N52).
        group_writes_limit: u32,
        forest: Forest,

        prefetch_timestamp: u64 = 0,
        prepare_timestamp: u64 = 0,
        commit_timestamp: u64 = 0,

        prefetch_operation: ?Operation = null,
        prefetch_input: ?[]align(constants.cache_line_size) const u8 = null,
        prefetch_snapshot: ?u64 = null,
        prefetch_callback: ?*const fn (*StateMachine) void = null,
        rows_prefetch_context: RowsGroove.PrefetchContext = undefined,

        changes_scan_tree: ChangesScanTree = undefined,
        history_scan_lookup: HistoryScanLookup = undefined,
        /// Results of the last `get_changes` or `get_history` prefetch, consumed by its commit.
        changes_scan_buffer: []Change,
        /// The number of changes scanned, or null if the filter was invalid.
        changes_scan_count: ?u32 = null,
        records_prefetch_context: RecordsGroove.PrefetchContext = undefined,
        record_changes_scan_tree: RecordChangesScanTree = undefined,
        record_history_scan_lookup: RecordHistoryScanLookup = undefined,
        /// Results of the last `get_record_changes` or `get_record_history` prefetch.
        record_changes_scan_buffer: []RecordChange,
        record_changes_scan_count: ?u32 = null,

        /// Scratch space for duplicate-write detection.
        write_keys: []WriteKey,
        /// One `commit` batch, widened (`batch_entries`).
        wide_entries: []WideEntry,
        /// Scratch space for resolving one transaction's adds: each added row's value so far.
        /// Looked up by key only, never iterated (determinism).
        add_rows: std.AutoHashMapUnmanaged(u128, [nerva.value_size]u8) = .{},

        forest_callback: ?*const fn (*StateMachine) void = null,

        // ---- Views (N52) ----

        /// The number of views declared, once known (null after a reset: every id is probed).
        view_count: ?u32 = null,
        /// Whether a view is building, once known (null after a reset: a pulse finds out).
        view_building: ?bool = null,
        views_prefetch_context: ViewsGroove.PrefetchContext = undefined,
        groups_prefetch_context: GroupsGroove.PrefetchContext = undefined,
        rows_scan_lookup: RowsScanLookup = undefined,
        groups_scan_lookup: GroupsScanLookup = undefined,
        /// The views as this op found them (`views_stored`) and as it leaves them (`views_op`).
        views_op: [nerva.views_max]View = undefined,
        views_stored: [nerva.views_max]View = undefined,
        views_op_count: u32 = 0,
        /// Per request, the transactions the views budget refused: prefetch decides, commit
        /// obeys (N52). Of those, the ones too large for any op (#32).
        view_txn_busy: std.DynamicBitSetUnmanaged = .{},
        view_txn_too_large: std.DynamicBitSetUnmanaged = .{},
        /// The op's distinct groups, as admitted so far (prefetch); looked up only.
        view_op_keys: std.AutoHashMapUnmanaged(u128, void) = .{},
        /// The keys the transaction being admitted added, to take back if it does not fit.
        view_txn_keys: std.ArrayListUnmanaged(u128) = .{},
        /// The same for members (N62): the op's distinct members as admitted so far, and those
        /// the transaction being admitted added.
        view_op_members: std.AutoHashMapUnmanaged(u128, void) = .{},
        view_txn_members: std.ArrayListUnmanaged(u128) = .{},
        /// The groups this op changed, in the order first touched, and their state now and as
        /// stored: written back once each at the end of the op.
        groups_touched: std.ArrayListUnmanaged(u128) = .{},
        groups_scratch: std.AutoHashMapUnmanaged(u128, GroupScratch) = .{},
        /// Rows a pulse scanned (one more than it adds, to know whether the table has more).
        backfill_rows: []Row,
        backfill_count: ?u32 = null,
        /// Groups a `get_view` scanned (one more than its limit, to know whether there are more).
        view_groups: []Group,
        view_groups_count: ?u32 = null,
        /// The building view a pulse backfills (an index into `views_op`), if any.
        backfill_view: ?u32 = null,

        // ---- Ledgers (N75) ----

        /// The number of ledgers declared, once known (null after a reset: every slot is
        /// probed).
        ledger_count: ?u32 = null,
        ledgers_prefetch_context: LedgersGroove.PrefetchContext = undefined,
        /// The ledgers, in declaration order (slot minus one), and their conserved fields.
        ledgers_op: [nerva.ledgers_max]Ledger = undefined,
        ledger_index: ledgers.Index = .{},

        // ---- min, max and as_of (N62) ----

        /// `members_per_op_max` for this `batch_size_limit`.
        member_writes_limit: u32,
        members_prefetch_context: MembersGroove.PrefetchContext = undefined,
        members_scan_lookup: MembersScanLookup = undefined,
        group_versions_scan_lookup: GroupVersionsScanLookup = undefined,
        view_versions_scan_lookup: ViewVersionsScanLookup = undefined,
        /// The members this op changed, in the order first touched, and their state now and as
        /// stored: written back once each at the end of the op.
        members_touched: std.ArrayListUnmanaged(u128) = .{},
        members_scratch: std.AutoHashMapUnmanaged(u128, MemberScratch) = .{},
        /// Per `min` or `max` slot of a group the op touched; looked up only.
        extremes_scratch: std.AutoHashMapUnmanaged(ExtremeKey, ExtremeScratch) = .{},
        /// The slots whose members' order the op prefetched, in the order prefetched, and an
        /// index by key; their members are in `extreme_members`.
        extreme_scans: std.ArrayListUnmanaged(ExtremeScan) = .{},
        extreme_scan_index: std.AutoHashMapUnmanaged(ExtremeKey, u32) = .{},
        extreme_scans_done: u32 = 0,
        /// The members stage 4 counted, so that each is counted once.
        extreme_counted: std.AutoHashMapUnmanaged(u128, void) = .{},
        extreme_members: []Member,
        extreme_members_count: u32 = 0,
        /// `get_view` as of a past op: the view's version, then each listed group's version
        /// (null: the group did not exist yet).
        view_version: ?ViewVersion = null,
        group_versions: []?GroupVersion,
        group_versions_done: u32 = 0,
        group_version_scans: u32 = 0,
        /// The groups the page lists: fewer than requested when the scans ran out.
        view_groups_listed: u32 = 0,
        view_version_buffer: [1]ViewVersion = undefined,
        group_version_buffer: [1]GroupVersion = undefined,
        /// The op being prefetched (`get_view` as of a past op clamps to it).
        prefetch_op: u64 = 0,
        /// The next timestamp a version takes, and the last it may (the op's reserve).
        version_timestamp: u64 = 0,
        version_timestamp_max: u64 = 0,

        // ---- Declared indexes (P123c) ----

        /// The number of indexes declared, once known (null after a reset: every id is probed).
        index_count: ?u32 = null,
        /// Whether an index is building, once known (null after a reset: a pulse finds out).
        index_building: ?bool = null,
        indexes_prefetch_context: IndexesGroove.PrefetchContext = undefined,
        index_entries_prefetch_context: IndexEntriesGroove.PrefetchContext = undefined,
        /// The indexes as this op found them, and as it leaves them.
        indexes_op: [nerva.indexes_max]Index = undefined,
        indexes_stored: [nerva.indexes_max]Index = undefined,
        indexes_op_count: u32 = 0,
        /// `index_entries_per_op_max` for this `batch_size_limit`.
        index_entry_writes_limit: u32,
        /// The entries this op changed, in the order first touched, and their state now and as
        /// stored: written back once each at the end of the op.
        index_entries_touched: std.ArrayListUnmanaged(u128) = .{},
        index_entries_scratch: std.AutoHashMapUnmanaged(u128, IndexEntryScratch) = .{},
        /// A `scan_index`: the index (an index into `indexes_op`), the entries scanned (one more
        /// than the page, to know whether there are more), and its scan.
        index_scan: ?u32 = null,
        index_scan_entries: []IndexEntry,
        index_scan_count: u32 = 0,
        index_entries_scan_lookup: IndexEntriesScanLookup = undefined,
        /// The building index a pulse backfills (an index into `indexes_op`), and the records it
        /// scanned (one more than it adds).
        backfill_index: ?u32 = null,
        backfill_records: []Record,
        backfill_records_count: ?u32 = null,
        records_scan_lookup: RecordsScanLookup = undefined,

        // ---- Restore (N80) ----

        /// Set from `restore_prefetch` to the end of the matching `restore_*` commit.
        restoring: bool = false,
        /// A view's restore: whether its table had any row (a tombstone counts) at its op.
        restore_table_rows: ?bool = null,
        restore_scan_callback: ?*const fn (*StateMachine, []const Row) void = null,

        pub fn init(
            self: *StateMachine,
            allocator: std.mem.Allocator,
            time: stdx.Time,
            grid: *Grid,
            options: Options,
        ) !void {
            _ = time;
            assert(options.batch_size_limit <= constants.message_body_size_max);

            const commit_entries_limit = Operation.commit.event_max(options.batch_size_limit);
            const commit_wide_entries_limit =
                Operation.commit_wide.event_max(options.batch_size_limit);
            assert(commit_wide_entries_limit <= commit_wide_entries_max);
            const lookup_records_limit =
                Operation.lookup_records.event_max(options.batch_size_limit);
            const groups_limit: u32 = @max(1, @divFloor(commit_entries_limit, 2));
            assert(groups_limit <= groups_per_op_max);
            const lookup_rows_limit = Operation.lookup_rows.event_max(options.batch_size_limit);
            assert(commit_entries_limit <= commit_entries_max);
            assert(lookup_rows_limit <= lookup_rows_max);
            const members_limit = commit_entries_limit;
            assert(members_limit <= members_per_op_max);

            const index_entries_limit = nerva.indexes_per_table_max * commit_wide_entries_limit;
            assert(index_entries_limit <= index_entries_per_op_max);
            assert(groups_limit <= index_entries_limit);
            self.* = .{
                .batch_size_limit = options.batch_size_limit,
                .group_writes_limit = groups_limit,
                .member_writes_limit = members_limit,
                .index_entry_writes_limit = index_entries_limit,
                .index_scan_entries = undefined,
                .backfill_records = undefined,
                .forest = undefined,
                .changes_scan_buffer = undefined,
                .record_changes_scan_buffer = undefined,
                .write_keys = undefined,
                .wide_entries = undefined,
                .backfill_rows = undefined,
                .view_groups = undefined,
                .extreme_members = undefined,
                .group_versions = undefined,
            };

            try self.forest.init(
                allocator,
                grid,
                .{
                    .compaction_block_count = options.lsm_forest_compaction_block_count,
                    .node_count = options.lsm_forest_node_count,
                },
                .{
                    .rows = .{
                        .cache_entries_max = options.cache_entries_rows,
                        .prefetch_entries_for_read_max = lookup_rows_limit,
                        .prefetch_entries_for_update_max = commit_entries_limit,
                        .tree_options_object = .{
                            .batch_value_count_limit = commit_entries_limit,
                        },
                        .tree_options_index = .{
                            .key = .{ .batch_value_count_limit = commit_entries_limit },
                        },
                    },
                    .changes = .{
                        .cache_entries_max = 0,
                        .prefetch_entries_for_read_max = 0,
                        .prefetch_entries_for_update_max = 0,
                        .tree_options_object = .{
                            .batch_value_count_limit = commit_entries_limit,
                        },
                        .tree_options_index = .{
                            .row_key = .{ .batch_value_count_limit = commit_entries_limit },
                        },
                    },
                    .views = .{
                        .cache_entries_max = ViewsGroove.ObjectsCache.Cache.value_count_max_multiple,
                        .prefetch_entries_for_read_max = nerva.views_max,
                        .prefetch_entries_for_update_max = nerva.views_max,
                        .tree_options_object = .{ .batch_value_count_limit = nerva.views_max },
                        .tree_options_index = .{
                            .id = .{ .batch_value_count_limit = nerva.views_max },
                        },
                    },
                    .groups = .{
                        .cache_entries_max = options.cache_entries_groups,
                        .prefetch_entries_for_read_max = 0,
                        .prefetch_entries_for_update_max = groups_limit,
                        .tree_options_object = .{ .batch_value_count_limit = groups_limit },
                        .tree_options_index = .{
                            .key = .{ .batch_value_count_limit = groups_limit },
                        },
                    },
                    .members = .{
                        .cache_entries_max = options.cache_entries_members,
                        .prefetch_entries_for_read_max = 0,
                        .prefetch_entries_for_update_max = members_limit,
                        .tree_options_object = .{ .batch_value_count_limit = members_limit },
                        .tree_options_index = .{
                            .key = .{ .batch_value_count_limit = members_limit },
                            .order = .{ .batch_value_count_limit = 2 * members_limit },
                        },
                    },
                    .group_versions = .{
                        .cache_entries_max = 0,
                        .prefetch_entries_for_read_max = 0,
                        .prefetch_entries_for_update_max = 0,
                        .tree_options_object = .{ .batch_value_count_limit = groups_limit },
                        .tree_options_index = .{
                            .version = .{ .batch_value_count_limit = groups_limit },
                        },
                    },
                    .view_versions = .{
                        .cache_entries_max = 0,
                        .prefetch_entries_for_read_max = 0,
                        .prefetch_entries_for_update_max = 0,
                        .tree_options_object = .{ .batch_value_count_limit = nerva.views_max },
                        .tree_options_index = .{
                            .version = .{ .batch_value_count_limit = nerva.views_max },
                        },
                    },
                    .records = .{
                        .cache_entries_max = options.cache_entries_records,
                        .prefetch_entries_for_read_max = lookup_records_limit,
                        .prefetch_entries_for_update_max = commit_wide_entries_limit,
                        .tree_options_object = .{
                            .batch_value_count_limit = commit_wide_entries_limit,
                        },
                        .tree_options_index = .{
                            .key = .{ .batch_value_count_limit = commit_wide_entries_limit },
                        },
                    },
                    .record_changes = .{
                        .cache_entries_max = 0,
                        .prefetch_entries_for_read_max = 0,
                        .prefetch_entries_for_update_max = 0,
                        .tree_options_object = .{
                            .batch_value_count_limit = commit_wide_entries_limit,
                        },
                        .tree_options_index = .{
                            .record_key = .{
                                .batch_value_count_limit = commit_wide_entries_limit,
                            },
                        },
                    },
                    .indexes = .{
                        .cache_entries_max = IndexesGroove.ObjectsCache.Cache
                            .value_count_max_multiple,
                        .prefetch_entries_for_read_max = nerva.indexes_max,
                        .prefetch_entries_for_update_max = nerva.indexes_max,
                        .tree_options_object = .{ .batch_value_count_limit = nerva.indexes_max },
                        .tree_options_index = .{
                            .id = .{ .batch_value_count_limit = nerva.indexes_max },
                        },
                    },
                    .index_entries = .{
                        .cache_entries_max = options.cache_entries_index_entries,
                        .prefetch_entries_for_read_max = 0,
                        .prefetch_entries_for_update_max = index_entries_limit,
                        .tree_options_object = .{ .batch_value_count_limit = index_entries_limit },
                        .tree_options_index = .{
                            .key = .{ .batch_value_count_limit = index_entries_limit },
                            .order = .{ .batch_value_count_limit = 2 * index_entries_limit },
                        },
                    },
                    .ledgers = .{
                        .cache_entries_max = LedgersGroove.ObjectsCache.Cache
                            .value_count_max_multiple,
                        .prefetch_entries_for_read_max = nerva.ledgers_max,
                        .prefetch_entries_for_update_max = nerva.ledgers_max,
                        // One declaration per op.
                        .tree_options_object = .{ .batch_value_count_limit = 1 },
                        .tree_options_index = .{
                            .slot = .{ .batch_value_count_limit = 1 },
                        },
                    },
                },
            );
            errdefer self.forest.deinit(allocator);

            self.changes_scan_buffer = try allocator.alloc(Change, changes_limit_max);
            errdefer allocator.free(self.changes_scan_buffer);

            self.record_changes_scan_buffer =
                try allocator.alloc(RecordChange, record_changes_limit_max);
            errdefer allocator.free(self.record_changes_scan_buffer);

            self.write_keys = try allocator.alloc(WriteKey, commit_entries_limit);
            errdefer allocator.free(self.write_keys);

            self.wide_entries = try allocator.alloc(WideEntry, commit_entries_limit);
            errdefer allocator.free(self.wide_entries);

            try self.add_rows.ensureTotalCapacity(allocator, commit_entries_limit);
            errdefer self.add_rows.deinit(allocator);

            self.backfill_rows = try allocator.alloc(Row, groups_limit + 1);
            errdefer allocator.free(self.backfill_rows);

            self.view_groups = try allocator.alloc(Group, view_groups_limit_max + 1);
            errdefer allocator.free(self.view_groups);

            self.view_txn_busy = try std.DynamicBitSetUnmanaged.initEmpty(
                allocator,
                request_batches_max,
            );
            errdefer self.view_txn_busy.deinit(allocator);
            self.view_txn_too_large = try std.DynamicBitSetUnmanaged.initEmpty(
                allocator,
                request_batches_max,
            );
            errdefer self.view_txn_too_large.deinit(allocator);
            try self.view_op_keys.ensureTotalCapacity(allocator, groups_limit);
            errdefer self.view_op_keys.deinit(allocator);
            try self.view_txn_keys.ensureTotalCapacity(allocator, groups_limit);
            errdefer self.view_txn_keys.deinit(allocator);
            try self.groups_touched.ensureTotalCapacity(allocator, groups_limit);
            errdefer self.groups_touched.deinit(allocator);
            try self.groups_scratch.ensureTotalCapacity(allocator, groups_limit);
            errdefer self.groups_scratch.deinit(allocator);

            try self.members_touched.ensureTotalCapacity(allocator, members_limit);
            errdefer self.members_touched.deinit(allocator);
            try self.members_scratch.ensureTotalCapacity(allocator, members_limit);
            errdefer self.members_scratch.deinit(allocator);
            // A member may touch two (group, slot) keys: the group it leaves, when it held that
            // group's value, and the group it enters (`extremes_gather`, #62).
            try self.extremes_scratch.ensureTotalCapacity(allocator, 2 * members_limit);
            errdefer self.extremes_scratch.deinit(allocator);
            try self.extreme_scans.ensureTotalCapacity(allocator, members_limit);
            errdefer self.extreme_scans.deinit(allocator);
            try self.extreme_scan_index.ensureTotalCapacity(allocator, members_limit);
            errdefer self.extreme_scan_index.deinit(allocator);
            try self.extreme_counted.ensureTotalCapacity(allocator, members_limit);
            errdefer self.extreme_counted.deinit(allocator);
            try self.view_op_members.ensureTotalCapacity(allocator, members_limit);
            errdefer self.view_op_members.deinit(allocator);
            try self.view_txn_members.ensureTotalCapacity(allocator, members_limit);
            errdefer self.view_txn_members.deinit(allocator);
            // Each scan reads one more member than the op may take from its slot.
            self.extreme_members = try allocator.alloc(Member, 2 * members_limit);
            errdefer allocator.free(self.extreme_members);
            self.group_versions = try allocator.alloc(?GroupVersion, view_groups_limit_max);
            errdefer allocator.free(self.group_versions);

            try self.index_entries_touched.ensureTotalCapacity(allocator, index_entries_limit);
            errdefer self.index_entries_touched.deinit(allocator);
            try self.index_entries_scratch.ensureTotalCapacity(allocator, index_entries_limit);
            errdefer self.index_entries_scratch.deinit(allocator);
            self.index_scan_entries = try allocator.alloc(IndexEntry, index_hits_max + 1);
            errdefer allocator.free(self.index_scan_entries);
            self.backfill_records = try allocator.alloc(Record, groups_limit + 1);
            errdefer allocator.free(self.backfill_records);
        }

        pub fn deinit(self: *StateMachine, allocator: std.mem.Allocator) void {
            allocator.free(self.backfill_records);
            allocator.free(self.index_scan_entries);
            self.index_entries_scratch.deinit(allocator);
            self.index_entries_touched.deinit(allocator);
            allocator.free(self.group_versions);
            allocator.free(self.extreme_members);
            self.view_txn_members.deinit(allocator);
            self.view_op_members.deinit(allocator);
            self.extreme_counted.deinit(allocator);
            self.extreme_scan_index.deinit(allocator);
            self.extreme_scans.deinit(allocator);
            self.extremes_scratch.deinit(allocator);
            self.members_scratch.deinit(allocator);
            self.members_touched.deinit(allocator);
            self.groups_scratch.deinit(allocator);
            self.groups_touched.deinit(allocator);
            self.view_txn_keys.deinit(allocator);
            self.view_op_keys.deinit(allocator);
            self.view_txn_busy.deinit(allocator);
            self.view_txn_too_large.deinit(allocator);
            allocator.free(self.view_groups);
            allocator.free(self.backfill_rows);
            self.add_rows.deinit(allocator);
            allocator.free(self.wide_entries);
            allocator.free(self.write_keys);
            allocator.free(self.record_changes_scan_buffer);
            allocator.free(self.changes_scan_buffer);
            self.forest.deinit(allocator);
        }

        pub fn reset(self: *StateMachine) void {
            self.forest.reset();
            self.* = .{
                .batch_size_limit = self.batch_size_limit,
                .group_writes_limit = self.group_writes_limit,
                .forest = self.forest,
                .changes_scan_buffer = self.changes_scan_buffer,
                .record_changes_scan_buffer = self.record_changes_scan_buffer,
                .write_keys = self.write_keys,
                .wide_entries = self.wide_entries,
                .add_rows = self.add_rows,
                .backfill_rows = self.backfill_rows,
                .view_groups = self.view_groups,
                .view_txn_busy = self.view_txn_busy,
                .view_txn_too_large = self.view_txn_too_large,
                .view_op_keys = self.view_op_keys,
                .view_txn_keys = self.view_txn_keys,
                .groups_touched = self.groups_touched,
                .groups_scratch = self.groups_scratch,
                .member_writes_limit = self.member_writes_limit,
                .members_touched = self.members_touched,
                .members_scratch = self.members_scratch,
                .extremes_scratch = self.extremes_scratch,
                .extreme_scans = self.extreme_scans,
                .extreme_scan_index = self.extreme_scan_index,
                .extreme_counted = self.extreme_counted,
                .view_op_members = self.view_op_members,
                .view_txn_members = self.view_txn_members,
                .extreme_members = self.extreme_members,
                .group_versions = self.group_versions,
                .index_entry_writes_limit = self.index_entry_writes_limit,
                .index_entries_touched = self.index_entries_touched,
                .index_entries_scratch = self.index_entries_scratch,
                .index_scan_entries = self.index_scan_entries,
                .backfill_records = self.backfill_records,
            };
            self.index_entries_touched.clearRetainingCapacity();
            self.index_entries_scratch.clearRetainingCapacity();
            self.members_touched.clearRetainingCapacity();
            self.members_scratch.clearRetainingCapacity();
            self.extremes_scratch.clearRetainingCapacity();
            self.extreme_scans.clearRetainingCapacity();
            self.extreme_scan_index.clearRetainingCapacity();
            self.extreme_counted.clearRetainingCapacity();
            self.view_op_members.clearRetainingCapacity();
            self.view_txn_members.clearRetainingCapacity();
            self.view_txn_busy.unsetAll();
            self.view_op_keys.clearRetainingCapacity();
            self.view_txn_keys.clearRetainingCapacity();
            self.groups_touched.clearRetainingCapacity();
            self.groups_scratch.clearRetainingCapacity();
            self.add_rows.clearRetainingCapacity();
        }

        pub fn open(self: *StateMachine, callback: *const fn (*StateMachine) void) void {
            assert(self.forest_callback == null);
            self.forest_callback = callback;
            self.forest.open(forest_callback_done);
        }

        pub fn compact(
            self: *StateMachine,
            callback: *const fn (*StateMachine) void,
            op: u64,
        ) void {
            assert(op != 0);
            assert(self.forest_callback == null);
            self.forest_callback = callback;
            self.forest.compact(forest_callback_done, op);
        }

        pub fn checkpoint(self: *StateMachine, callback: *const fn (*StateMachine) void) void {
            assert(self.forest_callback == null);
            self.forest_callback = callback;
            self.forest.checkpoint(forest_callback_done);
        }

        fn forest_callback_done(forest: *Forest) void {
            const self: *StateMachine = @fieldParentPtr("forest", forest);
            const callback = self.forest_callback.?;
            self.forest_callback = null;
            callback(self);
        }

        /// Pulses backfill building views (N52). Unknown after a reset: one pulse finds out.
        pub fn pulse_needed(self: *const StateMachine, timestamp: u64) bool {
            _ = timestamp;
            return (self.view_building orelse true) or (self.index_building orelse true);
        }

        pub fn input_valid(
            self: *const StateMachine,
            operation: Operation,
            message_body_used: []align(constants.cache_line_size) const u8,
        ) bool {
            assert(message_body_used.len <= self.batch_size_limit);

            if (!operation.is_multi_batch()) {
                return self.batch_valid(operation, message_body_used);
            }
            assert(operation.is_multi_batch());

            var body_decoder = MultiBatchDecoder.init(message_body_used, .{
                .element_size = operation.event_size(),
            }) catch |err| switch (err) {
                error.MultiBatchInvalid => return false,
            };

            var result_count_expected: u32 = 0;
            while (body_decoder.pop()) |batch| {
                if (!self.batch_valid(operation, batch)) return false;
                result_count_expected += operation.result_count_expected(batch);
            }
            const reply_trailer_size: u32 = vsr.multi_batch.trailer_total_size(.{
                .element_size = operation.result_size(),
                .batch_count = body_decoder.batch_count(),
            });
            return result_count_expected * operation.result_size() + reply_trailer_size <=
                constants.message_body_size_max;
        }

        /// Validates the shape of one batch; entry contents are validated at commit.
        fn batch_valid(self: *const StateMachine, operation: Operation, batch: []const u8) bool {
            assert(batch.len <= self.batch_size_limit);
            switch (operation) {
                inline else => |operation_comptime| {
                    const event_size = operation_comptime.event_size();
                    if (comptime !operation_comptime.is_batchable()) {
                        return batch.len == event_size;
                    }
                    maybe(batch.len == 0);
                    if (batch.len % event_size != 0) return false;
                    const event_count: u32 = @intCast(@divExact(batch.len, event_size));
                    return event_count <= operation_comptime.event_max(self.batch_size_limit);
                },
            }
        }

        /// Advances `prepare_timestamp` by one per commit entry, so every write gets a unique
        /// timestamp.
        pub fn prepare(
            self: *StateMachine,
            operation: Operation,
            message_body_used: []align(constants.cache_line_size) const u8,
        ) void {
            assert(message_body_used.len <= self.batch_size_limit);
            const payload: []const u8 = switch (operation) {
                .lookup_rows, .commit, .commit_wide, .lookup_records => payload: {
                    const body_decoder = MultiBatchDecoder.init(message_body_used, .{
                        .element_size = operation.event_size(),
                    }) catch unreachable; // Already validated by `input_valid()`.
                    break :payload body_decoder.payload;
                },
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
                => message_body_used,
            };
            self.prepare_timestamp +=
                self.prepare_delta(operation, payload) + self.versions_reserve(operation);
        }

        fn prepare_delta(self: *const StateMachine, operation: Operation, events: []const u8) u64 {
            return switch (operation) {
                .commit => @divExact(events.len, @sizeOf(Entry)) * entry_timestamps,
                .commit_wide => @divExact(events.len, @sizeOf(WideEntry)) * entry_timestamps,
                .declare_view, .declare_ledger, .declare_index => 1,
                // Each row a pulse may add takes an entry's block.
                .pulse => self.group_writes_limit * entry_timestamps,
                .lookup_rows,
                .get_changes,
                .get_history,
                .get_view,
                .get_ledger,
                .lookup_records,
                .get_record_changes,
                .get_record_history,
                .scan_index,
                => 0,
            };
        }

        /// Timestamps an op takes, below those of its writes, for the versions of the groups and
        /// views it changes (N62).
        fn versions_reserve(self: *const StateMachine, operation: Operation) u64 {
            return switch (operation) {
                .commit, .commit_wide, .pulse => self.group_writes_limit + nerva.views_max,
                .declare_view => 1,
                .lookup_rows,
                .get_changes,
                .get_history,
                .get_view,
                .declare_ledger,
                .get_ledger,
                .lookup_records,
                .get_record_changes,
                .get_record_history,
                .declare_index,
                .scan_index,
                => 0,
            };
        }

        /// Starts the op's versions at the bottom of its reserve: `writes_min` is the timestamp
        /// just below its writes'.
        fn versions_begin(self: *StateMachine, operation: Operation, writes_min: u64) void {
            const reserve = self.versions_reserve(operation);
            assert(reserve > 0);
            assert(writes_min >= reserve);
            self.version_timestamp = writes_min - reserve + 1;
            self.version_timestamp_max = writes_min;
            assert(TimestampRange.valid(self.version_timestamp));
        }

        fn version_timestamp_next(self: *StateMachine) u64 {
            assert(self.version_timestamp <= self.version_timestamp_max);
            defer self.version_timestamp += 1;
            return self.version_timestamp;
        }

        pub fn prefetch(
            self: *StateMachine,
            callback: *const fn (*StateMachine) void,
            op: u64,
            snapshot: u64,
            operation: Operation,
            message_body_used: []align(constants.cache_line_size) const u8,
        ) void {
            assert(op > 0);
            assert(op <= snapshot);
            assert(self.prefetch_operation == null);
            assert(self.prefetch_input == null);
            assert(self.prefetch_callback == null);
            assert(message_body_used.len <= self.batch_size_limit);

            self.prefetch_operation = operation;
            self.prefetch_op = op;
            self.prefetch_input = message_body_used;
            self.prefetch_snapshot = snapshot;
            self.prefetch_callback = callback;

            switch (operation) {
                .lookup_rows => self.prefetch_rows(RowKey, message_body_used),
                .commit,
                .commit_wide,
                .declare_view,
                .declare_ledger,
                .get_ledger,
                => self.prefetch_ledgers(),
                .lookup_records => self.prefetch_records_lookup(message_body_used),
                .get_record_changes => self.prefetch_record_changes(message_body_used),
                .get_record_history => self.prefetch_record_history(message_body_used),
                .declare_index, .scan_index => self.prefetch_indexes(),
                .get_changes => self.prefetch_changes(message_body_used),
                .get_history => self.prefetch_history(message_body_used),
                .get_view, .pulse => self.prefetch_views(),
            }
        }

        /// Prefetches the row of every event across all batches. Events with an invalid table
        /// are skipped: they are rejected at commit without being looked up.
        fn prefetch_rows(
            self: *StateMachine,
            comptime Event: type,
            body: []align(constants.cache_line_size) const u8,
        ) void {
            const body_decoder = MultiBatchDecoder.init(body, .{
                .element_size = @sizeOf(Event),
            }) catch unreachable; // Already validated by `input_valid()`.
            const events = stdx.bytes_as_slice(.exact, Event, body_decoder.payload);

            const rows = &self.forest.grooves.rows;
            rows.prefetch_setup(self.prefetch_snapshot.?);
            for (events) |*event| {
                if (event.table == 0) continue;
                rows.prefetch_enqueue(.{ .key = nerva.row_key(event.table, event.id) });
            }
            rows.prefetch(prefetch_rows_callback, &self.rows_prefetch_context);
        }

        /// Prefetches the row of every entry across all transactions, and the key row of every
        /// `key` entry. Entries with an invalid table are skipped: they are rejected at commit
        /// without being looked up.
        fn prefetch_commit_rows(self: *StateMachine) void {
            const operation = self.prefetch_operation.?;
            var decoder = MultiBatchDecoder.init(self.prefetch_input.?, .{
                .element_size = operation.event_size(),
            }) catch unreachable; // Already validated by `input_valid()`.
            const rows = &self.forest.grooves.rows;
            rows.prefetch_setup(self.prefetch_snapshot.?);
            while (decoder.pop()) |batch| {
                for (self.batch_entries(operation, batch)) |*entry| {
                    if (entry.kind == .key) {
                        rows.prefetch_enqueue(.{ .key = commit_key_row(entry) });
                        continue;
                    }
                    if (entry.table == 0 or nerva.table_is_record(entry.table)) continue;
                    rows.prefetch_enqueue(.{ .key = entry_row_key(entry) });
                }
            }
            rows.prefetch(prefetch_rows_callback, &self.rows_prefetch_context);
        }

        /// Stage 2 of a commit (P123b): the record of every record entry.
        fn prefetch_commit_records(self: *StateMachine) void {
            const operation = self.prefetch_operation.?;
            const records = &self.forest.grooves.records;
            records.prefetch_setup(self.prefetch_snapshot.?);
            // `commit` writes rows only.
            if (operation == .commit_wide) {
                var decoder = MultiBatchDecoder.init(self.prefetch_input.?, .{
                    .element_size = operation.event_size(),
                }) catch unreachable; // Already validated by `input_valid()`.
                while (decoder.pop()) |batch| {
                    for (self.batch_entries(operation, batch)) |*entry| {
                        if (entry.kind == .key or !nerva.table_is_record(entry.table)) continue;
                        records.prefetch_enqueue(.{
                            .key = nerva.record_key(entry.table, entry.id),
                        });
                    }
                }
            }
            records.prefetch(prefetch_records_callback, &self.records_prefetch_context);
        }

        /// The record of every key of a `lookup_records` request (P123b). Keys outside the
        /// record tables, or with reserved bytes set, are answered absent without a lookup.
        fn prefetch_records_lookup(
            self: *StateMachine,
            body: []align(constants.cache_line_size) const u8,
        ) void {
            const body_decoder = MultiBatchDecoder.init(body, .{
                .element_size = @sizeOf(RecordKey),
            }) catch unreachable; // Already validated by `input_valid()`.
            const keys = stdx.bytes_as_slice(.exact, RecordKey, body_decoder.payload);
            const records = &self.forest.grooves.records;
            records.prefetch_setup(self.prefetch_snapshot.?);
            for (keys) |*key| {
                if (!record_key_valid(key)) continue;
                records.prefetch_enqueue(.{ .key = nerva.record_key(key.table, key.id) });
            }
            records.prefetch(prefetch_records_callback, &self.records_prefetch_context);
        }

        fn record_key_valid(key: *const RecordKey) bool {
            return nerva.table_is_record(key.table) and stdx.zeroed(&key.reserved);
        }

        fn prefetch_records_callback(context: *RecordsGroove.PrefetchContext) void {
            const self: *StateMachine = @alignCast(
                @fieldParentPtr("records_prefetch_context", context),
            );
            switch (self.prefetch_operation.?) {
                .commit, .commit_wide => self.prefetch_commit_index_entries(),
                .lookup_records, .scan_index => self.prefetch_finish(),
                else => unreachable,
            }
        }

        /// One batch of `commit` or `commit_wide` as wide entries: `commit_wide`'s as sent,
        /// `commit`'s widened into `wide_entries`, which holds one batch at a time.
        fn batch_entries(
            self: *StateMachine,
            operation: Operation,
            batch: []const u8,
        ) []const WideEntry {
            switch (operation) {
                .commit_wide => return stdx.bytes_as_slice(.exact, WideEntry, batch),
                .commit => {
                    const entries = stdx.bytes_as_slice(.exact, Entry, batch);
                    const wide = self.wide_entries[0..entries.len];
                    for (entries, wide) |*entry, *entry_wide| {
                        entry_wide.* = WideEntry.from_entry(entry);
                    }
                    return wide;
                },
                else => unreachable,
            }
        }

        /// The LSM key of a row entry's row, before the entry is validated: an id past 64 bits
        /// (`id_invalid`) is truncated, harmlessly, since nothing is written for it.
        fn entry_row_key(entry: *const WideEntry) u128 {
            assert(!nerva.table_is_record(entry.table));
            return nerva.row_key(entry.table, @truncate(entry.id));
        }

        fn prefetch_rows_callback(context: *RowsGroove.PrefetchContext) void {
            const self: *StateMachine = @alignCast(
                @fieldParentPtr("rows_prefetch_context", context),
            );
            switch (self.prefetch_operation.?) {
                .commit, .commit_wide => self.prefetch_commit_records(),
                .lookup_rows => self.prefetch_finish(),
                else => unreachable,
            }
        }

        fn prefetch_changes(
            self: *StateMachine,
            body: []align(constants.cache_line_size) const u8,
        ) void {
            assert(self.changes_scan_count == null);
            const filter = changes_filter(body);

            const limit = changes_limit(filter) orelse {
                log.debug("get_changes: invalid filter {}", .{filter});
                return self.prefetch_finish();
            };
            assert(limit > 0);
            assert(limit <= changes_limit_max);

            const timestamp_min = if (filter.timestamp_min == 0)
                TimestampRange.timestamp_min
            else
                filter.timestamp_min;

            self.changes_scan_count = 0;
            self.changes_scan_tree.init(
                &self.forest.grooves.changes.objects,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                timestamp_min,
                TimestampRange.timestamp_max,
                .ascending,
            );
            self.changes_scan_read();
        }

        fn changes_filter(body: []align(constants.cache_line_size) const u8) *const ChangesFilter {
            assert(body.len == @sizeOf(ChangesFilter));
            return @alignCast(std.mem.bytesAsValue(ChangesFilter, body[0..@sizeOf(ChangesFilter)]));
        }

        /// The effective limit of a valid filter, or null if the filter is invalid.
        fn changes_limit(filter: *const ChangesFilter) ?u32 {
            if (filter.limit == 0) return null;
            if (!stdx.zeroed(&filter.reserved)) return null;
            if (filter.timestamp_min != 0 and !TimestampRange.valid(filter.timestamp_min)) {
                return null;
            }
            return @min(filter.limit, changes_limit_max);
        }

        fn changes_scan_read(self: *StateMachine) void {
            self.changes_scan_tree.read({}, changes_scan_read_callback);
        }

        fn changes_scan_read_callback(_: void, scan_tree: *ChangesScanTree) void {
            const self: *StateMachine = @fieldParentPtr("changes_scan_tree", scan_tree);
            const filter = changes_filter(self.prefetch_input.?);
            const limit = changes_limit(filter).?;

            while (self.changes_scan_count.? < limit) {
                const change = scan_tree.next() catch |err| switch (err) {
                    error.Pending => return self.changes_scan_read(),
                } orelse break;
                assert(change.kind == .put or change.kind == .delete);
                assert(change.timestamp >= filter.timestamp_min);
                self.changes_scan_buffer[self.changes_scan_count.?] = change;
                self.changes_scan_count.? += 1;
            }

            self.forest.scan_buffer_pool.reset();
            self.prefetch_finish();
        }

        fn prefetch_history(
            self: *StateMachine,
            body: []align(constants.cache_line_size) const u8,
        ) void {
            assert(self.changes_scan_count == null);
            const filter = history_filter(body);

            const limit = history_limit(filter) orelse {
                log.debug("get_history: invalid filter {}", .{filter});
                return self.prefetch_finish();
            };
            assert(limit > 0);
            assert(limit <= changes_limit_max);

            const changes = &self.forest.grooves.changes;
            const scan = changes.scan_builder.scan_prefix(
                .row_key,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                nerva.row_key(filter.table, filter.id),
                .{
                    .min = TimestampRange.timestamp_min,
                    .max = if (filter.timestamp_max == 0)
                        TimestampRange.timestamp_max
                    else
                        filter.timestamp_max,
                },
                .descending,
            );
            self.changes_scan_count = 0;
            self.history_scan_lookup = HistoryScanLookup.init(changes, scan);
            self.history_scan_lookup.read(
                self.changes_scan_buffer[0..limit],
                prefetch_history_callback,
            );
        }

        fn prefetch_history_callback(
            scan_lookup: *HistoryScanLookup,
            results: []const Change,
        ) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("history_scan_lookup", scan_lookup));
            assert(self.changes_scan_count.? == 0);
            assert(results.len <= history_limit(history_filter(self.prefetch_input.?)).?);
            assert(results.len == 0 or results.ptr == self.changes_scan_buffer.ptr);

            self.changes_scan_count = @intCast(results.len);
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.changes.scan_builder.reset();
            self.prefetch_finish();
        }

        fn history_filter(body: []align(constants.cache_line_size) const u8) *const HistoryFilter {
            assert(body.len == @sizeOf(HistoryFilter));
            return @alignCast(
                std.mem.bytesAsValue(HistoryFilter, body[0..@sizeOf(HistoryFilter)]),
            );
        }

        /// The effective limit of a valid filter, or null if the filter is invalid.
        fn history_limit(filter: *const HistoryFilter) ?u32 {
            if (filter.table == 0) return null;
            if (filter.limit == 0) return null;
            if (filter.op_max == 0) return null;
            if (!stdx.zeroed(&filter.reserved)) return null;
            if (filter.timestamp_max != 0 and !TimestampRange.valid(filter.timestamp_max)) {
                return null;
            }
            return @min(filter.limit, changes_limit_max);
        }

        // ---- Declared indexes (P123c) ----

        /// Prefetches every declared index, then loads them.
        fn prefetch_indexes(self: *StateMachine) void {
            const groove = &self.forest.grooves.indexes;
            groove.prefetch_setup(self.prefetch_snapshot.?);
            const count = self.index_count orelse nerva.indexes_max;
            for (1..count + 1) |id| groove.prefetch_enqueue(.{ .id = id });
            groove.prefetch(prefetch_indexes_callback, &self.indexes_prefetch_context);
        }

        fn prefetch_indexes_callback(context: *IndexesGroove.PrefetchContext) void {
            const self: *StateMachine = @alignCast(
                @fieldParentPtr("indexes_prefetch_context", context),
            );
            self.indexes_load();
            switch (self.prefetch_operation.?) {
                .commit, .commit_wide => self.prefetch_commit_rows(),
                .pulse => self.prefetch_backfill_rows(),
                .declare_index => self.prefetch_finish(),
                .scan_index => self.prefetch_index_scan(),
                else => unreachable,
            }
        }

        /// Loads the indexes prefetched for this op into `indexes_op` and `indexes_stored`.
        fn indexes_load(self: *StateMachine) void {
            const groove = &self.forest.grooves.indexes;
            const count = self.index_count orelse nerva.indexes_max;
            var loaded: u32 = 0;
            var building = false;
            for (1..count + 1) |id| {
                switch (groove.get(id)) {
                    .found_object => |index| {
                        // Ids are dense: 1, 2, … in declaration order.
                        assert(index.id == loaded + 1);
                        self.indexes_op[loaded] = index;
                        self.indexes_stored[loaded] = index;
                        loaded += 1;
                        building = building or index.state == .building;
                    },
                    .not_found => break,
                }
            }
            if (self.index_count) |known| assert(known == loaded);
            self.index_count = loaded;
            self.index_building = building;
            self.indexes_op_count = loaded;
            assert(self.index_entries_touched.items.len == 0);
            assert(self.index_entries_scratch.count() == 0);
        }

        /// Stage 3 of a commit: the entry of every record write in every index of its table.
        fn prefetch_commit_index_entries(self: *StateMachine) void {
            const operation = self.prefetch_operation.?;
            const entries = &self.forest.grooves.index_entries;
            entries.prefetch_setup(self.prefetch_snapshot.?);
            if (operation == .commit_wide and self.indexes_op_count > 0) {
                var decoder = MultiBatchDecoder.init(self.prefetch_input.?, .{
                    .element_size = operation.event_size(),
                }) catch unreachable; // Already validated by `input_valid()`.
                while (decoder.pop()) |batch| {
                    for (self.batch_entries(operation, batch)) |*entry| {
                        if (entry.kind != .put and entry.kind != .delete) continue;
                        if (!nerva.table_is_record(entry.table)) continue;
                        const key = nerva.record_key(entry.table, entry.id);
                        for (self.indexes_op[0..self.indexes_op_count]) |*index| {
                            if (index.definition.table != entry.table) continue;
                            entries.prefetch_enqueue(.{
                                .key = nerva.index_entry_key(index.id, key),
                            });
                        }
                    }
                }
            }
            entries.prefetch(prefetch_index_entries_callback, &self.index_entries_prefetch_context);
        }

        fn prefetch_index_entries_callback(context: *IndexEntriesGroove.PrefetchContext) void {
            const self: *StateMachine = @alignCast(
                @fieldParentPtr("index_entries_prefetch_context", context),
            );
            switch (self.prefetch_operation.?) {
                .commit, .commit_wide => self.prefetch_commit_groups(),
                .pulse => self.prefetch_finish(),
                else => unreachable,
            }
        }

        /// Keeps every index over `table` exact after one record changed from `old` to `new`
        /// (null: absent or deleted) at `op`. `timestamp` is the entry's (`entry_timestamps`):
        /// an entry it creates in the table's `n`th index takes
        /// `timestamp + 1 + views_per_table_max + n`, the timestamps a row's `min` and `max`
        /// members take, which records never have.
        fn indexes_record_changed(
            self: *StateMachine,
            table: u32,
            id: u128,
            old: ?*const Record,
            new: ?*const [nerva.record_value_size]u8,
            op: u64,
            timestamp: u64,
        ) void {
            const key = nerva.record_key(table, id);
            var slot: u64 = 0;
            for (self.indexes_op[0..self.indexes_op_count]) |*index| {
                if (index.definition.table != table) continue;
                defer slot += 1;
                assert(slot < nerva.indexes_per_table_max);
                // A building index adds records from its cursor on when the pulse reaches them.
                if (index.state == .building and
                    key & std.math.maxInt(u96) >= index.backfill_cursor) continue;
                const value_old: ?*const [nerva.record_value_size]u8 = if (old) |record|
                    if (record.flags.deleted) null else &record.value
                else
                    null;
                self.index_record_changed(
                    index,
                    key,
                    id,
                    if (value_old) |value| indexes.place(&index.definition, value, old.?.op) else null,
                    if (new) |value| indexes.place(&index.definition, value, op) else null,
                    timestamp + 1 + nerva.views_per_table_max + slot,
                );
            }
        }

        /// One index's part of `indexes_record_changed`, and a pulse's (with `old` null).
        fn index_record_changed(
            self: *StateMachine,
            index: *Index,
            key: u128,
            id: u128,
            old: ?indexes.Place,
            new: ?indexes.Place,
            timestamp: u64,
        ) void {
            if (old == null and new == null) return;
            const scratch = self.index_entry_scratch(index.id, key, id);
            const entry = &scratch.entry;
            // An entry is present exactly while its record passes the index's `where`.
            assert(entry.flags.present == (old != null));
            assert(entry.id == id);
            if (new) |place| {
                if (entry.timestamp == 0) {
                    assert(TimestampRange.valid(timestamp));
                    entry.timestamp = timestamp;
                }
                if (old == null) index.entry_count += 1;
                entry.flags.present = true;
                entry.eq_key = place.eq_key;
                entry.position = nerva.index_position(
                    indexes.position_prefix(index.id, &place.eq_key),
                    place.order,
                );
            } else {
                assert(index.entry_count > 0);
                index.entry_count -= 1;
                entry.flags.present = false;
                entry.eq_key = @splat(0);
                entry.position = 0;
            }
        }

        /// The entry's state in this op, from the groove the first time.
        fn index_entry_scratch(
            self: *StateMachine,
            index_id: u64,
            key: u128,
            id: u128,
        ) *IndexEntryScratch {
            const entry_key = nerva.index_entry_key(index_id, key);
            const slot = self.index_entries_scratch.getOrPutAssumeCapacity(entry_key);
            if (!slot.found_existing) {
                const stored: ?IndexEntry =
                    switch (self.forest.grooves.index_entries.get(entry_key)) {
                        .found_object => |entry| entry,
                        .not_found => null,
                    };
                slot.value_ptr.* = .{
                    .entry = stored orelse .{
                        .key = entry_key,
                        .position = 0,
                        .id = id,
                        .timestamp = 0, // Assigned when the record first enters the index.
                        .index_id = @intCast(index_id),
                        .flags = .{},
                        .eq_key = @splat(0),
                    },
                    .stored = stored,
                };
                self.index_entries_touched.appendAssumeCapacity(entry_key);
            }
            return slot.value_ptr;
        }

        /// Ends an op that may have changed indexes (commit, pulse): writes back each entry it
        /// touched, once, in the order first touched, then the indexes it changed.
        fn indexes_finish(self: *StateMachine) void {
            const entries = &self.forest.grooves.index_entries;
            assert(self.index_entries_touched.items.len <= self.index_entry_writes_limit);
            for (self.index_entries_touched.items) |key| {
                const scratch = self.index_entries_scratch.getPtr(key).?;
                if (scratch.stored) |*stored| {
                    if (!stdx.equal_bytes(IndexEntry, stored, &scratch.entry)) {
                        entries.update(.{ .old = stored, .new = &scratch.entry });
                    }
                } else if (scratch.entry.timestamp != 0) {
                    entries.insert(&scratch.entry);
                }
            }
            self.index_entries_touched.clearRetainingCapacity();
            self.index_entries_scratch.clearRetainingCapacity();
            self.indexes_store();
        }

        fn indexes_store(self: *StateMachine) void {
            const groove = &self.forest.grooves.indexes;
            var building = false;
            for (
                self.indexes_op[0..self.indexes_op_count],
                self.indexes_stored[0..self.indexes_op_count],
            ) |*index, *stored| {
                building = building or index.state == .building;
                if (stdx.equal_bytes(Index, index, stored)) continue;
                groove.update(.{ .old = stored, .new = index });
                stored.* = index.*;
            }
            self.index_building = building;
        }

        fn execute_declare_index(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            assert(message_body_used.len == @sizeOf(IndexDefinition));
            const definition: *const IndexDefinition = @alignCast(std.mem.bytesAsValue(
                IndexDefinition,
                message_body_used[0..@sizeOf(IndexDefinition)],
            ));
            const result: *DeclareIndexResult = @alignCast(std.mem.bytesAsValue(
                DeclareIndexResult,
                output_buffer[0..@sizeOf(DeclareIndexResult)],
            ));
            result.* = self.index_declare(op, timestamp, definition);
            self.indexes_store();
            return @sizeOf(DeclareIndexResult);
        }

        /// Declares an index, building: pulses add the records already written, none possibly.
        fn index_declare(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            definition: *const IndexDefinition,
        ) DeclareIndexResult {
            if (indexes.definition_validate(definition)) |status| {
                return .{ .status = status, .index_id = 0, .op = 0 };
            }
            const name = indexes.definition_name(definition);
            var table_indexes: u32 = 0;
            for (self.indexes_op[0..self.indexes_op_count]) |*index| {
                if (std.mem.eql(u8, indexes.definition_name(&index.definition), name)) {
                    if (stdx.equal_bytes(IndexDefinition, &index.definition, definition)) {
                        return .{
                            .status = .exists,
                            .index_id = index.id,
                            .op = index.declared_op,
                        };
                    }
                    return .{ .status = .different, .index_id = 0, .op = 0 };
                }
                if (index.definition.table == definition.table) table_indexes += 1;
            }
            if (self.indexes_op_count == nerva.indexes_max) {
                return .{ .status = .indexes_full, .index_id = 0, .op = 0 };
            }
            if (table_indexes == nerva.indexes_per_table_max) {
                return .{ .status = .table_indexes_full, .index_id = 0, .op = 0 };
            }
            const slot = self.indexes_op_count;
            const index: Index = .{
                .id = slot + 1,
                .timestamp = timestamp,
                .backfill_cursor = 0,
                .declared_op = op,
                .entry_count = 0,
                .state = .building,
                .definition = definition.*,
            };
            self.forest.grooves.indexes.insert(&index);
            self.indexes_op[slot] = index;
            self.indexes_stored[slot] = index;
            self.indexes_op_count += 1;
            self.index_count = self.indexes_op_count;
            return .{ .status = .created, .index_id = index.id, .op = op };
        }

        fn index_query(body: []align(constants.cache_line_size) const u8) *const IndexQuery {
            assert(body.len == @sizeOf(IndexQuery));
            return @alignCast(std.mem.bytesAsValue(IndexQuery, body[0..@sizeOf(IndexQuery)]));
        }

        /// The query's page size, or null if it is malformed.
        fn index_query_limit(query: *const IndexQuery) ?u32 {
            if (query.limit == 0) return null;
            if (query.flags.padding != 0) return null;
            if (!stdx.zeroed(&query.reserved_a) or !stdx.zeroed(&query.reserved_b)) return null;
            if (query.order_min > query.order_max) return null;
            if (query.index_id == 0 and query.name[0] == 0) return null;
            if (query.index_id != 0 and !stdx.zeroed(&query.name)) return null;
            return @min(query.limit, index_hits_max);
        }

        /// The index the query names (an index into `indexes_op`), if declared.
        fn index_query_slot(self: *const StateMachine, query: *const IndexQuery) ?u32 {
            if (query.index_id != 0) {
                if (query.index_id > self.indexes_op_count) return null;
                return @intCast(query.index_id - 1);
            }
            const name = std.mem.sliceTo(&query.name, 0);
            for (self.indexes_op[0..self.indexes_op_count], 0..) |*index, slot| {
                if (std.mem.eql(u8, indexes.definition_name(&index.definition), name)) {
                    return @intCast(slot);
                }
            }
            return null;
        }

        /// Stage 1 of `scan_index`: the entries after the cursor at the cursor's own order (an
        /// exact position, later timestamps), then stage 2.
        fn prefetch_index_scan(self: *StateMachine) void {
            assert(self.index_scan == null);
            assert(self.index_scan_count == 0);
            const query = index_query(self.prefetch_input.?);
            const limit = index_query_limit(query) orelse return self.prefetch_finish();
            const slot = self.index_query_slot(query) orelse return self.prefetch_finish();
            const index = &self.indexes_op[slot];
            if (index.state != .ready) return self.prefetch_finish();
            if (!indexes.eq_key_valid(&index.definition, &query.eq_key)) {
                return self.prefetch_finish();
            }
            self.index_scan = slot;

            const cursor = query.cursor_timestamp != 0 and
                query.cursor_order >= query.order_min and query.cursor_order <= query.order_max;
            if (!cursor) return self.prefetch_index_scan_range();
            const entries = &self.forest.grooves.index_entries;
            const prefix = indexes.position_prefix(index.id, &query.eq_key);
            const scan = entries.scan_builder.scan_prefix(
                .order,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                nerva.index_position(prefix, query.cursor_order),
                if (query.flags.descending) .{
                    .min = TimestampRange.timestamp_min,
                    .max = @max(TimestampRange.timestamp_min, query.cursor_timestamp - 1),
                } else .{
                    .min = @min(query.cursor_timestamp + 1, TimestampRange.timestamp_max),
                    .max = TimestampRange.timestamp_max,
                },
                if (query.flags.descending) .descending else .ascending,
            );
            self.index_entries_scan_lookup = IndexEntriesScanLookup.init(entries, scan);
            self.index_entries_scan_lookup.read(
                self.index_scan_entries[0 .. limit + 1],
                prefetch_index_scan_exact_callback,
            );
        }

        fn prefetch_index_scan_exact_callback(
            scan_lookup: *IndexEntriesScanLookup,
            results: []const IndexEntry,
        ) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("index_entries_scan_lookup", scan_lookup));
            const query = index_query(self.prefetch_input.?);
            assert(results.len == 0 or results.ptr == self.index_scan_entries.ptr);
            // A timestamp bound at the cursor's own excludes the cursor's entry.
            var count: u32 = 0;
            for (results) |*entry| {
                if (entry.timestamp == query.cursor_timestamp) continue;
                self.index_scan_entries[count] = entry.*;
                count += 1;
            }
            self.index_scan_count = count;
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.index_entries.scan_builder.reset();
            self.prefetch_index_scan_range();
        }

        /// Stage 2: the positions strictly past the cursor's order (or the whole range), until
        /// the page and one more are found.
        fn prefetch_index_scan_range(self: *StateMachine) void {
            const query = index_query(self.prefetch_input.?);
            const limit = index_query_limit(query).?;
            const index = &self.indexes_op[self.index_scan.?];
            const wanted = limit + 1 - self.index_scan_count;
            const cursor = query.cursor_timestamp != 0 and
                query.cursor_order >= query.order_min and query.cursor_order <= query.order_max;
            var order_min = query.order_min;
            var order_max = query.order_max;
            if (cursor) {
                if (query.flags.descending) {
                    if (query.cursor_order == order_min) return self.prefetch_index_records();
                    order_max = query.cursor_order - 1;
                } else {
                    if (query.cursor_order == order_max) return self.prefetch_index_records();
                    order_min = query.cursor_order + 1;
                }
            }
            if (wanted == 0) return self.prefetch_index_records();
            const entries = &self.forest.grooves.index_entries;
            const prefix = indexes.position_prefix(index.id, &query.eq_key);
            const scan = entries.scan_builder.scan_prefix_range(
                .order,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                nerva.index_position(prefix, order_min),
                nerva.index_position(prefix, order_max),
                if (query.flags.descending) .descending else .ascending,
            );
            self.index_entries_scan_lookup = IndexEntriesScanLookup.init(entries, scan);
            self.index_entries_scan_lookup.read(
                self.index_scan_entries[self.index_scan_count..][0..wanted],
                prefetch_index_scan_range_callback,
            );
        }

        fn prefetch_index_scan_range_callback(
            scan_lookup: *IndexEntriesScanLookup,
            results: []const IndexEntry,
        ) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("index_entries_scan_lookup", scan_lookup));
            assert(results.len == 0 or
                results.ptr == self.index_scan_entries[self.index_scan_count..].ptr);
            self.index_scan_count += @intCast(results.len);
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.index_entries.scan_builder.reset();
            self.prefetch_index_records();
        }

        /// Stage 3: the records the page lists.
        fn prefetch_index_records(self: *StateMachine) void {
            const index = &self.indexes_op[self.index_scan.?];
            const records = &self.forest.grooves.records;
            records.prefetch_setup(self.prefetch_snapshot.?);
            for (self.index_scan_entries[0..self.index_scan_count]) |*entry| {
                records.prefetch_enqueue(.{ .key = index_record_key(index, entry) });
            }
            records.prefetch(prefetch_records_callback, &self.records_prefetch_context);
        }

        /// The key of the record an entry of `index` names.
        fn index_record_key(index: *const Index, entry: *const IndexEntry) u128 {
            assert(entry.index_id == index.id);
            return @as(u128, index.definition.table) << 96 | (entry.key & std.math.maxInt(u96));
        }

        fn execute_scan_index(
            self: *StateMachine,
            op: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            defer {
                self.index_scan = null;
                self.index_scan_count = 0;
            }
            const query = index_query(message_body_used);
            const limit = index_query_limit(query) orelse {
                assert(self.index_scan == null);
                return 0;
            };
            const results = stdx.bytes_as_slice(.inexact, IndexRecord, output_buffer);
            const header = &results[0];
            header.* = std.mem.zeroes(IndexRecord);
            header.kind = .header;
            header.op = op;
            header.state = .missing;
            const slot = self.index_query_slot(query) orelse {
                assert(self.index_scan == null);
                return @sizeOf(IndexRecord);
            };
            const index = &self.indexes_op[slot];
            header.index_id = index.id;
            header.table = index.definition.table;
            header.state = index.state;
            if (self.index_scan == null) return @sizeOf(IndexRecord); // Building, or a bad key.

            const scanned = self.index_scan_entries[0..self.index_scan_count];
            assert(scanned.len <= limit + 1);
            const listed = @min(scanned.len, limit);
            var count: u32 = 0;
            for (scanned[0..listed], 0..) |*entry, position| {
                assert(entry.flags.present);
                if (position > 0) {
                    const previous = &scanned[position - 1];
                    if (query.flags.descending) {
                        assert(previous.position >= entry.position);
                    } else {
                        assert(previous.position <= entry.position);
                    }
                }
                // Another `eq` key whose prefix is the same: skipped.
                if (!stdx.equal_bytes([nerva.group_key_size_max]u8, &entry.eq_key, &query.eq_key)) {
                    continue;
                }
                const record = switch (self.forest.grooves.records.get(index_record_key(index, entry))) {
                    .found_object => |record| record,
                    .not_found => unreachable, // An entry is present only for a record.
                };
                assert(record.id == entry.id);
                assert(!record.flags.deleted);
                const place = indexes.place(&index.definition, &record.value, record.op).?;
                assert(stdx.equal_bytes([nerva.group_key_size_max]u8, &place.eq_key, &entry.eq_key));
                assert(place.order == @as(u64, @truncate(entry.position)));
                results[1 + count] = .{
                    .id = record.id,
                    .table = record.table,
                    .kind = .record,
                    .flags = .{},
                    .state = .missing,
                    .op = record.op,
                    .order = place.order,
                    .timestamp = entry.timestamp,
                    .index_id = index.id,
                    .value = record.value,
                };
                count += 1;
            }
            if (scanned.len > listed) {
                assert(listed > 0);
                header.flags.more = true;
                header.order = @truncate(scanned[listed - 1].position);
                header.timestamp = scanned[listed - 1].timestamp;
            }
            return (1 + count) * @sizeOf(IndexRecord);
        }

        /// A pulse with no view building: the next records of the first building index (P123c),
        /// then their entries (none exist yet; prefetched so that the commit can tell).
        fn prefetch_backfill_records(self: *StateMachine) void {
            assert(self.backfill_index == null);
            assert(self.backfill_records_count == null);
            const slot = for (self.indexes_op[0..self.indexes_op_count], 0..) |*index, slot| {
                if (index.state == .building) break slot;
            } else return self.prefetch_finish();
            self.backfill_index = @intCast(slot);
            const index = &self.indexes_op[slot];
            const table: u128 = index.definition.table;

            const records = &self.forest.grooves.records;
            const scan = records.scan_builder.scan_unique_key_range(
                .key,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                table << 96 | index.backfill_cursor,
                table << 96 | std.math.maxInt(u96),
                .ascending,
            );
            self.records_scan_lookup = RecordsScanLookup.init(records, scan);
            self.records_scan_lookup.read(
                self.backfill_records[0 .. self.group_writes_limit + 1],
                prefetch_backfill_records_callback,
            );
        }

        fn prefetch_backfill_records_callback(
            scan_lookup: *RecordsScanLookup,
            results: []const Record,
        ) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("records_scan_lookup", scan_lookup));
            assert(results.len == 0 or results.ptr == self.backfill_records.ptr);
            self.backfill_records_count = @intCast(results.len);
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.records.scan_builder.reset();

            const index = &self.indexes_op[self.backfill_index.?];
            const entries = &self.forest.grooves.index_entries;
            entries.prefetch_setup(self.prefetch_snapshot.?);
            const count = @min(results.len, self.group_writes_limit);
            for (results[0..count]) |*record| {
                entries.prefetch_enqueue(.{ .key = nerva.index_entry_key(index.id, record.key) });
            }
            entries.prefetch(prefetch_index_entries_callback, &self.index_entries_prefetch_context);
        }

        /// Adds the records the pulse scanned to the building index. Replies nothing.
        fn execute_pulse_index(self: *StateMachine, timestamp: u64) usize {
            defer {
                self.backfill_index = null;
                self.backfill_records_count = null;
            }
            const slot = self.backfill_index orelse {
                assert(self.index_building == false);
                return 0;
            };
            const index = &self.indexes_op[slot];
            assert(index.state == .building);
            const scanned = self.backfill_records[0..self.backfill_records_count.?];
            const count = @min(scanned.len, self.group_writes_limit);
            // Each record takes an entry's block of timestamps, as a commit's entry does; its
            // index's slot among its table's indexes picks the block's timestamp.
            const timestamp_base = timestamp - self.prepare_delta(.pulse, &.{});
            var table_slot: u64 = 0;
            for (self.indexes_op[0..slot]) |*other| {
                if (other.definition.table == index.definition.table) table_slot += 1;
            }
            for (scanned[0..count], 0..) |*record, k| {
                assert(record.table == index.definition.table);
                assert(record.key & std.math.maxInt(u96) >= index.backfill_cursor);
                if (record.flags.deleted) continue;
                const block = timestamp_base + k * entry_timestamps;
                self.index_record_changed(
                    index,
                    record.key,
                    record.id,
                    null,
                    indexes.place(&index.definition, &record.value, record.op),
                    block + 1 + nerva.views_per_table_max + table_slot,
                );
            }
            if (scanned.len > count) {
                index.backfill_cursor = scanned[count].key & std.math.maxInt(u96);
            } else {
                index.state = .ready;
            }
            self.indexes_finish();
            return 0;
        }

        // ---- Records' changes and history (P123b): as `get_changes` and `get_history` ----

        fn prefetch_record_changes(
            self: *StateMachine,
            body: []align(constants.cache_line_size) const u8,
        ) void {
            assert(self.record_changes_scan_count == null);
            const filter = changes_filter(body);
            const limit = record_changes_limit(filter) orelse {
                log.debug("get_record_changes: invalid filter {}", .{filter});
                return self.prefetch_finish();
            };
            assert(limit > 0);

            self.record_changes_scan_count = 0;
            self.record_changes_scan_tree.init(
                &self.forest.grooves.record_changes.objects,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                if (filter.timestamp_min == 0)
                    TimestampRange.timestamp_min
                else
                    filter.timestamp_min,
                TimestampRange.timestamp_max,
                .ascending,
            );
            self.record_changes_scan_read();
        }

        fn record_changes_scan_read(self: *StateMachine) void {
            self.record_changes_scan_tree.read({}, record_changes_scan_read_callback);
        }

        fn record_changes_scan_read_callback(_: void, scan_tree: *RecordChangesScanTree) void {
            const self: *StateMachine = @fieldParentPtr("record_changes_scan_tree", scan_tree);
            const filter = changes_filter(self.prefetch_input.?);
            const limit = record_changes_limit(filter).?;

            while (self.record_changes_scan_count.? < limit) {
                const change = scan_tree.next() catch |err| switch (err) {
                    error.Pending => return self.record_changes_scan_read(),
                } orelse break;
                assert(change.kind == .put or change.kind == .delete);
                assert(change.timestamp >= filter.timestamp_min);
                self.record_changes_scan_buffer[self.record_changes_scan_count.?] = change;
                self.record_changes_scan_count.? += 1;
            }

            self.forest.scan_buffer_pool.reset();
            self.prefetch_finish();
        }

        fn record_changes_limit(filter: *const nerva.ChangesFilter) ?u32 {
            const limit = changes_limit(filter) orelse return null;
            return @min(limit, record_changes_limit_max);
        }

        fn prefetch_record_history(
            self: *StateMachine,
            body: []align(constants.cache_line_size) const u8,
        ) void {
            assert(self.record_changes_scan_count == null);
            const filter = record_history_filter(body);
            const limit = record_history_limit(filter) orelse {
                log.debug("get_record_history: invalid filter {}", .{filter});
                return self.prefetch_finish();
            };
            assert(limit > 0);

            const changes = &self.forest.grooves.record_changes;
            const scan = changes.scan_builder.scan_prefix(
                .record_key,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                nerva.record_key(filter.table, filter.id),
                .{
                    .min = TimestampRange.timestamp_min,
                    .max = if (filter.timestamp_max == 0)
                        TimestampRange.timestamp_max
                    else
                        filter.timestamp_max,
                },
                .descending,
            );
            self.record_changes_scan_count = 0;
            self.record_history_scan_lookup = RecordHistoryScanLookup.init(changes, scan);
            self.record_history_scan_lookup.read(
                self.record_changes_scan_buffer[0..limit],
                prefetch_record_history_callback,
            );
        }

        fn prefetch_record_history_callback(
            scan_lookup: *RecordHistoryScanLookup,
            results: []const RecordChange,
        ) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("record_history_scan_lookup", scan_lookup));
            assert(self.record_changes_scan_count.? == 0);
            assert(results.len <=
                record_history_limit(record_history_filter(self.prefetch_input.?)).?);
            assert(results.len == 0 or results.ptr == self.record_changes_scan_buffer.ptr);

            self.record_changes_scan_count = @intCast(results.len);
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.record_changes.scan_builder.reset();
            self.prefetch_finish();
        }

        fn record_history_filter(
            body: []align(constants.cache_line_size) const u8,
        ) *const RecordHistoryFilter {
            assert(body.len == @sizeOf(RecordHistoryFilter));
            return @alignCast(std.mem.bytesAsValue(
                RecordHistoryFilter,
                body[0..@sizeOf(RecordHistoryFilter)],
            ));
        }

        /// The effective limit of a valid filter, or null if the filter is invalid.
        fn record_history_limit(filter: *const RecordHistoryFilter) ?u32 {
            if (!nerva.table_is_record(filter.table)) return null;
            if (filter.limit == 0) return null;
            if (filter.op_max == 0) return null;
            if (!stdx.zeroed(&filter.reserved)) return null;
            if (filter.timestamp_max != 0 and !TimestampRange.valid(filter.timestamp_max)) {
                return null;
            }
            return @min(filter.limit, record_changes_limit_max);
        }

        fn prefetch_finish(self: *StateMachine) void {
            assert(self.prefetch_operation != null);
            assert(self.prefetch_input != null);
            const callback = self.prefetch_callback.?;
            self.prefetch_operation = null;
            self.prefetch_input = null;
            self.prefetch_snapshot = null;
            self.prefetch_callback = null;
            callback(self);
        }

        pub fn commit(
            self: *StateMachine,
            client: u128,
            op: u64,
            timestamp: u64,
            operation: Operation,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            _ = client;
            assert(op != 0);
            assert(timestamp > self.commit_timestamp);
            assert(message_body_used.len <= self.batch_size_limit);

            return switch (operation) {
                inline .lookup_rows,
                .commit,
                .commit_wide,
                .lookup_records,
                => |operation_comptime| self.execute_multi_batch(
                    operation_comptime,
                    op,
                    timestamp,
                    message_body_used,
                    output_buffer,
                ),
                .get_changes => self.execute_get_changes(op, message_body_used, output_buffer),
                .get_history => self.execute_get_history(op, message_body_used, output_buffer),
                .get_view => self.execute_get_view(op, message_body_used, output_buffer),
                .declare_view => self.execute_declare_view(
                    op,
                    timestamp,
                    message_body_used,
                    output_buffer,
                ),
                .pulse => self.execute_pulse(op, timestamp),
                .declare_ledger => self.execute_declare_ledger(
                    op,
                    timestamp,
                    message_body_used,
                    output_buffer,
                ),
                .get_ledger => self.execute_get_ledger(message_body_used, output_buffer),
                .get_record_changes => self.execute_get_record_changes(
                    op,
                    message_body_used,
                    output_buffer,
                ),
                .get_record_history => self.execute_get_record_history(
                    op,
                    message_body_used,
                    output_buffer,
                ),
                .declare_index => self.execute_declare_index(
                    op,
                    timestamp,
                    message_body_used,
                    output_buffer,
                ),
                .scan_index => self.execute_scan_index(op, message_body_used, output_buffer),
            };
        }

        fn execute_multi_batch(
            self: *StateMachine,
            comptime operation: Operation,
            op: u64,
            timestamp: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            comptime assert(operation.is_multi_batch());

            var body_decoder = MultiBatchDecoder.init(message_body_used, .{
                .element_size = operation.event_size(),
            }) catch unreachable; // Already validated by `input_valid()`.
            var reply_encoder = MultiBatchEncoder.init(output_buffer, .{
                .element_size = operation.result_size(),
            });

            // Each batch's writes take the timestamps just below its share of the prepare's.
            var batch_timestamp = timestamp - self.prepare_delta(operation, body_decoder.payload);
            const committing = operation == .commit or operation == .commit_wide;
            if (committing) self.versions_begin(operation, batch_timestamp);
            var batch_index: u32 = 0;
            while (body_decoder.pop()) |batch| : (batch_index += 1) {
                batch_timestamp += self.prepare_delta(operation, batch);
                const bytes_written: usize = switch (operation) {
                    .lookup_rows => self.execute_lookup_rows(
                        op,
                        batch,
                        reply_encoder.writable().?,
                    ),
                    .lookup_records => self.execute_lookup_records(
                        op,
                        batch,
                        reply_encoder.writable().?,
                    ),
                    .commit, .commit_wide => self.execute_commit(
                        op,
                        batch_timestamp,
                        self.batch_entries(operation, batch),
                        operation == .commit,
                        if (self.view_txn_too_large.isSet(batch_index))
                            .too_large
                        else if (self.view_txn_busy.isSet(batch_index))
                            .busy
                        else
                            .fits,
                        reply_encoder.writable().?,
                    ),
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
                    => comptime unreachable,
                };
                reply_encoder.add(@intCast(bytes_written));
            }
            assert(batch_timestamp == timestamp);
            assert(body_decoder.batch_count() == reply_encoder.batch_count);
            if (committing) {
                self.views_finish(op);
                self.indexes_finish();
            }
            return reply_encoder.finish();
        }

        fn execute_lookup_rows(
            self: *StateMachine,
            op: u64,
            batch: []const u8,
            output: []u8,
        ) usize {
            const keys = stdx.bytes_as_slice(.exact, RowKey, batch);
            const results = stdx.bytes_as_slice(.inexact, RowValue, output)[0..keys.len];

            for (keys, results) |*key, *result| {
                result.* = .{
                    .id = key.id,
                    .table = key.table,
                    .flags = .{},
                    .op = 0,
                    .op_read = op,
                    .value = @splat(0),
                };
                if (key.table == 0 or key.reserved != 0) continue;

                switch (self.forest.grooves.rows.get(nerva.row_key(key.table, key.id))) {
                    .found_object => |row| {
                        result.op = row.op;
                        if (!row.flags.deleted) {
                            result.flags.exists = true;
                            result.value = row.value;
                        }
                    },
                    .not_found => {},
                }
            }
            return keys.len * @sizeOf(RowValue);
        }

        fn execute_lookup_records(
            self: *StateMachine,
            op: u64,
            batch: []const u8,
            output: []u8,
        ) usize {
            const keys = stdx.bytes_as_slice(.exact, RecordKey, batch);
            const results = stdx.bytes_as_slice(.inexact, RecordValue, output)[0..keys.len];
            for (keys, results) |*key, *result| {
                result.* = .{
                    .id = key.id,
                    .table = key.table,
                    .flags = .{},
                    .op = 0,
                    .op_read = op,
                    .value = @splat(0),
                };
                if (!record_key_valid(key)) continue;
                switch (self.forest.grooves.records.get(nerva.record_key(key.table, key.id))) {
                    .found_object => |record| {
                        if (record.id != key.id) {
                            result.flags.collision = true;
                            continue;
                        }
                        result.op = record.op;
                        if (!record.flags.deleted) {
                            result.flags.exists = true;
                            result.value = record.value;
                        }
                    },
                    .not_found => {},
                }
            }
            return keys.len * @sizeOf(RecordValue);
        }

        /// Executes one transaction. `timestamp` is the timestamp of its last entry. `narrow`:
        /// sent by `commit`, which writes rows only.
        fn execute_commit(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            entries: []const WideEntry,
            narrow: bool,
            admission: views.Admission,
            output: []u8,
        ) usize {
            const results = stdx.bytes_as_slice(.inexact, EntryResult, output)[0..entries.len];
            assert(entries.len <= self.write_keys.len);

            // Resolving the adds fills in each add's result (`applied`, `value`).
            const failure = self.commit_failure(entries, narrow, admission) orelse
                self.adds_resolve(entries, results);
            if (failure) |f| {
                for (results, 0..) |*result, index| {
                    result.* = if (index == f.index)
                        .{ .status = f.status, .op = f.op, .value = f.value }
                    else
                        .{ .status = .aborted, .op = 0 };
                }
            } else {
                for (entries, results, 0..) |*entry, *result, index| {
                    const entry_timestamp =
                        timestamp - entries.len * entry_timestamps + index * entry_timestamps + 1;
                    assert(TimestampRange.valid(entry_timestamp));
                    assert(result.status == .ok);
                    switch (entry.kind) {
                        .read => {},
                        .key => self.commit_key_put(op, entry_timestamp, entries),
                        .put => if (nerva.table_is_record(entry.table))
                            self.record_put(op, entry_timestamp, entry)
                        else
                            self.row_put(op, entry_timestamp, entry, entry.row_value()),
                        .delete => if (nerva.table_is_record(entry.table))
                            self.record_delete(op, entry_timestamp, entry)
                        else
                            self.row_delete(op, entry_timestamp, entry),
                        .add => self.row_add(op, entry_timestamp, entry, result),
                        _ => unreachable, // Rejected by `entry_validate()`.
                    }
                    result.op = op;
                }
            }
            return entries.len * @sizeOf(EntryResult);
        }

        /// The first reason the transaction cannot commit, or null.
        /// A key already committed comes first: a resend must report it, whatever else changed
        /// since. Then the views budget (prefetch decided it: `views_busy`, `views_too_large`),
        /// then static checks (per entry, then pairs: N75), then duplicate writes, then read
        /// conflicts.
        fn commit_failure(
            self: *StateMachine,
            entries: []const WideEntry,
            narrow: bool,
            admission: views.Admission,
        ) ?Failure {
            if (self.commit_key_failure(entries)) |failure| return failure;
            if (admission != .fits) {
                const index = for (entries, 0..) |*entry, index| {
                    if (self.entry_viewed(entry)) break index;
                } else unreachable; // A transaction without groups always fits.
                return .{
                    .index = @intCast(index),
                    .status = if (admission == .too_large) .views_too_large else .views_busy,
                    .op = 0,
                };
            }
            for (entries, 0..) |*entry, index| {
                if (entry.kind == .key and index > 0) {
                    return .{ .index = @intCast(index), .status = .key_misplaced, .op = 0 };
                }
                // `commit` writes rows only (P123b).
                if (narrow and nerva.table_is_record(entry.table)) {
                    return .{ .index = @intCast(index), .status = .table_invalid, .op = 0 };
                }
                if (nerva.wide_entry_validate(entry)) |status| {
                    return .{ .index = @intCast(index), .status = status, .op = 0 };
                }
                if (entry.kind == .add) {
                    const add = Add.from_entry(entry);
                    for (self.views_op[0..self.views_op_count]) |*view| {
                        if (!view_maintained(view, entry.table)) continue;
                        if (views.add_touches_key(&view.definition, add.offset)) {
                            return .{
                                .index = @intCast(index),
                                .status = .view_key_field,
                                .op = 0,
                            };
                        }
                    }
                }
                if (entry.kind == .add) {
                    const add = Add.from_entry(entry);
                    if (add.flags.delta_from and (add.delta_from >= index or
                        entries[add.delta_from].kind != .add))
                    {
                        return .{
                            .index = @intCast(index),
                            .status = .delta_from_invalid,
                            .op = 0,
                        };
                    }
                    // A conserved field is an `i64`, changed only as a whole (N75).
                    const index_ = &self.ledger_index;
                    const conserved_write = if (index_.find(entry.table, add.offset) != null)
                        add.field != .i64
                    else
                        index_.touches(entry.table, add.offset, 8);
                    if (conserved_write) {
                        return .{
                            .index = @intCast(index),
                            .status = .conserved_write,
                            .op = 0,
                        };
                    }
                }
            }
            if (self.unpaired(entries)) |index| {
                return .{ .index = index, .status = .unpaired, .op = 0 };
            }
            if (self.write_duplicate(entries)) |index| {
                return .{ .index = index, .status = .write_duplicate, .op = 0 };
            }
            for (entries, 0..) |*entry, index| {
                if (entry.kind == .key or !nerva.table_is_record(entry.table)) continue;
                _ = self.record_stored(entry) catch {
                    return .{ .index = @intCast(index), .status = .id_collision, .op = 0 };
                };
            }
            for (entries, 0..) |*entry, index| {
                if (entry.kind != .read) continue;
                const version = if (nerva.table_is_record(entry.table))
                    if (self.record_stored(entry) catch unreachable) |record| record.op else 0
                else
                    self.row_version(entry_row_key(entry));
                if (version != entry.op_seen) {
                    return .{ .index = @intCast(index), .status = .conflict, .op = version };
                }
            }
            return null;
        }

        /// The index of the first conserved add that is not one half of a pair (N75), or null.
        /// A pair is a first half (`pair`) at `i` and its partner at `i + 1`: an add to another
        /// field of the same ledger whose `delta_from` names `i`, without bounds or `clamp`. No
        /// other add may name a first half. Needs only the entries and the ledgers: every add
        /// has passed `entry_validate`, its `delta_from` names an earlier add, and a conserved
        /// add is an `i64`.
        fn unpaired(self: *const StateMachine, entries: []const WideEntry) ?u32 {
            var index: u32 = 0;
            while (index < entries.len) {
                const entry = &entries[index];
                if (entry.kind != .add) {
                    index += 1;
                    continue;
                }
                const add = Add.from_entry(entry);
                if (add.flags.delta_from) {
                    assert(add.delta_from < index);
                    // Earlier first halves were checked with their partners, which are skipped.
                    if (Add.from_entry(&entries[add.delta_from]).flags.pair) return index;
                }
                const conserved = self.ledger_index.find(entry.table, add.offset);
                if (!add.flags.pair) {
                    if (conserved != null) return index;
                    index += 1;
                    continue;
                }
                const first = conserved orelse return index;
                assert(add.field == .i64);
                if (index + 1 == entries.len) return index;
                const partner_entry = &entries[index + 1];
                if (partner_entry.kind != .add) return index;
                const partner = Add.from_entry(partner_entry);
                if (!partner.flags.delta_from or partner.delta_from != index) return index;

                const partner_field =
                    self.ledger_index.find(partner_entry.table, partner.offset) orelse
                    return index + 1;
                assert(partner.field == .i64);
                if (partner_field.ledger != first.ledger) return index + 1;
                if (partner.flags.pair or partner.flags.clamp or
                    partner.flags.min or partner.flags.max)
                {
                    return index + 1;
                }
                if (partner_entry.table == entry.table and partner_entry.id == entry.id and
                    partner.offset == add.offset)
                {
                    return index + 1;
                }
                index += 2;
            }
            return null;
        }

        /// The index of the earliest write whose row an earlier write in the same transaction
        /// already wrote, or null. Sorts in scratch space: O(n log n), no allocation.
        fn write_duplicate(self: *StateMachine, entries: []const WideEntry) ?u32 {
            var count: u32 = 0;
            for (entries, 0..) |*entry, index| {
                // A key's row is written only when no row is there (`commit_key_failure`).
                if (entry.kind == .read or entry.kind == .key) continue;
                self.write_keys[count] = .{
                    .key = if (nerva.table_is_record(entry.table))
                        nerva.record_key(entry.table, entry.id)
                    else
                        entry_row_key(entry),
                    .index = @intCast(index),
                };
                count += 1;
            }
            const write_keys = self.write_keys[0..count];
            std.mem.sortUnstable(WriteKey, write_keys, {}, struct {
                fn less_than(_: void, a: WriteKey, b: WriteKey) bool {
                    if (a.key != b.key) return a.key < b.key;
                    return a.index < b.index;
                }
            }.less_than);

            var duplicate: ?u32 = null;
            for (write_keys[0..count -| 1], write_keys[@min(1, count)..]) |a, b| {
                if (a.key != b.key) continue;
                assert(a.index < b.index);
                // Several adds may change one row; a put or delete must be its only write.
                if (entries[a.index].kind == .add and entries[b.index].kind == .add) continue;
                duplicate = @min(duplicate orelse b.index, b.index);
            }
            return duplicate;
        }

        /// The LSM key of the row a `key` entry's key is kept in.
        fn commit_key_row(entry: *const WideEntry) u128 {
            assert(entry.kind == .key);
            return nerva.row_key(
                nerva.table_commit_keys,
                nerva.commit_key_id(CommitKey.entry_key(entry)),
            );
        }

        /// The checksum a key's row keeps of the transaction's entries after its key entry.
        fn commit_key_checksum(entries: []const WideEntry) u128 {
            assert(entries[0].kind == .key);
            return vsr.checksum(std.mem.sliceAsBytes(entries[1..]));
        }

        /// Why a transaction that starts with a valid key cannot commit because the key's row
        /// exists, or null. The row is the key's own (`committed_before` if it holds these
        /// entries, else `key_reused`) or another key's (`key_collision`); each reports the op
        /// that wrote the row. Rows of `table_commit_keys` are written only by
        /// `commit_key_put`, once each, so the row's op is the op its transaction committed at.
        fn commit_key_failure(self: *StateMachine, entries: []const WideEntry) ?Failure {
            if (entries.len == 0 or entries[0].kind != .key) return null;
            // An invalid key entry is reported by the static checks.
            if (nerva.wide_entry_validate(&entries[0]) != null) return null;
            const row = switch (self.forest.grooves.rows.get(commit_key_row(&entries[0]))) {
                .found_object => |row| row,
                .not_found => return null,
            };
            assert(!row.flags.deleted);
            assert(row.op > 0);
            const stored = std.mem.bytesToValue(CommitKey, &row.value);
            assert(stored.key != 0);
            assert(stdx.zeroed(&stored.reserved));
            const status: EntryStatus = if (stored.key != CommitKey.entry_key(&entries[0]))
                .key_collision
            else if (stored.entry_count == entries.len - 1 and
                stored.checksum == commit_key_checksum(entries))
                .committed_before
            else
                .key_reused;
            return .{ .index = 0, .status = status, .op = row.op };
        }

        /// Writes the key's row of a transaction that commits under a key (it is the first
        /// entry). The row was absent: `commit_key_failure` found none.
        fn commit_key_put(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            entries: []const WideEntry,
        ) void {
            const key = CommitKey.entry_key(&entries[0]);
            const stored: CommitKey = .{
                .key = key,
                .checksum = commit_key_checksum(entries),
                .entry_count = @intCast(entries.len - 1),
            };
            var entry: WideEntry = .{
                .id = nerva.commit_key_id(key),
                .table = nerva.table_commit_keys,
                .kind = .put,
                .op_seen = 0,
                .value = @splat(0),
            };
            entry.value[0..nerva.value_size].* = std.mem.toBytes(stored);
            assert(self.row_version(commit_key_row(&entries[0])) == 0);
            self.row_put(op, timestamp, &entry, entry.row_value());
        }

        /// A record entry's record as stored (a tombstone included), null if its key holds
        /// nothing, or `error.Collision` if it holds another id (P123b).
        fn record_stored(self: *StateMachine, entry: *const WideEntry) error{Collision}!?Record {
            assert(nerva.table_is_record(entry.table));
            return switch (self.forest.grooves.records.get(
                nerva.record_key(entry.table, entry.id),
            )) {
                .found_object => |record| found: {
                    assert(record.table == entry.table);
                    if (record.id != entry.id) return error.Collision;
                    break :found record;
                },
                .not_found => null,
            };
        }

        fn record_put(self: *StateMachine, op: u64, timestamp: u64, entry: *const WideEntry) void {
            assert(entry.kind == .put);
            const records = &self.forest.grooves.records;
            const stored = self.record_stored(entry) catch unreachable;
            self.indexes_record_changed(
                entry.table,
                entry.id,
                if (stored) |*record| record else null,
                &entry.value,
                op,
                timestamp,
            );
            if (stored) |record_old| {
                // Equal when an earlier transaction in the same request wrote the record.
                assert(record_old.op <= op);
                var record_new = record_old;
                record_new.value = entry.value;
                record_new.op = op;
                record_new.flags.deleted = false;
                // Unchanged when an earlier write in the same op left the same bytes.
                if (!stdx.equal_bytes(Record, &record_old, &record_new)) {
                    records.update(.{ .old = &record_old, .new = &record_new });
                }
            } else {
                records.insert(&.{
                    .key = nerva.record_key(entry.table, entry.id),
                    .id = entry.id,
                    .table = entry.table,
                    .flags = .{},
                    .op = op,
                    .timestamp = timestamp,
                    .value = entry.value,
                });
            }
            self.record_change_insert(op, timestamp, entry, .put, &entry.value);
        }

        /// Deleting a record that does not exist (or is already deleted) is a no-op.
        fn record_delete(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            entry: *const WideEntry,
        ) void {
            assert(entry.kind == .delete);
            const record_old = (self.record_stored(entry) catch unreachable) orelse return;
            if (record_old.flags.deleted) return;
            assert(record_old.op <= op);
            self.indexes_record_changed(entry.table, entry.id, &record_old, null, op, timestamp);
            var record_new = record_old;
            record_new.value = @splat(0);
            record_new.op = op;
            record_new.flags.deleted = true;
            self.forest.grooves.records.update(.{ .old = &record_old, .new = &record_new });
            self.record_change_insert(op, timestamp, entry, .delete, &@splat(0));
        }

        fn record_change_insert(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            entry: *const WideEntry,
            kind: nerva.ChangeKind,
            value: *const [nerva.record_value_size]u8,
        ) void {
            assert(kind == .put or kind == .delete);
            assert(kind == .put or stdx.zeroed(value));
            self.forest.grooves.record_changes.insert(&.{
                .id = entry.id,
                .table = entry.table,
                .kind = kind,
                .flags = .{},
                .op = op,
                .timestamp = timestamp,
                .value = value.*,
            });
        }

        /// The row's version: the op of its last write, or zero if it has never existed.
        fn row_version(self: *StateMachine, key: u128) u64 {
            return switch (self.forest.grooves.rows.get(key)) {
                .found_object => |row| row.op,
                .not_found => 0,
            };
        }

        fn row_put(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            entry: *const WideEntry,
            value: *const [nerva.value_size]u8,
        ) void {
            assert(entry.kind == .put or entry.kind == .add);
            assert(entry.id <= std.math.maxInt(u64));
            const rows = &self.forest.grooves.rows;
            const key = entry_row_key(entry);
            const value_old: ?[nerva.value_size]u8 = switch (rows.get(key)) {
                .found_object => |row| if (row.flags.deleted) null else row.value,
                .not_found => null,
            };
            self.views_row_changed(
                entry.table,
                @intCast(entry.id),
                if (value_old) |*old| old else null,
                value,
                timestamp,
            );
            switch (rows.get(key)) {
                .found_object => |row_old| {
                    // Equal when an earlier transaction in the same request wrote the row.
                    assert(row_old.op <= op);
                    var row_new = row_old;
                    row_new.value = value.*;
                    row_new.op = op;
                    row_new.flags.deleted = false;
                    // Unchanged when an earlier write in the same op left the same bytes (the
                    // groove refuses a no-op update); the change is still recorded.
                    if (!stdx.equal_bytes(Row, &row_old, &row_new)) {
                        rows.update(.{ .old = &row_old, .new = &row_new });
                    }
                },
                .not_found => rows.insert(&.{
                    .key = key,
                    .value = value.*,
                    .op = op,
                    .timestamp = timestamp,
                    .flags = .{},
                }),
            }
            self.change_insert(op, timestamp, entry, .put, value);
        }

        /// Applies an add resolved by `adds_resolve`: writes the row with the field changed, as
        /// a put of the whole value.
        fn row_add(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            entry: *const WideEntry,
            result: *const EntryResult,
        ) void {
            const add = Add.from_entry(entry);
            var value: [nerva.value_size]u8 = switch (self.forest.grooves.rows.get(
                entry_row_key(entry),
            )) {
                .found_object => |row| if (row.flags.deleted) @splat(0) else row.value,
                .not_found => @splat(0),
            };
            const field = value[add.offset..][0..8];
            const old = std.mem.readInt(u64, field, .little);
            assert(nerva.add_apply(&add, old, result.applied) == result.value);
            std.mem.writeInt(u64, field, result.value, .little);
            self.row_put(op, timestamp, entry, &value);
        }

        /// Resolves the transaction's adds in order against the rows (and the earlier adds of the
        /// same transaction), without writing: the first add that cannot apply, or null with
        /// every result `ok` and each add's `applied` and `value` filled in.
        fn adds_resolve(
            self: *StateMachine,
            entries: []const WideEntry,
            results: []EntryResult,
        ) ?Failure {
            assert(entries.len == results.len);
            self.add_rows.clearRetainingCapacity();
            for (entries, results, 0..) |*entry, *result, index| {
                result.* = .{ .status = .ok, .op = 0 };
                if ((entry.kind == .put or entry.kind == .delete) and
                    !nerva.table_is_record(entry.table))
                {
                    if (!self.conserved_unchanged(entry)) return .{
                        .index = @intCast(index),
                        .status = .conserved_write,
                        .op = 0,
                    };
                }
                if (entry.kind != .add) continue;
                const conserved = self.ledger_index.find(entry.table, Add.from_entry(entry).offset);
                // A conserved add never moves its field down past the floor (N75).
                const add = if (conserved) |field|
                    nerva.ledger_bounds(&Add.from_entry(entry), field.floor)
                else
                    Add.from_entry(entry);

                const key = entry_row_key(entry);
                const row = self.add_rows.getOrPutAssumeCapacity(key);
                if (!row.found_existing) {
                    const rows = &self.forest.grooves.rows;
                    const current: ?[nerva.value_size]u8 = switch (rows.get(key)) {
                        .found_object => |found| if (found.flags.deleted) null else found.value,
                        .not_found => null,
                    };
                    if (current == null and !add.flags.create) {
                        return .{ .index = @intCast(index), .status = .row_absent, .op = 0 };
                    }
                    row.value_ptr.* = current orelse @splat(0);
                }

                const field = row.value_ptr[add.offset..][0..8];
                const old = std.mem.readInt(u64, field, .little);
                const delta = if (add.flags.delta_from) delta: {
                    assert(add.delta_from < index);
                    assert(entries[add.delta_from].kind == .add);
                    break :delta -results[add.delta_from].applied;
                } else add.delta;
                const applied = nerva.add_amount(&add, old, delta) orelse return .{
                    .index = @intCast(index),
                    .status = .out_of_bounds,
                    .op = 0,
                    .value = old,
                };
                result.applied = applied;
                result.value = nerva.add_apply(&add, old, applied);
                std.mem.writeInt(u64, field, result.value, .little);
            }
            return null;
        }

        /// Whether a put or delete leaves the row's conserved fields as they are (N75): a put
        /// must not change their bytes, and a delete needs them all zero. A row that does not
        /// exist holds zeros. A put or delete is the only write to its row in its transaction
        /// (`write_duplicate`), so the stored row is the one it changes.
        fn conserved_unchanged(self: *StateMachine, entry: *const WideEntry) bool {
            assert(entry.kind == .put or entry.kind == .delete);
            const fields = self.ledger_index.table_fields(entry.table);
            if (fields.len == 0) return true;
            const current: [nerva.value_size]u8 =
                switch (self.forest.grooves.rows.get(entry_row_key(entry))) {
                    .found_object => |row| if (row.flags.deleted) @splat(0) else row.value,
                    .not_found => @splat(0),
                };
            const new: [nerva.value_size]u8 =
                if (entry.kind == .put) entry.row_value().* else @splat(0);
            for (fields) |*field| {
                if (!std.mem.eql(
                    u8,
                    current[field.offset..][0..8],
                    new[field.offset..][0..8],
                )) return false;
            }
            return true;
        }

        /// Deleting a row that does not exist (or is already deleted) is a no-op.
        fn row_delete(self: *StateMachine, op: u64, timestamp: u64, entry: *const WideEntry) void {
            assert(entry.kind == .delete);
            assert(entry.id <= std.math.maxInt(u64));
            const rows = &self.forest.grooves.rows;
            switch (rows.get(entry_row_key(entry))) {
                .found_object => |row_old| {
                    if (row_old.flags.deleted) return;
                    assert(row_old.op <= op);
                    self.views_row_changed(
                        entry.table,
                        @intCast(entry.id),
                        &row_old.value,
                        null,
                        timestamp,
                    );
                    var row_new = row_old;
                    row_new.value = @splat(0);
                    row_new.op = op;
                    row_new.flags.deleted = true;
                    rows.update(.{ .old = &row_old, .new = &row_new });
                },
                .not_found => return,
            }
            self.change_insert(op, timestamp, entry, .delete, &@splat(0));
        }

        fn change_insert(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            entry: *const WideEntry,
            kind: nerva.ChangeKind,
            value: *const [nerva.value_size]u8,
        ) void {
            assert(kind == .put or kind == .delete);
            assert(kind == .put or stdx.zeroed(value));
            self.forest.grooves.changes.insert(&.{
                .id = @intCast(entry.id),
                .table = entry.table,
                .kind = kind,
                .flags = .{},
                .op = op,
                .timestamp = timestamp,
                .value = value.*,
            });
        }

        // ---- Ledgers (N75) ----

        /// Prefetches every declared ledger (stage 0 of `commit`, `declare_view`,
        /// `declare_ledger` and `get_ledger`), loads them, then the views where the operation
        /// needs them.
        fn prefetch_ledgers(self: *StateMachine) void {
            const groove = &self.forest.grooves.ledgers;
            groove.prefetch_setup(self.prefetch_snapshot.?);
            const count = self.ledger_count orelse nerva.ledgers_max;
            for (1..count + 1) |slot| groove.prefetch_enqueue(.{ .slot = slot });
            groove.prefetch(prefetch_ledgers_callback, &self.ledgers_prefetch_context);
        }

        fn prefetch_ledgers_callback(context: *LedgersGroove.PrefetchContext) void {
            const self: *StateMachine = @alignCast(
                @fieldParentPtr("ledgers_prefetch_context", context),
            );
            self.ledgers_load();
            switch (self.prefetch_operation.?) {
                .commit, .commit_wide, .declare_view, .declare_ledger => self.prefetch_views(),
                .get_ledger => self.prefetch_finish(),
                else => unreachable,
            }
        }

        /// Loads the ledgers prefetched for this op into `ledgers_op`, and indexes those not
        /// indexed yet (ledgers are immutable: the index only grows).
        fn ledgers_load(self: *StateMachine) void {
            const groove = &self.forest.grooves.ledgers;
            const count = self.ledger_count orelse nerva.ledgers_max;
            var loaded: u32 = 0;
            for (1..count + 1) |slot| {
                switch (groove.get(slot)) {
                    .found_object => |ledger| {
                        // Slots are dense: 1, 2, … in declaration order.
                        assert(ledger.slot == loaded + 1);
                        self.ledgers_op[loaded] = ledger;
                        loaded += 1;
                    },
                    .not_found => break,
                }
            }
            if (self.ledger_count) |known| assert(known == loaded);
            self.ledger_count = loaded;
            assert(self.ledger_index.ledger_count <= loaded);
            for (self.ledgers_op[self.ledger_index.ledger_count..loaded]) |*ledger| {
                self.ledger_index.insert(&ledger.definition);
            }
            assert(self.ledger_index.ledger_count == loaded);
        }

        fn execute_declare_ledger(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            assert(message_body_used.len == @sizeOf(LedgerDefinition));
            const definition: *const LedgerDefinition = @alignCast(std.mem.bytesAsValue(
                LedgerDefinition,
                message_body_used[0..@sizeOf(LedgerDefinition)],
            ));
            const result: *DeclareLedgerResult = @alignCast(std.mem.bytesAsValue(
                DeclareLedgerResult,
                output_buffer[0..@sizeOf(DeclareLedgerResult)],
            ));
            result.* = self.ledger_declare(op, timestamp, definition);
            return @sizeOf(DeclareLedgerResult);
        }

        fn ledger_declare(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            definition: *const LedgerDefinition,
        ) DeclareLedgerResult {
            if (ledgers.definition_validate(definition)) |status| {
                return .{ .status = status, .op = 0 };
            }
            const count = self.ledger_count.?;
            for (self.ledgers_op[0..count]) |*ledger| {
                if (ledger.definition.id != definition.id) continue;
                if (stdx.equal_bytes(LedgerDefinition, &ledger.definition, definition)) {
                    return .{ .status = .exists, .op = ledger.op };
                }
                return .{ .status = .ledger_immutable, .op = 0 };
            }
            if (count == nerva.ledgers_max) return .{ .status = .ledgers_full, .op = 0 };
            for (definition.fields[0..definition.field_count]) |*field| {
                if (self.ledger_index.find(field.table, field.offset) != null) {
                    return .{ .status = .ledger_field_taken, .op = 0 };
                }
                for (self.views_op[0..self.views_op_count]) |*view| {
                    if (!view_maintained(view, field.table)) continue;
                    if (views.add_touches_key(&view.definition, field.offset)) {
                        return .{ .status = .field_viewed, .op = 0 };
                    }
                }
            }

            const ledger: Ledger = .{
                .slot = count + 1,
                .timestamp = timestamp,
                .op = op,
                .definition = definition.*,
            };
            self.forest.grooves.ledgers.insert(&ledger);
            self.ledgers_op[count] = ledger;
            self.ledger_count = count + 1;
            self.ledger_index.insert(&ledger.definition);
            return .{ .status = .created, .op = op };
        }

        fn execute_get_ledger(
            self: *StateMachine,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            assert(message_body_used.len == @sizeOf(LedgerQuery));
            const query: *const LedgerQuery = @alignCast(
                std.mem.bytesAsValue(LedgerQuery, message_body_used[0..@sizeOf(LedgerQuery)]),
            );
            const result: *Ledger = @alignCast(
                std.mem.bytesAsValue(Ledger, output_buffer[0..@sizeOf(Ledger)]),
            );
            result.* = std.mem.zeroes(Ledger);
            if (!stdx.zeroed(&query.reserved)) return @sizeOf(Ledger);
            const ledgers_declared = self.ledgers_op[0..self.ledger_count.?];
            if (query.id != 0 and query.slot == 0) {
                for (ledgers_declared) |*ledger| {
                    if (ledger.definition.id == query.id) result.* = ledger.*;
                }
            }
            if (query.id == 0 and query.slot != 0 and query.slot <= ledgers_declared.len) {
                result.* = ledgers_declared[query.slot - 1];
                assert(result.slot == query.slot);
            }
            return @sizeOf(Ledger);
        }

        // ---- Views (N52) ----

        /// Prefetches every declared view (stage 0 of `commit`, `get_view`, `declare_view` and
        /// `pulse`), loads them, then runs the operation's own stage.
        fn prefetch_views(self: *StateMachine) void {
            const groove = &self.forest.grooves.views;
            groove.prefetch_setup(self.prefetch_snapshot.?);
            const count = self.view_count orelse nerva.views_max;
            for (1..count + 1) |id| groove.prefetch_enqueue(.{ .id = id });
            groove.prefetch(prefetch_views_callback, &self.views_prefetch_context);
        }

        fn prefetch_views_callback(context: *ViewsGroove.PrefetchContext) void {
            const self: *StateMachine = @alignCast(
                @fieldParentPtr("views_prefetch_context", context),
            );
            self.views_load();
            switch (self.prefetch_operation.?) {
                .commit, .commit_wide, .pulse => self.prefetch_indexes(),
                .declare_view => if (self.restoring)
                    self.prefetch_restore_table()
                else
                    self.prefetch_finish(),
                .declare_ledger => self.prefetch_finish(),
                .get_view => self.prefetch_view_groups(),
                else => unreachable,
            }
        }

        /// Prefetches the groups a commit may touch (stage 2, after the rows), and admits each
        /// transaction in order while the op's distinct groups fit in `group_writes_limit`
        /// (N52): a transaction that would not fit is refused (`views_busy`) at commit. The
        /// groups counted are a superset of those the commit can touch, computed from the rows
        /// as they are before the op: for every write, in every view of its table, the old row's
        /// group and the put's (or a creating add's empty row's) group.
        fn prefetch_commit_groups(self: *StateMachine) void {
            const operation = self.prefetch_operation.?;
            var decoder = MultiBatchDecoder.init(self.prefetch_input.?, .{
                .element_size = operation.event_size(),
            }) catch unreachable; // Already validated by `input_valid()`.

            const groups = &self.forest.grooves.groups;
            groups.prefetch_setup(self.prefetch_snapshot.?);
            // Stage 3 prefetches the members admitted here.
            const members = &self.forest.grooves.members;
            members.prefetch_setup(self.prefetch_snapshot.?);
            self.view_txn_busy.unsetAll();
            self.view_txn_too_large.unsetAll();
            self.view_op_keys.clearRetainingCapacity();
            self.view_op_members.clearRetainingCapacity();
            var batch_index: u32 = 0;
            while (decoder.pop()) |batch| : (batch_index += 1) {
                const entries = self.batch_entries(operation, batch);
                switch (self.view_txn_admit(entries)) {
                    .fits => {},
                    .busy => {
                        self.view_txn_busy.set(batch_index);
                        continue;
                    },
                    .too_large => {
                        self.view_txn_busy.set(batch_index);
                        self.view_txn_too_large.set(batch_index);
                        continue;
                    },
                }
                for (self.view_txn_keys.items) |key| groups.prefetch_enqueue(.{ .key = key });
                for (self.view_txn_members.items) |key| members.prefetch_enqueue(.{ .key = key });
            }
            self.view_txn_keys.clearRetainingCapacity();
            self.view_txn_members.clearRetainingCapacity();
            groups.prefetch(prefetch_groups_callback, &self.groups_prefetch_context);
        }

        /// Adds the transaction's groups and members to the op's, if they fit (`view_txn_keys`
        /// and `view_txn_members` hold those it added). Otherwise leaves the op's as they were.
        /// A write counts, in each view of its table, the groups of its old and new values that
        /// pass the view's filter, and if either does, its member in each `min` or `max` slot.
        fn view_txn_admit(self: *StateMachine, entries: []const WideEntry) views.Admission {
            self.view_txn_keys.clearRetainingCapacity();
            self.view_txn_members.clearRetainingCapacity();
            // A transaction whose key's row exists writes nothing (`commit_key_failure`).
            if (entries.len > 0 and entries[0].kind == .key and
                self.forest.grooves.rows.get(commit_key_row(&entries[0])) == .found_object)
            {
                return .fits;
            }
            const admission: views.Admission = admission: {
                for (entries) |*entry| {
                    if (!self.entry_viewed(entry)) continue;
                    const rows = &self.forest.grooves.rows;
                    const value_old: ?[nerva.value_size]u8 =
                        switch (rows.get(entry_row_key(entry))) {
                            .found_object => |row| if (row.flags.deleted) null else row.value,
                            .not_found => null,
                        };
                    for (self.views_op[0..self.views_op_count]) |*view| {
                        if (view.definition.table != entry.table) continue;
                        var matched = false;
                        for (views.entry_values(entry, value_old)) |candidate| {
                            const value = candidate orelse continue;
                            if (!views.row_matches(&view.definition, &value)) continue;
                            matched = true;
                            const group_key = views.group_key(&view.definition, &value);
                            const key = views.group_tree_key(view.id, &group_key);
                            const op_keys = &self.view_op_keys;
                            const txn_keys = &self.view_txn_keys;
                            if (!admit(op_keys, txn_keys, key, self.group_writes_limit)) {
                                // Too large if the op's budget holds only this transaction's.
                                const own = txn_keys.items.len == op_keys.count();
                                break :admission if (own) .too_large else .busy;
                            }
                        }
                        if (!matched) continue;
                        const definition = &view.definition;
                        const aggregates = definition.aggregates[0..definition.aggregate_count];
                        for (aggregates, 0..) |*aggregate, slot| {
                            if (!views.extreme(aggregate.function)) continue;
                            const key = nerva.member_key(view.id, @intCast(slot), @truncate(entry.id));
                            const op_keys = &self.view_op_members;
                            const txn_keys = &self.view_txn_members;
                            if (!admit(op_keys, txn_keys, key, self.member_writes_limit)) {
                                const own = txn_keys.items.len == op_keys.count();
                                break :admission if (own) .too_large else .busy;
                            }
                        }
                    }
                }
                break :admission .fits;
            };
            if (admission != .fits) {
                for (self.view_txn_keys.items) |added| assert(self.view_op_keys.remove(added));
                for (self.view_txn_members.items) |added| {
                    assert(self.view_op_members.remove(added));
                }
                self.view_txn_keys.clearRetainingCapacity();
                self.view_txn_members.clearRetainingCapacity();
            }
            return admission;
        }

        /// Counts `key` in the op's set, and the transaction's list, unless already counted; false
        /// if the set is full.
        fn admit(
            op_keys: *std.AutoHashMapUnmanaged(u128, void),
            txn_keys: *std.ArrayListUnmanaged(u128),
            key: u128,
            limit: u32,
        ) bool {
            if (op_keys.contains(key)) return true;
            if (op_keys.count() == limit) return false;
            op_keys.putAssumeCapacity(key, {});
            txn_keys.appendAssumeCapacity(key);
            return true;
        }

        /// Whether the entry writes a table with a view (in any state).
        fn entry_viewed(self: *const StateMachine, entry: *const WideEntry) bool {
            if (entry.table == 0) return false;
            switch (entry.kind) {
                .put, .delete, .add => {},
                else => return false,
            }
            for (self.views_op[0..self.views_op_count]) |*view| {
                if (view.definition.table == entry.table) return true;
            }
            return false;
        }

        fn prefetch_groups_callback(context: *GroupsGroove.PrefetchContext) void {
            const self: *StateMachine = @alignCast(
                @fieldParentPtr("groups_prefetch_context", context),
            );
            switch (self.prefetch_operation.?) {
                .commit, .commit_wide => self.prefetch_commit_members(),
                .pulse => self.prefetch_backfill_members(),
                else => unreachable,
            }
        }

        /// Stage 3 of `commit` (N62): the members admission counted, in every `min` or `max`
        /// slot of every admitted write's table (enqueued by `prefetch_commit_groups`).
        fn prefetch_commit_members(self: *StateMachine) void {
            const members = &self.forest.grooves.members;
            members.prefetch(prefetch_members_callback, &self.members_prefetch_context);
        }

        fn members_enqueue(self: *StateMachine, view: *const View, id: u64) void {
            const definition = &view.definition;
            for (definition.aggregates[0..definition.aggregate_count], 0..) |*aggregate, slot| {
                if (!views.extreme(aggregate.function)) continue;
                self.forest.grooves.members.prefetch_enqueue(.{
                    .key = nerva.member_key(view.id, @intCast(slot), id),
                });
            }
        }

        /// Stage 3 of `pulse`: the members of the rows it adds (none exist yet; prefetched so
        /// that the commit can tell).
        fn prefetch_backfill_members(self: *StateMachine) void {
            const members = &self.forest.grooves.members;
            members.prefetch_setup(self.prefetch_snapshot.?);
            if (self.backfill_view) |index| {
                const view = &self.views_op[index];
                const count = @min(self.backfill_count.?, self.backfill_rows_max(view));
                for (self.backfill_rows[0..count]) |*row| {
                    self.members_enqueue(view, @truncate(row.key));
                }
            }
            members.prefetch(prefetch_members_callback, &self.members_prefetch_context);
        }

        fn prefetch_members_callback(context: *MembersGroove.PrefetchContext) void {
            const self: *StateMachine = @alignCast(
                @fieldParentPtr("members_prefetch_context", context),
            );
            switch (self.prefetch_operation.?) {
                .commit, .commit_wide => self.prefetch_extreme_scans(),
                .pulse => self.prefetch_finish(),
                else => unreachable,
            }
        }

        /// Stage 4 of `commit` (N62). For every slot a write may take a member out of (from
        /// the rows as they are before the op, as admission counts), counts the writes that
        /// may; and where one of them may take away the member holding the group's value,
        /// prefetches the first `removals_max + 1` members of the slot's order, one scan each.
        fn prefetch_extreme_scans(self: *StateMachine) void {
            assert(self.extreme_scans.items.len == 0);
            assert(self.extreme_scan_index.count() == 0);
            const operation = self.prefetch_operation.?;
            var decoder = MultiBatchDecoder.init(self.prefetch_input.?, .{
                .element_size = operation.event_size(),
            }) catch unreachable; // Already validated by `input_valid()`.
            var batch_index: u32 = 0;
            while (decoder.pop()) |batch| : (batch_index += 1) {
                if (self.view_txn_busy.isSet(batch_index)) continue;
                for (self.batch_entries(operation, batch)) |*entry| {
                    if (!self.entry_viewed(entry)) continue;
                    const old = switch (self.forest.grooves.rows.get(entry_row_key(entry))) {
                        .found_object => |row| if (row.flags.deleted) continue else row.value,
                        .not_found => continue,
                    };
                    const id: u64 = @truncate(entry.id);
                    for (self.views_op[0..self.views_op_count]) |*view| {
                        if (!view_maintained(view, entry.table)) continue;
                        if (view.state == .building and id >= view.backfill_cursor) continue;
                        if (!views.row_matches(&view.definition, &old)) continue;
                        self.extreme_scans_count(view, id, &old);
                    }
                }
            }
            var count: u32 = 0;
            for (self.extreme_scans.items) |*scan| {
                if (!scan.read) continue;
                scan.start = count;
                count += scan.removals_max + 1;
            }
            assert(count <= self.extreme_members.len);
            self.extreme_members_count = count;
            self.extreme_scans_done = 0;
            self.extreme_scan_next();
        }

        /// Counts one write that may take row `id`'s members, as `old`, out of its group's
        /// slots (each member once, however many writes the op has to its row), and marks a slot
        /// to read if `old` holds the group's value there.
        fn extreme_scans_count(
            self: *StateMachine,
            view: *const View,
            id: u64,
            old: *const [nerva.value_size]u8,
        ) void {
            const definition = &view.definition;
            const group_key = views.group_key(definition, old);
            const tree_key = views.group_tree_key(view.id, &group_key);
            const group: ?Group = switch (self.forest.grooves.groups.get(tree_key)) {
                .found_object => |group| group,
                .not_found => null,
            };
            for (definition.aggregates[0..definition.aggregate_count], 0..) |*aggregate, index| {
                if (!views.extreme(aggregate.function)) continue;
                const slot: u8 = @intCast(index);
                const key: ExtremeKey = .{ .group = tree_key, .slot = slot };
                const entry = self.extreme_scan_index.getOrPutAssumeCapacity(key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = @intCast(self.extreme_scans.items.len);
                    self.extreme_scans.appendAssumeCapacity(.{
                        .key = key,
                        .prefix = views.member_order_prefix(view.id, slot, &group_key),
                        .function = aggregate.function,
                        .removals_max = 0,
                    });
                }
                const scan = &self.extreme_scans.items[entry.value_ptr.*];
                const member = nerva.member_key(view.id, slot, id);
                if (self.extreme_counted.getOrPutAssumeCapacity(member).found_existing) continue;
                scan.removals_max += 1;
                const stored = group orelse continue;
                if (stored.count == 0) continue;
                const value = views.field_integer(aggregate.field, old);
                if (value == std.mem.readInt(i128, &stored.sums[slot], .little)) scan.read = true;
            }
        }

        fn extreme_scan_next(self: *StateMachine) void {
            while (self.extreme_scans_done < self.extreme_scans.items.len) {
                if (self.extreme_scans.items[self.extreme_scans_done].read) break;
                self.extreme_scans_done += 1;
            } else return self.prefetch_finish();

            const scan = &self.extreme_scans.items[self.extreme_scans_done];
            const members = &self.forest.grooves.members;
            const range = members.scan_builder.scan_prefix_range(
                .order,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                nerva.member_order(scan.prefix, 0),
                nerva.member_order(scan.prefix, std.math.maxInt(u64)),
                switch (scan.function) {
                    .min => .ascending,
                    .max => .descending,
                    else => unreachable,
                },
            );
            self.members_scan_lookup = MembersScanLookup.init(members, range);
            self.members_scan_lookup.read(
                self.extreme_members[scan.start..][0 .. scan.removals_max + 1],
                extreme_scan_callback,
            );
        }

        fn extreme_scan_callback(scan_lookup: *MembersScanLookup, results: []const Member) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("members_scan_lookup", scan_lookup));
            const scan = &self.extreme_scans.items[self.extreme_scans_done];
            assert(results.len <= scan.removals_max + 1);
            scan.count = @intCast(results.len);
            self.extreme_scans_done += 1;
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.members.scan_builder.reset();
            self.extreme_scan_next();
        }

        /// Whether `view` is kept up to date with writes to `table`.
        fn view_maintained(view: *const View, table: u32) bool {
            return view.definition.table == table and
                (view.state == .building or view.state == .ready);
        }

        /// Loads the views prefetched for this op into `views_op` and `views_stored`.
        fn views_load(self: *StateMachine) void {
            const groove = &self.forest.grooves.views;
            const count = self.view_count orelse nerva.views_max;
            var loaded: u32 = 0;
            var building = false;
            for (1..count + 1) |id| {
                switch (groove.get(id)) {
                    .found_object => |view| {
                        // Ids are dense: 1, 2, … in declaration order.
                        assert(view.id == loaded + 1);
                        self.views_op[loaded] = view;
                        self.views_stored[loaded] = view;
                        loaded += 1;
                        building = building or view.state == .building;
                    },
                    .not_found => break,
                }
            }
            if (self.view_count) |known| assert(known == loaded);
            self.view_count = loaded;
            self.view_building = building;
            self.views_op_count = loaded;
            assert(self.groups_touched.items.len == 0);
            assert(self.groups_scratch.count() == 0);
        }

        /// Writes back the views this op changed, with their versions at `op`.
        fn views_store(self: *StateMachine, op: u64) void {
            const groove = &self.forest.grooves.views;
            var building = false;
            for (
                self.views_op[0..self.views_op_count],
                self.views_stored[0..self.views_op_count],
            ) |*view, *stored| {
                building = building or view.state == .building;
                if (stdx.equal_bytes(View, view, stored)) continue;
                groove.update(.{ .old = stored, .new = view });
                stored.* = view.*;
                self.view_version_insert(view, op);
            }
            self.view_building = building;
        }

        fn view_version_insert(self: *StateMachine, view: *const View, op: u64) void {
            self.forest.grooves.view_versions.insert(&.{
                .version = nerva.view_version_key(view.id, op),
                .timestamp = self.version_timestamp_next(),
                .op = op,
                .group_count = view.group_count,
                .state = view.state,
                .hash = view.hash,
            });
        }

        /// Keeps the views over `table` exact after one row changed from `old` to `new` (null:
        /// absent). `timestamp` is the entry's (`entry_timestamps`): a group it creates in the
        /// table's `n`th view takes `timestamp + 1 + n`, and a member it creates in the table's
        /// `m`th `min` or `max` slot takes `timestamp + 1 + views_per_table_max + m`.
        fn views_row_changed(
            self: *StateMachine,
            table: u32,
            id: u64,
            old: ?*const [nerva.value_size]u8,
            new: ?*const [nerva.value_size]u8,
            timestamp: u64,
        ) void {
            var slot: u64 = 0;
            var extreme_slot: u64 = 0;
            for (self.views_op[0..self.views_op_count]) |*view| {
                if (view.definition.table != table) continue;
                defer slot += 1;
                defer extreme_slot += views.extreme_count(&view.definition);
                assert(slot < nerva.views_per_table_max);
                if (!view_maintained(view, table)) continue;
                // A building view adds rows from its cursor on when the pulse reaches them.
                if (view.state == .building and id >= view.backfill_cursor) continue;
                self.view_row_changed(
                    view,
                    id,
                    old,
                    new,
                    timestamp + 1 + slot,
                    timestamp + 1 + nerva.views_per_table_max + extreme_slot,
                );
            }
            assert(extreme_slot <= nerva.view_extremes_per_table_max);
        }

        /// One view's part of `views_row_changed`, and a pulse's (with `old` null).
        fn view_row_changed(
            self: *StateMachine,
            view: *View,
            id: u64,
            old: ?*const [nerva.value_size]u8,
            new: ?*const [nerva.value_size]u8,
            group_timestamp: u64,
            member_timestamp: u64,
        ) void {
            const old_in = if (old) |value| views.row_matches(&view.definition, value) else false;
            const new_in = if (new) |value| views.row_matches(&view.definition, value) else false;
            if (old_in) self.group_change(view, old.?, .remove, 0);
            if (new_in) self.group_change(view, new.?, .add, group_timestamp);
            if (old_in or new_in) {
                self.members_change(view, id, if (new_in) new.? else null, member_timestamp);
            }
        }

        /// Moves the row's member of each `min` or `max` slot of `view` to its place in `value`'s
        /// group, or takes it out of the order (`value` null), in the op's scratch members. A
        /// member created now takes `timestamp + m` in the view's `m`th such slot.
        fn members_change(
            self: *StateMachine,
            view: *const View,
            id: u64,
            value: ?*const [nerva.value_size]u8,
            timestamp: u64,
        ) void {
            if (view.state == .failed) return; // An earlier collision.
            const definition = &view.definition;
            var m: u64 = 0;
            for (definition.aggregates[0..definition.aggregate_count], 0..) |*aggregate, index| {
                if (!views.extreme(aggregate.function)) continue;
                defer m += 1;
                const slot: u8 = @intCast(index);
                const member = &self.member_scratch(view.id, slot, id).member;
                if (value) |row| {
                    if (member.timestamp == 0) {
                        assert(TimestampRange.valid(timestamp + m));
                        member.timestamp = timestamp + m;
                    }
                    const group_key = views.group_key(definition, row);
                    member.flags.present = true;
                    member.group_key = group_key;
                    member.value = std.mem.toBytes(std.mem.nativeToLittle(
                        i128,
                        views.field_integer(aggregate.field, row),
                    ));
                    member.position = nerva.member_order(
                        views.member_order_prefix(view.id, slot, &group_key),
                        views.field_ordered(aggregate.field, row),
                    );
                } else {
                    member.flags.present = false;
                    member.group_key = @splat(0);
                    member.value = @splat(0);
                    member.position = 0;
                }
            }
        }

        /// The member's state in this op, from the groove the first time.
        fn member_scratch(self: *StateMachine, view_id: u64, slot: u8, id: u64) *MemberScratch {
            const key = nerva.member_key(view_id, slot, id);
            const entry = self.members_scratch.getOrPutAssumeCapacity(key);
            if (!entry.found_existing) {
                const stored: ?Member = switch (self.forest.grooves.members.get(key)) {
                    .found_object => |member| member,
                    .not_found => null,
                };
                entry.value_ptr.* = .{
                    .member = stored orelse .{
                        .key = key,
                        .position = 0,
                        .timestamp = 0, // Assigned when it first joins a group.
                        .view_id = @intCast(view_id),
                        .slot = slot,
                        .flags = .{},
                        .group_key = @splat(0),
                        .value = @splat(0),
                    },
                    .stored = stored,
                };
                self.members_touched.appendAssumeCapacity(key);
            }
            return entry.value_ptr;
        }

        /// Adds the row to, or removes it from, its group of `view` (count and sums), in the op's
        /// scratch groups. `views_finish` then settles `min` and `max`, the view's hash and group
        /// count, and writes the groups back. `timestamp` is for a group created now.
        fn group_change(
            self: *StateMachine,
            view: *View,
            value: *const [nerva.value_size]u8,
            sign: enum { add, remove },
            timestamp: u64,
        ) void {
            if (view.state == .failed) return; // An earlier collision.
            const key = views.group_key(&view.definition, value);
            const tree_key = views.group_tree_key(view.id, &key);
            const scratch = self.group_scratch(tree_key, &key);
            const group = &scratch.group;
            if (!std.mem.eql(u8, &group.group_key, &key)) {
                // Two group keys hashed alike: every replica fails the view at this op.
                log.warn("view {}: group hash collision; the view fails", .{view.id});
                view.state = .failed;
                return;
            }
            if (group.timestamp == 0) {
                // Created now: a row leaves only a group it is counted in.
                assert(scratch.stored == null);
                assert(sign == .add);
                assert(TimestampRange.valid(timestamp));
                group.timestamp = timestamp;
            }

            views.group_apply(&view.definition, group, value, switch (sign) {
                .add => .add,
                .remove => .remove,
            });
        }

        /// The group's state in this op, from the groove the first time.
        fn group_scratch(
            self: *StateMachine,
            tree_key: u128,
            key: *const [nerva.group_key_size_max]u8,
        ) *GroupScratch {
            const entry = self.groups_scratch.getOrPutAssumeCapacity(tree_key);
            if (!entry.found_existing) {
                const stored: ?Group = switch (self.forest.grooves.groups.get(tree_key)) {
                    .found_object => |group| group,
                    .not_found => null,
                };
                entry.value_ptr.* = .{
                    .group = stored orelse .{
                        .key = tree_key,
                        .timestamp = 0, // Assigned when a row first joins it.
                        .count = 0,
                        .group_key = key.*,
                        .sums = @splat(@splat(0)),
                    },
                    .stored = stored,
                };
                self.groups_touched.appendAssumeCapacity(tree_key);
            }
            return entry.value_ptr;
        }

        /// Ends an op that may have changed views (commit, pulse): settles the `min` and `max`
        /// of every group it touched, then writes back its groups, members and views, each
        /// once, with their versions (N62).
        fn views_finish(self: *StateMachine, op: u64) void {
            self.views_finish_groups(op);
            self.views_finish_views(op);
        }

        fn views_finish_groups(self: *StateMachine, op: u64) void {
            assert(op < 1 << nerva.version_op_bits);
            self.extremes_gather();
            self.extremes_settle();
            self.groups_store(op);
            self.members_store();
            self.extreme_counted.clearRetainingCapacity();
            self.extremes_scratch.clearRetainingCapacity();
            self.extreme_scans.clearRetainingCapacity();
            self.extreme_scan_index.clearRetainingCapacity();
            self.extreme_scans_done = 0;
            self.extreme_members_count = 0;
        }

        fn views_finish_views(self: *StateMachine, op: u64) void {
            self.views_store(op);
            assert(self.version_timestamp <= self.version_timestamp_max + 1);
        }

        /// From the members the op touched: per group and slot, the best value it brought in,
        /// and whether it took away the member holding the group's value as stored.
        fn extremes_gather(self: *StateMachine) void {
            assert(self.extremes_scratch.count() == 0);
            for (self.members_touched.items) |key| {
                const scratch = self.members_scratch.getPtr(key).?;
                const view = &self.views_op[scratch.member.view_id - 1];
                if (view.state == .failed) continue;
                const slot = scratch.member.slot;
                const function = view.definition.aggregates[slot].function;
                assert(views.extreme(function));

                if (scratch.stored) |*stored| {
                    if (stored.flags.present) {
                        const group_key = views.group_tree_key(view.id, &stored.group_key);
                        // The row left its group as stored, so the op touched the group.
                        const group = self.groups_scratch.getPtr(group_key).?;
                        const group_stored = group.stored.?;
                        assert(group_stored.count > 0);
                        if (stdx.equal_bytes([16]u8, &stored.value, &group_stored.sums[slot])) {
                            self.extreme_scratch(group_key, slot).stored_left = true;
                        }
                    }
                }
                if (scratch.member.flags.present) {
                    const group_key = views.group_tree_key(view.id, &scratch.member.group_key);
                    const extreme = self.extreme_scratch(group_key, slot);
                    extreme.best = extreme_better(
                        function,
                        extreme.best,
                        std.mem.readInt(i128, &scratch.member.value, .little),
                    );
                }
            }
        }

        fn extreme_scratch(self: *StateMachine, group: u128, slot: u8) *ExtremeScratch {
            const entry = self.extremes_scratch.getOrPutAssumeCapacity(.{
                .group = group,
                .slot = slot,
            });
            if (!entry.found_existing) entry.value_ptr.* = .{};
            return entry.value_ptr;
        }

        fn extreme_better(function: nerva.AggregateFunction, best: ?i128, value: i128) i128 {
            const current = best orelse return value;
            return switch (function) {
                .min => @min(current, value),
                .max => @max(current, value),
                else => unreachable,
            };
        }

        /// Sets every `min` and `max` slot of the groups the op touched: the best of the members
        /// it brought in and the members it did not touch. Those are represented by the value as
        /// stored, unless the op took away the member holding it: then by the first untouched
        /// member of the order, as prefetched (`prefetch_extreme_scans`).
        fn extremes_settle(self: *StateMachine) void {
            for (self.groups_touched.items) |group_key| {
                const scratch = self.groups_scratch.getPtr(group_key).?;
                const view = &self.views_op[@as(usize, @intCast(group_key >> 64)) - 1];
                const definition = &view.definition;
                for (definition.aggregates[0..definition.aggregate_count], 0..) |*aggregate, i| {
                    if (view.state == .failed) break;
                    if (!views.extreme(aggregate.function)) continue;
                    const slot: u8 = @intCast(i);
                    const group = &scratch.group;
                    if (group.count == 0) {
                        group.sums[slot] = @splat(0);
                        continue;
                    }
                    const extreme_key: ExtremeKey = .{ .group = group_key, .slot = slot };
                    const extreme = self.extremes_scratch.get(extreme_key);
                    var best: ?i128 = if (extreme) |e| e.best else null;
                    const stored_count = if (scratch.stored) |*stored| stored.count else 0;
                    if (stored_count > 0) {
                        const stored = &scratch.stored.?;
                        if (extreme == null or !extreme.?.stored_left) {
                            best = extreme_better(
                                aggregate.function,
                                best,
                                std.mem.readInt(i128, &stored.sums[slot], .little),
                            );
                        } else if (self.extreme_untouched(view, slot, group)) |value| {
                            best = extreme_better(aggregate.function, best, value);
                        }
                    }
                    if (view.state == .failed) break;
                    // The group is not empty: some member is in it.
                    group.sums[slot] = std.mem.toBytes(std.mem.nativeToLittle(i128, best.?));
                }
            }
        }

        /// The first member of the group's order of `slot`, as prefetched, that the op did not
        /// touch, or null if it touched them all. Fails the view on an order prefix collision.
        fn extreme_untouched(
            self: *StateMachine,
            view: *View,
            slot: u8,
            group: *const Group,
        ) ?i128 {
            const index = self.extreme_scan_index.get(.{ .group = group.key, .slot = slot }).?;
            const scan = &self.extreme_scans.items[index];
            assert(scan.read);
            // The member holding the group's value was in the order.
            assert(scan.count > 0);
            for (self.extreme_members[scan.start..][0..scan.count]) |*member| {
                assert(member.flags.present);
                if (member.view_id != view.id or member.slot != slot or
                    !std.mem.eql(u8, &member.group_key, &group.group_key))
                {
                    // Two groups' orders share a prefix: every replica fails the view here.
                    log.warn("view {}: member order collision; the view fails", .{view.id});
                    view.state = .failed;
                    return null;
                }
                if (self.members_scratch.contains(member.key)) continue;
                return std.mem.readInt(i128, &member.value, .little);
            }
            // Every member prefetched was touched: then they were all the slot had.
            assert(scan.count <= scan.removals_max);
            return null;
        }

        /// Writes back each group this op changed, once, in the order first touched, with its
        /// version at `op`, and keeps each view's hash and group count.
        fn groups_store(self: *StateMachine, op: u64) void {
            const groups = &self.forest.grooves.groups;
            for (self.groups_touched.items) |tree_key| {
                const scratch = self.groups_scratch.getPtr(tree_key).?;
                const group = &scratch.group;
                const view = &self.views_op[@as(usize, @intCast(tree_key >> 64)) - 1];
                const empty = std.mem.zeroes(Group);
                const stored = if (scratch.stored) |*stored| stored else &empty;

                views.hash_update(&view.hash, &views.group_digest(view.id, stored), .remove);
                views.hash_update(&view.hash, &views.group_digest(view.id, group), .add);
                if (stored.count == 0 and group.count > 0) view.group_count += 1;
                if (stored.count > 0 and group.count == 0) view.group_count -= 1;

                if (scratch.stored) |*group_stored| {
                    if (stdx.equal_bytes(Group, group_stored, group)) continue;
                    group.op = op;
                    groups.update(.{ .old = group_stored, .new = group });
                } else {
                    // Touched and left empty, never written.
                    if (group.timestamp == 0) continue;
                    group.op = op;
                    groups.insert(group);
                }
                self.forest.grooves.group_versions.insert(&.{
                    .version = nerva.group_version_key(tree_key, op),
                    .timestamp = self.version_timestamp_next(),
                    .op = op,
                    .key = tree_key,
                    .count = group.count,
                    .group_key = group.group_key,
                    .sums = group.sums,
                });
            }
            self.groups_touched.clearRetainingCapacity();
            self.groups_scratch.clearRetainingCapacity();
        }

        /// Writes back each member this op changed, once, in the order first touched.
        fn members_store(self: *StateMachine) void {
            const members = &self.forest.grooves.members;
            for (self.members_touched.items) |key| {
                const scratch = self.members_scratch.getPtr(key).?;
                if (scratch.stored) |*stored| {
                    if (!stdx.equal_bytes(Member, stored, &scratch.member)) {
                        members.update(.{ .old = stored, .new = &scratch.member });
                    }
                } else if (scratch.member.timestamp != 0) {
                    members.insert(&scratch.member);
                }
            }
            self.members_touched.clearRetainingCapacity();
            self.members_scratch.clearRetainingCapacity();
        }

        /// Stage 1 of `get_view`: scans the view's groups from the query's cursor.
        fn prefetch_view_groups(self: *StateMachine) void {
            assert(self.view_groups_count == null);
            const query = view_query(self.prefetch_input.?);
            const limit = view_query_limit(query) orelse return self.prefetch_finish();
            const view_id = self.view_query_id(query) orelse return self.prefetch_finish();

            const groups = &self.forest.grooves.groups;
            const scan = groups.scan_builder.scan_unique_key_range(
                .key,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                @as(u128, view_id) << 64 | query.group_hash_min,
                @as(u128, view_id) << 64 | std.math.maxInt(u64),
                .ascending,
            );
            self.groups_scan_lookup = GroupsScanLookup.init(groups, scan);
            self.groups_scan_lookup.read(self.view_groups[0 .. limit + 1], prefetch_view_groups_callback);
        }

        fn prefetch_view_groups_callback(
            scan_lookup: *GroupsScanLookup,
            results: []const Group,
        ) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("groups_scan_lookup", scan_lookup));
            assert(results.len == 0 or results.ptr == self.view_groups.ptr);
            self.view_groups_count = @intCast(results.len);
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.groups.scan_builder.reset();
            const query = view_query(self.prefetch_input.?);
            if (query.as_of == 0) return self.prefetch_finish();
            self.prefetch_view_version();
        }

        /// The last version at or before `as_of` (clamped: no version is newer than the read).
        fn view_query_as_of(query: *const ViewQuery, op: u64) u64 {
            assert(query.as_of != 0);
            return @min(query.as_of, op);
        }

        /// Stage 2 of `get_view` as of a past op (N62): the view's version then.
        fn prefetch_view_version(self: *StateMachine) void {
            const query = view_query(self.prefetch_input.?);
            const view_id = self.view_query_id(query).?;
            const as_of = view_query_as_of(query, self.prefetch_op);
            const view_versions = &self.forest.grooves.view_versions;
            const scan = view_versions.scan_builder.scan_prefix_range(
                .version,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                nerva.view_version_key(view_id, 0),
                nerva.view_version_key(view_id, as_of),
                .descending,
            );
            self.view_versions_scan_lookup = ViewVersionsScanLookup.init(view_versions, scan);
            self.view_versions_scan_lookup.read(
                (&self.view_version_buffer)[0..1],
                prefetch_view_version_callback,
            );
        }

        fn prefetch_view_version_callback(
            scan_lookup: *ViewVersionsScanLookup,
            results: []const ViewVersion,
        ) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("view_versions_scan_lookup", scan_lookup));
            assert(results.len <= 1);
            self.view_version = if (results.len == 1) results[0] else null;
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.view_versions.scan_builder.reset();
            self.group_versions_done = 0;
            self.group_version_scans = 0;
            self.prefetch_group_version_next();
        }

        /// Stage 3 of `get_view` as of a past op: each listed group's version then. A group no
        /// op has changed since is as it was (N66); any other takes a scan, and the page ends
        /// before the group that would take more than `view_as_of_scans_max`.
        fn prefetch_group_version_next(self: *StateMachine) void {
            const query = view_query(self.prefetch_input.?);
            const limit = view_query_limit(query).?;
            const listed = @min(self.view_groups_count.?, limit);
            const as_of = view_query_as_of(query, self.prefetch_op);
            self.view_groups_listed = listed;
            if (self.view_version == null) return self.prefetch_finish();
            while (self.group_versions_done < listed) : (self.group_versions_done += 1) {
                const group = &self.view_groups[self.group_versions_done];
                assert(group.op > 0);
                if (group.op > as_of) {
                    if (self.group_version_scans < view_as_of_scans_max) break;
                    self.view_groups_listed = self.group_versions_done;
                    return self.prefetch_finish();
                }
                self.group_versions[self.group_versions_done] = .{
                    .version = nerva.group_version_key(group.key, group.op),
                    .timestamp = group.timestamp,
                    .op = group.op,
                    .key = group.key,
                    .count = group.count,
                    .group_key = group.group_key,
                    .sums = group.sums,
                };
            } else return self.prefetch_finish();
            const group = &self.view_groups[self.group_versions_done];
            const group_versions = &self.forest.grooves.group_versions;
            const scan = group_versions.scan_builder.scan_prefix_range(
                .version,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                nerva.group_version_key(group.key, 0),
                nerva.group_version_key(group.key, as_of),
                .descending,
            );
            self.group_versions_scan_lookup = GroupVersionsScanLookup.init(group_versions, scan);
            self.group_versions_scan_lookup.read(
                (&self.group_version_buffer)[0..1],
                prefetch_group_version_callback,
            );
        }

        fn prefetch_group_version_callback(
            scan_lookup: *GroupVersionsScanLookup,
            results: []const GroupVersion,
        ) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("group_versions_scan_lookup", scan_lookup));
            assert(results.len <= 1);
            const group = &self.view_groups[self.group_versions_done];
            if (results.len == 1) assert(results[0].key == group.key);
            self.group_versions[self.group_versions_done] =
                if (results.len == 1) results[0] else null;
            self.group_versions_done += 1;
            self.group_version_scans += 1;
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.group_versions.scan_builder.reset();
            self.prefetch_group_version_next();
        }

        fn view_query(body: []align(constants.cache_line_size) const u8) *const ViewQuery {
            assert(body.len == @sizeOf(ViewQuery));
            return @alignCast(std.mem.bytesAsValue(ViewQuery, body[0..@sizeOf(ViewQuery)]));
        }

        /// The effective limit of a valid query, or null if the query is invalid.
        fn view_query_limit(query: *const ViewQuery) ?u32 {
            if (query.limit == 0) return null;
            if (!stdx.zeroed(&query.reserved)) return null;
            // By id or by name, not both.
            if (query.view_id != 0 and !stdx.zeroed(&query.name)) return null;
            return @min(query.limit, view_groups_limit_max);
        }

        /// The id of the view a valid query names, or null if no such view is declared.
        fn view_query_id(self: *const StateMachine, query: *const ViewQuery) ?u64 {
            if (query.view_id != 0) {
                return if (query.view_id <= self.views_op_count) query.view_id else null;
            }
            const name_size = std.mem.indexOfScalar(u8, &query.name, 0) orelse query.name.len;
            const name = query.name[0..name_size];
            if (name.len == 0 or !stdx.zeroed(query.name[name_size..])) return null;
            for (self.views_op[0..self.views_op_count]) |*view| {
                if (std.mem.eql(u8, views.definition_name(&view.definition), name)) return view.id;
            }
            return null;
        }

        /// Stage 1 of `pulse`: scans the rows of the oldest building view's table from its
        /// cursor, then (stage 2) prefetches their groups.
        fn prefetch_backfill_rows(self: *StateMachine) void {
            assert(self.backfill_count == null);
            assert(self.backfill_view == null);
            const index = for (self.views_op[0..self.views_op_count], 0..) |*view, index| {
                if (view.state == .building) break index;
            } else return self.prefetch_backfill_records();
            self.backfill_view = @intCast(index);
            const view = &self.views_op[index];

            const rows = &self.forest.grooves.rows;
            const scan = rows.scan_builder.scan_unique_key_range(
                .key,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                nerva.row_key(view.definition.table, view.backfill_cursor),
                nerva.row_key(view.definition.table, std.math.maxInt(u64)),
                .ascending,
            );
            self.rows_scan_lookup = RowsScanLookup.init(rows, scan);
            self.rows_scan_lookup.read(self.backfill_rows, prefetch_backfill_rows_callback);
        }

        fn prefetch_backfill_rows_callback(
            scan_lookup: *RowsScanLookup,
            results: []const Row,
        ) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("rows_scan_lookup", scan_lookup));
            assert(results.len == 0 or results.ptr == self.backfill_rows.ptr);
            self.backfill_count = @intCast(results.len);
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.rows.scan_builder.reset();

            // Stage 2: the groups of the rows this pulse adds.
            const view = &self.views_op[self.backfill_view.?];
            const groups = &self.forest.grooves.groups;
            groups.prefetch_setup(self.prefetch_snapshot.?);
            const count = @min(results.len, self.backfill_rows_max(view));
            for (results[0..count]) |*row| {
                if (row.flags.deleted) continue;
                if (!views.row_matches(&view.definition, &row.value)) continue;
                const key = views.group_key(&view.definition, &row.value);
                groups.prefetch_enqueue(.{ .key = views.group_tree_key(view.id, &key) });
            }
            groups.prefetch(prefetch_groups_callback, &self.groups_prefetch_context);
        }

        fn execute_get_view(
            self: *StateMachine,
            op: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            defer {
                self.view_groups_count = null;
                self.view_version = null;
                self.group_versions_done = 0;
                self.group_version_scans = 0;
                self.view_groups_listed = 0;
            }
            const query = view_query(message_body_used);
            const limit = view_query_limit(query) orelse {
                assert(self.view_groups_count == null);
                return 0;
            };
            const records = stdx.bytes_as_slice(.inexact, ViewRecord, output_buffer);
            const header = &records[0];
            header.* = std.mem.zeroes(ViewRecord);
            header.kind = .header;
            header.view_id = query.view_id;
            header.op = op;
            const view_id = self.view_query_id(query) orelse {
                assert(self.view_groups_count == null);
                header.state = .missing;
                return @sizeOf(ViewRecord);
            };
            header.view_id = view_id;

            const view = &self.views_op[view_id - 1];
            assert(view.id == view_id);
            header.declared_op = view.declared_op;
            const name = views.definition_name(&view.definition);
            @memcpy(header.group_key[0..name.len], name);
            const as_of = query.as_of != 0;
            if (as_of) {
                // As the op `as_of` left it (N62); missing if it was declared later.
                const version = self.view_version orelse {
                    header.state = .missing;
                    return @sizeOf(ViewRecord);
                };
                assert(version.op <= view_query_as_of(query, op));
                header.state = version.state;
                header.group_count = version.group_count;
                header.hash = version.hash;
            } else {
                header.state = view.state;
                header.group_count = view.group_count;
                header.hash = view.hash;
            }

            const scanned = self.view_groups[0..self.view_groups_count.?];
            assert(scanned.len <= limit + 1);
            // As of an op, the scans may have ended the page early.
            const listed = if (as_of) self.view_groups_listed else @min(scanned.len, limit);
            assert(listed <= @min(scanned.len, limit));
            if (as_of) assert(self.group_versions_done == listed);
            var count: usize = 0;
            for (scanned[0..listed], 0..) |*group_now, index| {
                assert(group_now.key >> 64 == view.id);
                const group: Group = if (as_of) group: {
                    // Not yet created at `as_of`.
                    const version = self.group_versions[index] orelse continue;
                    assert(version.key == group_now.key);
                    break :group .{
                        .key = version.key,
                        .timestamp = group_now.timestamp,
                        .count = version.count,
                        .group_key = version.group_key,
                        .sums = version.sums,
                    };
                } else group_now.*;
                // Empty groups are kept (their history stays readable), but not listed.
                if (group.count == 0) continue;
                const record = &records[1 + count];
                record.* = std.mem.zeroes(ViewRecord);
                record.kind = .group;
                record.view_id = view.id;
                record.group_hash = @truncate(group.key);
                record.count = group.count;
                record.group_key = group.group_key;
                record.sums = group.sums;
                count += 1;
            }
            if (scanned.len > listed) {
                header.flags.more = true;
                header.cursor = @truncate(scanned[listed].key);
            }
            return (1 + count) * @sizeOf(ViewRecord);
        }

        fn execute_declare_view(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            assert(message_body_used.len == @sizeOf(ViewDefinition));
            const definition: *const ViewDefinition = @alignCast(
                std.mem.bytesAsValue(ViewDefinition, message_body_used[0..@sizeOf(ViewDefinition)]),
            );
            const result: *DeclareResult = @alignCast(
                std.mem.bytesAsValue(DeclareResult, output_buffer[0..@sizeOf(DeclareResult)]),
            );
            self.versions_begin(.declare_view, timestamp - self.prepare_delta(.declare_view, &.{}));
            result.* = self.view_declare(op, timestamp, definition, .building);
            if (result.status == .created) {
                self.view_version_insert(&self.views_op[result.view_id - 1], op);
            }
            self.views_store(op);
            return @sizeOf(DeclareResult);
        }

        /// Declares a view in `state`: `building` (pulses add the rows already written, none
        /// possibly), or `ready` when restoring one whose table has no rows (N80).
        fn view_declare(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            definition: *const ViewDefinition,
            state: nerva.ViewState,
        ) DeclareResult {
            assert(state == .building or (state == .ready and self.restoring));
            if (views.definition_validate(definition)) |status| {
                return .{ .status = status, .view_id = 0, .op = 0 };
            }
            const name = views.definition_name(definition);
            var table_views: u32 = 0;
            var table_extremes: u32 = views.extreme_count(definition);
            for (self.views_op[0..self.views_op_count]) |*view| {
                if (std.mem.eql(u8, views.definition_name(&view.definition), name)) {
                    if (stdx.equal_bytes(ViewDefinition, &view.definition, definition)) {
                        return .{ .status = .exists, .view_id = view.id, .op = view.declared_op };
                    }
                    return .{ .status = .different, .view_id = 0, .op = 0 };
                }
                if (view.definition.table == definition.table) {
                    table_views += 1;
                    table_extremes += views.extreme_count(&view.definition);
                }
            }
            // Adds move conserved fields, and must not move rows between groups (N75).
            const ledger_index = &self.ledger_index;
            for (definition.where[0..definition.where_count]) |*clause| {
                const field = clause.field;
                if (ledger_index.touches(definition.table, field.offset, field.size)) {
                    return .{ .status = .ledger_field, .view_id = 0, .op = 0 };
                }
            }
            for (definition.group_by[0..definition.group_by_count]) |field| {
                if (ledger_index.touches(definition.table, field.offset, field.size)) {
                    return .{ .status = .ledger_field, .view_id = 0, .op = 0 };
                }
            }
            if (self.views_op_count == nerva.views_max) {
                return .{ .status = .views_full, .view_id = 0, .op = 0 };
            }
            if (table_views == nerva.views_per_table_max) {
                return .{ .status = .table_views_full, .view_id = 0, .op = 0 };
            }
            if (table_extremes > self.table_extremes_max()) {
                return .{ .status = .table_extremes_full, .view_id = 0, .op = 0 };
            }

            const index = self.views_op_count;
            const view: View = .{
                .id = index + 1,
                .timestamp = timestamp,
                .declared_op = op,
                .backfill_cursor = 0,
                .group_count = 0,
                .state = state,
                .hash = @splat(0),
                .definition = definition.*,
            };
            self.forest.grooves.views.insert(&view);
            self.views_op[index] = view;
            self.views_stored[index] = view;
            self.views_op_count += 1;
            self.view_count = self.views_op_count;
            return .{ .status = .created, .view_id = view.id, .op = op };
        }

        /// The rows one pulse adds to `view`: each may write a group and a member in each of the
        /// view's `min` and `max` slots, within the op's limits for both.
        /// The `min` and `max` slots a table's views may hold between them: also no more than
        /// one op's member budget, since a write takes a member in each slot (#68). Only
        /// configurations with tiny requests (the VOPR's) are below `view_extremes_per_table_max`.
        fn table_extremes_max(self: *const StateMachine) u32 {
            return @min(nerva.view_extremes_per_table_max, self.member_writes_limit);
        }

        fn backfill_rows_max(self: *const StateMachine, view: *const View) u32 {
            const extremes = @max(1, views.extreme_count(&view.definition));
            const rows = @min(self.group_writes_limit, @divFloor(self.member_writes_limit, extremes));
            assert(rows > 0);
            return rows;
        }

        /// Adds the rows the pulse scanned to the building view's groups. Replies nothing.
        fn execute_pulse(self: *StateMachine, op: u64, timestamp: u64) usize {
            defer {
                self.backfill_view = null;
                self.backfill_count = null;
            }
            const index = self.backfill_view orelse {
                assert(self.view_building == false);
                return self.execute_pulse_index(timestamp);
            };
            const view = &self.views_op[index];
            assert(view.state == .building);
            const scanned = self.backfill_rows[0..self.backfill_count.?];
            const count = @min(scanned.len, self.backfill_rows_max(view));
            // Each row takes an entry's block of timestamps (`entry_timestamps`).
            const timestamp_base = timestamp - self.prepare_delta(.pulse, &.{});
            self.versions_begin(.pulse, timestamp_base);
            for (scanned[0..count], 0..) |*row, k| {
                const id: u64 = @truncate(row.key);
                assert(row.key >> 64 == view.definition.table);
                assert(id >= view.backfill_cursor);
                if (row.flags.deleted) continue;
                const block = timestamp_base + k * entry_timestamps;
                self.view_row_changed(
                    view,
                    id,
                    null,
                    &row.value,
                    block + 1,
                    block + 1 + nerva.views_per_table_max,
                );
            }
            self.views_finish_groups(op);
            if (view.state == .building) {
                if (scanned.len > count) {
                    view.backfill_cursor = @truncate(scanned[count].key);
                } else {
                    view.state = .ready;
                }
            }
            self.views_finish_views(op);
            return 0;
        }

        // ---- Restore (N80) ----
        //
        // `nerva import` rebuilds a cluster's state from another release's export: every change
        // at its recorded op and timestamp, and the declarations of views and ledgers at theirs.
        // In process only: never an `Operation`, so no client can reach it. Everything derived
        // (views' groups, members and versions; the ledger index) is recomputed by this code, as
        // a commit computes it, while the rules a commit checks are not: the history being
        // restored already passed them. Deterministic, so every replica's file is identical.

        pub const RestoreError = error{
            /// The op's changes touch more view groups or members than one op may.
            ViewsBudget,
            /// A delete of a row that is not there, or changes out of op or timestamp order.
            HistoryInvalid,
            /// A view or ledger this state machine does not declare as the history says.
            DeclarationRefused,
        };

        /// The most changes one op may restore (one transaction's worth of entries).
        pub fn restore_changes_max(self: *const StateMachine) u32 {
            return Operation.commit.event_max(self.batch_size_limit);
        }

        /// Encodes one op's changes as the single batch of entries `restore_prefetch` reads.
        /// Returns the body's size.
        pub fn restore_entries(
            self: *const StateMachine,
            changes: []const Change,
            body: []align(constants.cache_line_size) u8,
        ) usize {
            assert(changes.len > 0);
            assert(changes.len <= self.restore_changes_max());
            var encoder = MultiBatchEncoder.init(body, .{ .element_size = @sizeOf(Entry) });
            const entries = stdx.bytes_as_slice(.inexact, Entry, encoder.writable().?);
            assert(entries.len >= changes.len);
            for (changes, entries[0..changes.len]) |*change, *entry| {
                entry.* = restore_entry(change);
            }
            encoder.add(@intCast(changes.len * @sizeOf(Entry)));
            const size = encoder.finish();
            assert(size <= self.batch_size_limit);
            return size;
        }

        /// The entry a commit would have taken to write `change`, as admission and prefetch see
        /// it: an add was recorded as the put of its row's new value.
        fn restore_entry(change: *const Change) Entry {
            assert(change.kind == .put or change.kind == .delete);
            assert(change.kind == .put or stdx.zeroed(&change.value));
            return .{
                .id = change.id,
                .table = change.table,
                .kind = if (change.kind == .put) .put else .delete,
                .op_seen = 0,
                .value = change.value,
            };
        }

        /// Prefetches one op of a restore: `commit` with `restore_entries`' body, `declare_view`
        /// or `declare_ledger` with the definition. Then call the matching `restore_*`.
        pub fn restore_prefetch(
            self: *StateMachine,
            callback: *const fn (*StateMachine) void,
            op: u64,
            operation: Operation,
            body: []align(constants.cache_line_size) const u8,
        ) void {
            assert(!self.restoring);
            assert(operation == .commit or operation == .declare_view or
                operation == .declare_ledger);
            self.restoring = true;
            self.prefetch(callback, op, op, operation, body);
        }

        /// Stage 3 of a view's restore: whether its table has a row yet.
        fn prefetch_restore_table(self: *StateMachine) void {
            assert(self.restoring);
            assert(self.restore_table_rows == null);
            const definition: *const ViewDefinition = @alignCast(std.mem.bytesAsValue(
                ViewDefinition,
                self.prefetch_input.?[0..@sizeOf(ViewDefinition)],
            ));
            if (definition.table == 0) {
                self.restore_table_rows = false; // Refused by `view_declare`.
                return self.prefetch_finish();
            }
            const rows = &self.forest.grooves.rows;
            const scan = rows.scan_builder.scan_unique_key_range(
                .key,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                self.prefetch_snapshot.?,
                nerva.row_key(definition.table, 0),
                nerva.row_key(definition.table, std.math.maxInt(u64)),
                .ascending,
            );
            self.rows_scan_lookup = RowsScanLookup.init(rows, scan);
            self.rows_scan_lookup.read(self.backfill_rows[0..1], prefetch_restore_table_callback);
        }

        fn prefetch_restore_table_callback(
            scan_lookup: *RowsScanLookup,
            results: []const Row,
        ) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("rows_scan_lookup", scan_lookup));
            assert(results.len <= 1);
            self.restore_table_rows = results.len > 0;
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.rows.scan_builder.reset();
            self.prefetch_finish();
        }

        /// Writes one op's changes with their recorded timestamps, and keeps the views as a
        /// commit does. `changes` are `restore_entries`' (prefetched), in timestamp order.
        /// Versions take timestamps from `timestamp_next`, the importer's counter, which it
        /// advances.
        pub fn restore_changes(
            self: *StateMachine,
            op: u64,
            changes: []const Change,
            timestamp_next: *u64,
        ) RestoreError!void {
            assert(self.restoring);
            defer self.restoring = false;
            assert(changes.len > 0);
            assert(self.groups_touched.items.len == 0);
            assert(self.members_touched.items.len == 0);
            // One batch: admission decided for all of it.
            if (self.view_txn_busy.isSet(0)) {
                assert(self.view_txn_too_large.isSet(0));
                self.views_finish_abandon();
                return error.ViewsBudget;
            }
            for (changes, 0..) |*change, index| {
                if (change.op != op) return error.HistoryInvalid;
                if (!TimestampRange.valid(change.timestamp + entry_timestamps - 1)) {
                    return error.HistoryInvalid;
                }
                // Each change's block of timestamps holds the groups and members it creates.
                if (index > 0 and
                    change.timestamp < changes[index - 1].timestamp + entry_timestamps)
                {
                    return error.HistoryInvalid;
                }
                if (change.table == 0) return error.HistoryInvalid;
                // A key's row is a put of a `CommitKey` (P123): what `commit_key_failure`
                // asserts of it.
                if (change.table == nerva.table_commit_keys) {
                    if (change.kind != .put) return error.HistoryInvalid;
                    const stored = std.mem.bytesToValue(CommitKey, &change.value);
                    if (stored.key == 0 or !stdx.zeroed(&stored.reserved)) {
                        return error.HistoryInvalid;
                    }
                }
                switch (change.kind) {
                    .put => {},
                    .delete => if (!stdx.zeroed(&change.value)) return error.HistoryInvalid,
                    .end => return error.HistoryInvalid,
                }
            }

            self.version_timestamp = timestamp_next.*;
            self.version_timestamp_max = timestamp_next.* + self.versions_reserve(.commit) - 1;
            assert(TimestampRange.valid(self.version_timestamp_max));
            for (changes) |*change| {
                const entry = WideEntry.from_entry(&restore_entry(change));
                if (change.kind == .delete) {
                    // Only a live row's delete is recorded. Checked as the op goes, since an
                    // earlier change of the op may have written the row: an error here leaves
                    // the op half applied, and the state machine must be discarded.
                    const live = switch (self.forest.grooves.rows.get(
                        nerva.row_key(change.table, change.id),
                    )) {
                        .found_object => |row| !row.flags.deleted,
                        .not_found => false,
                    };
                    if (!live) return error.HistoryInvalid;
                }
                if (change.table == nerva.table_commit_keys) {
                    // Written once: checked as the op goes, as for deletes.
                    if (self.row_version(nerva.row_key(change.table, change.id)) != 0) {
                        return error.HistoryInvalid;
                    }
                }
                switch (change.kind) {
                    .put => self.row_put(op, change.timestamp, &entry, &change.value),
                    .delete => self.row_delete(op, change.timestamp, &entry),
                    .end => unreachable,
                }
            }
            self.views_finish(op);
            timestamp_next.* = self.version_timestamp;
        }

        /// Forgets the scratch an op's prefetch left, when the op is not committed.
        fn views_finish_abandon(self: *StateMachine) void {
            assert(self.groups_touched.items.len == 0);
            self.extreme_counted.clearRetainingCapacity();
            self.extreme_scans.clearRetainingCapacity();
            self.extreme_scan_index.clearRetainingCapacity();
            self.extreme_scans_done = 0;
            self.extreme_members_count = 0;
        }

        /// Declares a view at its recorded op with id `view_id`: `ready` if its table had no
        /// rows (later changes keep it exact, as commits did), else `building`, for the new
        /// cluster's pulses to backfill.
        pub fn restore_view(
            self: *StateMachine,
            op: u64,
            definition: *const ViewDefinition,
            view_id: u64,
            timestamp_next: *u64,
        ) RestoreError!void {
            assert(self.restoring);
            defer self.restoring = false;
            const table_rows = self.restore_table_rows.?;
            self.restore_table_rows = null;

            self.version_timestamp = timestamp_next.* + 1;
            self.version_timestamp_max = timestamp_next.* + 1;
            const result = self.view_declare(
                op,
                timestamp_next.*,
                definition,
                if (table_rows) .building else .ready,
            );
            if (result.status != .created or result.view_id != view_id) {
                log.warn("restore: view {} at op {}: {s} (id {})", .{
                    view_id,
                    op,
                    @tagName(result.status),
                    result.view_id,
                });
                return error.DeclarationRefused;
            }
            self.view_version_insert(&self.views_op[view_id - 1], op);
            self.views_store(op);
            timestamp_next.* = self.version_timestamp;
        }

        /// Declares a ledger at its recorded op.
        pub fn restore_ledger(
            self: *StateMachine,
            op: u64,
            definition: *const LedgerDefinition,
            timestamp_next: *u64,
        ) RestoreError!void {
            assert(self.restoring);
            defer self.restoring = false;
            const result = self.ledger_declare(op, timestamp_next.*, definition);
            if (result.status != .created) {
                log.warn("restore: ledger {} at op {}: {s}", .{
                    definition.id,
                    op,
                    @tagName(result.status),
                });
                return error.DeclarationRefused;
            }
            timestamp_next.* += 1;
        }

        /// The views, as the last op restored left them.
        pub fn restore_views(self: *const StateMachine) []const View {
            return self.views_op[0..self.views_op_count];
        }

        /// The ledgers, in declaration order, as the last op restored left them.
        pub fn restore_ledgers(self: *const StateMachine) []const Ledger {
            return self.ledgers_op[0 .. self.ledger_count orelse 0];
        }

        /// The ledgers' conserved fields, for totals.
        pub fn restore_ledger_index(self: *const StateMachine) *const ledgers.Index {
            return &self.ledger_index;
        }

        /// Reads the rows with keys from `key_min`, tombstones included, in key order, up to
        /// `rows.len` of them, as of `snapshot`: the importer's checks.
        pub fn restore_scan_rows(
            self: *StateMachine,
            callback: *const fn (*StateMachine, []const Row) void,
            snapshot: u64,
            key_min: u128,
            rows: []Row,
        ) void {
            assert(self.restore_scan_callback == null);
            assert(rows.len > 0);
            self.restore_scan_callback = callback;
            const groove = &self.forest.grooves.rows;
            const scan = groove.scan_builder.scan_unique_key_range(
                .key,
                self.forest.scan_buffer_pool.acquire_assume_capacity(),
                snapshot,
                key_min,
                std.math.maxInt(u128),
                .ascending,
            );
            self.rows_scan_lookup = RowsScanLookup.init(groove, scan);
            self.rows_scan_lookup.read(rows, restore_scan_rows_callback);
        }

        fn restore_scan_rows_callback(scan_lookup: *RowsScanLookup, results: []const Row) void {
            const self: *StateMachine =
                @alignCast(@fieldParentPtr("rows_scan_lookup", scan_lookup));
            self.forest.scan_buffer_pool.reset();
            self.forest.grooves.rows.scan_builder.reset();
            const callback = self.restore_scan_callback.?;
            self.restore_scan_callback = null;
            callback(self, results);
        }

        fn execute_get_changes(
            self: *StateMachine,
            op: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            defer self.changes_scan_count = null;
            const filter = changes_filter(message_body_used);
            const limit = changes_limit(filter) orelse {
                assert(self.changes_scan_count == null);
                return 0;
            };
            const count = self.changes_scan_count.?;
            assert(count <= limit);

            const results = stdx.bytes_as_slice(.inexact, Change, output_buffer)[0 .. count + 1];
            stdx.copy_disjoint(
                .exact,
                Change,
                results[0..count],
                self.changes_scan_buffer[0..count],
            );

            const more = count == limit;
            results[count] = .{
                .id = 0,
                .table = 0,
                .kind = .end,
                .flags = .{ .more = more },
                .op = if (more) 0 else op,
                .timestamp = if (count == 0)
                    filter.timestamp_min
                else
                    results[count - 1].timestamp + 1,
                .value = @splat(0),
            };
            return (count + 1) * @sizeOf(Change);
        }

        fn execute_get_history(
            self: *StateMachine,
            op: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            defer self.changes_scan_count = null;
            const filter = history_filter(message_body_used);
            const limit = history_limit(filter) orelse {
                assert(self.changes_scan_count == null);
                return 0;
            };
            const count = self.changes_scan_count.?;
            assert(count <= limit);
            const scanned = self.changes_scan_buffer[0..count];

            const results = stdx.bytes_as_slice(.inexact, Change, output_buffer)[0 .. count + 1];
            var returned: u32 = 0;
            for (scanned, 0..) |*change, index| {
                assert(change.table == filter.table);
                assert(change.id == filter.id);
                assert(change.kind == .put or change.kind == .delete);
                assert(change.op < op);
                if (filter.timestamp_max != 0) assert(change.timestamp <= filter.timestamp_max);
                if (index > 0) {
                    assert(change.timestamp < scanned[index - 1].timestamp);
                    assert(change.op <= scanned[index - 1].op);
                }
                if (change.op > filter.op_max) {
                    // Newest first: changes after `op_max` all come before the first returned.
                    assert(returned == 0);
                    continue;
                }
                results[returned] = change.*;
                returned += 1;
            }

            const more = count == limit;
            results[returned] = .{
                .id = 0,
                .table = 0,
                .kind = .end,
                .flags = .{ .more = more },
                .op = if (more) 0 else op,
                .timestamp = if (more) scanned[count - 1].timestamp - 1 else 0,
                .value = @splat(0),
            };
            return (returned + 1) * @sizeOf(Change);
        }

        fn execute_get_record_changes(
            self: *StateMachine,
            op: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            defer self.record_changes_scan_count = null;
            const filter = changes_filter(message_body_used);
            const limit = record_changes_limit(filter) orelse {
                assert(self.record_changes_scan_count == null);
                return 0;
            };
            const count = self.record_changes_scan_count.?;
            assert(count <= limit);

            const results =
                stdx.bytes_as_slice(.inexact, RecordChange, output_buffer)[0 .. count + 1];
            stdx.copy_disjoint(
                .exact,
                RecordChange,
                results[0..count],
                self.record_changes_scan_buffer[0..count],
            );

            const more = count == limit;
            results[count] = .{
                .id = 0,
                .table = 0,
                .kind = .end,
                .flags = .{ .more = more },
                .op = if (more) 0 else op,
                .timestamp = if (count == 0)
                    filter.timestamp_min
                else
                    results[count - 1].timestamp + 1,
                .value = @splat(0),
            };
            return (count + 1) * @sizeOf(RecordChange);
        }

        fn execute_get_record_history(
            self: *StateMachine,
            op: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            defer self.record_changes_scan_count = null;
            const filter = record_history_filter(message_body_used);
            const limit = record_history_limit(filter) orelse {
                assert(self.record_changes_scan_count == null);
                return 0;
            };
            const count = self.record_changes_scan_count.?;
            assert(count <= limit);
            const scanned = self.record_changes_scan_buffer[0..count];

            const results =
                stdx.bytes_as_slice(.inexact, RecordChange, output_buffer)[0 .. count + 1];
            var returned: u32 = 0;
            for (scanned, 0..) |*change, index| {
                assert(change.table == filter.table);
                assert(change.kind == .put or change.kind == .delete);
                assert(change.op < op);
                if (filter.timestamp_max != 0) assert(change.timestamp <= filter.timestamp_max);
                if (index > 0) {
                    assert(change.timestamp < scanned[index - 1].timestamp);
                    assert(change.op <= scanned[index - 1].op);
                }
                // The key's history: another id whose key collides never wrote it (refused).
                assert(change.id == filter.id);
                if (change.op > filter.op_max) {
                    assert(returned == 0);
                    continue;
                }
                results[returned] = change.*;
                returned += 1;
            }

            const more = count == limit;
            results[returned] = .{
                .id = 0,
                .table = 0,
                .kind = .end,
                .flags = .{ .more = more },
                .op = if (more) 0 else op,
                .timestamp = if (more) scanned[count - 1].timestamp - 1 else 0,
                .value = @splat(0),
            };
            return (returned + 1) * @sizeOf(RecordChange);
        }
    };
}
