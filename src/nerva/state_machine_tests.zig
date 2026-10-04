//! Deterministic tests of the Nerva state machine: one state machine on simulated storage,
//! driven through `prepare`, `prefetch` and `commit` the way the replica drives it.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const stdx = @import("stdx");
const constants = @import("../constants.zig");
const vsr = @import("../vsr.zig");
const nerva = @import("../nerva.zig");
const fixtures = @import("../testing/fixtures.zig");
const Storage = @import("../testing/storage.zig").Storage;
const StateMachine = @import("state_machine.zig").StateMachineType(Storage);
const workload = @import("workload.zig");
const SuperBlock = vsr.SuperBlockType(Storage);
const Grid = vsr.GridType(Storage);
const data_file_size_min = @import("../vsr/superblock.zig").data_file_size_min;
const MultiBatchDecoder = vsr.multi_batch.MultiBatchDecoder;
const MultiBatchEncoder = vsr.multi_batch.MultiBatchEncoder;

const Operation = nerva.Operation;
const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const RowValue = nerva.RowValue;
const Change = nerva.Change;
const Receipt = workload.Receipt;
const receipt_claim = workload.receipt_claim;

const Body = [constants.message_body_size_max]u8;

const Context = struct {
    arena: std.mem.Allocator,
    storage: Storage,
    time_sim: stdx.TimeSim,
    trace: @import("../trace.zig").Tracer,
    superblock: SuperBlock,
    grid: Grid,
    state_machine: StateMachine,
    request: *align(constants.cache_line_size) Body,
    reply: *align(constants.cache_line_size) Body,
    op: u64 = 1,
    prefetching: bool = false,

    fn init(context: *Context, arena: std.mem.Allocator) !void {
        context.* = .{
            .arena = arena,
            .storage = try fixtures.init_storage(arena, .{ .size = 4096 }),
            .time_sim = fixtures.init_time(.{}),
            .trace = undefined,
            .superblock = undefined,
            .grid = undefined,
            .state_machine = undefined,
            .request = try body_alloc(arena),
            .reply = try body_alloc(arena),
        };
        context.time_sim.ticks = 1;
        context.trace = try fixtures.init_tracer(arena, context.time_sim.interface(), .{});
        context.superblock = try fixtures.init_superblock(arena, &context.storage, .{
            .storage_size_limit = data_file_size_min,
        });
        // Pretend that the superblock is open so that the Forest can initialize.
        context.superblock.opened = true;
        context.superblock.working.vsr_state.checkpoint.header.op = 0;
        context.grid = try fixtures.init_grid(arena, &context.trace, &context.superblock, .{});
        try context.state_machine.init(arena, context.time_sim.interface(), &context.grid, .{
            .batch_size_limit = constants.message_body_size_max,
            .lsm_forest_node_count = 1,
        });
    }

    /// Executes one request of `operation`, whose events are split into `batches`, and
    /// returns the results of each batch.
    fn execute(
        context: *Context,
        comptime operation: Operation,
        batches: []const []const operation.EventType(),
    ) ![]const []const operation.ResultType() {
        const Event = operation.EventType();
        const Result = operation.ResultType();

        const body_size: usize = if (comptime operation.is_multi_batch()) size: {
            var encoder = MultiBatchEncoder.init(context.request, .{
                .element_size = @sizeOf(Event),
            });
            for (batches) |batch| {
                const bytes = std.mem.sliceAsBytes(batch);
                stdx.copy_disjoint(.inexact, u8, encoder.writable().?, bytes);
                encoder.add(@intCast(bytes.len));
            }
            break :size encoder.finish();
        } else size: {
            assert(batches.len == 1);
            assert(batches[0].len == 1);
            const bytes = std.mem.asBytes(&batches[0][0]);
            stdx.copy_disjoint(.inexact, u8, context.request, bytes);
            break :size bytes.len;
        };
        const body = context.request[0..body_size];

        const state_machine = &context.state_machine;
        assert(state_machine.input_valid(operation, body));

        state_machine.prepare(operation, body);
        if (state_machine.prepare_timestamp == state_machine.commit_timestamp) {
            state_machine.prepare_timestamp += 1;
        }
        const timestamp = state_machine.prepare_timestamp;
        assert(timestamp > state_machine.commit_timestamp);

        context.prefetching = true;
        state_machine.prefetch_timestamp = timestamp;
        state_machine.prefetch(prefetch_callback, context.op, context.op, operation, body);
        while (context.prefetching) context.storage.run();

        const reply_size = state_machine.commit(
            1,
            context.op,
            timestamp,
            operation,
            body,
            context.reply,
        );
        state_machine.commit_timestamp = timestamp;
        context.op += 1;

        const reply = context.reply[0..reply_size];
        if (comptime !operation.is_multi_batch()) {
            const results = try context.arena.dupe(
                Result,
                stdx.bytes_as_slice(.exact, Result, reply),
            );
            return try context.arena.dupe([]const Result, &.{results});
        }

        var decoder = try MultiBatchDecoder.init(reply, .{ .element_size = @sizeOf(Result) });
        const results = try context.arena.alloc([]const Result, batches.len);
        for (results, batches) |*result, batch| {
            result.* = try context.arena.dupe(
                Result,
                stdx.bytes_as_slice(.exact, Result, decoder.pop().?),
            );
            assert(result.len == batch.len);
        }
        assert(decoder.pop() == null);
        return results;
    }

    fn body_alloc(arena: std.mem.Allocator) !*align(constants.cache_line_size) Body {
        const bytes = try arena.alignedAlloc(u8, constants.cache_line_size, @sizeOf(Body));
        return bytes[0..@sizeOf(Body)];
    }

    fn prefetch_callback(state_machine: *StateMachine) void {
        const context: *Context = @fieldParentPtr("state_machine", state_machine);
        assert(context.prefetching);
        context.prefetching = false;
    }

    /// Commits each transaction as its own batch, all in one request (one op).
    fn commit(context: *Context, transactions: []const []const Entry) ![]const []const EntryResult {
        return context.execute(.commit, transactions);
    }

    fn lookup(context: *Context, table: u32, id: u64) !RowValue {
        const results = try context.execute(.lookup_rows, &.{&.{.{ .id = id, .table = table }}});
        return results[0][0];
    }

    fn changes(context: *Context, timestamp_min: u64, limit: u32) ![]const Change {
        const results = try context.execute(
            .get_changes,
            &.{&.{.{ .timestamp_min = timestamp_min, .limit = limit }}},
        );
        return results[0];
    }
};

