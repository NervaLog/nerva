//! `nerva api`'s documents: values of up to 512 KiB under string keys, in namespaces, read and
//! written in optimistic transactions (docs/DECISIONS.md N41). Stored as `documents.zig`
//! documents in `catalog.table_documents`.
//!
//!     POST /v1/documents/get     {"namespace": "7", "keys": ["a", …], "as_of": "12"}
//!     POST /v1/documents/commit  {"namespace": "7", "key": "<32 hex digits>",
//!                                 "reads": [{"key": "a", "version": "9"}],
//!                                 "writes": [{"key": "a", "value_hex": "…"},
//!                                            {"key": "b", "delete": true}]}
//!     GET  /v1/documents/changes?namespace=7&cursor=<c>&limit=<n>
//!
//! - A key is 1–1024 bytes of UTF-8; a value up to 512 KiB, as hex (`value_hex`). A `get` reads
//!   at most as many chunks as 256 documents of 64 KiB (about 16 MiB): more answers 413.
//! - A document's `version` is the op of its last write (a put or a delete), or "0" if it was
//!   never written. `get` answers each key's `exists`, `version` and `value_hex` ("" if absent),
//!   as of one op: the latest, or `as_of` (which must already be committed).
//! - A commit is one transaction: every read must still be at its `version` ("0" for a key never
//!   written), or nothing applies. `200 {"status": "committed", "op"}`, `409 {"status":
//!   "conflict", "key", "version"}` (the stale read and the document's current version), or 400.
//!   A commit may carry a `key`, exactly as `/v1/commit` does (P123, `api.zig`): it is sent as
//!   the transaction's first entry, and the same request again answers `200 {"status":
//!   "committed", "op", "replayed": true, "code": "NRV-W0201"}` and applies nothing; other
//!   reads and writes under the key answer `409 key_reused` (or `key_collision`).
//!   A commit's entries are limited by one request: about 600 KB of keys and values in all.
//! - `changes` lists the namespace's document writes in commit order, each with its `op`, `kind`
//!   (`put` or `delete`), and `value_hex` for a put. Paging is as in `/v1/changes`: `limit`
//!   bounds the underlying changes scanned, so a page may hold fewer documents, or none, while
//!   `more` is true. A page always ends at an op boundary.
//! - A delete writes a tombstone (`documents.zig`). A put that shrinks a document, and a delete,
//!   leave its old trailing chunks in place, unread: an accepted cost (N41).

const std = @import("std");
const assert = std.debug.assert;

const nerva = @import("../../nerva.zig");
const config = @import("../../config.zig");
const vsr = @import("../../vsr.zig");
const catalog = @import("../catalog.zig");
const documents = @import("../documents.zig");
const api = @import("api.zig");

const Change = nerva.Change;
const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
const value_size = nerva.value_size;

const Reply = api.Reply;
const Writer = api.Writer;
const bad_as = api.bad_as;

const table = catalog.table_documents;

/// Keys per `get`, at most.
pub const keys_max = 256;
/// Chunks per `get`, at most: as many as `keys_max` documents of 64 KiB, the largest before
/// documents grew to 512 KiB, so every `get` that answered then still does, and a reply stays
/// well inside the request's memory budget (#25, #60).
pub const get_chunks_max = keys_max * documents.chunk_count(documents.key_size_max, 64 * 1024);

comptime {
    // A document of the largest key and value fits one commit request of the production
    // configuration, with room to spare: it is written atomically (#25). (Tests run with smaller
    // messages.)
    const message_size_max = config.configs.default_production.cluster.message_size_max;
    const body_size_max = message_size_max - @sizeOf(vsr.Header);
    const chunks = documents.chunk_count(documents.key_size_max, documents.value_size_max);
    // A commit is one batch of entries, plus a multi-batch trailer well under 1024 entries.
    assert((chunks + 1024) * @sizeOf(Entry) <= body_size_max);
}
/// Rows per lookup when reading documents' tail chunks.
const tail_rows_max = 1024;
/// An op's changes: at most one request's entries (`Operation.commit.event_max`), with room.
const changes_per_op_max = 1 << 16;

const Document = struct {
    key: []const u8,
    /// The op of the last write at the read's op, or zero if never written.
    version: u64,
    /// Null if absent (never written, or deleted).
    value: ?[]const u8,
};

