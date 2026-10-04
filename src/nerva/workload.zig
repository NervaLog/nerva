//! The VOPR workload for Nerva: random transactions over a small key space (so that conflicts
//! are common), point lookups and change-feed scans.
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

const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const EntryStatus = nerva.EntryStatus;
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
const Change = nerva.Change;
const ChangesFilter = nerva.ChangesFilter;
const value_size = nerva.value_size;

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

        const Failure = struct { index: usize, status: EntryStatus, op: u64 };

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
            return .{ .allocator = allocator, .prng = prng, .options = options };
        }

        pub fn deinit(workload: *Workload, allocator: std.mem.Allocator) void {
            log.info("transactions committed={} failed={} changes={}", .{
                workload.transactions_committed,
                workload.transactions_failed,
                workload.changes.items.len,
            });
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
            _ = client_index;
            workload.requests_sent += 1;

            const operation: Operation = switch (workload.prng.chances(.{
                .commit = 8,
                .lookup_rows = 3,
                .get_changes = 2,
            })) {
                .commit => .commit,
                .lookup_rows => .lookup_rows,
                .get_changes => .get_changes,
            };
            const size = switch (operation) {
                .commit => workload.build_commit(body[0..workload.options.batch_size_limit]),
                .lookup_rows => workload.build_lookup_rows(
                    body[0..workload.options.batch_size_limit],
                ),
                .get_changes => workload.build_get_changes(body),
            };
            return .{ .operation = operation, .size = size };
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
                const entries = entries_free[0..workload.prng.int_inclusive(
                    usize,
                    @min(entries_free.len, workload.options.entries_per_transaction_max),
                )];
                workload.build_transaction(entries);
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
                })) {
                    .read => .read,
                    .put => .put,
                    .delete => .delete,
                };

                // Keep duplicate writes rare: they abort the whole transaction.
                if (kind != .read and !prng.chance(stdx.PRNG.ratio(1, 50))) {
                    for (entries[0..index]) |*previous| {
                        // Not `row_key()`: an earlier entry may have been made invalid.
                        if (previous.kind != .read and previous.table == table and
                            previous.id == id)
                        {
                            entry.* = workload.entry_read(table, id);
                            break;
                        }
                    } else entry.* = workload.entry_write(kind, table, id);
                } else {
                    entry.* = if (kind == .read)
                        workload.entry_read(table, id)
                    else
                        workload.entry_write(kind, table, id);
                }

                if (prng.chance(workload.options.invalid_entry_probability)) {
                    switch (prng.chances(.{ .table = 1, .reserved = 1, .value = 1, .kind = 1 })) {
                        .table => entry.table = 0,
                        .reserved => entry.reserved_b = 1,
                        .value => entry.value[prng.index(&entry.value)] = 1,
                        .kind => entry.kind = @enumFromInt(prng.range_inclusive(u8, 4, 255)),
                    }
                }
            }
        }

        fn entry_read(workload: *Workload, table: u32, id: u64) Entry {
            const version = workload.row_version(nerva.row_key(table, id));
            const op_seen = if (workload.prng.chance(workload.options.stale_read_probability))
                workload.prng.int_inclusive(u64, workload.op_max)
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

        fn entry_write(workload: *Workload, kind: nerva.EntryKind, table: u32, id: u64) Entry {
            assert(kind == .put or kind == .delete);
            var entry: Entry = .{
                .id = id,
                .table = table,
                .kind = kind,
                .op_seen = 0,
                .value = @splat(0),
            };
            if (kind == .put) workload.prng.fill(&entry.value);
            return entry;
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
                const keys = keys_free[0..workload.prng.int_inclusive(
                    usize,
                    @min(keys_free.len, reply_keys_free, 16),
                )];
                keys_total += keys.len;
                for (keys) |*key| {
                    key.* = .{
                        .id = workload.prng.int_inclusive(u64, workload.options.id_count - 1),
                        // Table zero is invalid, and must come back as not found.
                        .table = workload.prng.int_inclusive(u32, workload.options.table_count),
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
                .timestamp_min = switch (prng.chances(.{ .start = 1, .known = 3, .after = 1 })) {
                    .start => 0,
                    .known => if (changes.len == 0) 0 else changes[prng.index(changes)].timestamp,
                    .after => if (changes.len == 0) 0 else changes[changes.len - 1].timestamp + 1,
                },
                // Zero is an invalid limit, and must return nothing.
                .limit = prng.int_inclusive(u32, 64),
            };
            return @sizeOf(ChangesFilter);
        }

        pub fn on_reply(
            workload: *Workload,
            client_index: usize,
            operation: Operation,
            timestamp: u64,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            _ = client_index;
            workload.requests_delivered += 1;
            assert(workload.requests_delivered <= workload.requests_sent);

            switch (operation) {
                .commit => workload.check_commit(timestamp, request_body, reply_body),
                .lookup_rows => workload.check_lookup_rows(request_body, reply_body),
                .get_changes => workload.check_get_changes(request_body, reply_body),
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

                if (workload.commit_failure(entries)) |failure| {
                    workload.transactions_failed += 1;
                    for (results, 0..) |result, index| {
                        if (index == failure.index) {
                            assert(result.status == failure.status);
                            assert(result.op == failure.op);
                        } else {
                            assert(result.status == .aborted);
                            assert(result.op == 0);
                        }
                    }
                    continue;
                }

                workload.transactions_committed += 1;
                const op = results[0].op;
                for (results) |result| {
                    assert(result.status == .ok);
                    assert(result.op == op);
                }
                if (op_request) |op_request_| assert(op == op_request_);
                assert(op > workload.op_max);
                op_request = op;

                for (entries, 0..) |*entry, index| {
                    const entry_timestamp = batch_timestamp - entries.len + index + 1;
                    workload.apply(op, entry_timestamp, entry);
                }
            }
            assert(reply.pop() == null);
            assert(batch_timestamp == timestamp);
            if (op_request) |op| workload.op_max = op;
        }

        /// The model's expectation, computed independently of the state machine.
        fn commit_failure(workload: *Workload, entries: []const Entry) ?Failure {
            for (entries, 0..) |*entry, index| {
                if (nerva.entry_validate(entry)) |status| {
                    return .{ .index = index, .status = status, .op = 0 };
                }
            }
            // The earliest write whose row an earlier write already wrote.
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
                const version = workload.row_version(nerva.row_key(entry.table, entry.id));
                if (version.op != entry.op_seen) {
                    return .{ .index = index, .status = .conflict, .op = version.op };
                }
            }
            return null;
        }

        fn apply(workload: *Workload, op: u64, timestamp: u64, entry: *const Entry) void {
            const key = nerva.row_key(entry.table, entry.id);
            const change_kind: nerva.ChangeKind = switch (entry.kind) {
                .read => return,
                .put => .put,
                .delete => kind: {
                    if (!workload.row_version(key).exists) return; // No-op.
                    break :kind .delete;
                },
                _ => unreachable,
            };
            const value: [value_size]u8 = if (change_kind == .put) entry.value else @splat(0);
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
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            var request = MultiBatchDecoder.init(request_body, .{
                .element_size = @sizeOf(RowKey),
            }) catch unreachable;
            var reply = MultiBatchDecoder.init(reply_body, .{
                .element_size = @sizeOf(RowValue),
            }) catch unreachable;

            while (request.pop()) |batch| {
                const keys = stdx.bytes_as_slice(.exact, RowKey, batch);
                const results = stdx.bytes_as_slice(.exact, RowValue, reply.pop().?);
                assert(results.len == keys.len);
                for (keys, results) |*key, *result| {
                    assert(result.id == key.id);
                    assert(result.table == key.table);
                    assert(stdx.zeroed(std.mem.asBytes(&result.reserved_a)));
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
        }

        fn check_get_changes(
            workload: *Workload,
            request_body: []align(constants.cache_line_size) const u8,
            reply_body: []align(constants.cache_line_size) const u8,
        ) void {
            const filter: *const ChangesFilter = @alignCast(
                std.mem.bytesAsValue(ChangesFilter, request_body[0..@sizeOf(ChangesFilter)]),
            );
            const results = stdx.bytes_as_slice(.exact, Change, reply_body);
            if (filter.limit == 0) {
                assert(results.len == 0);
                return;
            }
            const limit = @min(filter.limit, StateMachine.changes_limit_max);

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
                workload.op_max = end.op;
            }
            assert(end.timestamp == if (count == 0)
                filter.timestamp_min
            else
                results[count - 1].timestamp + 1);
        }
    };
}
