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
const EntryResult = nerva.EntryResult;
const EntryStatus = nerva.EntryStatus;
const Add = nerva.Add;
const View = nerva.View;
const Group = nerva.Group;
const ViewDefinition = nerva.ViewDefinition;
const ViewQuery = nerva.ViewQuery;
const ViewRecord = nerva.ViewRecord;
const DeclareResult = nerva.DeclareResult;
const views = @import("views.zig");
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
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

        /// Timestamps a commit entry takes: its change, then one per view of its table, for a
        /// group the entry creates (N52).
        pub const entry_timestamps = 1 + nerva.views_per_table_max;
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
            assert(view_groups_limit_max > 0);
        }

        pub const Options = struct {
            batch_size_limit: u32,
            lsm_forest_compaction_block_count: u32 = Forest.Options.compaction_block_count_min,
            lsm_forest_node_count: u32,
            cache_entries_rows: u32 = cache_entries_rows_multiple,
            cache_entries_groups: u32 = GroupsGroove.ObjectsCache.Cache.value_count_max_multiple,
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
                .ignored = &[_][:0]const u8{ "count", "group_key", "sums", "reserved" },
                .optional = &[_][:0]const u8{},
                .derived = .{},
                .objects_cache = true,
            },
        );

        pub const Forest = ForestType(Storage, .{
            .rows = RowsGroove,
            .changes = ChangesGroove,
            .views = ViewsGroove,
            .groups = GroupsGroove,
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

        const ChangesScanTree = ScanTreeType(void, ChangesGroove.ObjectTree, Storage);
        const HistoryScanLookup = ScanLookupType(
            ChangesGroove,
            ChangesGroove.ScanBuilder.Scan,
            Storage,
        );

        /// The first write of a transaction that duplicates an earlier write's row.
        const WriteKey = struct { key: u128, index: u32 };

        const Failure = struct { index: u32, status: EntryStatus, op: u64, value: u64 = 0 };

        const GroupScratch = struct { group: Group, stored: ?Group };

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

        /// Scratch space for duplicate-write detection.
        write_keys: []WriteKey,
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
        /// obeys (N52).
        view_txn_busy: std.DynamicBitSetUnmanaged = .{},
        /// The op's distinct groups, as admitted so far (prefetch); looked up only.
        view_op_keys: std.AutoHashMapUnmanaged(u128, void) = .{},
        /// The keys the transaction being admitted added, to take back if it does not fit.
        view_txn_keys: std.ArrayListUnmanaged(u128) = .{},
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
            const groups_limit: u32 = @max(1, @divFloor(commit_entries_limit, 2));
            assert(groups_limit <= groups_per_op_max);
            const lookup_rows_limit = Operation.lookup_rows.event_max(options.batch_size_limit);
            assert(commit_entries_limit <= commit_entries_max);
            assert(lookup_rows_limit <= lookup_rows_max);

            self.* = .{
                .batch_size_limit = options.batch_size_limit,
                .group_writes_limit = groups_limit,
                .forest = undefined,
                .changes_scan_buffer = undefined,
                .write_keys = undefined,
                .backfill_rows = undefined,
                .view_groups = undefined,
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
                },
            );
            errdefer self.forest.deinit(allocator);

            self.changes_scan_buffer = try allocator.alloc(Change, changes_limit_max);
            errdefer allocator.free(self.changes_scan_buffer);

            self.write_keys = try allocator.alloc(WriteKey, commit_entries_limit);
            errdefer allocator.free(self.write_keys);

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
            try self.view_op_keys.ensureTotalCapacity(allocator, groups_limit);
            errdefer self.view_op_keys.deinit(allocator);
            try self.view_txn_keys.ensureTotalCapacity(allocator, groups_limit);
            errdefer self.view_txn_keys.deinit(allocator);
            try self.groups_touched.ensureTotalCapacity(allocator, groups_limit);
            errdefer self.groups_touched.deinit(allocator);
            try self.groups_scratch.ensureTotalCapacity(allocator, groups_limit);
            errdefer self.groups_scratch.deinit(allocator);
        }

        pub fn deinit(self: *StateMachine, allocator: std.mem.Allocator) void {
            self.groups_scratch.deinit(allocator);
            self.groups_touched.deinit(allocator);
            self.view_txn_keys.deinit(allocator);
            self.view_op_keys.deinit(allocator);
            self.view_txn_busy.deinit(allocator);
            allocator.free(self.view_groups);
            allocator.free(self.backfill_rows);
            self.add_rows.deinit(allocator);
            allocator.free(self.write_keys);
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
                .write_keys = self.write_keys,
                .add_rows = self.add_rows,
                .backfill_rows = self.backfill_rows,
                .view_groups = self.view_groups,
                .view_txn_busy = self.view_txn_busy,
                .view_op_keys = self.view_op_keys,
                .view_txn_keys = self.view_txn_keys,
                .groups_touched = self.groups_touched,
                .groups_scratch = self.groups_scratch,
            };
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
            return self.view_building orelse true;
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
                .lookup_rows, .commit => payload: {
                    const body_decoder = MultiBatchDecoder.init(message_body_used, .{
                        .element_size = operation.event_size(),
                    }) catch unreachable; // Already validated by `input_valid()`.
                    break :payload body_decoder.payload;
                },
                .get_changes, .get_history, .get_view, .declare_view, .pulse => message_body_used,
            };
            self.prepare_timestamp += self.prepare_delta(operation, payload);
        }

        fn prepare_delta(self: *const StateMachine, operation: Operation, events: []const u8) u64 {
            return switch (operation) {
                .commit => @divExact(events.len, @sizeOf(Entry)) * entry_timestamps,
                .declare_view => 1,
                .pulse => self.group_writes_limit,
                .lookup_rows, .get_changes, .get_history, .get_view => 0,
            };
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
            self.prefetch_input = message_body_used;
            self.prefetch_snapshot = snapshot;
            self.prefetch_callback = callback;

            switch (operation) {
                .lookup_rows => self.prefetch_rows(RowKey, message_body_used),
                .commit => self.prefetch_views(),
                .get_changes => self.prefetch_changes(message_body_used),
                .get_history => self.prefetch_history(message_body_used),
                .get_view, .declare_view, .pulse => self.prefetch_views(),
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

        fn prefetch_rows_callback(context: *RowsGroove.PrefetchContext) void {
            const self: *StateMachine = @alignCast(
                @fieldParentPtr("rows_prefetch_context", context),
            );
            switch (self.prefetch_operation.?) {
                .commit => self.prefetch_commit_groups(),
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
                inline .lookup_rows, .commit => |operation_comptime| self.execute_multi_batch(
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
                .pulse => self.execute_pulse(timestamp),
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
            var batch_index: u32 = 0;
            while (body_decoder.pop()) |batch| : (batch_index += 1) {
                batch_timestamp += self.prepare_delta(operation, batch);
                const bytes_written: usize = switch (operation) {
                    .lookup_rows => self.execute_lookup_rows(
                        op,
                        batch,
                        reply_encoder.writable().?,
                    ),
                    .commit => self.execute_commit(
                        op,
                        batch_timestamp,
                        batch,
                        self.view_txn_busy.isSet(batch_index),
                        reply_encoder.writable().?,
                    ),
                    .get_changes, .get_history, .get_view, .declare_view, .pulse => {
                        comptime unreachable;
                    },
                };
                reply_encoder.add(@intCast(bytes_written));
            }
            assert(batch_timestamp == timestamp);
            assert(body_decoder.batch_count() == reply_encoder.batch_count);
            if (operation == .commit) {
                self.groups_store();
                self.views_store();
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

        /// Executes one transaction. `timestamp` is the timestamp of its last entry.
        fn execute_commit(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            batch: []const u8,
            views_busy: bool,
            output: []u8,
        ) usize {
            const entries = stdx.bytes_as_slice(.exact, Entry, batch);
            const results = stdx.bytes_as_slice(.inexact, EntryResult, output)[0..entries.len];
            assert(entries.len <= self.write_keys.len);

            // Resolving the adds fills in each add's result (`applied`, `value`).
            const failure = self.commit_failure(entries, views_busy) orelse
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
                        .put => self.row_put(op, entry_timestamp, entry, &entry.value),
                        .delete => self.row_delete(op, entry_timestamp, entry),
                        .add => self.row_add(op, entry_timestamp, entry, result),
                        _ => unreachable, // Rejected by `entry_validate()`.
                    }
                    result.op = op;
                }
            }
            return entries.len * @sizeOf(EntryResult);
        }

        /// The first reason the transaction cannot commit, or null.
        /// The views budget comes first (prefetch decided it, `views_busy`), then static checks,
        /// then duplicate writes, then read conflicts.
        fn commit_failure(self: *StateMachine, entries: []const Entry, views_busy: bool) ?Failure {
            if (views_busy) {
                const index = for (entries, 0..) |*entry, index| {
                    if (self.entry_viewed(entry)) break index;
                } else unreachable; // A transaction without groups always fits.
                return .{ .index = @intCast(index), .status = .views_busy, .op = 0 };
            }
            for (entries, 0..) |*entry, index| {
                if (nerva.entry_validate(entry)) |status| {
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
                }
            }
            if (self.write_duplicate(entries)) |index| {
                return .{ .index = index, .status = .write_duplicate, .op = 0 };
            }
            for (entries, 0..) |*entry, index| {
                if (entry.kind != .read) continue;
                const version = self.row_version(nerva.row_key(entry.table, entry.id));
                if (version != entry.op_seen) {
                    return .{ .index = @intCast(index), .status = .conflict, .op = version };
                }
            }
            return null;
        }

        /// The index of the earliest write whose row an earlier write in the same transaction
        /// already wrote, or null. Sorts in scratch space: O(n log n), no allocation.
        fn write_duplicate(self: *StateMachine, entries: []const Entry) ?u32 {
            var count: u32 = 0;
            for (entries, 0..) |*entry, index| {
                if (entry.kind == .read) continue;
                self.write_keys[count] = .{
                    .key = nerva.row_key(entry.table, entry.id),
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
            entry: *const Entry,
            value: *const [nerva.value_size]u8,
        ) void {
            assert(entry.kind == .put or entry.kind == .add);
            const rows = &self.forest.grooves.rows;
            const key = nerva.row_key(entry.table, entry.id);
            const value_old: ?[nerva.value_size]u8 = switch (rows.get(key)) {
                .found_object => |row| if (row.flags.deleted) null else row.value,
                .not_found => null,
            };
            self.views_row_changed(
                entry.table,
                entry.id,
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
            entry: *const Entry,
            result: *const EntryResult,
        ) void {
            const add = Add.from_entry(entry);
            var value: [nerva.value_size]u8 = switch (self.forest.grooves.rows.get(
                nerva.row_key(entry.table, entry.id),
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
            entries: []const Entry,
            results: []EntryResult,
        ) ?Failure {
            assert(entries.len == results.len);
            self.add_rows.clearRetainingCapacity();
            for (entries, results, 0..) |*entry, *result, index| {
                result.* = .{ .status = .ok, .op = 0 };
                if (entry.kind != .add) continue;
                const add = Add.from_entry(entry);

                const key = nerva.row_key(entry.table, entry.id);
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

        /// Deleting a row that does not exist (or is already deleted) is a no-op.
        fn row_delete(self: *StateMachine, op: u64, timestamp: u64, entry: *const Entry) void {
            assert(entry.kind == .delete);
            const rows = &self.forest.grooves.rows;
            switch (rows.get(nerva.row_key(entry.table, entry.id))) {
                .found_object => |row_old| {
                    if (row_old.flags.deleted) return;
                    assert(row_old.op <= op);
                    self.views_row_changed(entry.table, entry.id, &row_old.value, null, timestamp);
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
            entry: *const Entry,
            kind: nerva.ChangeKind,
            value: *const [nerva.value_size]u8,
        ) void {
            assert(kind == .put or kind == .delete);
            assert(kind == .put or stdx.zeroed(value));
            self.forest.grooves.changes.insert(&.{
                .id = entry.id,
                .table = entry.table,
                .kind = kind,
                .flags = .{},
                .op = op,
                .timestamp = timestamp,
                .value = value.*,
            });
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
                .commit => self.prefetch_rows(Entry, self.prefetch_input.?),
                .declare_view => self.prefetch_finish(),
                .get_view => self.prefetch_view_groups(),
                .pulse => self.prefetch_backfill_rows(),
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
            var decoder = MultiBatchDecoder.init(self.prefetch_input.?, .{
                .element_size = @sizeOf(Entry),
            }) catch unreachable; // Already validated by `input_valid()`.

            const groups = &self.forest.grooves.groups;
            groups.prefetch_setup(self.prefetch_snapshot.?);
            self.view_txn_busy.unsetAll();
            self.view_op_keys.clearRetainingCapacity();
            var batch_index: u32 = 0;
            while (decoder.pop()) |batch| : (batch_index += 1) {
                const entries = stdx.bytes_as_slice(.exact, Entry, batch);
                if (!self.view_txn_admit(entries)) {
                    self.view_txn_busy.set(batch_index);
                    continue;
                }
                for (self.view_txn_keys.items) |key| groups.prefetch_enqueue(.{ .key = key });
            }
            self.view_txn_keys.clearRetainingCapacity();
            groups.prefetch(prefetch_groups_callback, &self.groups_prefetch_context);
        }

        /// Adds the transaction's groups to the op's, if they fit (`view_txn_keys` holds those
        /// it added). Otherwise leaves the op's groups as they were.
        fn view_txn_admit(self: *StateMachine, entries: []const Entry) bool {
            self.view_txn_keys.clearRetainingCapacity();
            for (entries) |*entry| {
                if (!self.entry_viewed(entry)) continue;
                const rows = &self.forest.grooves.rows;
                const value_old: ?[nerva.value_size]u8 =
                    switch (rows.get(nerva.row_key(entry.table, entry.id))) {
                        .found_object => |row| if (row.flags.deleted) null else row.value,
                        .not_found => null,
                    };
                for (self.views_op[0..self.views_op_count]) |*view| {
                    if (view.definition.table != entry.table) continue;
                    for (views.entry_values(entry, value_old)) |candidate| {
                        const value = candidate orelse continue;
                        if (!views.row_matches(&view.definition, &value)) continue;
                        const group_key = views.group_key(&view.definition, &value);
                        const key = views.group_tree_key(view.id, &group_key);
                        if (self.view_op_keys.contains(key)) continue;
                        if (self.view_op_keys.count() == self.group_writes_limit) {
                            for (self.view_txn_keys.items) |added| {
                                assert(self.view_op_keys.remove(added));
                            }
                            self.view_txn_keys.clearRetainingCapacity();
                            return false;
                        }
                        self.view_op_keys.putAssumeCapacity(key, {});
                        self.view_txn_keys.appendAssumeCapacity(key);
                    }
                }
            }
            return true;
        }

        /// Whether the entry writes a table with a view (in any state).
        fn entry_viewed(self: *const StateMachine, entry: *const Entry) bool {
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
            self.prefetch_finish();
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

        /// Writes back the views this op changed.
        fn views_store(self: *StateMachine) void {
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
            }
            self.view_building = building;
        }

        /// Keeps the views over `table` exact after one row changed from `old` to `new` (null:
        /// absent). `timestamp` is the entry's: a group it creates in the table's `n`th view
        /// takes `timestamp + 1 + n`.
        fn views_row_changed(
            self: *StateMachine,
            table: u32,
            id: u64,
            old: ?*const [nerva.value_size]u8,
            new: ?*const [nerva.value_size]u8,
            timestamp: u64,
        ) void {
            var slot: u64 = 0;
            for (self.views_op[0..self.views_op_count]) |*view| {
                if (view.definition.table != table) continue;
                defer slot += 1;
                assert(slot < nerva.views_per_table_max);
                if (!view_maintained(view, table)) continue;
                // A building view adds rows from its cursor on when the pulse reaches them.
                if (view.state == .building and id >= view.backfill_cursor) continue;

                if (old) |value| {
                    if (views.row_matches(&view.definition, value)) {
                        self.group_change(view, value, .remove, 0);
                    }
                }
                if (new) |value| {
                    if (views.row_matches(&view.definition, value)) {
                        self.group_change(view, value, .add, timestamp + 1 + slot);
                    }
                }
            }
        }

        /// Adds the row to, or removes it from, its group of `view`, keeping the view's hash and
        /// group count, in the op's scratch groups (written back by `groups_store`). `timestamp`
        /// is for a group created now.
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

            const count_old = group.count;
            views.hash_update(&view.hash, &views.group_digest(view.id, group), .remove);
            views.group_apply(&view.definition, group, value, switch (sign) {
                .add => .add,
                .remove => .remove,
            });
            views.hash_update(&view.hash, &views.group_digest(view.id, group), .add);
            if (count_old == 0 and group.count > 0) view.group_count += 1;
            if (count_old > 0 and group.count == 0) view.group_count -= 1;
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

        /// Writes back each group this op changed, once, in the order first touched.
        fn groups_store(self: *StateMachine) void {
            const groups = &self.forest.grooves.groups;
            for (self.groups_touched.items) |tree_key| {
                const scratch = self.groups_scratch.getPtr(tree_key).?;
                if (scratch.stored) |*stored| {
                    if (!stdx.equal_bytes(Group, stored, &scratch.group)) {
                        groups.update(.{ .old = stored, .new = &scratch.group });
                    }
                } else if (scratch.group.timestamp != 0) {
                    groups.insert(&scratch.group);
                }
            }
            self.groups_touched.clearRetainingCapacity();
            self.groups_scratch.clearRetainingCapacity();
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
            self.prefetch_finish();
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
            } else return self.prefetch_finish();
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
            const count = @min(results.len, self.group_writes_limit);
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
            defer self.view_groups_count = null;
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
            header.state = view.state;
            header.declared_op = view.declared_op;
            header.group_count = view.group_count;
            header.hash = view.hash;

            const scanned = self.view_groups[0..self.view_groups_count.?];
            assert(scanned.len <= limit + 1);
            var count: usize = 0;
            for (scanned[0..@min(scanned.len, limit)]) |*group| {
                assert(group.key >> 64 == view.id);
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
            if (scanned.len > limit) {
                header.flags.more = true;
                header.cursor = @truncate(scanned[limit].key);
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
            result.* = self.view_declare(op, timestamp, definition);
            self.views_store();
            return @sizeOf(DeclareResult);
        }

        fn view_declare(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            definition: *const ViewDefinition,
        ) DeclareResult {
            if (views.definition_validate(definition)) |status| {
                return .{ .status = status, .view_id = 0, .op = 0 };
            }
            const name = views.definition_name(definition);
            var table_views: u32 = 0;
            for (self.views_op[0..self.views_op_count]) |*view| {
                if (std.mem.eql(u8, views.definition_name(&view.definition), name)) {
                    if (stdx.equal_bytes(ViewDefinition, &view.definition, definition)) {
                        return .{ .status = .exists, .view_id = view.id, .op = view.declared_op };
                    }
                    return .{ .status = .different, .view_id = 0, .op = 0 };
                }
                if (view.definition.table == definition.table) table_views += 1;
            }
            if (self.views_op_count == nerva.views_max) {
                return .{ .status = .views_full, .view_id = 0, .op = 0 };
            }
            if (table_views == nerva.views_per_table_max) {
                return .{ .status = .table_views_full, .view_id = 0, .op = 0 };
            }

            const index = self.views_op_count;
            // Every view starts building: pulses add the rows already written (none, possibly).
            const view: View = .{
                .id = index + 1,
                .timestamp = timestamp,
                .declared_op = op,
                .backfill_cursor = 0,
                .group_count = 0,
                .state = .building,
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

        /// Adds the rows the pulse scanned to the building view's groups. Replies nothing.
        fn execute_pulse(self: *StateMachine, timestamp: u64) usize {
            defer {
                self.backfill_view = null;
                self.backfill_count = null;
            }
            const index = self.backfill_view orelse {
                assert(self.view_building == false);
                return 0;
            };
            const view = &self.views_op[index];
            assert(view.state == .building);
            const scanned = self.backfill_rows[0..self.backfill_count.?];
            const count = @min(scanned.len, self.group_writes_limit);
            const timestamp_base = timestamp - self.group_writes_limit;
            for (scanned[0..count], 0..) |*row, k| {
                const id: u64 = @truncate(row.key);
                assert(row.key >> 64 == view.definition.table);
                assert(id >= view.backfill_cursor);
                if (row.flags.deleted) continue;
                if (!views.row_matches(&view.definition, &row.value)) continue;
                self.group_change(view, &row.value, .add, timestamp_base + k + 1);
            }
            self.groups_store();
            if (view.state == .building) {
                if (scanned.len > self.group_writes_limit) {
                    view.backfill_cursor = @truncate(scanned[self.group_writes_limit].key);
                } else {
                    view.state = .ready;
                }
            }
            self.views_store();
            return 0;
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
    };
}
