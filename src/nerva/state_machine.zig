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
        /// group the entry creates (N49).
        pub const entry_timestamps = 1 + nerva.views_per_table_max;
        /// Groups one op can write (N49).
        pub const groups_per_op_max: u32 = nerva.view_group_writes_max;
        comptime {
            assert(nerva.backfill_rows_per_op <= groups_per_op_max);
        }
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
            cache_entries_rows: u32 = RowsGroove.ObjectsCache.Cache.value_count_max_multiple,
            cache_entries_groups: u32 = GroupsGroove.ObjectsCache.Cache.value_count_max_multiple,
        };

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

        batch_size_limit: u32,
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

        // ---- Views (N49) ----

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
        /// Rows a pulse scanned (one more than it adds, to know whether the table has more).
        backfill_rows: []Row,
        backfill_count: ?u32 = null,
        /// Groups a `get_view` scanned (one more than its limit, to know whether there are more).
        view_groups: []Group,
        view_groups_count: ?u32 = null,

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
            const groups_limit: u32 = groups_per_op_max;
            const lookup_rows_limit = Operation.lookup_rows.event_max(options.batch_size_limit);
            assert(commit_entries_limit <= commit_entries_max);
            assert(lookup_rows_limit <= lookup_rows_max);

            self.* = .{
                .batch_size_limit = options.batch_size_limit,
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

            self.backfill_rows = try allocator.alloc(Row, nerva.backfill_rows_per_op + 1);
            errdefer allocator.free(self.backfill_rows);

            self.view_groups = try allocator.alloc(Group, view_groups_limit_max + 1);
            errdefer allocator.free(self.view_groups);
        }

        pub fn deinit(self: *StateMachine, allocator: std.mem.Allocator) void {
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
                .forest = self.forest,
                .changes_scan_buffer = self.changes_scan_buffer,
                .write_keys = self.write_keys,
                .add_rows = self.add_rows,
                .backfill_rows = self.backfill_rows,
                .view_groups = self.view_groups,
            };
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

        /// Pulses backfill building views (N49). Unknown after a reset: one pulse finds out.
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
            self.prepare_timestamp += prepare_delta(operation, payload);
        }

        fn prepare_delta(operation: Operation, events: []const u8) u64 {
            return switch (operation) {
                .commit => @divExact(events.len, @sizeOf(Entry)) * entry_timestamps,
                .declare_view => 1,
                .pulse => nerva.backfill_rows_per_op,
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
                .commit => self.prefetch_rows(Entry, message_body_used),
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
            self.prefetch_finish();
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
            var batch_timestamp = timestamp - prepare_delta(operation, body_decoder.payload);
            while (body_decoder.pop()) |batch| {
                batch_timestamp += prepare_delta(operation, batch);
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
            output: []u8,
        ) usize {
            const entries = stdx.bytes_as_slice(.exact, Entry, batch);
            const results = stdx.bytes_as_slice(.inexact, EntryResult, output)[0..entries.len];
            assert(entries.len <= self.write_keys.len);

            // Resolving the adds fills in each add's result (`applied`, `value`).
            const failure = self.commit_failure(entries) orelse self.adds_resolve(entries, results);
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
        /// Static checks come first, then duplicate writes, then read conflicts.
        fn commit_failure(self: *StateMachine, entries: []const Entry) ?Failure {
            for (entries, 0..) |*entry, index| {
                if (nerva.entry_validate(entry)) |status| {
                    return .{ .index = @intCast(index), .status = status, .op = 0 };
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

        // ---- Views (N49) ----

        /// Prefetches every declared view (stage 0 of `commit`, `get_view`, `declare_view` and
        /// `pulse`), then the operation's own stage.
        fn prefetch_views(self: *StateMachine) void {
            _ = self;
            @panic("TODO");
        }

        /// Prefetches the groups a commit may touch (stage 2, after the rows).
        fn prefetch_commit_groups(self: *StateMachine) void {
            _ = self;
            @panic("TODO");
        }

        /// Loads the views prefetched for this op into `views_op` and `views_stored`.
        fn views_load(self: *StateMachine) void {
            _ = self;
            @panic("TODO");
        }

        /// Writes back the views this op changed.
        fn views_store(self: *StateMachine) void {
            _ = self;
            @panic("TODO");
        }

        /// Keeps the views over `table` exact after one row changed from `old` to `new` (null:
        /// absent). `timestamp` is the entry's: groups it creates take the ones after it.
        fn views_row_changed(
            self: *StateMachine,
            table: u32,
            id: u64,
            old: ?*const [nerva.value_size]u8,
            new: ?*const [nerva.value_size]u8,
            timestamp: u64,
        ) void {
            _ = self;
            _ = table;
            _ = id;
            _ = old;
            _ = new;
            _ = timestamp;
            @panic("TODO");
        }

        fn execute_get_view(
            self: *StateMachine,
            op: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            _ = self;
            _ = op;
            _ = message_body_used;
            _ = output_buffer;
            @panic("TODO");
        }

        fn execute_declare_view(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            message_body_used: []align(constants.cache_line_size) const u8,
            output_buffer: *align(constants.cache_line_size) [constants.message_body_size_max]u8,
        ) usize {
            _ = self;
            _ = op;
            _ = timestamp;
            _ = message_body_used;
            _ = output_buffer;
            @panic("TODO");
        }

        /// Adds the rows the pulse scanned to the building view's groups. Replies nothing.
        fn execute_pulse(self: *StateMachine, timestamp: u64) usize {
            _ = self;
            _ = timestamp;
            @panic("TODO");
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
