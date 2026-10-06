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
    /// Set while the forest compacts or checkpoints.
    forest_busy: bool = false,
    superblock_context: SuperBlock.Context = undefined,

    fn init(context: *Context, arena: std.mem.Allocator) !void {
        context.* = .{
            .arena = arena,
            .storage = try fixtures.init_storage(arena, .{
                .size = constants.storage_size_limit_default,
            }),
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
        try fixtures.storage_format(arena, &context.storage, .{});
        context.superblock = try fixtures.init_superblock(arena, &context.storage, .{});
        fixtures.open_superblock(&context.superblock);
        context.grid = try fixtures.init_grid(arena, &context.trace, &context.superblock, .{});
        fixtures.open_grid(&context.grid);
        // The first checkpoint is trivially durable.
        context.grid.free_set.mark_checkpoint_durable();
        try context.state_machine.init(arena, context.time_sim.interface(), &context.grid, .{
            .batch_size_limit = constants.message_body_size_max,
            .lsm_forest_node_count = 1024,
        });
        context.forest_busy = true;
        context.state_machine.open(forest_callback);
        context.forest_run();
    }

    fn forest_callback(state_machine: *StateMachine) void {
        const context: *Context = @fieldParentPtr("state_machine", state_machine);
        assert(context.forest_busy);
        context.forest_busy = false;
    }

    fn forest_run(context: *Context) void {
        while (context.forest_busy) context.storage.run();
    }

    /// Ends an op as the replica does: compacts, and checkpoints when the op triggers one, so
    /// that tests may run for many ops.
    fn op_end(context: *Context) void {
        const op = context.op;
        context.op += 1;

        context.forest_busy = true;
        context.state_machine.compact(forest_callback, op);
        context.forest_run();

        const checkpoint_op_previous = context.superblock.working.vsr_state.checkpoint.header.op;
        const trigger = vsr.Checkpoint.trigger_for_checkpoint(
            vsr.Checkpoint.checkpoint_after(checkpoint_op_previous),
        );
        if (trigger == null or op != trigger.?) return;
        const checkpoint_op = op - constants.lsm_compaction_ops;

        context.forest_busy = true;
        context.state_machine.checkpoint(forest_callback);
        context.forest_run();

        const Grid_ = @TypeOf(context.grid);
        const grid_done = struct {
            var done = false;
            fn callback(_: *Grid_) void {
                done = true;
            }
        };
        grid_done.done = false;
        context.grid.checkpoint(grid_done.callback);
        while (!grid_done.done) context.storage.run();

        context.forest_busy = true;
        context.superblock.checkpoint(superblock_callback, &context.superblock_context, .{
            .header = header: {
                var header = vsr.Header.Prepare.root(fixtures.cluster);
                header.op = checkpoint_op;
                header.set_checksum();
                break :header header;
            },
            .view_attributes = null,
            .manifest_references = context.state_machine.forest.manifest_log
                .checkpoint_references(),
            .free_set_references = .{
                .blocks_acquired = context.grid
                    .free_set_checkpoint_blocks_acquired.checkpoint_reference(),
                .blocks_released = context.grid
                    .free_set_checkpoint_blocks_released.checkpoint_reference(),
            },
            .client_sessions_reference = .{
                .last_block_checksum = 0,
                .last_block_address = 0,
                .trailer_size = 0,
                .checksum = vsr.checksum(&.{}),
            },
            .commit_max = checkpoint_op + 1,
            .sync_op_min = 0,
            .sync_op_max = 0,
            .storage_size = data_file_size_min +
                (context.grid.free_set.highest_address_acquired() orelse 0) * constants.block_size,
            .release = vsr.Release.minimum,
        });
        context.forest_run();
        // One process: every checkpoint is durable at once.
        context.grid.mark_checkpoint_not_durable();
        context.grid.free_set.mark_checkpoint_durable();
    }

    fn superblock_callback(superblock_context: *SuperBlock.Context) void {
        const context: *Context = @alignCast(@fieldParentPtr("superblock_context", superblock_context));
        assert(context.forest_busy);
        context.forest_busy = false;
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
        // The reply is copied out below, before the next op.
        const reply = context.reply[0..reply_size];
        defer context.op_end();

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

    fn declare(context: *Context, definition: nerva.ViewDefinition) !nerva.DeclareResult {
        const results = try context.execute(.declare_view, &.{&.{definition}});
        assert(results[0].len == 1);
        return results[0][0];
    }

    fn declare_ledger(
        context: *Context,
        definition: nerva.LedgerDefinition,
    ) !nerva.DeclareLedgerResult {
        const results = try context.execute(.declare_ledger, &.{&.{definition}});
        assert(results[0].len == 1);
        return results[0][0];
    }

    fn get_ledger(context: *Context, id: u32) !nerva.Ledger {
        return context.get_ledger_query(.{ .id = id });
    }

    fn get_ledger_query(context: *Context, query: nerva.LedgerQuery) !nerva.Ledger {
        const results = try context.execute(.get_ledger, &.{&.{query}});
        assert(results[0].len == 1);
        return results[0][0];
    }

    /// The header, then the page's groups.
    fn view(context: *Context, query: nerva.ViewQuery) ![]const nerva.ViewRecord {
        const results = try context.execute(.get_view, &.{&.{query}});
        return results[0];
    }

    /// A `pulse`, as the replica sends it to itself: no body, no reply.
    fn pulse(context: *Context) void {
        const state_machine = &context.state_machine;
        const body = context.request[0..0];
        assert(state_machine.input_valid(.pulse, body));
        state_machine.prepare(.pulse, body);
        if (state_machine.prepare_timestamp == state_machine.commit_timestamp) {
            state_machine.prepare_timestamp += 1;
        }
        const timestamp = state_machine.prepare_timestamp;
        context.prefetching = true;
        state_machine.prefetch_timestamp = timestamp;
        state_machine.prefetch(prefetch_callback, context.op, context.op, .pulse, body);
        while (context.prefetching) context.storage.run();
        const reply_size = state_machine.commit(1, context.op, timestamp, .pulse, body, context.reply);
        assert(reply_size == 0);
        state_machine.commit_timestamp = timestamp;
        context.op_end();
    }

    /// Pulses until no view is building; returns the number of pulses.
    fn pulse_until_ready(context: *Context) u32 {
        var pulses: u32 = 0;
        while (context.state_machine.pulse_needed(0)) : (pulses += 1) {
            assert(pulses < 10_000);
            context.pulse();
        }
        return pulses;
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

// ---- Ledgers: conserved fields (N75) ----

/// Accounts in table 7 (`available` at 0 and `held` at 8, both floored at 0), and a source in
/// table 9 (`balance` at 0, no floor): ledger 1.
const accounts = 7;
const sources = 9;

fn conserved(table: u32, offset: u8, floor: ?i64) nerva.LedgerField {
    return .{
        .table = table,
        .offset = offset,
        .flags = .{ .floor = floor != null },
        .floor = floor orelse 0,
    };
}

fn ledger_definition(id: u32, fields: []const nerva.LedgerField) nerva.LedgerDefinition {
    var definition = std.mem.zeroes(nerva.LedgerDefinition);
    definition.id = id;
    definition.field_count = @intCast(fields.len);
    @memcpy(definition.fields[0..fields.len], fields);
    return definition;
}

fn accounts_ledger() nerva.LedgerDefinition {
    return ledger_definition(1, &.{
        conserved(accounts, 0, 0),
        conserved(accounts, 8, 0),
        conserved(sources, 0, null),
    });
}

/// An add to the i64 field at `offset`.
fn move(table: u32, id: u64, offset: u8, delta: i64, options: struct {
    min: ?i64 = null,
    max: ?i64 = null,
    clamp: bool = false,
    create: bool = false,
    delta_from: ?u32 = null,
    pair: bool = false,
}) Entry {
    const parameters: nerva.Add = .{
        .delta = delta,
        .min = @bitCast(options.min orelse 0),
        .max = @bitCast(options.max orelse 0),
        .delta_from = options.delta_from orelse 0,
        .offset = offset,
        .field = .i64,
        .flags = .{
            .min = options.min != null,
            .max = options.max != null,
            .clamp = options.clamp,
            .create = options.create,
            .delta_from = options.delta_from != null,
            .pair = options.pair,
        },
    };
    return .{ .id = id, .table = table, .kind = .add, .op_seen = 0, .value = parameters.value() };
}

/// The partner of the pair whose first half is at `first`.
fn partner(table: u32, id: u64, offset: u8, first: u32) Entry {
    return move(table, id, offset, 0, .{ .delta_from = first, .create = true });
}

fn signed(row: RowValue, offset: u8) i64 {
    return std.mem.readInt(i64, row.value[offset..][0..8], .little);
}

/// Declares the accounts ledger and funds account 1 with `amount` from source 1.
fn ledger_funded(context: *Context, amount: i64) !void {
    const declared = try context.declare_ledger(accounts_ledger());
    try testing.expectEqual(nerva.DeclareLedgerStatus.created, declared.status);
    const funded = try context.commit(&.{&.{
        move(sources, 1, 0, -amount, .{ .pair = true, .create = true }),
        partner(accounts, 1, 0, 0),
    }});
    try expect_statuses(funded[0], &.{ .ok, .ok });
}

/// The ledger's total over the rows the tests use: it must never change.
fn ledger_total(context: *Context) !i64 {
    var total: i64 = 0;
    for (1..4) |id| {
        const account = try context.lookup(accounts, id);
        total += signed(account, 0) + signed(account, 8);
        total += signed(try context.lookup(sources, id), 0);
    }
    return total;
}

test "ledger: a pair moves one amount between conserved fields, and the total stays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);
    try ledger_funded(context, 50);
    try testing.expectEqual(0, try ledger_total(context));

    // available -5 -> held, in one row.
    const reserved = try context.commit(&.{&.{
        move(accounts, 1, 0, -5, .{ .pair = true }),
        partner(accounts, 1, 8, 0),
    }});
    try expect_statuses(reserved[0], &.{ .ok, .ok });
    try testing.expectEqual(5, reserved[0][1].applied);
    const account = try context.lookup(accounts, 1);
    try testing.expectEqual(45, signed(account, 0));
    try testing.expectEqual(5, signed(account, 8));
    // A field without a floor goes negative: the source the funds came from.
    try testing.expectEqual(-50, signed(try context.lookup(sources, 1), 0));
    try testing.expectEqual(0, try ledger_total(context));

    // Several pairs in one transaction, and on one row, stack.
    const posted = try context.commit(&.{&.{
        move(accounts, 1, 8, -3, .{ .pair = true }),
        partner(accounts, 2, 0, 0),
        move(accounts, 1, 8, -2, .{ .pair = true }),
        partner(accounts, 1, 0, 2),
    }});
    try expect_statuses(posted[0], &.{ .ok, .ok, .ok, .ok });
    try testing.expectEqual(47, signed(try context.lookup(accounts, 1), 0));
    try testing.expectEqual(3, signed(try context.lookup(accounts, 2), 0));
    try testing.expectEqual(0, try ledger_total(context));

    // Adds outside the ledger, on its tables or others, need no partner (N42 as before).
    const other = try context.commit(&.{&.{
        move(accounts, 1, 16, 9, .{}),
        add(1, 1, 0, 4, .{ .create = true }),
    }});
    try expect_statuses(other[0], &.{ .ok, .ok });
    try testing.expectEqual(9, signed(try context.lookup(accounts, 1), 16));
}

test "ledger: conserved adds outside a pair are unpaired, and nothing applies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);
    try ledger_funded(context, 50);
    _ = try context.declare_ledger(ledger_definition(2, &.{
        conserved(accounts, 24, null),
        conserved(accounts, 32, null),
    }));
    const op_before = (try context.lookup(accounts, 1)).op;

    const Case = struct { entries: []const Entry, statuses: []const nerva.EntryStatus };
    const cases = [_]Case{
        // A first half without its partner; at the end of the transaction.
        .{
            .entries = &.{ move(accounts, 1, 0, -5, .{ .pair = true }), put(1, 1, 3) },
            .statuses = &.{ .unpaired, .aborted },
        },
        .{
            .entries = &.{ put(1, 1, 3), move(accounts, 1, 0, -5, .{ .pair = true }) },
            .statuses = &.{ .aborted, .unpaired },
        },
        // A conserved add without `pair`, alone or naming a non-conserved add.
        .{
            .entries = &.{move(accounts, 1, 0, -5, .{})},
            .statuses = &.{.unpaired},
        },
        .{
            .entries = &.{ add(1, 1, 0, 5, .{ .create = true }), partner(accounts, 1, 8, 0) },
            .statuses = &.{ .aborted, .unpaired },
        },
        // `pair` on an add outside every ledger.
        .{
            .entries = &.{
                move(accounts, 1, 16, -5, .{ .pair = true }),
                partner(accounts, 1, 8, 0),
            },
            .statuses = &.{ .unpaired, .aborted },
        },
        // The next entry does not name the first half, or is not an add.
        .{
            .entries = &.{
                move(accounts, 1, 0, -5, .{ .pair = true }),
                move(accounts, 1, 8, 5, .{}),
            },
            .statuses = &.{ .unpaired, .aborted },
        },
        .{
            .entries = &.{ move(accounts, 1, 0, -5, .{ .pair = true }), put(1, 1, 3) },
            .statuses = &.{ .unpaired, .aborted },
        },
        // A partner in another ledger, outside every ledger, or on the first half's own field.
        .{
            .entries = &.{
                move(accounts, 1, 0, -5, .{ .pair = true }),
                partner(accounts, 1, 24, 0),
            },
            .statuses = &.{ .aborted, .unpaired },
        },
        .{
            .entries = &.{
                move(accounts, 1, 0, -5, .{ .pair = true }),
                partner(accounts, 1, 16, 0),
            },
            .statuses = &.{ .aborted, .unpaired },
        },
        .{
            .entries = &.{
                move(accounts, 1, 0, -5, .{ .pair = true }),
                partner(accounts, 1, 0, 0),
            },
            .statuses = &.{ .aborted, .unpaired },
        },
        // A partner with bounds, `clamp` or `pair` of its own.
        .{
            .entries = &.{
                move(accounts, 1, 0, -5, .{ .pair = true }),
                move(accounts, 1, 8, 0, .{ .delta_from = 0, .max = 100 }),
            },
            .statuses = &.{ .aborted, .unpaired },
        },
        .{
            .entries = &.{
                move(accounts, 1, 0, -5, .{ .pair = true }),
                move(accounts, 1, 8, 0, .{ .delta_from = 0, .clamp = true }),
            },
            .statuses = &.{ .aborted, .unpaired },
        },
        .{
            .entries = &.{
                move(accounts, 1, 0, -5, .{ .pair = true }),
                move(accounts, 1, 8, 0, .{ .delta_from = 0, .pair = true }),
                partner(accounts, 2, 0, 1),
            },
            .statuses = &.{ .aborted, .unpaired, .aborted },
        },
        // A third add naming a first half: conserved, or not.
        .{
            .entries = &.{
                move(accounts, 1, 0, -5, .{ .pair = true }),
                partner(accounts, 1, 8, 0),
                partner(accounts, 2, 0, 0),
            },
            .statuses = &.{ .aborted, .aborted, .unpaired },
        },
        .{
            .entries = &.{
                move(accounts, 1, 0, -5, .{ .pair = true }),
                partner(accounts, 1, 8, 0),
                move(accounts, 1, 16, 0, .{ .delta_from = 0 }),
            },
            .statuses = &.{ .aborted, .aborted, .unpaired },
        },
    };
    for (cases) |case| {
        const results = try context.commit(&.{case.entries});
        try expect_statuses(results[0], case.statuses);
    }
    // Nothing applied.
    try testing.expectEqual(op_before, (try context.lookup(accounts, 1)).op);
    try testing.expect(!(try context.lookup(1, 1)).flags.exists);
    try testing.expectEqual(0, try ledger_total(context));
}

test "ledger: floors stop the first half, or clamp it; a partner never clamps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);
    try ledger_funded(context, 7);

    // Floor 0, no `min`, no clamp: out_of_bounds, with the current value.
    const refused = try context.commit(&.{&.{
        move(accounts, 1, 0, -10, .{ .pair = true }),
        partner(accounts, 1, 8, 0),
    }});
    try expect_statuses(refused[0], &.{ .out_of_bounds, .aborted });
    try testing.expectEqual(7, refused[0][0].value);

    // An entry's own `min` below the floor does not lower it.
    const below = try context.commit(&.{&.{
        move(accounts, 1, 0, -10, .{ .pair = true, .min = -100 }),
        partner(accounts, 1, 8, 0),
    }});
    try expect_statuses(below[0], &.{ .out_of_bounds, .aborted });

    // With clamp: "reserve up to 10" takes the 7 there is, and the partner gains exactly 7.
    const clamped = try context.commit(&.{&.{
        move(accounts, 1, 0, -10, .{ .pair = true, .clamp = true }),
        partner(accounts, 1, 8, 0),
    }});
    try expect_statuses(clamped[0], &.{ .ok, .ok });
    try testing.expectEqual(-7, clamped[0][0].applied);
    try testing.expectEqual(7, clamped[0][1].applied);

    // An entry's own `min` above the floor binds first.
    const bounded = try context.commit(&.{&.{
        move(accounts, 1, 8, -10, .{ .pair = true, .clamp = true, .min = 4 }),
        partner(accounts, 1, 0, 0),
    }});
    try expect_statuses(bounded[0], &.{ .ok, .ok });
    try testing.expectEqual(-3, bounded[0][0].applied);

    // The partner stopped by its own floor fails the whole transaction: here it would take
    // 5 from an `available` of 3.
    const stopped = try context.commit(&.{&.{
        move(accounts, 1, 8, 5, .{ .pair = true }),
        partner(accounts, 1, 0, 0),
    }});
    try expect_statuses(stopped[0], &.{ .aborted, .out_of_bounds });
    try testing.expectEqual(3, stopped[0][1].value);
    // Or by the i64 range.
    const overflow = try context.commit(&.{&.{
        move(sources, 2, 0, std.math.minInt(i64) + 1, .{ .pair = true, .create = true }),
        partner(sources, 3, 0, 0),
        move(sources, 4, 0, -10, .{ .pair = true, .create = true }),
        partner(sources, 3, 0, 2),
    }});
    try expect_statuses(overflow[0], &.{ .aborted, .aborted, .aborted, .out_of_bounds });

    const account = try context.lookup(accounts, 1);
    try testing.expectEqual(3, signed(account, 0));
    try testing.expectEqual(4, signed(account, 8));
    try testing.expectEqual(0, try ledger_total(context));
}