fn value(byte: u8) [nerva.value_size]u8 {
    return @splat(byte);
}

fn put(table: u32, id: u64, byte: u8) Entry {
    return .{ .id = id, .table = table, .kind = .put, .op_seen = 0, .value = value(byte) };
}

fn read(table: u32, id: u64, op_seen: u64) Entry {
    return .{ .id = id, .table = table, .kind = .read, .op_seen = op_seen, .value = @splat(0) };
}

fn delete(table: u32, id: u64) Entry {
    return .{ .id = id, .table = table, .kind = .delete, .op_seen = 0, .value = @splat(0) };
}

fn expect_statuses(results: []const EntryResult, statuses: []const nerva.EntryStatus) !void {
    try testing.expectEqual(statuses.len, results.len);
    for (results, statuses) |result, status| try testing.expectEqual(status, result.status);
}

fn context_init(arena: *std.heap.ArenaAllocator) !*Context {
    const context = try arena.allocator().create(Context);
    try context.init(arena.allocator());
    return context;
}

test "commit: blind put, then lookup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    const results = try context.commit(&.{&.{put(1, 10, 0xaa)}});
    try expect_statuses(results[0], &.{.ok});
    const op_commit = results[0][0].op;
    try testing.expectEqual(@as(u64, 1), op_commit);

    const row = try context.lookup(1, 10);
    try testing.expect(row.flags.exists);
    try testing.expectEqual(op_commit, row.op);
    try testing.expectEqual(value(0xaa), row.value);

    const missing = try context.lookup(1, 11);
    try testing.expect(!missing.flags.exists);
    try testing.expectEqual(@as(u64, 0), missing.op);
}

test "commit: stale read conflicts and applies nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    const op_first = (try context.commit(&.{&.{put(1, 1, 1)}}))[0][0].op;

    // Read at the current version: commits.
    const ok = try context.commit(&.{&.{ read(1, 1, op_first), put(1, 1, 2), put(1, 2, 2) }});
    try expect_statuses(ok[0], &.{ .ok, .ok, .ok });
    const op_second = ok[0][0].op;

    // Read at the old version: conflict, reporting the current version; nothing applied.
    const stale = try context.commit(&.{&.{ put(1, 3, 3), read(1, 1, op_first), put(1, 1, 3) }});
    try expect_statuses(stale[0], &.{ .aborted, .conflict, .aborted });
    try testing.expectEqual(op_second, stale[0][1].op);

    try testing.expectEqual(value(2), (try context.lookup(1, 1)).value);
    try testing.expectEqual(op_second, (try context.lookup(1, 1)).op);
    try testing.expect(!(try context.lookup(1, 3)).flags.exists);
}

