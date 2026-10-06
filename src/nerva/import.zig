//! `nerva import` (docs/DECISIONS.md N80): one replica's data file, rebuilt from an export
//! (`export_file.zig`) by this release's code, so that a cluster keeps its data across releases.
//!
//! Run once per replica, on the same export: every replica's file holds the same state, since
//! nothing here reads a clock or a random number. Two passes over the export:
//!
//! 1. `plan`, before any data file exists: the whole export is checked (CRCs, order, the
//!    SHA-256), and each view's definition is rebuilt from its catalog document with this
//!    release's `catalog` code.
//! 2. `ImporterType.run`, on a newly formatted data file: the state machine, on real storage,
//!    restores every op up to the export's op, at its number (changes with their timestamps;
//!    views and ledgers at their declarations), with a compaction beat after every op and a
//!    checkpoint at every checkpoint trigger, as a replica would. The last checkpoint, C, is the
//!    first at or after the export's op; the WAL then holds, as a replica leaves it, the
//!    prepare of op C and empty pulses up to the op that makes C durable, so that replicas start
//!    from C and repair nothing before it. Then the checks run against the restored forest.
//!
//! Timestamps: changes keep theirs (feed cursors stay valid); views, ledgers and versions take
//! the importer's own counter, which starts past the export's last timestamp.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.import_);

const stdx = @import("stdx");
const vsr = @import("../vsr.zig");
const constants = @import("../constants.zig");
const nerva = @import("../nerva.zig");
const catalog = @import("catalog.zig");
const documents = @import("documents.zig");
const export_file = @import("export_file.zig");
const replica_format = @import("../vsr/replica_format.zig");
const data_file_size_min = @import("../vsr/superblock.zig").data_file_size_min;
const StateMachineType = @import("state_machine.zig").StateMachineType;

/// Catalog rows (`catalog.table_catalog`) an export may hold: layouts and view declarations.
pub const catalog_rows_max = 1 << 16;
/// The latest change timestamp restored: far below `TimestampRange.timestamp_max`, so that the
/// versions, views, ledgers and checkpoints after it never pass it (wall-clock nanoseconds
/// reach it in 2116; #80).
const timestamp_restore_max: u64 = 1 << 62;
/// The latest op restored. Import restores every op up to the export's, about 38,000 a second
/// when they are empty, so this is far past any cluster an import can carry.
const as_of_max: u64 = 1 << 48;
/// Ops between progress lines.
const ops_progress: u64 = 1 << 20;
/// Rows per read of the forest while checking.
const check_rows_page = 1024;
/// Between the importer's last timestamp and the checkpoint's prepare: more than any op takes.
const checkpoint_timestamp_gap: u64 = std.time.ns_per_s;

pub const Error = error{
    /// A view, a ledger or a change this release cannot restore as the export says.
    Refused,
    /// The restored state differs from the export's checks.
    ChecksFailed,
};

pub const PlanView = struct {
    record: export_file.View,
    definition: nerva.ViewDefinition,
};

/// What pass 1 learned from a verified export.
pub const Plan = struct {
    summary: export_file.Summary,
    /// The last change's timestamp (zero without changes).
    timestamp_max: u64,
    /// The most changes of one op.
    op_changes_max: u64,
    views: [nerva.views_max]PlanView,
    ledgers: [nerva.ledgers_max]export_file.Ledger,
    checks_view: [nerva.views_max]export_file.CheckView,
    checks_ledger: [nerva.ledgers_max]export_file.CheckLedger,
    /// By table.
    checks_table: []const export_file.CheckTable,

    pub fn view_slice(plan_: *const Plan) []const PlanView {
        return plan_.views[0..plan_.summary.view_count];
    }

    pub fn ledger_slice(plan_: *const Plan) []const export_file.Ledger {
        return plan_.ledgers[0..plan_.summary.ledger_count];
    }
};

pub const CatalogRows = std.AutoHashMapUnmanaged(u64, [nerva.value_size]u8);