test "ledger: a field below its floor moves back up, never further down" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    // Rows written before the ledger: account 1's `available` is -4.
    _ = try context.commit(&.{&.{move(accounts, 1, 0, -4, .{ .create = true })}});
    _ = try context.declare_ledger(accounts_ledger());

    const down = try context.commit(&.{&.{
        move(accounts, 1, 0, -1, .{ .pair = true, .clamp = true }),
        partner(accounts, 1, 8, 0),
    }});
    try expect_statuses(down[0], &.{ .ok, .ok });
    try testing.expectEqual(0, down[0][0].applied);

    const up = try context.commit(&.{&.{
        move(sources, 1, 0, -6, .{ .pair = true, .create = true }),
        partner(accounts, 1, 0, 0),
    }});
    try expect_statuses(up[0], &.{ .ok, .ok });
    try testing.expectEqual(2, signed(try context.lookup(accounts, 1), 0));
}

test "ledger: puts, deletes and overlapping adds cannot change conserved fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);
    try ledger_funded(context, 50);

    var account = try context.lookup(accounts, 1);
    // A put that changes a conserved field, or creates a row with one not zero.
    var changed = put(accounts, 1, 0);
    changed.value = account.value;
    changed.value[3] ^= 1;
    try expect_statuses((try context.commit(&.{&.{changed}}))[0], &.{.conserved_write});
    try expect_statuses(
        (try context.commit(&.{&.{ put(5, 1, 1), put(accounts, 2, 1) }}))[0],
        &.{ .aborted, .conserved_write },
    );
    // One that changes only other fields of the row commits; so does one creating a row whose
    // conserved fields are zero.
    var other = put(accounts, 1, 0);
    other.value = account.value;
    other.value[16] = 0xaa;
    var created = put(accounts, 2, 0);
    @memset(created.value[16..], 0xbb);
    try expect_statuses((try context.commit(&.{&.{ other, created }}))[0], &.{ .ok, .ok });
    account = try context.lookup(accounts, 1);
    try testing.expectEqual(50, signed(account, 0));
    try testing.expectEqual(0xaa, account.value[16]);

    // A delete of a row holding a balance; then one whose conserved fields are all zero, and
    // one of a row that does not exist.
    try expect_statuses((try context.commit(&.{&.{delete(accounts, 1)}}))[0], &.{.conserved_write});
    try expect_statuses(
        (try context.commit(&.{&.{ delete(accounts, 2), delete(accounts, 3) }}))[0],
        &.{ .ok, .ok },
    );
    try testing.expect(!(try context.lookup(accounts, 2)).flags.exists);

    // An add straddling `available@0` and `held@8`, or matching a field as a u64.
    try expect_statuses(
        (try context.commit(&.{&.{move(accounts, 1, 4, 1, .{})}}))[0],
        &.{.conserved_write},
    );
    try expect_statuses(
        (try context.commit(&.{&.{add(accounts, 1, 8, 1, .{})}}))[0],
        &.{.conserved_write},
    );
    try expect_statuses(
        (try context.commit(&.{&.{
            move(accounts, 1, 0, -1, .{ .pair = true }),
            add(accounts, 1, 8, 0, .{ .delta_from = 0 }),
        }}))[0],
        &.{ .aborted, .conserved_write },
    );
    try testing.expectEqual(0, try ledger_total(context));
}

