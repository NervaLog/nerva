//! `nerva export` (docs/DECISIONS.md N80): a client of a running cluster that writes the change
//! feed up to an op, the declarations of its views and ledgers, and checks of the state at that
//! op, to an export file (`export_file.zig`). Another release's `nerva import` replays it.
//!
//! The checks come from the export itself: each view's hash and group count as of the op, read
//! from the cluster; each ledger's total and each table's live rows, computed from the feed. The
//! rows are held in memory, one entry per row that ever existed, to compute them.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.export_);

const stdx = @import("stdx");
const constants = @import("../constants.zig");
const nerva = @import("../nerva.zig");
const ledgers = @import("ledgers.zig");
const export_file = @import("export_file.zig");
const catalog = @import("catalog.zig");
const import_ = @import("import.zig");
const Client = @import("client.zig").Client;

const changes_page_limit =
    nerva.Operation.get_changes.result_max(constants.message_body_size_max) - 1;

pub const Error = error{
    /// `--as-of` names an op the cluster has not reached.
    AsOfAhead,
    /// More distinct tables than an export checks.
    TooManyTables,
    /// More catalog rows than an import restores.
    TooManyCatalogRows,
    /// A view that `nerva import` would refuse (the log says why).
    ViewRefused,
};

const RowState = struct {
    op: u64,
    value: [nerva.value_size]u8,
    live: bool,
};

const Rows = std.AutoHashMapUnmanaged(u128, RowState);

/// Writes the export through `writer` (an `export_file.WriterType`); returns its summary.
/// `as_of` null: the op of the first read.
pub fn run(
    gpa: std.mem.Allocator,
    client: *Client,
    writer: anytype,
    as_of_option: ?u64,
) !export_file.Summary {
    var records: [2]nerva.ViewRecord = undefined;
    const op_read = op: {
        const header = try view_header(client, .{
            .view_id = 1,
            .group_hash_min = 0,
            .limit = 1,
        }, &records);
        break :op header.op;
    };
    const as_of = as_of_option orelse op_read;
    if (as_of > op_read) {
        log.err("--as-of={} is past the cluster's op {}", .{ as_of, op_read });
        return error.AsOfAhead;
    }
    assert(as_of > 0);
    log.info("exporting as of op {} (the cluster is at op {})", .{ as_of, op_read });

    var rows: Rows = .{};
    defer rows.deinit(gpa);
    const change_count = try changes_export(gpa, client, writer, as_of, &rows);
    log.info("{} changes, {} rows", .{ change_count, rows.count() });

    // What `nerva import` checks first, checked here too: an export it would refuse is found
    // before the replicas are stopped (#79).
    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var catalog_rows: import_.CatalogRows = .{};
    var rows_iterator = rows.iterator();
    while (rows_iterator.next()) |entry| {
        if (!entry.value_ptr.live) continue;
        if (entry.key_ptr.* >> 64 != catalog.table_catalog) continue;
        if (catalog_rows.count() == import_.catalog_rows_max) {
            log.err("the catalog has more than {} rows", .{import_.catalog_rows_max});
            return error.TooManyCatalogRows;
        }
        try catalog_rows.put(arena, @truncate(entry.key_ptr.*), entry.value_ptr.value);
    }

    var checks_view: [nerva.views_max]export_file.CheckView = undefined;
    var view_count: u32 = 0;
    while (view_count < nerva.views_max) {
        const id = view_count + 1;
        const latest = try view_header(client, .{
            .view_id = id,
            .group_hash_min = 0,
            .limit = 1,
        }, &records);
        if (latest.state == .missing) break;
        if (latest.declared_op > as_of) break; // Ids follow declaration order.
        assert(stdx.zeroed(latest.group_key[32..]));
        const view: export_file.View = .{
            .name = latest.group_key[0..32].*,
            .id = id,
            .declared_op = latest.declared_op,
        };
        _ = import_.view_definition(arena, &catalog_rows, &view) catch |err| switch (err) {
            error.Refused => {
                // Most often a gateway between declaring the view and writing its catalog
                // document: the next export finds it. A gateway that stopped there leaves the
                // view without one until `PUT /v1/views/<name>` is sent again.
                log.err("view {s}: `nerva import` would refuse it as of op {}: export again " ++
                    "later, or PUT the view again through `nerva api`", .{
                    std.mem.sliceTo(&view.name, 0),
                    as_of,
                });
                return error.ViewRefused;
            },
            else => return err,
        };
        try writer.write(&.{ .view = view });
        const then = try view_header(client, .{
            .view_id = id,
            .group_hash_min = 0,
            .limit = 1,
            .as_of = as_of,
        }, &records);
        assert(then.state != .missing);
        checks_view[view_count] = .{
            .id = id,
            .state = then.state,
            .group_count = then.group_count,
            .hash = then.hash,
        };
        view_count += 1;
    }

    var definitions: [nerva.ledgers_max]nerva.LedgerDefinition = undefined;
    var ledger_count: u32 = 0;
    while (ledger_count < nerva.ledgers_max) {
        const ledger = try client.get_ledger_slot(ledger_count + 1);
        if (ledger.slot == 0) break;
        assert(ledger.slot == ledger_count + 1);
        if (ledger.op > as_of) break; // Slots follow declaration order.
        try writer.write(&.{ .ledger = .{ .op = ledger.op, .definition = ledger.definition } });
        definitions[ledger_count] = ledger.definition;
        ledger_count += 1;
    }

    for (checks_view[0..view_count]) |*check| try writer.write(&.{ .check_view = check.* });

    var index: ledgers.Index = .{};
    for (definitions[0..ledger_count]) |*definition| index.insert(definition);
    var totals: [nerva.ledgers_max]i128 = @splat(0);
    var keys = try std.ArrayListUnmanaged(u128).initCapacity(gpa, rows.count());
    defer keys.deinit(gpa);
    var iterator = rows.iterator();
    while (iterator.next()) |entry| {
        if (!entry.value_ptr.live) continue;
        keys.appendAssumeCapacity(entry.key_ptr.*);
        const table: u32 = @intCast(entry.key_ptr.* >> 64);
        for (index.table_fields(table)) |*field| {
            const value = &entry.value_ptr.value;
            totals[field.ledger] += std.mem.readInt(i64, value[field.offset..][0..8], .little);
        }
    }
    for (definitions[0..ledger_count], totals[0..ledger_count]) |*definition, total| {
        try writer.write(&.{ .check_ledger = .{ .id = definition.id, .total = total } });
    }

    // Live rows in key order: one check per table.
    std.mem.sortUnstable(u128, keys.items, {}, std.sort.asc(u128));
    var table_count: u32 = 0;
    var start: usize = 0;
    while (start < keys.items.len) {
        const table: u32 = @intCast(keys.items[start] >> 64);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var end = start;
        while (end < keys.items.len and keys.items[end] >> 64 == table) : (end += 1) {
            const row = rows.getPtr(keys.items[end]).?;
            const id: u64 = @truncate(keys.items[end]);
            export_file.rows_hash_update(&hash, table, id, row.op, &row.value);
        }
        if (table_count == export_file.tables_max) return error.TooManyTables;
        try writer.write(&.{ .check_table = .{
            .table = table,
            .row_count = end - start,
            .rows_hash = hash.finalResult(),
        } });
        table_count += 1;
        start = end;
    }

    const summary: export_file.Summary = .{
        .as_of = as_of,
        .change_count = change_count,
        .view_count = view_count,
        .ledger_count = ledger_count,
        .table_count = table_count,
    };
    try writer.write(&.{ .summary = summary });
    try writer.finish();
    return summary;
}

