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

    fn history(context: *Context, filter: nerva.HistoryFilter) ![]const Change {
        const results = try context.execute(.get_history, &.{&.{filter}});
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

/// An add to the u64 field at `offset`.
fn add(table: u32, id: u64, offset: u8, delta: i64, options: struct {
    min: ?u64 = null,
    max: ?u64 = null,
    clamp: bool = false,
    create: bool = false,
    delta_from: ?u32 = null,
}) Entry {
    const parameters: nerva.Add = .{
        .delta = delta,
        .min = options.min orelse 0,
        .max = options.max orelse 0,
        .delta_from = options.delta_from orelse 0,
        .offset = offset,
        .field = .u64,
        .flags = .{
            .min = options.min != null,
            .max = options.max != null,
            .clamp = options.clamp,
            .create = options.create,
            .delta_from = options.delta_from != null,
        },
    };
    return .{
        .id = id,
        .table = table,
        .kind = .add,
        .op_seen = 0,
        .value = parameters.value(),
    };
}

fn field(row: RowValue, offset: u8) u64 {
    return std.mem.readInt(u64, row.value[offset..][0..8], .little);
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
    try testing.expectEqual(op_commit + 1, row.op_read); // The lookup's own op.
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

test "commit: identical writes to one row in one request" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    // The second put leaves the row as the first left it: still a change of its own.
    const results = try context.commit(&.{ &.{put(1, 1, 7)}, &.{put(1, 1, 7)} });
    for (results) |result| try expect_statuses(result, &.{.ok});
    try testing.expectEqual(value(7), (try context.lookup(1, 1)).value);
    try testing.expectEqual(@as(usize, 3), (try context.changes(0, 10)).len);

    // An add that applies nothing, after an add in the same op.
    const adds = try context.commit(&.{
        &.{add(1, 2, 0, 5, .{ .create = true })},
        &.{add(1, 2, 0, 0, .{})},
    });
    for (adds) |result| try expect_statuses(result, &.{.ok});
    try testing.expectEqual(@as(u64, 5), field(try context.lookup(1, 2), 0));
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

const latest = std.math.maxInt(u64);

fn history_filter(
    table: u32,
    id: u64,
    limit: u32,
    op_max: u64,
    timestamp_max: u64,
) nerva.HistoryFilter {
    return .{
        .table = table,
        .id = id,
        .limit = limit,
        .op_max = op_max,
        .timestamp_max = timestamp_max,
    };
}

test "get_history: a row as of any op, newest first, paged by cursor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    const op_1 = (try context.commit(&.{&.{ put(1, 1, 1), put(1, 2, 7) }}))[0][0].op;
    const op_2 = (try context.commit(&.{&.{put(1, 1, 2)}}))[0][0].op;
    const op_3 = (try context.commit(&.{&.{delete(1, 1)}}))[0][0].op;
    const op_4 = (try context.commit(&.{&.{put(1, 1, 4)}}))[0][0].op;
    _ = try context.commit(&.{&.{ read(1, 1, op_1), put(1, 1, 9) }}); // Conflicts: no change.

    // The whole history of (1, 1), newest first; other rows are not in it.
    const all = try context.history(history_filter(1, 1, 10, latest, 0));
    try testing.expectEqual(@as(usize, 5), all.len);
    const ops = [_]u64{ op_4, op_3, op_2, op_1 };
    const kinds = [_]nerva.ChangeKind{ .put, .delete, .put, .put };
    const bytes = [_]u8{ 4, 0, 2, 1 };
    for (all[0..4], ops, kinds, bytes) |change, op, kind, byte| {
        try testing.expectEqual(op, change.op);
        try testing.expectEqual(kind, change.kind);
        try testing.expectEqual(value(byte), change.value);
        try testing.expectEqual(@as(u64, 1), change.id);
    }
    try testing.expectEqual(nerva.ChangeKind.end, all[4].kind);
    try testing.expect(!all[4].flags.more);
    try testing.expect(all[4].op > op_4); // The op of the query itself.
    try testing.expectEqual(@as(u64, 0), all[4].timestamp);

    // As of each op: the first change returned is the row at that op.
    const as_of_2 = try context.history(history_filter(1, 1, 10, op_2, 0));
    try testing.expectEqual(@as(usize, 3), as_of_2.len);
    try testing.expectEqual(op_2, as_of_2[0].op);
    try testing.expectEqual(value(2), as_of_2[0].value);
    const as_of_3 = try context.history(history_filter(1, 1, 1, op_3, 0));
    // The scan reached op 4 first: no change returned yet, page on.
    try testing.expectEqual(@as(usize, 1), as_of_3.len);
    try testing.expect(as_of_3[0].flags.more);
    try testing.expectEqual(all[0].timestamp - 1, as_of_3[0].timestamp);
    const as_of_3_next = try context.history(history_filter(1, 1, 1, op_3, as_of_3[0].timestamp));
    try testing.expectEqual(@as(usize, 2), as_of_3_next.len);
    try testing.expectEqual(nerva.ChangeKind.delete, as_of_3_next[0].kind);
    try testing.expectEqual(op_3, as_of_3_next[0].op);
    try testing.expect(as_of_3_next[1].flags.more);

    // Before the row's first write: nothing.
    _ = try context.commit(&.{&.{put(1, 3, 3)}});
    const op_5 = (try context.commit(&.{&.{put(1, 4, 5)}}))[0][0].op;
    const before = try context.history(history_filter(1, 4, 10, op_5 - 1, 0));
    try testing.expectEqual(@as(usize, 1), before.len);
    try testing.expect(!before[0].flags.more);
    const never = try context.history(history_filter(2, 1, 10, latest, 0));
    try testing.expectEqual(@as(usize, 1), never.len);

    // Invalid filters return nothing at all.
    const invalid = [_]nerva.HistoryFilter{
        history_filter(0, 1, 10, latest, 0), // Table zero.
        history_filter(1, 1, 0, latest, 0), // No limit.
        history_filter(1, 1, 10, 0, 0), // As of op zero.
    };
    for (invalid) |filter| {
        try testing.expectEqual(@as(usize, 0), (try context.history(filter)).len);
    }
    var reserved = history_filter(1, 1, 10, latest, 0);
    reserved.reserved[31] = 1;
    try testing.expectEqual(@as(usize, 0), (try context.history(reserved)).len);
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

test "add: adds to one row never conflict, and apply in log order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    // Three transactions in one request, each adding to the same row without reading it.
    const results = try context.commit(&.{
        &.{add(1, 1, 0, 100, .{ .create = true })},
        &.{add(1, 1, 0, -30, .{})},
        &.{ add(1, 1, 0, 5, .{}), add(1, 1, 8, 7, .{}) },
    });
    for (results) |result| for (result) |r| try testing.expectEqual(nerva.EntryStatus.ok, r.status);
    try testing.expectEqual(@as(u64, 100), results[0][0].value);
    try testing.expectEqual(@as(u64, 70), results[1][0].value);
    try testing.expectEqual(@as(i64, -30), results[1][0].applied);
    try testing.expectEqual(@as(u64, 75), results[2][0].value);
    try testing.expectEqual(@as(u64, 7), results[2][1].value);

    const row = try context.lookup(1, 1);
    try testing.expectEqual(@as(u64, 75), field(row, 0));
    try testing.expectEqual(@as(u64, 7), field(row, 8));
    try testing.expectEqual(results[0][0].op, row.op);

    // Every add is a put of the whole row in the feed.
    const changes = try context.changes(0, 10);
    try testing.expectEqual(@as(usize, 5), changes.len);
    try testing.expectEqual(nerva.ChangeKind.put, changes[3].kind);
    try testing.expectEqual(@as(u64, 75), std.mem.readInt(u64, changes[3].value[0..8], .little));
    try testing.expectEqual(row.value, changes[3].value);
}

test "add: bounds refuse the transaction, or clamp to what fits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    _ = try context.commit(&.{&.{add(1, 1, 0, 20, .{ .create = true })}});

    // Past the bound: out_of_bounds with the current value; the put before it is not applied.
    const refused = try context.commit(&.{&.{ put(1, 2, 9), add(1, 1, 0, -30, .{ .min = 0 }) }});
    try expect_statuses(refused[0], &.{ .aborted, .out_of_bounds });
    try testing.expectEqual(@as(u64, 20), refused[0][1].value);
    try testing.expect(!(try context.lookup(1, 2)).flags.exists);

    // "Reserve up to 30": takes the 20 there is.
    const clamped = try context.commit(&.{&.{add(1, 1, 0, -30, .{ .min = 0, .clamp = true })}});
    try expect_statuses(clamped[0], &.{.ok});
    try testing.expectEqual(@as(i64, -20), clamped[0][0].applied);
    try testing.expectEqual(@as(u64, 0), clamped[0][0].value);

    // Nothing left: applies nothing, still commits.
    const empty = try context.commit(&.{&.{add(1, 1, 0, -30, .{ .min = 0, .clamp = true })}});
    try expect_statuses(empty[0], &.{.ok});
    try testing.expectEqual(@as(i64, 0), empty[0][0].applied);

    // Below zero without a bound: out of the type's range.
    try expect_statuses((try context.commit(&.{&.{add(1, 1, 0, -1, .{})}}))[0], &.{.out_of_bounds});
    // Past a maximum.
    try expect_statuses(
        (try context.commit(&.{&.{add(1, 1, 0, 11, .{ .max = 10 })}}))[0],
        &.{.out_of_bounds},
    );
}