test "ledger: declarations are immutable, one ledger per field, and survive a reload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    const created = try context.declare_ledger(accounts_ledger());
    try testing.expectEqual(nerva.DeclareLedgerStatus.created, created.status);
    // Again, identically: a no-op that names the op it was declared at.
    const again = try context.declare_ledger(accounts_ledger());
    try testing.expectEqual(nerva.DeclareLedgerStatus.exists, again.status);
    try testing.expectEqual(created.op, again.op);

    var different = accounts_ledger();
    different.fields[2].flags.floor = true;
    try testing.expectEqual(
        nerva.DeclareLedgerStatus.ledger_immutable,
        (try context.declare_ledger(different)).status,
    );
    const taken = try context.declare_ledger(
        ledger_definition(2, &.{ conserved(accounts, 8, null), conserved(accounts, 16, null) }),
    );
    try testing.expectEqual(nerva.DeclareLedgerStatus.ledger_field_taken, taken.status);
    try testing.expectEqual(nerva.DeclareLedgerStatus.invalid, (try context.declare_ledger(
        ledger_definition(2, &.{conserved(accounts, 16, null)}),
    )).status);
    try testing.expectEqual(nerva.DeclareLedgerStatus.table_invalid, (try context.declare_ledger(
        ledger_definition(2, &.{ conserved(1, 0, null), conserved(0xFFFF_0001, 0, null) }),
    )).status);

    const stored = try context.get_ledger(1);
    try testing.expectEqual(1, stored.slot);
    try testing.expectEqual(created.op, stored.op);
    const definition = accounts_ledger();
    try testing.expect(stdx.equal_bytes(nerva.LedgerDefinition, &stored.definition, &definition));
    try testing.expect(stdx.zeroed(std.mem.asBytes(&try context.get_ledger(2))));
    // By slot (N78); never by both, nor with reserved bytes.
    const by_slot = try context.get_ledger_query(.{ .id = 0, .slot = 1 });
    try testing.expect(stdx.equal_bytes(nerva.Ledger, &stored, &by_slot));
    for ([_]nerva.LedgerQuery{
        .{ .id = 0, .slot = 2 },
        .{ .id = 1, .slot = 1 },
        .{ .id = 0, .slot = 1, .reserved = .{ 0, 0, 0, 1 } },
        .{ .id = 0 },
    }) |query| {
        try testing.expect(stdx.zeroed(std.mem.asBytes(&try context.get_ledger_query(query))));
    }

    // Writes on every kind of table id, the reserved ones included, leave the declaration.
    _ = try context.commit(&.{
        &.{ put(1, 1, 1), delete(1, 1) },
        &.{ put(0xFFFF_0001, 1, 1), delete(0xFFFF_0001, 1) },
        &.{ put(0xFFFF_FFFF, 1, 1), delete(0xFFFF_FFFF, 1) },
    });
    // What a reset (state sync) forgets: the state machine finds the ledger again.
    context.state_machine.ledger_count = null;
    context.state_machine.ledger_index = .{};
    try testing.expectEqual(created.op, (try context.get_ledger(1)).op);
    try testing.expectEqual(1, context.state_machine.ledger_index.ledger_count);
    try expect_statuses(
        (try context.commit(&.{&.{move(accounts, 1, 0, 5, .{ .create = true })}}))[0],
        &.{.unpaired},
    );

    // Up to `ledgers_max`, each over its own table.
    for (2..nerva.ledgers_max + 1) |id| {
        const table: u32 = @intCast(100 + id);
        const result = try context.declare_ledger(ledger_definition(
            @intCast(id),
            &.{ conserved(table, 0, null), conserved(table, 8, null) },
        ));
        try testing.expectEqual(nerva.DeclareLedgerStatus.created, result.status);
    }
    try testing.expectEqual(nerva.DeclareLedgerStatus.ledgers_full, (try context.declare_ledger(
        ledger_definition(1000, &.{ conserved(1, 0, null), conserved(1, 8, null) }),
    )).status);
    try testing.expectEqual(created.op, (try context.get_ledger(1)).op);
    try testing.expectEqual(nerva.ledgers_max, (try context.get_ledger(nerva.ledgers_max)).slot);
}

