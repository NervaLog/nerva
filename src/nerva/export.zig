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
const record_changes_page_limit =
    nerva.Operation.get_record_changes.result_max(constants.message_body_size_max) - 1;

pub const Error = error{
    /// `--as-of` names an op the cluster has not reached.
    AsOfAhead,
    /// More distinct tables than an export checks.
    TooManyTables,
    /// More catalog rows than an import restores.
    TooManyCatalogRows,
    /// A view that `nerva import` would refuse (the log says why).
    ViewRefused,
    /// The first records or index appeared during a version 1 export: export again.
    RecordsAppeared,
};

const RowState = struct {
    op: u64,
    value: [nerva.value_size]u8,
    live: bool,
};

const Rows = std.AutoHashMapUnmanaged(u128, RowState);

const RecordState = struct {
    id: u128,
    op: u64,
    value: [nerva.record_value_size]u8,
    live: bool,
};

/// By `record_key`: a table's records are adjacent, in the order its check hashes them.
const Records = std.AutoHashMapUnmanaged(u128, RecordState);

/// The export file's version for this cluster: 2 if it holds a record's change or an index
/// (P123b, P123c), else 1, which the release before reads too.
pub fn format_version(client: *Client) !u32 {
    var page: [2]nerva.RecordChange = undefined;
    const count = try client.get_record_changes(.{ .timestamp_min = 0, .limit = 1 }, &page);
    assert(count >= 1);
    if (count > 1) return 2;
    if ((try client.get_index(1)).id != 0) return 2;
    return 1;
}

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
    var records_state: Records = .{};
    defer records_state.deinit(gpa);
    const counts = try changes_export(gpa, client, writer, as_of, &rows, &records_state);
    const change_count = counts.rows;
    log.info("{} changes, {} rows; {} records' changes, {} records", .{
        change_count,
        rows.count(),
        counts.records,
        records_state.count(),
    });

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

    var index_count: u32 = 0;
    while (index_count < nerva.indexes_max) {
        const index_ = try client.get_index(index_count + 1);
        if (index_.id == 0) break;
        assert(index_.id == index_count + 1);
        if (index_.declared_op > as_of) break; // Ids follow declaration order.
        if (writer.version == 1) {
            log.err("an index was declared during the export: export again", .{});
            return error.RecordsAppeared;
        }
        try writer.write(&.{ .index = .{
            .id = index_.id,
            .declared_op = index_.declared_op,
            .definition = index_.definition,
        } });
        index_count += 1;
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

    // Live records in key order: one check per record table.
    var record_keys = try std.ArrayListUnmanaged(u128).initCapacity(gpa, records_state.count());
    defer record_keys.deinit(gpa);
    var records_iterator = records_state.iterator();
    while (records_iterator.next()) |entry| {
        if (entry.value_ptr.live) record_keys.appendAssumeCapacity(entry.key_ptr.*);
    }
    std.mem.sortUnstable(u128, record_keys.items, {}, std.sort.asc(u128));
    var record_table_count: u32 = 0;
    start = 0;
    while (start < record_keys.items.len) {
        const table: u32 = @intCast(record_keys.items[start] >> 96);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var end = start;
        while (end < record_keys.items.len and record_keys.items[end] >> 96 == table) : (end += 1) {
            const record = records_state.getPtr(record_keys.items[end]).?;
            export_file.records_hash_update(&hash, table, record.id, record.op, &record.value);
        }
        if (record_table_count == export_file.tables_max) return error.TooManyTables;
        try writer.write(&.{ .check_records = .{
            .table = table,
            .record_count = end - start,
            .records_hash = hash.finalResult(),
        } });
        record_table_count += 1;
        start = end;
    }

    const summary: export_file.Summary = .{
        .as_of = as_of,
        .change_count = change_count,
        .view_count = view_count,
        .ledger_count = ledger_count,
        .table_count = table_count,
        .record_change_count = counts.records,
        .index_count = index_count,
        .record_table_count = record_table_count,
    };
    try writer.write(&.{ .summary = summary });
    try writer.finish();
    return summary;
}

/// Writes every change of rows and records at or before `as_of`, the two feeds merged by
/// timestamp, and keeps each row's and record's last state.
fn changes_export(
    gpa: std.mem.Allocator,
    client: *Client,
    writer: anytype,
    as_of: u64,
    rows: *Rows,
    records: *Records,
) !struct { rows: u64, records: u64 } {
    var feed_rows: Feed(nerva.Change, changes_page_limit) = try .init(gpa);
    defer feed_rows.deinit(gpa);
    var feed_records: Feed(nerva.RecordChange, record_changes_page_limit) = try .init(gpa);
    defer feed_records.deinit(gpa);
    var count_rows: u64 = 0;
    var count_records: u64 = 0;
    while (true) {
        const row = try feed_rows.peek(client, as_of);
        const record = try feed_records.peek(client, as_of);
        if (row == null and record == null) break;
        if (record == null or (row != null and row.?.timestamp < record.?.timestamp)) {
            const change = row.?;
            assert(change.kind == .put or change.kind == .delete);
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
            count_rows += 1;
            feed_rows.pop();
        } else {
            const change = record.?;
            assert(change.kind == .put or change.kind == .delete);
            if (writer.version == 1) {
                log.err("records were first written during the export: export again", .{});
                return error.RecordsAppeared;
            }
            try writer.write(&.{ .record_change = .{
                .table = change.table,
                .id = change.id,
                .op = change.op,
                .timestamp = change.timestamp,
                .kind = if (change.kind == .put) .put else .delete,
                .value = change.value,
            } });
            try records.put(gpa, nerva.record_key(change.table, change.id), .{
                .id = change.id,
                .op = change.op,
                .value = change.value,
                .live = change.kind == .put,
            });
            count_records += 1;
            feed_records.pop();
        }
    }
    return .{ .rows = count_rows, .records = count_records };
}

/// One feed, read a page at a time, up to `as_of`.
fn Feed(comptime Change: type, comptime page_limit: u32) type {
    return struct {
        const FeedType = @This();

        page: []Change,
        /// The page's changes, and the next to return.
        count: usize = 0,
        next: usize = 0,
        cursor: u64 = 0,
        done: bool = false,

        fn init(gpa: std.mem.Allocator) !FeedType {
            return .{ .page = try gpa.alloc(Change, page_limit + 1) };
        }

        fn deinit(feed: *FeedType, gpa: std.mem.Allocator) void {
            gpa.free(feed.page);
        }

        /// The next change at or before `as_of`, or null once there are none.
        fn peek(feed: *FeedType, client: *Client, as_of: u64) !?Change {
            while (feed.next == feed.count) {
                if (feed.done) return null;
                const filter: nerva.ChangesFilter = .{
                    .timestamp_min = feed.cursor,
                    .limit = page_limit,
                };
                const records = if (Change == nerva.Change)
                    try client.get_changes(filter, feed.page)
                else
                    try client.get_record_changes(filter, feed.page);
                assert(records > 0);
                const end = feed.page[records - 1];
                assert(end.kind == .end);
                feed.count = records - 1;
                feed.next = 0;
                feed.done = !end.flags.more;
                feed.cursor = end.timestamp;
            }
            const change = feed.page[feed.next];
            if (change.op > as_of) {
                feed.done = true;
                feed.next = feed.count;
                return null;
            }
            return change;
        }

        fn pop(feed: *FeedType) void {
            assert(feed.next < feed.count);
            feed.next += 1;
        }
    };
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