pub fn get(arena: std.mem.Allocator, client: anytype, body: []const u8) !Reply {
    const Request = struct {
        namespace: []const u8,
        keys: []const []const u8,
        as_of: ?[]const u8 = null,
    };
    const request = try api.json_parse(Request, arena, body);
    const namespace = try api.u64_parse(request.namespace, "namespace");
    if (request.keys.len == 0) return bad_as(.E0502, "keys must not be empty");
    if (request.keys.len > keys_max) return bad_as(.E0502, "too many keys for one request");
    var seen: std.StringHashMapUnmanaged(void) = .{};
    for (request.keys) |key| {
        try key_check(key);
        if ((try seen.getOrPut(arena, key)).found_existing) return bad_as(.E0502, "repeated key");
    }

    const as_of: ?u64 = if (request.as_of) |text| try api.u64_parse(text, "as_of") else null;
    if (as_of == 0) return bad_as(.E0107, "as_of must be positive");

    const row_keys = try arena.alloc(RowKey, request.keys.len);
    for (row_keys, request.keys) |*row_key, key| {
        row_key.* = .{ .table = table, .id = documents.row_id(namespace, key) };
    }
    const chunk0s = try arena.alloc(RowValue, row_keys.len);
    try client.lookup_rows(row_keys, chunk0s);
    const op_read = chunk0s[0].op_read;

    // As in `/v1/row`: a lookup's own op is newer than every committed op.
    if (as_of != null and as_of.? >= op_read) return api.not_committed("as_of is not yet committed");

    // Each document's chunk 0 at the read's op: the lookup's, or the history's for `as_of`.
    for (chunk0s) |*chunk0| {
        assert(chunk0.op_read == op_read);
        const at = as_of orelse continue;
        if (chunk0.op <= at) continue;
        const change = try api.change_as_of(client, table, chunk0.id, at);
        chunk0.op = if (change) |c| c.op else 0;
        chunk0.flags.exists = if (change) |c| c.kind == .put else false;
        chunk0.value = if (change) |c| c.value else @splat(0);
    }

    var chunk_total: usize = 0;
    for (chunk0s) |*chunk0| {
        if (!chunk0.flags.exists) continue;
        chunk_total += documents.chunk0_count(&chunk0.value) catch return error.Corrupt;
    }
    if (chunk_total > get_chunks_max) {
        return api.error_reply(
            arena,
            .E0504,
            413,
            "documents too large for one get: ask for fewer keys",
            .no,
        );
    }

    const found = try arena.alloc(Document, request.keys.len);
    try documents_read(arena, client, namespace, request.keys, chunk0s, found);

    var out = Writer.init(arena);
    // Sized up front: grown step by step, the arena would keep every smaller copy (#60).
    var reply_size: usize = 64;
    for (found) |*document| {
        // A key's JSON is at most 6 bytes per byte (`\u00XX`); a value is hex.
        reply_size += 96 + 6 * document.key.len + 2 * (if (document.value) |v| v.len else 0);
    }
    try out.list.ensureTotalCapacity(reply_size);
    try out.raw("{\"op\":");
    try out.number(as_of orelse op_read);
    try out.raw(",\"documents\":[");
    for (found, 0..) |*document, index| {
        if (index > 0) try out.raw(",");
        try out.raw("{\"key\":");
        try string(&out, document.key);
        try out.print(",\"exists\":{},\"version\":", .{document.value != null});
        try out.number(document.version);
        try out.raw(",\"value_hex\":");
        try out.hex(document.value orelse "");
        try out.raw("}");
    }
    try out.raw("]}");
    return .{ .status = 200, .body = out.items() };
}