test "ledger: views cannot filter or group by a conserved field, in either order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    // The revenue view (table 5) groups by `section@0` (1 byte) and filters on `sold@16`; it
    // sums `price@8`.
    const revenue = try context.declare(revenue_view("revenue"));
    try testing.expectEqual(nerva.DeclareStatus.created, revenue.status);
    try testing.expectEqual(nerva.DeclareLedgerStatus.field_viewed, (try context.declare_ledger(
        ledger_definition(1, &.{ conserved(5, 0, null), conserved(sources, 0, null) }),
    )).status);
    try testing.expectEqual(nerva.DeclareLedgerStatus.field_viewed, (try context.declare_ledger(
        ledger_definition(1, &.{ conserved(5, 16, null), conserved(sources, 0, null) }),
    )).status);
    // Summing a conserved field is what views are for.
    try testing.expectEqual(nerva.DeclareLedgerStatus.created, (try context.declare_ledger(
        ledger_definition(1, &.{ conserved(5, 8, null), conserved(sources, 0, null) }),
    )).status);

    // The other order: a ledger on table 6, then views over it.
    try testing.expectEqual(nerva.DeclareLedgerStatus.created, (try context.declare_ledger(
        ledger_definition(2, &.{ conserved(6, 0, null), conserved(6, 16, null) }),
    )).status);
    var grouped = revenue_view("grouped");
    grouped.table = 6;
    const grouped_result = try context.declare(grouped);
    try testing.expectEqual(nerva.DeclareStatus.ledger_field, grouped_result.status);
    var filtered = revenue_view("filtered");
    filtered.table = 6;
    filtered.group_by[0] = .{ .offset = 24, .size = 1, .kind = .unsigned };
    const filtered_result = try context.declare(filtered);
    try testing.expectEqual(nerva.DeclareStatus.ledger_field, filtered_result.status);
    var summed = revenue_view("summed");
    summed.table = 6;
    summed.where_count = 0;
    summed.where[0] = std.mem.zeroes(nerva.Where);
    summed.group_by_count = 0;
    summed.group_by[0] = std.mem.zeroes(nerva.FieldRef);
    summed.aggregates[1].field = .{ .offset = 16, .size = 8, .kind = .signed };
    try testing.expectEqual(nerva.DeclareStatus.created, (try context.declare(summed)).status);

    // The sum view follows pairs exactly.
    _ = try context.commit(&.{&.{
        move(6, 1, 0, -40, .{ .pair = true, .create = true }),
        partner(6, 2, 16, 0),
    }});
    _ = context.pulse_until_ready();
    const records = try context.view(.{ .view_id = 2, .group_hash_min = 0, .limit = 10 });
    try testing.expectEqual(2, records.len);
    try testing.expectEqual(40, std.mem.readInt(i128, &records[1].sums[1], .little));
}

// ---- Views maintained in the state machine (N52) ----

const views = @import("views.zig");

/// Seats in table 5: `section` u8 at 0, `price` u64 at 8, `sold` bool at 16. The view: sold seats
/// by section, counted, with the sum of their prices.
fn revenue_view(name: []const u8) nerva.ViewDefinition {
    var definition = std.mem.zeroes(nerva.ViewDefinition);
    @memcpy(definition.name[0..name.len], name);
    definition.table = 5;
    definition.where_count = 1;
    definition.where[0] = .{
        .field = .{ .offset = 16, .size = 1, .kind = .boolean },
        .comparison = .eq,
        .value = std.mem.toBytes(std.mem.nativeToLittle(i128, 1)),
    };
    definition.group_by_count = 1;
    definition.group_by[0] = .{ .offset = 0, .size = 1, .kind = .unsigned };
    definition.aggregate_count = 2;
    definition.aggregates[0] = .{ .function = .count, .field = std.mem.zeroes(nerva.FieldRef) };
    definition.aggregates[1] = .{
        .function = .sum,
        .field = .{ .offset = 8, .size = 8, .kind = .unsigned },
    };
    return definition;
}

fn seat(id: u64, section: u8, price: u64, sold: bool) Entry {
    var entry = put(5, id, 0);
    entry.value = @splat(0);
    entry.value[0] = section;
    std.mem.writeInt(u64, entry.value[8..16], price, .little);
    entry.value[16] = @intFromBool(sold);
    return entry;
}

/// Every page of a view's groups, by section: count and price sum. Checks the header against
/// the groups it lists (the hash and the group count).
fn view_sections(context: *Context, view_id: u64) !struct {
    state: nerva.ViewState,
    count: [8]u64,
    sum: [8]i128,
} {
    var count: [8]u64 = @splat(0);
    var sum: [8]i128 = @splat(0);
    var hash: [32]u8 = @splat(0);
    var groups: u64 = 0;
    var cursor: u64 = 0;
    var header_last: nerva.ViewRecord = undefined;
    while (true) {
        const records = try context.view(.{ .view_id = view_id, .group_hash_min = cursor, .limit = 2 });
        const header = records[0];
        try testing.expectEqual(nerva.ViewRecord.Kind.header, header.kind);
        header_last = header;
        for (records[1..]) |*record| {
            try testing.expectEqual(nerva.ViewRecord.Kind.group, record.kind);
            try testing.expect(record.count > 0);
            const section = record.group_key[0];
            count[section] += record.count;
            sum[section] += std.mem.readInt(i128, &record.sums[1], .little);
            var group = std.mem.zeroes(nerva.Group);
            group.count = record.count;
            group.group_key = record.group_key;
            group.sums = record.sums;
            views.hash_update(&hash, &views.group_digest(view_id, &group), .add);
            groups += 1;
        }
        if (!header.flags.more) break;
        cursor = header.cursor;
    }
    // The replicated hash and group count agree with the groups listed.
    try testing.expectEqual(header_last.hash, hash);
    try testing.expectEqual(header_last.group_count, groups);
    return .{ .state = header_last.state, .count = count, .sum = sum };
}

test "views: declared on an empty table, then kept exact by every commit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    const declared = try context.declare(revenue_view("revenue"));
    try testing.expectEqual(nerva.DeclareStatus.created, declared.status);
    try testing.expectEqual(@as(u64, 1), declared.view_id);
    try testing.expectEqual(@as(u32, 1), context.pulse_until_ready());
    try testing.expectEqual(nerva.ViewState.ready, (try view_sections(context, 1)).state);

    // Two transactions in one request, then a move between sections, an unsold seat, a delete.
    _ = try context.commit(&.{
        &.{ seat(1, 1, 100, true), seat(2, 1, 50, true) },
        &.{ seat(3, 2, 70, true), seat(4, 2, 10, false) },
    });
    var sections = try view_sections(context, 1);
    try testing.expectEqual(@as(u64, 2), sections.count[1]);
    try testing.expectEqual(@as(i128, 150), sections.sum[1]);
    try testing.expectEqual(@as(u64, 1), sections.count[2]);

    _ = try context.commit(&.{&.{ seat(2, 2, 55, true), seat(4, 2, 10, true), delete(5, 3) }});
    sections = try view_sections(context, 1);
    try testing.expectEqual(@as(u64, 1), sections.count[1]);
    try testing.expectEqual(@as(i128, 100), sections.sum[1]);
    try testing.expectEqual(@as(u64, 2), sections.count[2]);
    try testing.expectEqual(@as(i128, 65), sections.sum[2]);

    // A stale transaction applies nothing to the view either.
    _ = try context.commit(&.{&.{ read(5, 1, 1), seat(1, 3, 999, true) }});
    try testing.expectEqual(sections, try view_sections(context, 1));

    // Emptying a group removes it from the listing, and from the hash.
    _ = try context.commit(&.{&.{delete(5, 1)}});
    sections = try view_sections(context, 1);
    try testing.expectEqual(@as(u64, 0), sections.count[1]);
}

test "views: a view over existing rows backfills in pulses, writes on both sides of the cursor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);
    const limit = context.state_machine.group_writes_limit;

    // More rows than one pulse adds, so that the build takes several pulses.
    const rows_count = 3 * limit + 1;
    var expected_count: [8]u64 = @splat(0);
    var expected_sum: [8]i128 = @splat(0);
    for (0..rows_count) |id| {
        const section: u8 = @intCast(id % 3);
        _ = try context.commit(&.{&.{seat(id, section, id, true)}});
        expected_count[section] += 1;
        expected_sum[section] += id;
    }

    try testing.expectEqual(nerva.DeclareStatus.created, (try context.declare(revenue_view("v"))).status);
    try testing.expectEqual(nerva.ViewState.building, (try view_sections(context, 1)).state);
    context.pulse();
    // One pulse in: rewrite a row behind the cursor and one ahead of it, and add a new one.
    _ = try context.commit(&.{&.{ seat(0, 4, 1000, true), seat(rows_count - 1, 5, 7, true) }});
    expected_count[0] -= 1;
    expected_sum[0] -= 0;
    expected_count[4] += 1;
    expected_sum[4] += 1000;
    const last_section: u8 = @intCast((rows_count - 1) % 3);
    expected_count[last_section] -= 1;
    expected_sum[last_section] -= rows_count - 1;
    expected_count[5] += 1;
    expected_sum[5] += 7;

    try testing.expect(context.pulse_until_ready() >= 2);
    const sections = try view_sections(context, 1);
    try testing.expectEqual(nerva.ViewState.ready, sections.state);
    try testing.expectEqual(expected_count, sections.count);
    try testing.expectEqual(expected_sum, sections.sum);
}