test "commit: reading a row as absent conflicts once it is inserted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    const op_insert = (try context.commit(&.{&.{put(2, 7, 1)}}))[0][0].op;

    const results = try context.commit(&.{&.{ read(2, 7, 0), put(2, 7, 9) }});
    try expect_statuses(results[0], &.{ .conflict, .aborted });
    try testing.expectEqual(op_insert, results[0][0].op);
}

test "commit: transactions in one request see each other's writes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    // Both transactions read row (1, 5) as absent; the first inserts it, so the second
    // conflicts against the version the first just wrote.
    const results = try context.commit(&.{
        &.{ read(1, 5, 0), put(1, 5, 1) },
        &.{ read(1, 5, 0), put(1, 5, 2) },
    });
    try expect_statuses(results[0], &.{ .ok, .ok });
    try expect_statuses(results[1], &.{ .conflict, .aborted });
    try testing.expectEqual(results[0][0].op, results[1][0].op);
    try testing.expectEqual(value(1), (try context.lookup(1, 5)).value);
}

test "commit: blind writes to one row in one request apply in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    const results = try context.commit(&.{ &.{put(1, 1, 1)}, &.{put(1, 1, 2)}, &.{delete(1, 1)} });
    for (results) |result| try expect_statuses(result, &.{.ok});
    const op = results[0][0].op;

    const row = try context.lookup(1, 1);
    try testing.expect(!row.flags.exists);
    try testing.expectEqual(op, row.op);

    const changes = try context.changes(0, 10);
    try testing.expectEqual(@as(usize, 4), changes.len);
    try testing.expectEqual(nerva.ChangeKind.put, changes[0].kind);
    try testing.expectEqual(value(1), changes[0].value);
    try testing.expectEqual(value(2), changes[1].value);
    try testing.expectEqual(nerva.ChangeKind.delete, changes[2].kind);
    for (changes[0..3]) |change| try testing.expectEqual(op, change.op);
}

test "commit: delete leaves a tombstone version, and the row can come back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    _ = try context.commit(&.{&.{put(3, 1, 1)}});
    const op_delete = (try context.commit(&.{&.{delete(3, 1)}}))[0][0].op;

    const deleted = try context.lookup(3, 1);
    try testing.expect(!deleted.flags.exists);
    try testing.expectEqual(op_delete, deleted.op);
    try testing.expectEqual(value(0), deleted.value);

    // Reading it as never-existed is stale: the tombstone's version is the delete.
    try expect_statuses((try context.commit(&.{&.{ read(3, 1, 0), put(3, 1, 2) }}))[0], &.{
        .conflict,
        .aborted,
    });

    const back = try context.commit(&.{&.{ read(3, 1, op_delete), put(3, 1, 2) }});
    try expect_statuses(back[0], &.{ .ok, .ok });
    try testing.expect((try context.lookup(3, 1)).flags.exists);

    // Deleting a row that never existed is a no-op that still commits.
    try expect_statuses((try context.commit(&.{&.{delete(3, 99)}}))[0], &.{.ok});
    try testing.expectEqual(@as(u64, 0), (try context.lookup(3, 99)).op);
}

test "commit: invalid entries abort the transaction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    try expect_statuses((try context.commit(&.{&.{ put(1, 1, 1), put(0, 1, 1) }}))[0], &.{
        .aborted,
        .table_invalid,
    });

    try expect_statuses(
        (try context.commit(&.{&.{ put(1, 1, 1), read(1, 1, 0), put(1, 1, 2) }}))[0],
        &.{ .aborted, .aborted, .write_duplicate },
    );

    var reserved = put(1, 1, 1);
    reserved.reserved_b = 1;
    try expect_statuses((try context.commit(&.{&.{reserved}}))[0], &.{.reserved_not_zero});

    var read_with_value = read(1, 1, 0);
    read_with_value.value[0] = 1;
    try expect_statuses((try context.commit(&.{&.{read_with_value}}))[0], &.{.value_not_zero});

    // Nothing was applied by any of the above.
    try testing.expectEqual(@as(u64, 0), (try context.lookup(1, 1)).op);
    try testing.expectEqual(@as(usize, 1), (try context.changes(0, 10)).len); // Just `end`.
}