/// Reads the documents whose chunk 0 rows are `chunk0s` (each at its version) into `found`.
/// A tail chunk rewritten since then is read from its history at that version.
fn documents_read(
    arena: std.mem.Allocator,
    client: anytype,
    namespace: u64,
    keys: []const []const u8,
    chunk0s: []const RowValue,
    found: []Document,
) !void {
    assert(keys.len == chunk0s.len);
    assert(keys.len == found.len);

    // Every document's chunks, chunk 0 first: `chunks[starts[i]..starts[i + 1]]`.
    const starts = try arena.alloc(usize, keys.len + 1);
    starts[0] = 0;
    for (chunk0s, 0..) |*chunk0, index| {
        const count = if (chunk0.flags.exists)
            documents.chunk0_count(&chunk0.value) catch return error.Corrupt
        else
            0;
        starts[index + 1] = starts[index] + count;
    }
    const chunks = try arena.alloc([value_size]u8, starts[keys.len]);
    const tails = try arena.alloc(RowKey, starts[keys.len]);
    var tail_count: usize = 0;
    for (chunk0s, 0..) |*chunk0, index| {
        const start = starts[index];
        if (start == starts[index + 1]) continue;
        chunks[start] = chunk0.value;
        for (start + 1..starts[index + 1], 1..) |_, chunk| {
            tails[tail_count] = .{
                .table = table,
                .id = documents.tail_id(chunk0.id, @intCast(chunk)),
            };
            tail_count += 1;
        }
    }

    // Tail chunks, in lookups of at most `tail_rows_max` rows, in the same order.
    const rows = try arena.alloc(RowValue, tail_count);
    var offset: usize = 0;
    while (offset < tail_count) {
        const size = @min(tail_rows_max, tail_count - offset);
        try client.lookup_rows(tails[offset..][0..size], rows[offset..][0..size]);
        offset += size;
    }

    var tail_index: usize = 0;
    for (chunk0s, keys, found, 0..) |*chunk0, key, *document, index| {
        document.* = .{ .key = key, .version = chunk0.op, .value = null };
        const start = starts[index];
        if (start == starts[index + 1]) continue;

        for (chunks[start + 1 .. starts[index + 1]]) |*chunk| {
            const tail = &rows[tail_index];
            tail_index += 1;
            // Written with chunk 0 at its version; a later write moved it on.
            if (tail.flags.exists and tail.op == chunk0.op) {
                chunk.* = tail.value;
            } else {
                if (tail.op < chunk0.op) return error.Corrupt;
                const change = try api.change_as_of(client, table, tail.id, chunk0.op) orelse
                    return error.Corrupt;
                if (change.op != chunk0.op or change.kind != .put) return error.Corrupt;
                chunk.* = change.value;
            }
        }
        const decoded = documents.chunks_decode(arena, chunks[start..starts[index + 1]]) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Corrupt => return error.Corrupt,
            };
        // A hash collision between two keys: never expected.
        if (decoded.namespace != namespace) return error.Corrupt;
        if (!std.mem.eql(u8, decoded.key, key)) return error.Corrupt;
        document.value = decoded.value;
    }
    assert(tail_index == tail_count);
}