test "views: declarations, adds and transactions over the op's groups are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    try testing.expectEqual(nerva.DeclareStatus.created, (try context.declare(revenue_view("a"))).status);
    const again = try context.declare(revenue_view("a"));
    try testing.expectEqual(nerva.DeclareStatus.exists, again.status);
    try testing.expectEqual(@as(u64, 1), again.view_id);
    var different = revenue_view("a");
    different.where_count = 0;
    different.where[0] = std.mem.zeroes(nerva.Where);
    try testing.expectEqual(nerva.DeclareStatus.different, (try context.declare(different)).status);
    // `min` and `max` count against their table's limit, across its views (N62).
    var extremes = revenue_view("m");
    extremes.table = 7;
    extremes.aggregate_count = 3;
    extremes.aggregates[1].function = .max;
    extremes.aggregates[2] = extremes.aggregates[1];
    extremes.aggregates[2].function = .min;
    try testing.expectEqual(nerva.DeclareStatus.created, (try context.declare(extremes)).status);
    @memcpy(extremes.name[0..2], "mm");
    try testing.expectEqual(nerva.DeclareStatus.created, (try context.declare(extremes)).status);
    @memcpy(extremes.name[0..3], "mmm");
    try testing.expectEqual(
        nerva.DeclareStatus.table_extremes_full,
        (try context.declare(extremes)).status,
    );
    var one_more = revenue_view("n");
    one_more.table = 7;
    try testing.expectEqual(nerva.DeclareStatus.created, (try context.declare(one_more)).status);
    var reserved = revenue_view("c");
    reserved.table = 0xFFFF_0001;
    try testing.expectEqual(nerva.DeclareStatus.table_invalid, (try context.declare(reserved)).status);
    for ([_][]const u8{ "b", "c", "d" }) |name| {
        try testing.expectEqual(nerva.DeclareStatus.created, (try context.declare(revenue_view(name))).status);
    }
    try testing.expectEqual(nerva.DeclareStatus.table_views_full, (try context.declare(revenue_view("e"))).status);
    _ = context.pulse_until_ready();

    // Adds may change a summed field, not a filtered or grouped one.
    _ = try context.commit(&.{&.{seat(1, 1, 100, true)}});
    const price_add = add(5, 1, 8, 5, .{});
    try expect_statuses((try context.commit(&.{&.{price_add}}))[0], &.{.ok});
    try testing.expectEqual(@as(i128, 105), (try view_sections(context, 1)).sum[1]);
    try expect_statuses((try context.commit(&.{&.{add(5, 1, 0, 1, .{})}}))[0], &.{.view_key_field});
    try expect_statuses((try context.commit(&.{&.{add(5, 1, 12, 1, .{})}}))[0], &.{.view_key_field});

    // Admission counts the op's distinct groups, not its writes: writes to groups already
    // counted are free, so any number of them fit.
    const limit = context.state_machine.group_writes_limit;
    const same_group = try arena.allocator().alloc(Entry, limit + 1);
    for (same_group, 0..) |*entry, index| entry.* = seat(100 + index, 2, 1, true);
    for ((try context.commit(&.{same_group}))[0]) |result| {
        try testing.expectEqual(nerva.EntryStatus.ok, result.status);
    }
    try testing.expectEqual(@as(u64, limit + 1), (try view_sections(context, 1)).count[2]);

    // A view on table 6 grouped by price: every price is a group of its own. A transaction
    // that does not fit is refused whole, while others in the same op are admitted in order:
    // one that fits exactly, one whose groups are all counted already, and a small one.
    var by_price = revenue_view("p");
    by_price.table = 6;
    by_price.group_by[0] = .{ .offset = 8, .size = 8, .kind = .unsigned };
    try testing.expectEqual(nerva.DeclareStatus.created, (try context.declare(by_price)).status);
    _ = context.pulse_until_ready();
    const priced = struct {
        fn entries(allocator: std.mem.Allocator, count: usize, price_base: u64) ![]Entry {
            const result = try allocator.alloc(Entry, count);
            for (result, 0..) |*entry, index| {
                entry.* = seat(price_base + index, 1, price_base + index, true);
                entry.table = 6;
            }
            return result;
        }
    }.entries;
    const allocator = arena.allocator();
    const too_many = try priced(allocator, limit + 1, 1_000_000);
    const small = try priced(allocator, 1, 4_000_000);
    // A transaction past the op's budget on its own can never fit: `views_too_large`, not
    // `views_busy` (#32). The next transaction of the request still fits.
    const refused = try context.commit(&.{ too_many, small });
    try testing.expectEqual(nerva.EntryStatus.views_too_large, refused[0][0].status);
    for (refused[0][1..]) |result| try testing.expectEqual(nerva.EntryStatus.aborted, result.status);
    try testing.expectEqual(nerva.EntryStatus.ok, refused[1][0].status);

    const fits = try priced(allocator, limit, 2_000_000);
    const counted = try priced(allocator, 1, 2_000_000 + limit - 1);
    counted[0].id = 3_000_000; // Another row, in a group the op counted already.
    const over = try priced(allocator, 1, 5_000_000);
    const results = try context.commit(&.{ fits, counted, over });
    for (results[0]) |result| try testing.expectEqual(nerva.EntryStatus.ok, result.status);
    try testing.expectEqual(nerva.EntryStatus.ok, results[1][0].status);
    // Past the budget only with the op's earlier transactions: a later op takes it.
    try testing.expectEqual(nerva.EntryStatus.views_busy, results[2][0].status);
    const retried = try context.commit(&.{over});
    try testing.expectEqual(nerva.EntryStatus.ok, retried[0][0].status);
}

test "views: reads page through the groups, and say when a view is missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);

    _ = try context.declare(revenue_view("v"));
    _ = context.pulse_until_ready();
    for (0..6) |section| _ = try context.commit(&.{&.{seat(section, @intCast(section), 1, true)}});

    const first = try context.view(.{ .view_id = 1, .group_hash_min = 0, .limit = 4 });
    try testing.expect(first[0].flags.more);
    try testing.expectEqual(@as(usize, 5), first.len);
    try testing.expectEqual(@as(u64, 6), first[0].group_count);
    const rest = try context.view(.{ .view_id = 1, .group_hash_min = first[0].cursor, .limit = 4 });
    try testing.expect(!rest[0].flags.more);
    try testing.expectEqual(@as(usize, 3), rest.len);
    // Pages follow storage order, without overlap.
    try testing.expect(first[4].group_hash < rest[1].group_hash);

    const missing = try context.view(.{ .view_id = 2, .group_hash_min = 0, .limit = 4 });
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqual(nerva.ViewState.missing, missing[0].state);
}