test "add: a reservation with delta_from moves exactly what was taken" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    // available at offset 0, held at offset 8, in one row.
    _ = try context.commit(&.{&.{add(1, 1, 0, 50, .{ .create = true })}});
    const reserve = [_]Entry{
        add(1, 1, 0, -30, .{ .min = 0, .clamp = true }),
        add(1, 1, 8, 0, .{ .delta_from = 0 }),
    };
    const results = try context.commit(&.{ &reserve, &reserve });
    try expect_statuses(results[0], &.{ .ok, .ok });
    try expect_statuses(results[1], &.{ .ok, .ok });
    try testing.expectEqual(@as(i64, 30), results[0][1].applied);
    try testing.expectEqual(@as(i64, -20), results[1][0].applied);
    try testing.expectEqual(@as(i64, 20), results[1][1].applied);

    const row = try context.lookup(1, 1);
    try testing.expectEqual(@as(u64, 0), field(row, 0));
    try testing.expectEqual(@as(u64, 50), field(row, 8));
}

test "add: absent rows, mixed writes and invalid references are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    try expect_statuses((try context.commit(&.{&.{add(1, 1, 0, 1, .{})}}))[0], &.{.row_absent});

    // A deleted row is absent too; `create` starts it from zeros.
    _ = try context.commit(&.{&.{put(1, 2, 0xff)}});
    _ = try context.commit(&.{&.{delete(1, 2)}});
    try expect_statuses((try context.commit(&.{&.{add(1, 2, 0, 1, .{})}}))[0], &.{.row_absent});
    const created = try context.commit(&.{&.{add(1, 2, 0, 1, .{ .create = true })}});
    try testing.expectEqual(@as(u64, 1), created[0][0].value);
    try testing.expectEqual(value(0)[8..].*, (try context.lookup(1, 2)).value[8..].*);

    // An add and a put of one row in one transaction.
    try expect_statuses(
        (try context.commit(&.{&.{ add(1, 2, 0, 1, .{}), put(1, 2, 1) }}))[0],
        &.{ .aborted, .write_duplicate },
    );
    try expect_statuses(
        (try context.commit(&.{&.{ put(1, 3, 1), add(1, 3, 0, 1, .{ .create = true }) }}))[0],
        &.{ .aborted, .write_duplicate },
    );

    // `delta_from` must name an earlier add.
    try expect_statuses(
        (try context.commit(&.{&.{add(1, 2, 0, 0, .{ .delta_from = 0 })}}))[0],
        &.{.delta_from_invalid},
    );
    try expect_statuses(
        (try context.commit(&.{&.{ put(1, 4, 1), add(1, 2, 0, 0, .{ .delta_from = 0 }) }}))[0],
        &.{ .aborted, .delta_from_invalid },
    );

    // Reads still come first: a stale read conflicts even if the adds would apply.
    try expect_statuses(
        (try context.commit(&.{&.{ add(1, 2, 0, 1, .{}), read(1, 2, 1) }}))[0],
        &.{ .aborted, .conflict },
    );
    try testing.expectEqual(@as(u64, 1), field(try context.lookup(1, 2), 0));
}