pub fn commit(arena: std.mem.Allocator, client: anytype, body: []const u8) !Reply {
    const Request = struct {
        key: ?[]const u8 = null,
        namespace: []const u8,
        reads: []const struct { key: []const u8, version: []const u8 } = &.{},
        writes: []const struct {
            key: []const u8,
            value_hex: ?[]const u8 = null,
            delete: bool = false,
        } = &.{},
    };
    const request = try api.json_parse(Request, arena, body);
    const key: ?u128 = if (request.key) |text| try api.key_parse(text) else null;
    const namespace = try api.u64_parse(request.namespace, "namespace");
    if (request.reads.len + request.writes.len == 0) {
        return bad_as(.E0502, "reads and writes must not both be empty");
    }

    var entries: std.ArrayListUnmanaged(Entry) = .{};
    // Under a key, the transaction starts with its key entry (P123); the reads and writes
    // that follow are indexed from `first`.
    if (key) |k| try entries.append(arena, nerva.commit_key_entry(k));
    const first = entries.items.len;
    var keys_read: std.StringHashMapUnmanaged(void) = .{};
    for (request.reads) |read| {
        try key_check(read.key);
        if ((try keys_read.getOrPut(arena, read.key)).found_existing) {
            return bad_as(.E0502, "a commit reads a key at most once");
        }
        try entries.append(arena, .{
            .id = documents.row_id(namespace, read.key),
            .table = table,
            .kind = .read,
            .op_seen = try api.u64_parse(read.version, "version"),
            .value = @splat(0),
        });
    }

    var keys_written: std.StringHashMapUnmanaged(void) = .{};
    for (request.writes) |write| {
        try key_check(write.key);
        if ((try keys_written.getOrPut(arena, write.key)).found_existing) {
            return bad_as(.E0502, "a commit writes a key at most once");
        }
        if (write.delete == (write.value_hex != null)) {
            return bad_as(.E0501, "a write has value_hex or \"delete\": true");
        }
        const value: ?[]const u8 =
            if (write.value_hex) |text| try value_parse(arena, text) else null;
        const chunks = try documents.chunks_encode(arena, namespace, write.key, value);
        const id0 = documents.row_id(namespace, write.key);
        for (chunks, 0..) |*chunk, index| {
            try entries.append(arena, .{
                .id = documents.chunk_id_from(id0, @intCast(index)),
                .table = table,
                .kind = .put,
                .op_seen = 0,
                .value = chunk.*,
            });
        }
    }

    const results = try arena.alloc(EntryResult, entries.items.len);
    try client.commit(entries.items, results);

    var out = Writer.init(arena);
    if (key != null) {
        if (try api.key_reply(arena, &out, results[0])) |reply| return reply;
    }
    for (results[first..], 0..) |result, index| {
        switch (result.status) {
            .ok, .aborted => continue,
            .conflict => {
                // Only reads conflict, and they come first.
                assert(index < request.reads.len);
                try out.raw("{\"status\":\"conflict\",\"key\":");
                try string(&out, request.reads[index].key);
                try out.raw(",\"version\":");
                try out.number(result.op);
                try out.raw("}");
                return api.refused_reply(&out, 409, .E0503);
            },
            // Two keys' chunks share a row id: a hash collision, never expected.
            .write_duplicate => return error.Corrupt,
            // Built above from valid parts: the server would be at fault.
            else => return api.unexpected_status(
                arena,
                "documents commit rejected an entry",
                result.status,
            ),
        }
    }
    assert(results[0].status == .ok);
    try out.raw("{\"status\":\"committed\",\"op\":");
    try out.number(results[0].op);
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

pub fn changes(arena: std.mem.Allocator, client: anytype, query: []const u8) !Reply {
    const parameters = try api.query_parse(arena, query, &.{ "namespace", "cursor", "limit" });
    const namespace = try api.u64_parse(
        parameters.get("namespace") orelse return bad_as(.E0107, "namespace is required"),
        "namespace",
    );
    const limit = try api.limit_parse(parameters.get("limit"));
    var cursor = if (parameters.get("cursor")) |text| try api.u64_parse(text, "cursor") else 0;

    // Whole ops only: read on while the page holds a single op that continues past it, and
    // leave a trailing op that continues for the next page.
    var accumulated: std.ArrayListUnmanaged(Change) = .{};
    const page = try arena.alloc(Change, limit + 1);
    var more: bool = undefined;
    var op_through: u64 = 0;
    for (0..changes_per_op_max / limit + 2) |iteration| {
        const count = try client.get_changes(.{ .timestamp_min = cursor, .limit = limit }, page);
        if (count == 0) {
            if (iteration == 0) return bad_as(.E0408, "invalid cursor");
            return error.Corrupt; // The feed's own cursor.
        }
        const end = page[count - 1];
        assert(end.kind == .end);
        try accumulated.appendSlice(arena, page[0 .. count - 1]);
        cursor = end.timestamp;
        more = end.flags.more;
        if (!more) {
            op_through = end.op;
            break;
        }
        const items = accumulated.items;
        if (items.len > 0 and items[0].op != items[items.len - 1].op) {
            var first = items.len - 1;
            while (items[first - 1].op == items[items.len - 1].op) first -= 1;
            cursor = items[first].timestamp;
            accumulated.shrinkRetainingCapacity(first);
            break;
        }
    } else return error.Corrupt; // An op larger than any request.

    var out = Writer.init(arena);
    try out.raw("{\"documents\":[");
    var written: u32 = 0;
    var start: usize = 0;
    const items = accumulated.items;
    while (start < items.len) {
        var end = start + 1;
        while (end < items.len and items[end].op == items[start].op) end += 1;
        const decoded = try op_documents(arena, namespace, items[start..end]);
        for (decoded) |document| {
            if (written > 0) try out.raw(",");
            written += 1;
            try out.raw("{\"key\":");
            try string(&out, document.key);
            try out.raw(",\"op\":");
            try out.number(items[start].op);
            if (document.value) |value| {
                try out.raw(",\"kind\":\"put\",\"value_hex\":");
                try out.hex(value);
            } else {
                try out.raw(",\"kind\":\"delete\"");
            }
            try out.raw("}");
        }
        start = end;
    }
    try out.print("],\"more\":{},\"cursor\":", .{more});
    try out.number(cursor);
    // The op the answer is complete through, once there is no more.
    try out.raw(",\"op\":");
    if (more) try out.raw("null") else try out.number(op_through);
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

/// The documents of `namespace` that one op wrote, from all of that op's changes: each document
/// once, as the op left it, in the order the op first wrote it.
fn op_documents(
    arena: std.mem.Allocator,
    namespace: u64,
    op_changes: []const Change,
) ![]const Document {
    assert(op_changes.len > 0);
    // The op's rows of the documents table, as the op left them.
    var rows: std.AutoArrayHashMapUnmanaged(u64, *const [value_size]u8) = .{};
    for (op_changes) |*change| {
        assert(change.op == op_changes[0].op);
        if (change.table != table) continue;
        // The API writes documents with puts only (deletes are tombstones).
        if (change.kind != .put) continue;
        try rows.put(arena, change.id, &change.value);
    }

    var found: std.ArrayListUnmanaged(Document) = .{};
    for (rows.keys(), rows.values()) |id, chunk0| {
        // Any row may be a tail; only a chunk 0 decodes to a key that hashes to its id.
        const header = std.mem.bytesToValue(documents.Header, chunk0[0..@sizeOf(documents.Header)]);
        if (header.namespace != namespace) continue;
        const count = documents.chunk0_count(chunk0) catch continue;
        const chunks = try arena.alloc([value_size]u8, count);
        chunks[0] = chunk0.*;
        const complete = for (chunks[1..], 1..) |*chunk, index| {
            chunk.* = (rows.get(documents.tail_id(id, @intCast(index))) orelse break false).*;
        } else true;
        if (!complete) continue;
        const decoded = documents.chunks_decode(arena, chunks) catch continue;
        if (documents.row_id(namespace, decoded.key) != id) continue;
        try found.append(arena, .{
            .key = decoded.key,
            .version = op_changes[0].op,
            .value = decoded.value,
        });
    }
    return found.items;
}

fn key_check(key: []const u8) error{BadRequest}!void {
    if (key.len == 0) return bad_as(.E0501, "a key must not be empty");
    if (key.len > documents.key_size_max) return bad_as(.E0501, "a key is at most 1024 bytes");
    if (!std.unicode.utf8ValidateSlice(key)) return bad_as(.E0501, "a key must be UTF-8");
}

fn value_parse(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len % 2 != 0) return bad_as(.E0501, "value_hex is not hex");
    if (text.len > documents.value_size_max * 2) return bad_as(.E0501, "a value is at most 512 KiB");
    const value = try arena.alloc(u8, text.len / 2);
    _ = std.fmt.hexToBytes(value, text) catch return bad_as(.E0501, "value_hex is not hex");
    return value;
}

fn string(out: *Writer, text: []const u8) !void {
    try std.json.stringify(text, .{}, out.list.writer());
}

const testing = std.testing;

test "documents feed: an op's changes decode to its documents, each as the op left it" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var op_changes: std.ArrayListUnmanaged(Change) = .{};
    const writes = [_]struct { namespace: u64, key: []const u8, value: ?[]const u8 }{
        .{ .namespace = 7, .key = "a", .value = "first" },
        .{ .namespace = 7, .key = "b" ** 100, .value = "x" ** 500 },
        .{ .namespace = 7, .key = "c", .value = null },
        .{ .namespace = 8, .key = "a", .value = "other namespace" },
        // A second write of "a" in the same op (another transaction of the same request).
        .{ .namespace = 7, .key = "a", .value = "second" },
    };
    for (writes) |write| {
        const chunks = try documents.chunks_encode(arena, write.namespace, write.key, write.value);
        for (chunks, 0..) |chunk, index| {
            try op_changes.append(arena, .{
                .id = documents.chunk_id(write.namespace, write.key, @intCast(index)),
                .table = table,
                .kind = .put,
                .flags = .{},
                .op = 9,
                .timestamp = op_changes.items.len + 1,
                .value = chunk,
            });
        }
    }
    // Another table's row, with a value that looks like chunk 0 of "d".
    try op_changes.append(arena, .{
        .id = documents.row_id(7, "d"),
        .table = 1,
        .kind = .put,
        .flags = .{},
        .op = 9,
        .timestamp = op_changes.items.len + 1,
        .value = (try documents.chunks_encode(arena, 7, "d", "v"))[0],
    });

    const found = try op_documents(arena, 7, op_changes.items);
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("a", found[0].key);
    try testing.expectEqualStrings("second", found[0].value.?);
    try testing.expectEqualStrings("b" ** 100, found[1].key);
    try testing.expectEqualStrings("x" ** 500, found[1].value.?);
    try testing.expectEqualStrings("c", found[2].key);
    try testing.expectEqual(null, found[2].value);
    for (found) |document| try testing.expectEqual(@as(u64, 9), document.version);
}