test "format: what a fixed script commits" {
    // A format guard (N54): every result, row and change a fixed script produces, summarized and
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
    // A ledger over table 2 (N75), a pair with a floor that clamps it, and a refused put.
    const declared = try context.declare_ledger(ledger_definition(1, &.{
        conserved(2, 0, 0),
        conserved(2, 8, null),
    }));
    try writer.print("declare_ledger: {s} op={}\n", .{ @tagName(declared.status), declared.op });
    try checksum_input.appendSlice(std.mem.asBytes(&declared));
    const ledger_requests = [_][]const []const Entry{
        &.{&.{ move(2, 1, 8, -30, .{ .pair = true, .create = true }), partner(2, 1, 0, 0) }},
        &.{
            &.{ move(2, 1, 0, -50, .{ .pair = true, .clamp = true }), partner(2, 2, 8, 0) },
            &.{put(2, 1, 0xE1)},
        },
    };
    for (ledger_requests, 0..) |request, request_index| {
        const results = try context.commit(request);
        for (results, 0..) |transaction, transaction_index| {
            for (transaction) |result| {
                try writer.print("ledger commit {}.{}: {s} op={} applied={} value={}\n", .{
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
    for (1..3) |id| {
        const row = try context.lookup(2, id);
        try writer.print("row 2/{}: op={} value[0..16]={}\n", .{
            id,
            row.op,
            std.fmt.fmtSliceHexLower(row.value[0..16]),
        });
        try checksum_input.appendSlice(std.mem.asBytes(&row));
    }
    const stored = try context.get_ledger(1);
    try writer.print("ledger 1: slot={} op={} timestamp={}\n", .{
        stored.slot,
        stored.op,
        stored.timestamp,
    });
    try checksum_input.appendSlice(std.mem.asBytes(&stored));
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
        \\change: put 1/1 op=1 timestamp=79 more=false
        \\change: put 1/2 op=1 timestamp=88 more=false
        \\change: put 1/3 op=1 timestamp=97 more=false
        \\change: put 1/3 op=1 timestamp=106 more=false
        \\change: delete 1/2 op=2 timestamp=193 more=false
        \\change: put 1/1 op=2 timestamp=211 more=false
        \\change: put 1/2 op=3 timestamp=298 more=false
        \\change: put 1/3 op=3 timestamp=307 more=false
        \\change: put 1/3 op=3 timestamp=316 more=false
        \\change: end 0/0 op=9 timestamp=317 more=false
        \\history 1/2: put op=3 timestamp=298
        \\history 1/2: delete op=2 timestamp=193
        \\history 1/2: put op=1 timestamp=88
        \\history 1/2: end op=10 timestamp=0
        \\declare_ledger: created op=11
        \\ledger commit 0.0: ok op=12 applied=-30 value=18446744073709551586
        \\ledger commit 0.0: ok op=12 applied=30 value=30
        \\ledger commit 1.0: ok op=13 applied=-30 value=0
        \\ledger commit 1.0: ok op=13 applied=30 value=30
        \\ledger commit 1.1: conserved_write op=0 applied=0 value=0
        \\row 2/1: op=13 value[0..16]=0000000000000000e2ffffffffffffff
        \\row 2/2: op=13 value[0..16]=00000000000000001e00000000000000
        \\ledger 1: slot=1 op=11 timestamp=427
        \\checksum: 143ac07b47dc8c858b8723796b4011a9
        \\
    ).diff(summary.items);
}

// ---- min, max and as_of (N62) ----

/// A row of table 5 as the extremes test writes it: `section` u8 at 0, `price` u64 at 8, `sold`
/// bool at 16, `temperature` i64 at 24.
fn reading(section: u8, price: u64, sold: bool, temperature: i64) [nerva.value_size]u8 {
    var row: [nerva.value_size]u8 = @splat(0);
    row[0] = section;
    std.mem.writeInt(u64, row[8..16], price, .little);
    row[16] = @intFromBool(sold);
    std.mem.writeInt(i64, row[24..32], temperature, .little);
    return row;
}

/// View 1: sold rows by section, with count, min, max and sum of the price. View 2: every row
/// by `sold`, with min and max of the (signed) temperature. Four `min` and `max` slots: the
/// table's limit.
fn extremes_views() [2]nerva.ViewDefinition {
    const price: nerva.FieldRef = .{ .offset = 8, .size = 8, .kind = .unsigned };
    const temperature: nerva.FieldRef = .{ .offset = 24, .size = 8, .kind = .signed };
    var prices = revenue_view("prices");
    prices.aggregate_count = 4;
    prices.aggregates[1] = .{ .function = .min, .field = price };
    prices.aggregates[2] = .{ .function = .max, .field = price };
    prices.aggregates[3] = .{ .function = .sum, .field = price };
    var temperatures = std.mem.zeroes(nerva.ViewDefinition);
    @memcpy(temperatures.name[0..12], "temperatures");
    temperatures.table = 5;
    temperatures.group_by_count = 1;
    temperatures.group_by[0] = .{ .offset = 16, .size = 1, .kind = .boolean };
    temperatures.aggregate_count = 2;
    temperatures.aggregates[0] = .{ .function = .min, .field = temperature };
    temperatures.aggregates[1] = .{ .function = .max, .field = temperature };
    return .{ prices, temperatures };
}

/// A view's groups, computed apart from the state machine: by key byte, the count and each
/// slot's i128.
const ExpectedGroups = struct {
    present: [8]bool = @splat(false),
    count: [8]u64 = @splat(0),
    slots: [8][nerva.view_aggregates_max]i128 = @splat(@splat(0)),

    fn from_rows(rows: *const std.AutoArrayHashMapUnmanaged(u64, [nerva.value_size]u8), view_index: u32) ExpectedGroups {
        var groups: ExpectedGroups = .{};
        for (rows.values()) |*row| {
            const section = row[0];
            const price: i128 = std.mem.readInt(u64, row[8..16], .little);
            const sold = row[16] == 1;
            const temperature: i128 = std.mem.readInt(i64, row[24..32], .little);
            const key: u8, const values: [2]i128 = switch (view_index) {
                0 => if (sold) .{ section, .{ price, price } } else continue,
                1 => .{ @intFromBool(sold), .{ temperature, temperature } },
                else => unreachable,
            };
            const slots = &groups.slots[key];
            if (!groups.present[key]) {
                groups.present[key] = true;
                if (view_index == 0) {
                    slots[1] = price;
                    slots[2] = price;
                } else {
                    slots[0] = temperature;
                    slots[1] = temperature;
                }
            }
            groups.count[key] += 1;
            if (view_index == 0) {
                slots[1] = @min(slots[1], values[0]);
                slots[2] = @max(slots[2], values[1]);
                slots[3] += price;
            } else {
                slots[0] = @min(slots[0], values[0]);
                slots[1] = @max(slots[1], values[1]);
            }
        }
        return groups;
    }
};

/// Every page of a view's groups, latest (`as_of` zero) or as of a past op, checked against
/// the header's hash and group count.
fn view_groups_read(context: *Context, view_id: u64, as_of: u64) !struct {
    state: nerva.ViewState,
    groups: ExpectedGroups,
} {
    var groups: ExpectedGroups = .{};
    var hash: [32]u8 = @splat(0);
    var group_count: u64 = 0;
    var cursor: u64 = 0;
    while (true) {
        const records = try context.view(.{
            .view_id = view_id,
            .group_hash_min = cursor,
            .as_of = as_of,
            .limit = 3,
        });
        const header = records[0];
        try testing.expectEqual(nerva.ViewRecord.Kind.header, header.kind);
        if (header.state == .missing) {
            try testing.expectEqual(@as(usize, 1), records.len);
            return .{ .state = .missing, .groups = groups };
        }
        for (records[1..]) |*record| {
            try testing.expect(record.count > 0);
            const key = record.group_key[0];
            try testing.expect(!groups.present[key]);
            groups.present[key] = true;
            groups.count[key] = record.count;
            for (&groups.slots[key], &record.sums) |*slot, *sum| {
                slot.* = std.mem.readInt(i128, sum, .little);
            }
            var group = std.mem.zeroes(nerva.Group);
            group.count = record.count;
            group.group_key = record.group_key;
            group.sums = record.sums;
            views.hash_update(&hash, &views.group_digest(view_id, &group), .add);
            group_count += 1;
        }
        if (!header.flags.more) {
            try testing.expectEqual(header.hash, hash);
            try testing.expectEqual(header.group_count, group_count);
            return .{ .state = header.state, .groups = groups };
        }
        cursor = header.cursor;
    }
}

test "views: min and max stay exact as the rows holding them leave, and read as of any op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const context = try context_init(&arena);
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // The model: present rows by id, and each view's groups after every op checked.
    var rows: std.AutoArrayHashMapUnmanaged(u64, [nerva.value_size]u8) = .{};
    const Snapshot = struct { op: u64, groups: [2]ExpectedGroups };
    var snapshots: std.ArrayListUnmanaged(Snapshot) = .{};

    const ids = 24;
    const step = struct {
        /// One request of a few transactions over distinct rows each (no duplicate writes):
        /// puts, deletes and adds to the price, with few prices so that ties are common. A
        /// transaction the op's members do not fit is refused whole (`views_busy`). Returns
        /// the number refused.
        fn request(
            ctx: *Context,
            arena_allocator: std.mem.Allocator,
            prng_random: std.Random,
            model: *std.AutoArrayHashMapUnmanaged(u64, [nerva.value_size]u8),
        ) !u32 {
            const transactions = try arena_allocator.alloc([]Entry, prng_random.intRangeAtMost(usize, 1, 3));
            for (transactions) |*transaction| {
                const count = prng_random.intRangeAtMost(usize, 1, 3);
                transaction.* = try arena_allocator.alloc(Entry, count);
                var taken: std.StaticBitSet(ids) = .initEmpty();
                for (transaction.*) |*entry| {
                    var id = prng_random.uintLessThan(u64, ids);
                    while (taken.isSet(id)) id = (id + 1) % ids;
                    taken.set(id);
                    entry.* = switch (prng_random.uintLessThan(u8, 10)) {
                        0...5 => entry: {
                            var e = put(5, id, 0);
                            e.value = reading(
                                prng_random.uintLessThan(u8, 3),
                                prng_random.uintLessThan(u64, 6),
                                prng_random.boolean(),
                                prng_random.intRangeAtMost(i64, -4, 4),
                            );
                            break :entry e;
                        },
                        6, 7 => delete(5, id),
                        else => add(5, id, 8, prng_random.intRangeAtMost(i64, 1, 3), .{ .create = true }),
                    };
                }
            }
            const results = try ctx.commit(transactions);
            var refused: u32 = 0;
            for (transactions, results) |transaction, transaction_results| {
                if (transaction_results[0].status == .views_busy) {
                    for (transaction_results[1..]) |result| {
                        try testing.expectEqual(nerva.EntryStatus.aborted, result.status);
                    }
                    refused += 1;
                    continue;
                }
                for (transaction_results) |result| try testing.expectEqual(nerva.EntryStatus.ok, result.status);
                for (transaction) |*entry| switch (entry.kind) {
                    .put => try model.put(arena_allocator, entry.id, entry.value),
                    .delete => _ = model.swapRemove(entry.id),
                    .add => {
                        const parameters = nerva.Add.from_entry(entry);
                        const row = try model.getOrPut(arena_allocator, entry.id);
                        if (!row.found_existing) row.value_ptr.* = @splat(0);
                        const old = std.mem.readInt(u64, row.value_ptr[8..16], .little);
                        std.mem.writeInt(u64, row.value_ptr[8..16], old + @as(u64, @intCast(parameters.delta)), .little);
                    },
                    else => unreachable,
                };
            }
            return refused;
        }
    };

    // Rows before the views: they are backfilled, with commits between the pulses.
    for (0..10) |_| _ = try step.request(context, allocator, random, &rows);
    const definitions = extremes_views();
    const op_before = context.op;
    for (definitions) |definition| {
        try testing.expectEqual(nerva.DeclareStatus.created, (try context.declare(definition)).status);
    }
    var extra = revenue_view("extra");
    extra.aggregates[1].function = .min;
    try testing.expectEqual(nerva.DeclareStatus.table_extremes_full, (try context.declare(extra)).status);
    while (context.state_machine.pulse_needed(0)) {
        context.pulse();
        _ = try step.request(context, allocator, random, &rows);
    }

    // Four `min` and `max` slots take four members per write: some ops' later transactions do
    // not fit (`member_writes_limit` is small in tests), and are refused.
    var refused: u32 = 0;
    for (0..300) |_| {
        refused += try step.request(context, allocator, random, &rows);
        const op = context.op - 1;
        var snapshot: Snapshot = .{ .op = op, .groups = undefined };
        for (0..2) |index| {
            snapshot.groups[index] = ExpectedGroups.from_rows(&rows, @intCast(index));
            const read_now = try view_groups_read(context, index + 1, 0);
            try testing.expectEqual(nerva.ViewState.ready, read_now.state);
            try testing.expectEqual(snapshot.groups[index], read_now.groups);
        }
        try snapshots.append(allocator, snapshot);
    }

    try testing.expect(refused > 0);
    try testing.expect(refused < 300);

    // As of past ops: the view as each op left it (and the reads since changed nothing).
    for (snapshots.items) |*snapshot| {
        for (0..2) |index| {
            const read_then = try view_groups_read(context, index + 1, snapshot.op);
            try testing.expectEqual(nerva.ViewState.ready, read_then.state);
            try testing.expectEqual(snapshot.groups[index], read_then.groups);
        }
    }
    // Before the declaration, the view did not exist.
    try testing.expectEqual(nerva.ViewState.missing, (try view_groups_read(context, 1, op_before - 1)).state);
    // While it was building, it was.
    try testing.expectEqual(nerva.ViewState.building, (try view_groups_read(context, 1, op_before)).state);
}

test "views: one op moving every min and max holder it admits to new groups (#62)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const context = try context_init(&arena);

    // Grouped by a u64 key, with four `min`/`max` slots (the most a table takes).
    const a: nerva.FieldRef = .{ .offset = 8, .size = 8, .kind = .unsigned };
    const b: nerva.FieldRef = .{ .offset = 16, .size = 8, .kind = .unsigned };
    var definition = std.mem.zeroes(nerva.ViewDefinition);
    @memcpy(definition.name[0..5], "moves");
    definition.table = 8;
    definition.group_by_count = 1;
    definition.group_by[0] = .{ .offset = 0, .size = 8, .kind = .unsigned };
    definition.aggregate_count = 5;
    definition.aggregates[0] = .{ .function = .count, .field = std.mem.zeroes(nerva.FieldRef) };
    definition.aggregates[1] = .{ .function = .min, .field = a };
    definition.aggregates[2] = .{ .function = .max, .field = a };
    definition.aggregates[3] = .{ .function = .min, .field = b };
    definition.aggregates[4] = .{ .function = .max, .field = b };
    const declared = try context.declare(definition);
    try testing.expectEqual(nerva.DeclareStatus.created, declared.status);
    _ = context.pulse_until_ready();

    // Each row alone in its group, so it holds all four slots. Moving them all in one
    // transaction admits 4 members per row (the op's member limit), and touches each slot of
    // the group it leaves and of the group it enters: twice as many as members.
    const rows = context.state_machine.member_writes_limit / 4;
    try testing.expect(2 * rows <= context.state_machine.group_writes_limit);
    const entries = try allocator.alloc(Entry, rows);
    for ([_]u64{ 0, rows }, 0..) |group_base, round| {
        for (entries, 0..) |*entry, index| {
            entry.* = put(8, index + 1, 0);
            std.mem.writeInt(u64, entry.value[0..8], group_base + index, .little);
            std.mem.writeInt(u64, entry.value[8..16], 1000 * round + index, .little);
            std.mem.writeInt(u64, entry.value[16..24], 7 * index, .little);
        }
        for ((try context.commit(&.{entries}))[0]) |result| {
            try testing.expectEqual(nerva.EntryStatus.ok, result.status);
        }
    }

    // Every row is in its new group, holding its slots; the old groups are gone.
    var seen: u64 = 0;
    var cursor: u64 = 0;
    while (true) {
        const records = try context.view(.{
            .view_id = declared.view_id,
            .group_hash_min = cursor,
            .as_of = 0,
            .limit = 256,
        });
        const header = records[0];
        try testing.expectEqual(nerva.ViewState.ready, header.state);
        for (records[1..]) |*record| {
            const group = std.mem.readInt(u64, record.group_key[0..8], .little);
            try testing.expect(group >= rows and group < 2 * rows);
            const index = group - rows;
            try testing.expectEqual(@as(u64, 1), record.count);
            const sum = struct {
                fn at(r: *const nerva.ViewRecord, slot: usize) i128 {
                    return std.mem.readInt(i128, &r.sums[slot], .little);
                }
            }.at;
            try testing.expectEqual(@as(i128, 1000 + index), sum(record, 1));
            try testing.expectEqual(@as(i128, 1000 + index), sum(record, 2));
            try testing.expectEqual(@as(i128, 7 * index), sum(record, 3));
            try testing.expectEqual(@as(i128, 7 * index), sum(record, 4));
            seen += 1;
        }
        if (!header.flags.more) break;
        cursor = header.cursor;
    }
    try testing.expectEqual(rows, seen);
}

// ---- Restore (N78) ----

/// Seats with `min` and `max` of the price as well: every kind of view state a restore rebuilds.
fn extremes_view(name: []const u8) nerva.ViewDefinition {
    var definition = revenue_view(name);
    definition.where_count = 0;
    definition.where[0] = std.mem.zeroes(nerva.Where);
    definition.aggregate_count = 4;
    definition.aggregates[2] = .{
        .function = .min,
        .field = .{ .offset = 8, .size = 8, .kind = .unsigned },
    };
    definition.aggregates[3] = .{
        .function = .max,
        .field = .{ .offset = 8, .size = 8, .kind = .unsigned },
    };
    return definition;
}

/// Every change of the feed, paged.
fn changes_all(context: *Context) ![]const Change {
    var all = std.ArrayList(Change).init(context.arena);
    var cursor: u64 = 0;
    while (true) {
        const page = try context.changes(cursor, StateMachine.changes_limit_max);
        const end = page[page.len - 1];
        try testing.expectEqual(nerva.ChangeKind.end, end.kind);
        try all.appendSlice(page[0 .. page.len - 1]);
        if (!end.flags.more) return all.items;
        cursor = end.timestamp;
    }
}

const RestoreDeclaration = union(enum) {
    view: struct { id: u64, definition: nerva.ViewDefinition },
    ledger: nerva.LedgerDefinition,
};

/// Restores one op as `nerva import` does (N78), after compacting the ops before it.
fn restore_op(
    context: *Context,
    op: u64,
    changes: []const Change,
    declaration: ?RestoreDeclaration,
    timestamp_next: *u64,
) !void {
    assert(op >= context.op);
    assert((changes.len > 0) != (declaration != null));
    while (context.op < op) context.op_end();
    const state_machine = &context.state_machine;
    const operation: Operation, const size = if (declaration) |declared| switch (declared) {
        .view => |*view| size: {
            stdx.copy_disjoint(.inexact, u8, context.request, std.mem.asBytes(&view.definition));
            break :size .{ .declare_view, @sizeOf(nerva.ViewDefinition) };
        },
        .ledger => |*definition| size: {
            stdx.copy_disjoint(.inexact, u8, context.request, std.mem.asBytes(definition));
            break :size .{ .declare_ledger, @sizeOf(nerva.LedgerDefinition) };
        },
    } else .{ .commit, state_machine.restore_entries(changes, context.request) };
    context.prefetching = true;
    state_machine.restore_prefetch(
        prefetch_callback_restore,
        op,
        operation,
        context.request[0..size],
    );
    while (context.prefetching) context.storage.run();
    defer context.op_end();
    if (declaration) |declared| switch (declared) {
        .view => |*view| try state_machine.restore_view(
            op,
            &view.definition,
            view.id,
            timestamp_next,
        ),
        .ledger => |*definition| try state_machine.restore_ledger(op, definition, timestamp_next),
    } else try state_machine.restore_changes(op, changes, timestamp_next);
}

fn prefetch_callback_restore(state_machine: *StateMachine) void {
    const context: *Context = @fieldParentPtr("state_machine", state_machine);
    assert(context.prefetching);
    context.prefetching = false;
}

/// A view's header, latest or as of an op.
fn view_header(context: *Context, view_id: u64, as_of: u64) !nerva.ViewRecord {
    const records = try context.view(.{
        .view_id = view_id,
        .group_hash_min = 0,
        .limit = 1,
        .as_of = as_of,
    });
    return records[0];
}

test "restore: a history restored at its ops reads as it was committed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = try context_init(&arena);

    // A view declared before its table has rows, then a ledger.
    const early = try original.declare(extremes_view("early"));
    try testing.expectEqual(nerva.DeclareStatus.created, early.status);
    try testing.expectEqual(@as(u32, 1), original.pulse_until_ready());
    try ledger_funded(original, 50);
    const ledger_op = (try original.get_ledger(1)).op;

    // Puts, deletes, adds and pairs; several transactions in one op, a row written twice in
    // one op, a row deleted and put back.
    for (0..12) |round| {
        const id: u64 = round % 5;
        _ = try original.commit(&.{
            &.{
                seat(id, @intCast(round % 3), 10 * round, round % 2 == 0),
                seat(20 + round, 1, 7, true),
            },
            &.{ seat(id, 2, 5 + round, true), add(1, 3, 0, 4, .{ .create = true }) },
            &.{
                move(accounts, 1, 0, -2, .{ .pair = true }),
                partner(accounts, 1, 8, 0),
            },
        });
        if (round % 4 == 3) _ = try original.commit(&.{&.{ delete(5, id), delete(5, 20 + round) }});
        _ = try original.lookup(5, id); // An op without changes.
    }
    // A view over rows that already exist: it backfills in pulses.
    const late = try original.declare(revenue_view("late"));
    try testing.expectEqual(nerva.DeclareStatus.created, late.status);
    _ = original.pulse_until_ready();
    _ = try original.commit(&.{&.{ seat(1, 0, 3, true), delete(5, 2) }});
    const as_of = original.op - 1;

    // The export, as `nerva export` reads it: the feed, the declarations and their ops.
    const changes = try changes_all(original);
    const early_header = try view_header(original, early.view_id, 0);
    const late_header = try view_header(original, late.view_id, 0);

    // The restore, as `nerva import` drives it: every op at its number.
    const restored = try context_init(&arena);
    var timestamp_next = changes[changes.len - 1].timestamp + StateMachine.entry_timestamps;
    var index: usize = 0;
    var op: u64 = 1;
    while (op <= as_of) : (op += 1) {
        if (op == early.op) {
            try restore_op(restored, op, &.{}, .{ .view = .{
                .id = early.view_id,
                .definition = extremes_view("early"),
            } }, &timestamp_next);
        } else if (op == late.op) {
            try restore_op(restored, op, &.{}, .{ .view = .{
                .id = late.view_id,
                .definition = revenue_view("late"),
            } }, &timestamp_next);
        } else if (op == ledger_op) {
            try restore_op(restored, op, &.{}, .{ .ledger = accounts_ledger() }, &timestamp_next);
        } else {
            const start = index;
            while (index < changes.len and changes[index].op == op) index += 1;
            if (index > start) {
                try restore_op(restored, op, changes[start..index], null, &timestamp_next);
            }
        }
    }
    try testing.expectEqual(changes.len, index);
    while (restored.op <= as_of) restored.op_end();

    // The feed: every change at its op and timestamp, so cursors stay valid.
    const changes_restored = try changes_all(restored);
    try testing.expectEqual(changes.len, changes_restored.len);
    for (changes, changes_restored) |expected, actual| {
        try testing.expect(stdx.equal_bytes(Change, &expected, &actual));
    }
    // Rows, their versions and histories, and the ledger's total.
    for ([_]u32{ 1, 5, accounts, sources }) |table| {
        for (0..40) |id| {
            const expected = try original.lookup(table, id);
            const actual = try restored.lookup(table, id);
            try testing.expectEqual(expected.flags, actual.flags);
            try testing.expectEqual(expected.op, actual.op);
            try testing.expectEqual(expected.value, actual.value);
            const filter: nerva.HistoryFilter = .{
                .table = table,
                .id = id,
                .limit = 64,
                .op_max = std.math.maxInt(u64),
                .timestamp_max = 0,
            };
            const history_expected = try original.history(filter);
            const history_actual = try restored.history(filter);
            try testing.expectEqual(history_expected.len, history_actual.len);
            // All but the `end` record, whose op is the read's.
            const count = history_expected.len - 1;
            for (history_expected[0..count], history_actual[0..count]) |a, b| {
                try testing.expect(stdx.equal_bytes(Change, &a, &b));
            }
        }
    }
    try testing.expectEqual(try ledger_total(original), try ledger_total(restored));
    const ledger_restored = try restored.get_ledger(1);
    try testing.expectEqual(ledger_op, ledger_restored.op);
    try testing.expectEqual(@as(u64, 1), ledger_restored.slot);

    // The view declared before rows: ready, the same hash, and the same as of every op after
    // the original's first pulse (the restore has none: it is ready at its declaration).
    const early_restored = try view_header(restored, early.view_id, 0);
    try testing.expectEqual(nerva.ViewState.ready, early_restored.state);
    try testing.expectEqual(early_header.hash, early_restored.hash);
    try testing.expectEqual(early_header.group_count, early_restored.group_count);
    try testing.expectEqual(early.op, early_restored.declared_op);
    op = early.op + 2;
    while (op <= as_of) : (op += 1) {
        const expected = try view_header(original, early.view_id, op);
        const actual = try view_header(restored, early.view_id, op);
        try testing.expectEqual(expected.state, actual.state);
        try testing.expectEqual(expected.hash, actual.hash);
        try testing.expectEqual(expected.group_count, actual.group_count);
    }
    // The view declared over existing rows: building, until the new cluster's pulses add them.
    const late_building = try view_header(restored, late.view_id, 0);
    try testing.expectEqual(nerva.ViewState.building, late_building.state);
    try testing.expect(restored.pulse_until_ready() > 0);
    const late_restored = try view_header(restored, late.view_id, 0);
    try testing.expectEqual(late_header.hash, late_restored.hash);
    try testing.expectEqual(late_header.group_count, late_restored.group_count);
    try testing.expectEqual(
        try view_sections(original, late.view_id),
        try view_sections(restored, late.view_id),
    );

    // The restored cluster commits on: a read of a restored version, and the view follows.
    const version = (try restored.lookup(5, 1)).op;
    const results = try restored.commit(&.{&.{ read(5, 1, version), seat(1, 1, 1, true) }});
    try expect_statuses(results[0], &.{ .ok, .ok });
    _ = try original.commit(&.{&.{ read(5, 1, version), seat(1, 1, 1, true) }});
    try testing.expectEqual(
        (try view_header(original, early.view_id, 0)).hash,
        (try view_header(restored, early.view_id, 0)).hash,
    );
}

test "restore: the rules a commit checks are not checked again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const context = try context_init(&arena);
    var timestamp_next: u64 = 1_000_000;

    try restore_op(context, 1, &.{}, .{ .ledger = accounts_ledger() }, &timestamp_next);
    // A put of a conserved field, alone: a commit refuses it; a restore writes it.
    var balance: [nerva.value_size]u8 = @splat(0);
    std.mem.writeInt(i64, balance[0..8], 100, .little);
    const change: Change = .{
        .id = 1,
        .table = accounts,
        .kind = .put,
        .flags = .{},
        .op = 2,
        .timestamp = 500,
        .value = balance,
    };
    try restore_op(context, 2, &.{change}, null, &timestamp_next);
    try testing.expectEqual(100, signed(try context.lookup(accounts, 1), 0));
    var entry = put(accounts, 2, 0);
    entry.value = balance;
    try expect_statuses((try context.commit(&.{&.{entry}}))[0], &.{.conserved_write});

    // A history no commit writes is refused: a delete of a row that is not there, timestamps
    // closer than an entry's block.
    var absent = change;
    absent.kind = .delete;
    absent.id = 9;
    absent.value = @splat(0);
    absent.op = context.op;
    absent.timestamp = 600;
    try testing.expectError(
        error.HistoryInvalid,
        restore_op(context, context.op, &.{absent}, null, &timestamp_next),
    );
}