test "format: what a fixed script commits" {
    // A format guard (N51): every result, row and change a fixed script produces, summarized and
    // checksummed. A change to what the state machine stores (ops, timestamps, tombstones, add
    // results, change values) fails here; a meant one updates the snapshot and says why.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    const signed_add: Entry = .{
        .id = 3,
        .table = 1,
        .kind = .add,
        .op_seen = 0,
        .value = (nerva.Add{
            .delta = -5,
            .min = 0,
            .max = 0,
            .delta_from = 0,
            .offset = 8,
            .field = .i64,
            .flags = .{ .create = true },
        }).value(),
    };
    const requests = [_][]const []const Entry{
        // Puts, adds creating a row (unsigned and signed), all in one request.
        &.{
            &.{ put(1, 1, 0xA1), put(1, 2, 0xA2) },
            &.{ add(1, 3, 0, 100, .{ .create = true }), signed_add },
        },
        // A delete; a read at the version seen, then a put.
        &.{ &.{delete(1, 2)}, &.{ read(1, 1, 1), put(1, 1, 0xB1) } },
        // A re-create; a clamped reservation moved by `delta_from`.
        &.{
            &.{put(1, 2, 0xC2)},
            &.{
                add(1, 3, 0, -150, .{ .min = 0, .clamp = true }),
                add(1, 3, 16, 0, .{ .delta_from = 0 }),
            },
        },
        // A stale read: the transaction fails whole.
        &.{&.{ read(1, 1, 1), put(1, 4, 0xD4) }},
    };

    var summary = std.ArrayList(u8).init(arena.allocator());
    const writer = summary.writer();
    var checksum_input = std.ArrayList(u8).init(arena.allocator());

    for (requests, 0..) |request, request_index| {
        const results = try context.commit(request);
        for (results, 0..) |transaction, transaction_index| {
            for (transaction) |result| {
                try writer.print("commit {}.{}: {s} op={} applied={} value={}\n", .{
                    request_index,
                    transaction_index,
                    @tagName(result.status),
                    result.op,
                    result.applied,
                    result.value,
                });
                try checksum_input.appendSlice(std.mem.asBytes(&result));
            }
        }
    }
    for (1..5) |id| {
        const row = try context.lookup(1, id);
        try writer.print("row 1/{}: exists={} op={} op_read={} value[0..24]={}\n", .{
            id,
            row.flags.exists,
            row.op,
            row.op_read,
            std.fmt.fmtSliceHexLower(row.value[0..24]),
        });
        try checksum_input.appendSlice(std.mem.asBytes(&row));
    }
    for (try context.changes(0, 100)) |change| {
        try writer.print("change: {s} {}/{} op={} timestamp={} more={}\n", .{
            @tagName(change.kind),
            change.table,
            change.id,
            change.op,
            change.timestamp,
            change.flags.more,
        });
        try checksum_input.appendSlice(std.mem.asBytes(&change));
    }
    for (try context.history(history_filter(1, 2, 100, std.math.maxInt(u64), 0))) |change| {
        try writer.print("history 1/2: {s} op={} timestamp={}\n", .{
            @tagName(change.kind),
            change.op,
            change.timestamp,
        });
        try checksum_input.appendSlice(std.mem.asBytes(&change));
    }
    try writer.print("checksum: {x:0>32}\n", .{vsr.checksum(checksum_input.items)});

    const snap = stdx.Snap.snap_fn("src");
    try snap(@src(),
        \\commit 0.0: ok op=1 applied=0 value=0
        \\commit 0.0: ok op=1 applied=0 value=0
        \\commit 0.1: ok op=1 applied=100 value=100
        \\commit 0.1: ok op=1 applied=-5 value=18446744073709551611
        \\commit 1.0: ok op=2 applied=0 value=0
        \\commit 1.1: ok op=2 applied=0 value=0
        \\commit 1.1: ok op=2 applied=0 value=0
        \\commit 2.0: ok op=3 applied=0 value=0
        \\commit 2.1: ok op=3 applied=-100 value=0
        \\commit 2.1: ok op=3 applied=100 value=100
        \\commit 3.0: conflict op=2 applied=0 value=0
        \\commit 3.0: aborted op=0 applied=0 value=0
        \\row 1/1: exists=true op=2 op_read=5 value[0..24]=b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1
        \\row 1/2: exists=true op=3 op_read=6 value[0..24]=c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2
        \\row 1/3: exists=true op=3 op_read=7 value[0..24]=0000000000000000fbffffffffffffff6400000000000000
        \\row 1/4: exists=false op=0 op_read=8 value[0..24]=000000000000000000000000000000000000000000000000
        \\change: put 1/1 op=1 timestamp=1 more=false
        \\change: put 1/2 op=1 timestamp=2 more=false
        \\change: put 1/3 op=1 timestamp=3 more=false
        \\change: put 1/3 op=1 timestamp=4 more=false
        \\change: delete 1/2 op=2 timestamp=5 more=false
        \\change: put 1/1 op=2 timestamp=7 more=false
        \\change: put 1/2 op=3 timestamp=8 more=false
        \\change: put 1/3 op=3 timestamp=9 more=false
        \\change: put 1/3 op=3 timestamp=10 more=false
        \\change: end 0/0 op=9 timestamp=11 more=false
        \\history 1/2: put op=3 timestamp=8
        \\history 1/2: delete op=2 timestamp=5
        \\history 1/2: put op=1 timestamp=2
        \\history 1/2: end op=10 timestamp=0
        \\checksum: fe42e6a1c001fed7e514f8c26ad02bef
        \\
    ).diff(summary.items);
}