test "get_changes: committed writes in op order, paged by cursor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    const op_a = (try context.commit(&.{&.{ put(1, 1, 1), put(1, 2, 2) }}))[0][0].op;
    _ = try context.commit(&.{&.{ read(1, 1, 0), put(1, 1, 9) }}); // Conflicts: no change.
    const op_b = (try context.commit(&.{&.{ delete(1, 1), read(1, 2, op_a) }}))[0][0].op;

    const all = try context.changes(0, 10);
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expectEqual(nerva.ChangeKind.put, all[0].kind);
    try testing.expectEqual(@as(u64, 1), all[0].id);
    try testing.expectEqual(op_a, all[0].op);
    try testing.expectEqual(value(1), all[0].value);
    try testing.expectEqual(@as(u64, 2), all[1].id);
    try testing.expectEqual(op_a, all[1].op);
    try testing.expectEqual(nerva.ChangeKind.delete, all[2].kind);
    try testing.expectEqual(op_b, all[2].op);
    try testing.expectEqual(value(0), all[2].value);
    try testing.expect(all[0].timestamp < all[1].timestamp);
    try testing.expect(all[1].timestamp < all[2].timestamp);

    const end = all[3];
    try testing.expectEqual(nerva.ChangeKind.end, end.kind);
    try testing.expect(!end.flags.more);
    try testing.expect(end.op > op_b); // The op of the query itself.
    try testing.expectEqual(all[2].timestamp + 1, end.timestamp);

    // Paging: two pages of at most two changes reassemble the feed exactly.
    const page_1 = try context.changes(0, 2);
    try testing.expectEqual(@as(usize, 3), page_1.len);
    try testing.expect(page_1[2].flags.more);
    try testing.expectEqual(@as(u64, 0), page_1[2].op);
    const page_2 = try context.changes(page_1[2].timestamp, 2);
    try testing.expectEqual(@as(usize, 2), page_2.len);
    try testing.expect(!page_2[1].flags.more);
    try testing.expectEqual(all[0].timestamp, page_1[0].timestamp);
    try testing.expectEqual(all[1].timestamp, page_1[1].timestamp);
    try testing.expectEqual(all[2].timestamp, page_2[0].timestamp);

    // Nothing after the cursor: just `end`, with the cursor unchanged.
    const none = try context.changes(end.timestamp, 10);
    try testing.expectEqual(@as(usize, 1), none.len);
    try testing.expectEqual(end.timestamp, none[0].timestamp);
}

fn receipt(context: *Context, id: u64) !struct { op: u64, receipt: Receipt } {
    const row = try context.lookup(workload.receipts_table, id);
    return .{ .op = row.op, .receipt = Receipt.from_value(&row.value) };
}

test "receipt race: two daemons claim one receipt, exactly one wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    // Both daemons saw the receipt before anyone claimed it (version 0, seq 0).
    const daemon_a = receipt_claim(7, 0, 0, 1);
    const daemon_b = receipt_claim(7, 0, 0, 2);
    const results = try context.commit(&.{ &daemon_a, &daemon_b });
    try expect_statuses(results[0], &.{ .ok, .ok });
    try expect_statuses(results[1], &.{ .conflict, .aborted });
    try testing.expectEqual(results[0][0].op, results[1][0].op); // The winner's version.

    const current = try receipt(context, 7);
    try testing.expectEqual(@as(u64, 1), current.receipt.seq);
    try testing.expectEqual(@as(u64, 1), current.receipt.owner);
}

test "receipt race: a hand-off wins with the new version, a stale retry loses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    const op_a = (try context.commit(&.{&receipt_claim(3, 0, 0, 1)}))[0][0].op;

    // Daemon B read the receipt after A's claim, and takes it over.
    const handoff = try context.commit(&.{&receipt_claim(3, op_a, 1, 2)});
    try expect_statuses(handoff[0], &.{ .ok, .ok });
    const op_b = handoff[0][0].op;

    // Daemon A retries with what it saw before B's claim: it loses, told B's version.
    const stale = try context.commit(&.{&receipt_claim(3, op_a, 1, 1)});
    try expect_statuses(stale[0], &.{ .conflict, .aborted });
    try testing.expectEqual(op_b, stale[0][0].op);

    const current = try receipt(context, 3);
    try testing.expectEqual(op_b, current.op);
    try testing.expectEqual(@as(u64, 2), current.receipt.seq);
    try testing.expectEqual(@as(u64, 2), current.receipt.owner);
}