/// Pass 1: reads and checks the whole export, and rebuilds the views' definitions. Allocates
/// the plan's table checks from `arena`.
pub fn plan(arena: std.mem.Allocator, path: []const u8) !Plan {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buffered = std.io.bufferedReader(file.reader());
    var reader = try export_file.ReaderType(@TypeOf(buffered).Reader).init(buffered.reader());

    var result: Plan = .{
        .summary = undefined,
        .timestamp_max = 0,
        .op_changes_max = 0,
        .views = undefined,
        .ledgers = undefined,
        .checks_view = undefined,
        .checks_ledger = undefined,
        .checks_table = &.{},
    };
    var checks_table = std.ArrayList(export_file.CheckTable).init(arena);
    var catalog_rows: CatalogRows = .{};
    var view_count: u32 = 0;
    var ledger_count: u32 = 0;
    var check_view_count: u32 = 0;
    var check_ledger_count: u32 = 0;
    var op_last: u64 = 0;
    var op_changes: u64 = 0;
    while (try reader.next()) |record| switch (record) {
        .change => |*change| {
            if (change.timestamp > timestamp_restore_max) {
                log.err("a change's timestamp {} is past {}", .{
                    change.timestamp,
                    timestamp_restore_max,
                });
                return error.Refused;
            }
            result.timestamp_max = change.timestamp;
            op_changes = if (change.op == op_last) op_changes + 1 else 1;
            op_last = change.op;
            result.op_changes_max = @max(result.op_changes_max, op_changes);
            if (change.table != catalog.table_catalog) continue;
            if (change.kind == .put) {
                if (catalog_rows.count() == catalog_rows_max and
                    !catalog_rows.contains(change.id))
                {
                    log.err("the catalog has more than {} rows", .{catalog_rows_max});
                    return error.Refused;
                }
                try catalog_rows.put(arena, change.id, change.value);
            } else {
                _ = catalog_rows.remove(change.id);
            }
        },
        .view => |*view| {
            result.views[view_count] = .{ .record = view.*, .definition = undefined };
            view_count += 1;
        },
        .ledger => |*ledger| {
            result.ledgers[ledger_count] = ledger.*;
            ledger_count += 1;
        },
        .check_view => |*check| {
            result.checks_view[check_view_count] = check.*;
            check_view_count += 1;
        },
        .check_ledger => |*check| {
            result.checks_ledger[check_ledger_count] = check.*;
            check_ledger_count += 1;
        },
        .check_table => |*check| try checks_table.append(check.*),
        .summary => |*summary| result.summary = summary.*,
    };
    // The reader returns null only once everything checked.
    assert(view_count == result.summary.view_count);
    assert(ledger_count == result.summary.ledger_count);
    result.checks_table = checks_table.items;

    if (result.summary.as_of == 0) return export_file.corrupt("the export's op is zero");
    if (result.summary.as_of > as_of_max) {
        log.err("the export's op {} is past {}", .{ result.summary.as_of, as_of_max });
        return error.Refused;
    }
    var declared_op_last: u64 = 0;
    for (result.views[0..result.summary.view_count]) |*view| {
        if (view.record.declared_op <= declared_op_last or
            view.record.declared_op > result.summary.as_of)
        {
            return export_file.corrupt("views are out of op order, or past the export's op");
        }
        declared_op_last = view.record.declared_op;
        for (result.ledger_slice()) |*ledger| {
            if (ledger.op == view.record.declared_op) {
                return export_file.corrupt("a view and a ledger are declared at one op");
            }
        }
        view.definition = try view_definition(arena, &catalog_rows, &view.record);
    }
    // The checks name what they check, in the declarations' order; pass 2 asserts it (#78).
    for (result.view_slice(), result.checks_view[0..check_view_count], 1..) |*view, *check, id| {
        if (view.record.id != id or check.id != id) {
            return export_file.corrupt("a view's id or its check's is out of order");
        }
    }
    for (result.ledger_slice(), result.checks_ledger[0..check_ledger_count]) |*ledger, *check| {
        if (check.id != ledger.definition.id) {
            return export_file.corrupt("a ledger's check names another ledger");
        }
    }
    return result;
}

/// A view's definition, from its catalog document and its table's layout. `nerva export` runs
/// it too, so that it refuses an export this would refuse.
pub fn view_definition(
    arena: std.mem.Allocator,
    catalog_rows: *const CatalogRows,
    view: *const export_file.View,
) !nerva.ViewDefinition {
    const name_size = std.mem.indexOfScalar(u8, &view.name, 0) orelse view.name.len;
    const name = view.name[0..name_size];
    const key = try std.fmt.allocPrint(arena, "view.{s}", .{name});
    const document = try document_read(arena, catalog_rows, key) orelse {
        log.err("view {s}: no catalog document {s}", .{ name, key });
        return error.Refused;
    };
    const declaration = catalog.view_parse(arena, document) catch |err| {
        log.err("view {s}: {s}: {s}", .{ name, @errorName(err), catalog.invalid_reason });
        return error.Refused;
    };
    const layout_key = try std.fmt.allocPrint(arena, "table.{}", .{declaration.table});
    const layout_document = try document_read(arena, catalog_rows, layout_key) orelse {
        log.err("view {s}: no layout for table {}", .{ name, declaration.table });
        return error.Refused;
    };
    const layout = catalog.layout_parse(arena, layout_document) catch |err| {
        log.err("view {s}: layout: {s}: {s}", .{ name, @errorName(err), catalog.invalid_reason });
        return error.Refused;
    };
    catalog.view_check(&declaration, &layout) catch {
        log.err("view {s}: {s}", .{ name, catalog.invalid_reason });
        return error.Refused;
    };
    catalog.view_name_validate(name) catch {
        log.err("view {s}: {s}", .{ name, catalog.invalid_reason });
        return error.Refused;
    };
    return catalog.view_definition(name, &declaration, &layout);
}