/// Writes every change at or before `as_of`, in feed order, and keeps each row's last state.
fn changes_export(
    gpa: std.mem.Allocator,
    client: *Client,
    writer: anytype,
    as_of: u64,
    rows: *Rows,
) !u64 {
    const page = try gpa.alloc(nerva.Change, changes_page_limit + 1);
    defer gpa.free(page);
    var cursor: u64 = 0;
    var count: u64 = 0;
    while (true) {
        const records = try client.get_changes(.{
            .timestamp_min = cursor,
            .limit = changes_page_limit,
        }, page);
        assert(records > 0);
        const end = page[records - 1];
        assert(end.kind == .end);
        for (page[0 .. records - 1]) |*change| {
            assert(change.kind == .put or change.kind == .delete);
            if (change.op > as_of) return count;
            try writer.write(&.{ .change = .{
                .table = change.table,
                .id = change.id,
                .op = change.op,
                .timestamp = change.timestamp,
                .kind = if (change.kind == .put) .put else .delete,
                .value = change.value,
            } });
            try rows.put(gpa, nerva.row_key(change.table, change.id), .{
                .op = change.op,
                .value = change.value,
                .live = change.kind == .put,
            });
            count += 1;
        }
        if (!end.flags.more) return count;
        cursor = end.timestamp;
    }
}

fn view_header(
    client: *Client,
    query: nerva.ViewQuery,
    records: *[2]nerva.ViewRecord,
) !nerva.ViewRecord {
    const count = try client.get_view(query, records);
    assert(count >= 1);
    assert(records[0].kind == .header);
    return records[0];
}
