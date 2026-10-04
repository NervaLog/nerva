//! Nerva's state machine: the commit core.
//!
//! - `lookup_rows`: point reads, returning each row's value and version.
//! - `commit`: one batch = one transaction. Reads assert the version they saw; if any read is
//!   stale, or any entry is invalid, nothing is applied. Otherwise every write is applied at
//!   this op and appended to the change feed.
//! - `get_changes`: the change feed, scanned in timestamp (and therefore op) order.
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
const TimestampRange = @import("../lsm/timestamp_range.zig").TimestampRange;
const MultiBatchDecoder = vsr.multi_batch.MultiBatchDecoder;
const MultiBatchEncoder = vsr.multi_batch.MultiBatchEncoder;

const Row = nerva.Row;
const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const EntryStatus = nerva.EntryStatus;
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
const Change = nerva.Change;
const ChangesFilter = nerva.ChangesFilter;
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

        comptime {
            assert(commit_entries_max > 0);
            assert(lookup_rows_max > 0);
            assert(changes_limit_max > 0);
        }

        pub const Options = struct {
            batch_size_limit: u32,
            lsm_forest_compaction_block_count: u32 = Forest.Options.compaction_block_count_min,
            lsm_forest_node_count: u32,
            cache_entries_rows: u32 = RowsGroove.ObjectsCache.Cache.value_count_max_multiple,
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
                .batch_value_count_max = .{ .timestamp = commit_entries_max },
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
                .derived = .{},
                // Append only: never looked up or updated.
                .objects_cache = false,
            },
        );

        pub const Forest = ForestType(Storage, .{
            .rows = RowsGroove,
            .changes = ChangesGroove,
        });

        const ChangesScanTree = ScanTreeType(void, ChangesGroove.ObjectTree, Storage);

        /// The first write of a transaction that duplicates an earlier write's row.
        const WriteKey = struct { key: u128, index: u32 };

        const Failure = struct { index: u32, status: EntryStatus, op: u64 };

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
        /// Results of the last `get_changes` prefetch, consumed by its commit.
        changes_scan_buffer: []Change,
        /// The number of changes scanned, or null if the filter was invalid.
        changes_scan_count: ?u32 = null,

        /// Scratch space for duplicate-write detection.
        write_keys: []WriteKey,

        forest_callback: ?*const fn (*StateMachine) void = null,

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
            const lookup_rows_limit = Operation.lookup_rows.event_max(options.batch_size_limit);
            assert(commit_entries_limit <= commit_entries_max);
            assert(lookup_rows_limit <= lookup_rows_max);

            self.* = .{
                .batch_size_limit = options.batch_size_limit,
                .forest = undefined,
                .changes_scan_buffer = undefined,
                .write_keys = undefined,
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
                        .tree_options_index = .{},
                    },
                },
            );
            errdefer self.forest.deinit(allocator);

            self.changes_scan_buffer = try allocator.alloc(Change, changes_limit_max);
            errdefer allocator.free(self.changes_scan_buffer);

            self.write_keys = try allocator.alloc(WriteKey, commit_entries_limit);
            errdefer allocator.free(self.write_keys);
        }

        pub fn deinit(self: *StateMachine, allocator: std.mem.Allocator) void {
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
            };
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

        pub fn pulse_needed(self: *const StateMachine, timestamp: u64) bool {
            _ = self;
            _ = timestamp;
            return false; // Nerva has no timeouts.
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
                .get_changes => message_body_used,
            };
            self.prepare_timestamp += prepare_delta(operation, payload);
        }

        fn prepare_delta(operation: Operation, events: []const u8) u64 {
            return switch (operation) {
                .commit => @divExact(events.len, @sizeOf(Entry)),
                .lookup_rows, .get_changes => 0,
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
                    .lookup_rows => self.execute_lookup_rows(batch, reply_encoder.writable().?),
                    .commit => self.execute_commit(
                        op,
                        batch_timestamp,
                        batch,
                        reply_encoder.writable().?,
                    ),
                    .get_changes => comptime unreachable,
                };
                reply_encoder.add(@intCast(bytes_written));
            }
            assert(batch_timestamp == timestamp);
            assert(body_decoder.batch_count() == reply_encoder.batch_count);
            return reply_encoder.finish();
        }

        fn execute_lookup_rows(self: *StateMachine, batch: []const u8, output: []u8) usize {
            const keys = stdx.bytes_as_slice(.exact, RowKey, batch);
            const results = stdx.bytes_as_slice(.inexact, RowValue, output)[0..keys.len];

            for (keys, results) |*key, *result| {
                result.* = .{
                    .id = key.id,
                    .table = key.table,
                    .flags = .{},
                    .op = 0,
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

            if (self.commit_failure(entries)) |failure| {
                for (results, 0..) |*result, index| {
                    result.* = if (index == failure.index)
                        .{ .status = failure.status, .op = failure.op }
                    else
                        .{ .status = .aborted, .op = 0 };
                }
            } else {
                for (entries, 0..) |*entry, index| {
                    const entry_timestamp = timestamp - entries.len + index + 1;
                    assert(TimestampRange.valid(entry_timestamp));
                    switch (entry.kind) {
                        .read => {},
                        .put => self.row_put(op, entry_timestamp, entry),
                        .delete => self.row_delete(op, entry_timestamp, entry),
                        _ => unreachable, // Rejected by `entry_validate()`.
                    }
                }
                @memset(results, .{ .status = .ok, .op = op });
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

        fn row_put(self: *StateMachine, op: u64, timestamp: u64, entry: *const Entry) void {
            assert(entry.kind == .put);
            const rows = &self.forest.grooves.rows;
            const key = nerva.row_key(entry.table, entry.id);
            switch (rows.get(key)) {
                .found_object => |row_old| {
                    // Equal when an earlier transaction in the same request wrote the row.
                    assert(row_old.op <= op);
                    var row_new = row_old;
                    row_new.value = entry.value;
                    row_new.op = op;
                    row_new.flags.deleted = false;
                    rows.update(.{ .old = &row_old, .new = &row_new });
                },
                .not_found => rows.insert(&.{
                    .key = key,
                    .value = entry.value,
                    .op = op,
                    .timestamp = timestamp,
                    .flags = .{},
                }),
            }
            self.change_insert(op, timestamp, entry, .put);
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
            self.change_insert(op, timestamp, entry, .delete);
        }

        fn change_insert(
            self: *StateMachine,
            op: u64,
            timestamp: u64,
            entry: *const Entry,
            kind: nerva.ChangeKind,
        ) void {
            assert(kind == .put or kind == .delete);
            self.forest.grooves.changes.insert(&.{
                .id = entry.id,
                .table = entry.table,
                .kind = kind,
                .flags = .{},
                .op = op,
                .timestamp = timestamp,
                .value = if (kind == .put) entry.value else @splat(0),
            });
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
    };
}