/// A catalog document's value as the export's last change left it, or null.
fn document_read(
    arena: std.mem.Allocator,
    catalog_rows: *const CatalogRows,
    key: []const u8,
) !?[]const u8 {
    const chunk0 = catalog_rows.get(documents.row_id(0, key)) orelse return null;
    const count = documents.chunk0_count(&chunk0) catch return export_file.corrupt(
        "a catalog document's first chunk does not decode",
    );
    const chunks = try arena.alloc([nerva.value_size]u8, count);
    chunks[0] = chunk0;
    for (chunks[1..], 1..) |*chunk, index| {
        chunk.* = catalog_rows.get(documents.chunk_id(0, key, @intCast(index))) orelse
            return export_file.corrupt("a catalog document's chunk is missing");
    }
    const decoded = documents.chunks_decode(arena, chunks) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Corrupt => return export_file.corrupt("a catalog document does not decode"),
    };
    if (decoded.namespace != 0 or !std.mem.eql(u8, decoded.key, key)) {
        return export_file.corrupt("a catalog document's key does not match its id");
    }
    return decoded.value;
}

pub const Options = struct {
    cluster: u128,
    release: vsr.Release,
    /// The export, read again (pass 2).
    input: []const u8,
};

pub fn ImporterType(comptime Storage: type) type {
    return struct {
        const StateMachine = StateMachineType(Storage);
        const SuperBlock = vsr.SuperBlockType(Storage);
        const Grid = vsr.GridType(Storage);

        /// Pass 2: restores the plan into the data file `storage` holds, newly formatted.
        pub fn run(
            gpa: std.mem.Allocator,
            time: stdx.Time,
            tracer: anytype,
            storage: *Storage,
            options: Options,
            plan_: *const Plan,
        ) !void {
            var superblock = try SuperBlock.init(gpa, storage, .{
                .storage_size_limit = constants.storage_size_limit_default,
            });
            defer superblock.deinit(gpa);
            var superblock_context: SuperBlock.Context = undefined;
            Wait.pending = true;
            superblock.open(Wait.superblock_done, &superblock_context);
            Wait.run(storage);

            const compaction_block_count = StateMachine.Forest.Options.compaction_block_count_min +
                constants.lsm_compaction_iops_write_max;
            var grid = try Grid.init(gpa, .{
                .superblock = &superblock,
                .trace = tracer,
                .cache_blocks_count = Grid.Cache.value_count_max_multiple,
                // As a replica's, without repairs (`replica.zig`).
                .stash_blocks_count = constants.grid_iops_read_max +
                    constants.lsm_scans_max * @as(u64, constants.lsm_levels) * 2 +
                    compaction_block_count +
                    StateMachine.Forest.manifest_log_compaction_pace.blocks_count() + 1,
                .missing_blocks_max = 0,
                .missing_tables_max = 0,
                .blocks_released_prior_checkpoint_durability_max = StateMachine.Forest
                    .compaction_blocks_released_per_pipeline_max(),
            });
            defer grid.deinit(gpa);
            Wait.pending = true;
            grid.open(Wait.grid_done);
            Wait.run(storage);
            // One process: the formatted (empty) checkpoint is durable.
            grid.free_set.mark_checkpoint_durable();

            const state_machine = try gpa.create(StateMachine);
            defer gpa.destroy(state_machine);
            try state_machine.init(gpa, time, &grid, .{
                .batch_size_limit = constants.message_body_size_max,
                .lsm_forest_compaction_block_count = compaction_block_count,
                .lsm_forest_node_count = @intCast(@divExact(
                    constants.lsm_manifest_memory_size_default,
                    constants.lsm_manifest_node_size,
                )),
            });
            defer state_machine.deinit(gpa);
            Wait.pending = true;
            state_machine.open(Wait.state_machine_done);
            Wait.run(storage);

            if (plan_.op_changes_max > state_machine.restore_changes_max()) {
                log.err("an op has {} changes; this release restores at most {} per op", .{
                    plan_.op_changes_max,
                    state_machine.restore_changes_max(),
                });
                return error.Refused;
            }

            var restore: Restore = .{
                .storage = storage,
                .superblock = &superblock,
                .superblock_context = &superblock_context,
                .grid = &grid,
                .state_machine = state_machine,
                .options = options,
                .plan = plan_,
                .timestamp_next = @max(
                    TimestampRangeMin,
                    plan_.timestamp_max + StateMachine.entry_timestamps,
                ),
                .body = try gpa.alignedAlloc(
                    u8,
                    constants.cache_line_size,
                    constants.message_body_size_max,
                ),
                .changes = try gpa.alloc(nerva.Change, state_machine.restore_changes_max()),
            };
            defer gpa.free(restore.body);
            defer gpa.free(restore.changes);
            // Registered last, so it runs first on an error (#78): the writes in flight land before
            // the grid's and state machine's buffers are freed and the file is closed.
            errdefer flush(storage);
            try restore.ops(gpa);
            try restore.checks(gpa);
            flush(storage);
        }

        const TimestampRangeMin = @import("../lsm/timestamp_range.zig").TimestampRange
            .timestamp_min;

        const Wait = struct {
            var pending: bool = false;

            fn superblock_done(_: *SuperBlock.Context) void {
                assert(pending);
                pending = false;
            }

            fn grid_done(_: *Grid) void {
                assert(pending);
                pending = false;
            }

            fn state_machine_done(_: *StateMachine) void {
                assert(pending);
                pending = false;
            }

            fn run(storage: *Storage) void {
                while (pending) storage.run();
            }
        };

        const Restore = struct {
            storage: *Storage,
            superblock: *SuperBlock,
            superblock_context: *SuperBlock.Context,
            grid: *Grid,
            state_machine: *StateMachine,
            options: Options,
            plan: *const Plan,
            /// The next timestamp a view, ledger, version or checkpoint takes.
            timestamp_next: u64,
            body: []align(constants.cache_line_size) u8,
            /// One op's changes.
            changes: []nerva.Change,

            /// Restores ops 1 to the trigger of the first checkpoint at or after the export's
            /// op, compacting after each and checkpointing at each trigger.
            fn ops(restore: *Restore, gpa: std.mem.Allocator) !void {
                const as_of = restore.plan.summary.as_of;
                var checkpoint_final = vsr.Checkpoint.checkpoint_after(0);
                while (checkpoint_final < as_of) {
                    checkpoint_final = vsr.Checkpoint.checkpoint_after(checkpoint_final);
                }
                const trigger_final = vsr.Checkpoint.trigger_for_checkpoint(checkpoint_final).?;
                log.info("restoring ops 1 to {} (checkpoint {}, trigger {})", .{
                    as_of,
                    checkpoint_final,
                    trigger_final,
                });

                const file = try std.fs.cwd().openFile(restore.options.input, .{});
                defer file.close();
                var buffered = std.io.bufferedReader(file.reader());
                const Reader = export_file.ReaderType(@TypeOf(buffered).Reader);
                var reader = try Reader.init(buffered.reader());

                var pending: ?export_file.Change = null;
                var changes_done = false;
                var view_index: u32 = 0;
                var ledger_index: u32 = 0;
                var ops_restored: u64 = 0;
                const views = restore.plan.view_slice();
                const ledgers_ = restore.plan.ledger_slice();
                var checkpoint_previous: u64 = 0;
                var op: u64 = 1;
                while (op <= trigger_final) : (op += 1) {
                    if (op <= as_of) {
                        if (pending == null and !changes_done) {
                            pending = try change_next(&reader);
                            changes_done = pending == null;
                        }
                        const change_op = if (pending) |change| change.op else null;
                        const view = if (view_index < views.len and
                            views[view_index].record.declared_op == op)
                            &views[view_index]
                        else
                            null;
                        const ledger = if (ledger_index < ledgers_.len and
                            ledgers_[ledger_index].op == op)
                            &ledgers_[ledger_index]
                        else
                            null;
                        if (change_op != null and change_op.? < op) {
                            return export_file.corrupt("changes are out of op order");
                        }
                        if (view != null or ledger != null) {
                            if (change_op == op) {
                                log.err("op {} both declares and changes rows", .{op});
                                return export_file.corrupt("an op both declares and writes");
                            }
                            if (view) |declared| {
                                try restore.view_restore(op, declared);
                                view_index += 1;
                            } else {
                                try restore.ledger_restore(op, &ledger.?.definition);
                                ledger_index += 1;
                            }
                            ops_restored += 1;
                        } else if (change_op == op) {
                            var count: u32 = 0;
                            while (pending) |change| {
                                if (change.op != op) break;
                                // Checked by pass 1, unless the file changed since.
                                if (count == restore.changes.len) {
                                    return export_file.corrupt("an op has too many changes");
                                }
                                restore.changes[count] = change_from_record(&change);
                                count += 1;
                                pending = try change_next(&reader);
                                changes_done = pending == null;
                            }
                            try restore.changes_restore(op, restore.changes[0..count]);
                            ops_restored += 1;
                        }
                    }

                    if (op % ops_progress == 0) {
                        log.info("op {} of {}: {} ops restored", .{
                            op,
                            trigger_final,
                            ops_restored,
                        });
                    }
                    Wait.pending = true;
                    restore.state_machine.compact(Wait.state_machine_done, op);
                    Wait.run(restore.storage);

                    const trigger = vsr.Checkpoint.trigger_for_checkpoint(
                        vsr.Checkpoint.checkpoint_after(checkpoint_previous),
                    ) orelse continue;
                    if (op != trigger) continue;
                    const checkpoint_op = op - constants.lsm_compaction_ops;
                    assert(checkpoint_op == vsr.Checkpoint.checkpoint_after(checkpoint_previous));
                    try restore.checkpoint(gpa, checkpoint_op, checkpoint_op == checkpoint_final);
                    checkpoint_previous = checkpoint_op;
                    log.debug("checkpoint {}: {} ops restored", .{ checkpoint_op, ops_restored });
                }
                assert(checkpoint_previous == checkpoint_final);
                log.info("{} ops restored", .{ops_restored});
                if (pending != null or view_index != views.len or ledger_index != ledgers_.len) {
                    return export_file.corrupt("records past the export's op");
                }
                // The rest of the export, read again: its SHA-256 must still match (the file
                // may have changed since pass 1).
                if (!changes_done) {
                    assert(try change_next(&reader) == null);
                }
                while (try reader.next()) |_| {}
            }

            /// The next change, or null once the changes' section has ended.
            fn change_next(reader: anytype) !?export_file.Change {
                if (reader.section > @intFromEnum(export_file.RecordKind.change)) return null;
                const record = try reader.next() orelse return null;
                return switch (record) {
                    .change => |change| change,
                    else => null,
                };
            }

            fn change_from_record(record: *const export_file.Change) nerva.Change {
                return .{
                    .id = record.id,
                    .table = record.table,
                    .kind = switch (record.kind) {
                        .put => .put,
                        .delete => .delete,
                        _ => unreachable, // Refused by the reader.
                    },
                    .flags = .{},
                    .op = record.op,
                    .timestamp = record.timestamp,
                    .value = record.value,
                };
            }

            fn changes_restore(restore: *Restore, op: u64, changes: []const nerva.Change) !void {
                const state_machine = restore.state_machine;
                const size = state_machine.restore_entries(changes, restore.body);
                Wait.pending = true;
                state_machine.restore_prefetch(
                    Wait.state_machine_done,
                    op,
                    .commit,
                    restore.body[0..size],
                );
                Wait.run(restore.storage);
                state_machine.restore_changes(op, changes, &restore.timestamp_next) catch |err| {
                    log.err("op {}: {} changes: {s}", .{ op, changes.len, @errorName(err) });
                    return error.Refused;
                };
            }

            fn view_restore(restore: *Restore, op: u64, view: *const PlanView) !void {
                const state_machine = restore.state_machine;
                const bytes = std.mem.asBytes(&view.definition);
                stdx.copy_disjoint(.inexact, u8, restore.body, bytes);
                Wait.pending = true;
                state_machine.restore_prefetch(
                    Wait.state_machine_done,
                    op,
                    .declare_view,
                    restore.body[0..bytes.len],
                );
                Wait.run(restore.storage);
                state_machine.restore_view(
                    op,
                    &view.definition,
                    view.record.id,
                    &restore.timestamp_next,
                ) catch return error.Refused;
            }

            fn ledger_restore(
                restore: *Restore,
                op: u64,
                definition: *const nerva.LedgerDefinition,
            ) !void {
                const state_machine = restore.state_machine;
                const bytes = std.mem.asBytes(definition);
                stdx.copy_disjoint(.inexact, u8, restore.body, bytes);
                Wait.pending = true;
                state_machine.restore_prefetch(
                    Wait.state_machine_done,
                    op,
                    .declare_ledger,
                    restore.body[0..bytes.len],
                );
                Wait.run(restore.storage);
                state_machine.restore_ledger(op, definition, &restore.timestamp_next) catch
                    return error.Refused;
            }

            /// Checkpoints the forest, grid and superblock at `checkpoint_op`, as a replica does
            /// at its trigger. The last one also writes the WAL a replica leaves there.
            fn checkpoint(
                restore: *Restore,
                gpa: std.mem.Allocator,
                checkpoint_op: u64,
                final: bool,
            ) !void {
                const superblock = restore.superblock;
                const grid = restore.grid;
                Wait.pending = true;
                restore.state_machine.checkpoint(Wait.state_machine_done);
                Wait.run(restore.storage);
                Wait.pending = true;
                grid.checkpoint(Wait.grid_done);
                Wait.run(restore.storage);

                // The checkpoint op's prepare: a pulse (client 0, no body), as replicas would
                // have prepared it while the previous checkpoint was current.
                var header = vsr.Header.Prepare.root(restore.options.cluster);
                header.operation = .pulse;
                header.op = checkpoint_op;
                header.commit = checkpoint_op - 1;
                header.timestamp = restore.timestamp_next +
                    if (final) checkpoint_timestamp_gap else 0;
                restore.timestamp_next = header.timestamp + 1;
                header.release = restore.options.release;
                // Its parent, op C - 1, is not in the WAL and never read: any value.
                header.parent = vsr.checksum(std.mem.asBytes(&checkpoint_op));
                header.checkpoint_id = superblock.working.vsr_state.checkpoint.parent_checkpoint_id;
                header.set_checksum_body(&.{});
                header.set_checksum();
                assert(header.invalid() == null);

                // The WAL from op C: C's prepare, then pulses up to the op past which C is
                // durable (`vsr.Checkpoint.durable`), chained by parent checksum, so that
                // replicas repair from op C + 1 only.
                var chain: [
                    constants.lsm_compaction_ops + constants.pipeline_prepare_queue_max +
                        2
                ]vsr.Header.Prepare = undefined;
                chain[0] = header;
                for (chain[1..], 1..) |*next, index| {
                    next.* = chain[index - 1];
                    next.op = checkpoint_op + index;
                    next.commit = next.op - 1;
                    next.timestamp = chain[index - 1].timestamp + std.time.ns_per_ms;
                    next.parent = chain[index - 1].checksum;
                    next.checkpoint_id = superblock.working.checkpoint_id();
                    next.set_checksum_body(&.{});
                    next.set_checksum();
                    assert(next.invalid() == null);
                }
                const head = chain[chain.len - 1];
                assert(vsr.Checkpoint.durable(checkpoint_op, head.op));
                assert(!vsr.Checkpoint.durable(checkpoint_op, head.op - 1));
                if (final) {
                    try wal_write(gpa, restore.storage, restore.options.cluster, &chain);
                    restore.timestamp_next = head.timestamp + 1;
                }
                const view_headers = vsr.Headers.ViewChangeArray.init(.view, &.{head});

                Wait.pending = true;
                superblock.checkpoint(Wait.superblock_done, restore.superblock_context, .{
                    .header = header,
                    .view_attributes = if (final) .{
                        .log_view = 0,
                        .view = 0,
                        .headers = &view_headers,
                    } else null,
                    .manifest_references = restore.state_machine.forest.manifest_log
                        .checkpoint_references(),
                    .free_set_references = .{
                        .blocks_acquired = grid.free_set_checkpoint_blocks_acquired
                            .checkpoint_reference(),
                        .blocks_released = grid.free_set_checkpoint_blocks_released
                            .checkpoint_reference(),
                    },
                    // No client sessions: clients register again.
                    .client_sessions_reference = .{
                        .last_block_checksum = 0,
                        .last_block_address = 0,
                        .trailer_size = 0,
                        .checksum = vsr.checksum(&.{}),
                    },
                    .commit_max = if (final) head.op else checkpoint_op,
                    .sync_op_min = 0,
                    .sync_op_max = 0,
                    .storage_size = data_file_size_min +
                        (grid.free_set.highest_address_acquired() orelse 0) * constants.block_size,
                    .release = restore.options.release,
                });
                Wait.run(restore.storage);
                // One process: every checkpoint is durable at once.
                grid.mark_checkpoint_not_durable();
                grid.free_set.mark_checkpoint_durable();
            }

            /// The export's checks against the restored forest: each view's hash and group
            /// count, each ledger's total, and each table's live rows.
            fn checks(restore: *Restore, gpa: std.mem.Allocator) !void {
                const state_machine = restore.state_machine;
                var failed = false;

                const views = state_machine.restore_views();
                assert(views.len == restore.plan.summary.view_count);
                for (views, restore.plan.checks_view[0..views.len]) |*view, *check| {
                    assert(view.id == check.id);
                    if (view.state != .ready or check.state != .ready) {
                        // Building: the new cluster's pulses add the rows (N80).
                        log.info("view {}: {s} here, {s} in the export: not compared", .{
                            view.id,
                            @tagName(view.state),
                            @tagName(check.state),
                        });
                        continue;
                    }
                    if (view.group_count != check.group_count or
                        !std.mem.eql(u8, &view.hash, &check.hash))
                    {
                        log.err("view {}: {} groups, hash {x}; the export: {} groups, hash {x}", .{
                            view.id,
                            view.group_count,
                            view.hash,
                            check.group_count,
                            check.hash,
                        });
                        failed = true;
                    }
                }

                const ledgers_ = state_machine.restore_ledgers();
                assert(ledgers_.len == restore.plan.summary.ledger_count);
                const index = state_machine.restore_ledger_index();
                var totals: [nerva.ledgers_max]i128 = @splat(0);

                const rows = try gpa.alloc(nerva.Row, check_rows_page);
                defer gpa.free(rows);
                var scan: Scan = .{ .rows = rows };
                var key_min: u128 = @as(u128, 1) << 64;
                var table_index: usize = 0;
                var table: u32 = 0;
                var table_rows: u64 = 0;
                var table_hash = std.crypto.hash.sha2.Sha256.init(.{});
                const snapshot = restore.superblock.working.vsr_state.checkpoint.header.op +
                    constants.lsm_compaction_ops + 1;
                while (true) {
                    const page = scan.read(restore.storage, state_machine, snapshot, key_min);
                    for (page) |*row| {
                        assert(row.key >= key_min);
                        if (row.flags.deleted) continue;
                        const row_table: u32 = @intCast(row.key >> 64);
                        if (row_table != table) {
                            if (table_rows > 0) {
                                failed = !table_check(
                                    restore.plan.checks_table,
                                    &table_index,
                                    table,
                                    table_rows,
                                    &table_hash,
                                ) or failed;
                            }
                            table = row_table;
                            table_rows = 0;
                            table_hash = std.crypto.hash.sha2.Sha256.init(.{});
                        }
                        table_rows += 1;
                        export_file.rows_hash_update(
                            &table_hash,
                            table,
                            @truncate(row.key),
                            row.op,
                            &row.value,
                        );
                        for (index.table_fields(table)) |*field| {
                            totals[field.ledger] +=
                                std.mem.readInt(i64, row.value[field.offset..][0..8], .little);
                        }
                    }
                    if (page.len < rows.len) break;
                    key_min = page[page.len - 1].key + 1;
                }
                if (table_rows > 0) {
                    failed = !table_check(
                        restore.plan.checks_table,
                        &table_index,
                        table,
                        table_rows,
                        &table_hash,
                    ) or failed;
                }
                if (table_index != restore.plan.checks_table.len) {
                    log.err("table {}: no rows here; the export has {}", .{
                        restore.plan.checks_table[table_index].table,
                        restore.plan.checks_table[table_index].row_count,
                    });
                    failed = true;
                }

                const checks_ledger = restore.plan.checks_ledger[0..ledgers_.len];
                for (ledgers_, checks_ledger, totals[0..ledgers_.len]) |*ledger, *check, total| {
                    assert(ledger.definition.id == check.id);
                    if (total != check.total) {
                        log.err("ledger {}: total {}; the export: {}", .{
                            check.id,
                            total,
                            check.total,
                        });
                        failed = true;
                    }
                }
                if (failed) return error.ChecksFailed;
                log.info("checks passed: {} views, {} ledgers, {} tables", .{
                    views.len,
                    ledgers_.len,
                    restore.plan.checks_table.len,
                });
            }
        };

        /// Whether a table's live rows match its check, the next one in order.
        fn table_check(
            checks_table: []const export_file.CheckTable,
            table_index: *usize,
            table: u32,
            row_count: u64,
            hash: *std.crypto.hash.sha2.Sha256,
        ) bool {
            while (table_index.* < checks_table.len and checks_table[table_index.*].table < table) {
                log.err("table {}: no rows here; the export has {}", .{
                    checks_table[table_index.*].table,
                    checks_table[table_index.*].row_count,
                });
                table_index.* += 1;
                return false;
            }
            if (table_index.* == checks_table.len or checks_table[table_index.*].table != table) {
                log.err("table {}: {} rows here; none in the export", .{ table, row_count });
                return false;
            }
            const check = &checks_table[table_index.*];
            table_index.* += 1;
            const digest = hash.finalResult();
            if (check.row_count != row_count or !std.mem.eql(u8, &digest, &check.rows_hash)) {
                log.err("table {}: {} rows here; {} in the export, or another hash", .{
                    table,
                    row_count,
                    check.row_count,
                });
                return false;
            }
            return true;
        }

        const Scan = struct {
            rows: []nerva.Row,
            results: ?[]const nerva.Row = null,

            fn read(
                scan: *Scan,
                storage: *Storage,
                state_machine: *StateMachine,
                snapshot: u64,
                key_min: u128,
            ) []const nerva.Row {
                assert(scan.results == null);
                assert(current == null);
                current = scan;
                defer current = null;
                state_machine.restore_scan_rows(callback, snapshot, key_min, scan.rows);
                while (scan.results == null) storage.run();
                defer scan.results = null;
                return scan.results.?;
            }

            var current: ?*Scan = null;

            fn callback(_: *StateMachine, results: []const nerva.Row) void {
                current.?.results = results;
            }
        };

        /// Writes prepares (headers without bodies) into their WAL slots, in the prepares zone
        /// and the headers zone, whole sectors of headers at a time: a slot not in the chain
        /// keeps what `format` wrote there.
        fn wal_write(
            gpa: std.mem.Allocator,
            storage: *Storage,
            cluster: u128,
            chain: []const vsr.Header.Prepare,
        ) !void {
            const sector = try gpa.alignedAlloc(u8, constants.sector_size, constants.sector_size);
            defer gpa.free(sector);
            for (chain) |*header| {
                @memset(sector, 0);
                stdx.copy_disjoint(.inexact, u8, sector, std.mem.asBytes(header));
                const slot = header.op % constants.journal_slot_count;
                write(storage, sector, .wal_prepares, slot * constants.message_size_max);
            }

            const headers_per_sector = @divExact(
                constants.sector_size,
                @sizeOf(vsr.Header.Prepare),
            );
            for (chain, 0..) |*first, index| {
                const sector_index = (first.op % constants.journal_slot_count) / headers_per_sector;
                // Each sector once, from the first header of the chain in it (the chain may
                // wrap around the ring).
                const seen = for (chain[0..index]) |*earlier| {
                    const earlier_sector =
                        (earlier.op % constants.journal_slot_count) / headers_per_sector;
                    if (earlier_sector == sector_index) break true;
                } else false;
                if (seen) continue;
                const headers = stdx.bytes_as_slice(.exact, vsr.Header.Prepare, sector);
                for (headers, 0..) |*slot_header, slot_in_sector| {
                    const slot = sector_index * headers_per_sector + slot_in_sector;
                    slot_header.* = replica_format.slot_header(cluster, slot);
                    for (chain) |*header| {
                        if (header.op % constants.journal_slot_count == slot) {
                            slot_header.* = header.*;
                        }
                    }
                }
                write(
                    storage,
                    sector,
                    .wal_headers,
                    sector_index * headers_per_sector * @sizeOf(vsr.Header.Prepare),
                );
            }
        }

        fn write(storage: *Storage, buffer: []const u8, zone: vsr.Zone, offset: u64) void {
            const Written = struct {
                var pending: bool = false;
                fn callback(_: *Storage.Write) void {
                    assert(pending);
                    pending = false;
                }
            };
            var write_: Storage.Write = undefined;
            Written.pending = true;
            storage.write_sectors(Written.callback, &write_, buffer, zone, offset);
            while (Written.pending) storage.run();
        }

        /// Until every write is on disk.
        fn flush(storage: *Storage) void {
            const Flushed = struct {
                var done = false;
                fn callback(_: *Storage.Flush) void {
                    done = true;
                }
            };
            var flush_: Storage.Flush = undefined;
            while (true) {
                for (0..100) |_| storage.run();
                Flushed.done = false;
                storage.flush_sectors(Flushed.callback, &flush_);
                while (!Flushed.done) storage.run();
                if (storage.unflushed == 0) break;
            }
        }
    };
}
