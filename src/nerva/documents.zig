//! Documents: keys with values of up to 512 KiB, chunked over a table's 80-byte rows, read and
//! written in optimistic transactions through the client (docs/DECISIONS.md N39).
//!
//! The catalog keeps layouts and view declarations this way. Chunk 0 of a document holds a
//! header, then the key, then the start of the value; chunks 1.. continue the stream. Chunk 0's
//! id derives from the namespace and the key, and later chunks' ids from chunk 0's id, so a
//! reader holding only chunk 0 (a view following the feed) can find the rest.
//!
//! A deleted document is a tombstone: chunk 0 (and any tails the key needs) written with the
//! `deleted` flag and the key, but no value. So the feed names the key of every delete, and the
//! document's version (chunk 0's op) still advances. `nerva api` deletes this way (N41).

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");

const nerva = @import("../nerva.zig");
const Client = @import("client.zig").Client;

const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
const value_size = nerva.value_size;

/// The largest value one commit request can carry, with room for other writes (#25): a
/// larger value would no longer be written atomically.
pub const value_size_max = 512 * 1024;
pub const key_size_max = 1024;

/// Chunk 0's header.
pub const Header = extern struct {
    namespace: u64,
    reserved_a: u64 = 0,
    key_size: u16,
    flags: Flags = .{},
    /// Key plus value.
    payload_size: u32,

    pub const Flags = packed struct(u16) {
        /// A tombstone: the payload is the key alone.
        deleted: bool = false,
        padding: u15 = 0,
    };

    comptime {
        assert(@sizeOf(Header) == 24);
        assert(stdx.no_padding(Header));
    }
};

const chunk0_payload = value_size - @sizeOf(Header);

/// The number of rows a key of `key_size` with a value of `value_size_` occupies.
pub fn chunk_count(key_size: usize, value_size_: usize) u32 {
    const payload = key_size + value_size_;
    if (payload <= chunk0_payload) return 1;
    return @intCast(1 + stdx.div_ceil(payload - chunk0_payload, value_size));
}

/// The row id of chunk `chunk` of `key`.
pub fn chunk_id(namespace: u64, key: []const u8, chunk: u32) u64 {
    const id0 = row_id(namespace, key);
    return if (chunk == 0) id0 else tail_id(id0, chunk);
}

/// The id of chunk 0 of `key`: the first 8 bytes of SHA-256, little-endian. Persisted: never
/// change the derivation.
pub fn row_id(namespace: u64, key: []const u8) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva.documents.v1");
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, namespace)));
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(key.len))));
    hash.update(key);
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, 0)));
    const digest = hash.finalResult();
    return std.mem.readInt(u64, digest[0..8], .little);
}

/// The id of tail chunk `chunk` (≥ 1) of the document whose chunk 0 has id `id0`.
pub fn tail_id(id0: u64, chunk: u32) u64 {
    assert(chunk > 0);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva.documents.tail.v1");
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, id0)));
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, chunk)));
    const digest = hash.finalResult();
    return std.mem.readInt(u64, digest[0..8], .little);
}

/// Splits `key` and `value` into row values: chunk 0 first. A null `value` is a tombstone.
pub fn chunks_encode(
    arena: std.mem.Allocator,
    namespace: u64,
    key: []const u8,
    value_or_deleted: ?[]const u8,
) error{OutOfMemory}![]const [value_size]u8 {
    const value = value_or_deleted orelse "";
    assert(key.len <= key_size_max);
    assert(value.len <= value_size_max);
    const count = chunk_count(key.len, value.len);
    const chunks = try arena.alloc([value_size]u8, count);
    for (chunks) |*chunk| chunk.* = @splat(0);

    const header: Header = .{
        .namespace = namespace,
        .key_size = @intCast(key.len),
        .flags = .{ .deleted = value_or_deleted == null },
        .payload_size = @intCast(key.len + value.len),
    };
    @memcpy(chunks[0][0..@sizeOf(Header)], std.mem.asBytes(&header));

    // The payload (key, then value) as one stream over the chunks' data regions.
    var chunk: usize = 0;
    var offset: usize = @sizeOf(Header);
    for (&[_][]const u8{ key, value }) |part| {
        var remaining = part;
        while (remaining.len > 0) {
            if (offset == value_size) {
                chunk += 1;
                offset = 0;
            }
            const size = @min(remaining.len, value_size - offset);
            @memcpy(chunks[chunk][offset..][0..size], remaining[0..size]);
            offset += size;
            remaining = remaining[size..];
        }
    }
    assert(chunk < count);
    return chunks;
}

pub const Decoded = struct {
    namespace: u64,
    key: []const u8,
    /// Null for a tombstone.
    value: ?[]const u8,
};

/// Reassembles chunks written by `chunks_encode`. `chunks` must hold `chunk_count` rows.
pub fn chunks_decode(
    arena: std.mem.Allocator,
    chunks: []const [value_size]u8,
) error{ OutOfMemory, Corrupt }!Decoded {
    const header = try header_check(&chunks[0]);
    const value_size_ = header.payload_size - header.key_size;
    if (chunks.len != chunk_count(header.key_size, value_size_)) return error.Corrupt;

    const payload = try arena.alloc(u8, header.payload_size);
    var written: usize = 0;
    for (chunks, 0..) |*chunk, index| {
        const data = if (index == 0) chunk[@sizeOf(Header)..] else chunk[0..];
        const size = @min(data.len, payload.len - written);
        @memcpy(payload[written..][0..size], data[0..size]);
        written += size;
    }
    assert(written == payload.len);
    return .{
        .namespace = header.namespace,
        .key = payload[0..header.key_size],
        .value = if (header.flags.deleted) null else payload[header.key_size..],
    };
}

/// From chunk 0's header: how many rows the document occupies.
pub fn chunk0_count(chunk0: *const [value_size]u8) error{Corrupt}!u32 {
    const header = try header_check(chunk0);
    return chunk_count(header.key_size, header.payload_size - header.key_size);
}

/// Chunk 0's header, if it could be one. (A tail chunk can pass: only a decoded key that hashes
/// back to chunk 0's id proves it.)
fn header_check(chunk0: *const [value_size]u8) error{Corrupt}!Header {
    const header = std.mem.bytesToValue(Header, chunk0[0..@sizeOf(Header)]);
    if (header.reserved_a != 0 or header.flags.padding != 0) return error.Corrupt;
    if (header.key_size > key_size_max) return error.Corrupt;
    if (header.payload_size < header.key_size) return error.Corrupt;
    const value_size_ = header.payload_size - header.key_size;
    if (value_size_ > value_size_max) return error.Corrupt;
    if (header.flags.deleted and value_size_ != 0) return error.Corrupt;
    return header;
}

pub const Error = Client.Error || error{
    OutOfMemory,
    /// Two keys hash to one row id, or a row does not decode.
    Corrupt,
    /// A key or value over the limits, or a transaction over one request.
    TooLarge,
};

/// One optimistic transaction over the documents of one namespace in one table, through a
/// client of type `ClientType` (`Client`, or a stub in tests).
pub fn TransactionType(comptime ClientType: type) type {
    return struct {
        const DocumentsTransaction = @This();

        client: *ClientType,
        table: u32,
        namespace: u64,

        arena: std.mem.Allocator = undefined,
        /// Row → the version this transaction saw.
        reads: std.AutoArrayHashMapUnmanaged(u64, u64) = .{},
        /// Row → the write to commit (a later write to the same row replaces an earlier one).
        writes: std.AutoArrayHashMapUnmanaged(u64, Entry) = .{},
        /// Key → value as this transaction sees it, including its own writes.
        cache: std.StringHashMapUnmanaged(?[]const u8) = .{},

        pub const Outcome = enum { committed, conflict };

        /// Starts a transaction whose memory comes from `arena` (reset by the caller per attempt).
        pub fn begin(transaction: *DocumentsTransaction, arena: std.mem.Allocator) void {
            transaction.arena = arena;
            transaction.reads = .{};
            transaction.writes = .{};
            transaction.cache = .{};
        }

        pub fn get(transaction: *DocumentsTransaction, key: []const u8) Error!?[]const u8 {
            if (transaction.cache.get(key)) |cached| return cached;
            if (key.len > key_size_max) return error.TooLarge;
            const arena = transaction.arena;

            const chunk0 = try transaction.lookup(row_id(transaction.namespace, key));
            const value: ?[]const u8 = if (!chunk0.flags.exists) null else value: {
                const count = try chunk0_count(&chunk0.value);
                const chunks = try arena.alloc([value_size]u8, count);
                chunks[0] = chunk0.value;
                if (count > 1) {
                    const keys = try arena.alloc(RowKey, count - 1);
                    for (keys, 1..) |*row_key, chunk| {
                        row_key.* = .{
                            .id = chunk_id(transaction.namespace, key, @intCast(chunk)),
                            .table = transaction.table,
                        };
                    }
                    const rows = try arena.alloc(RowValue, keys.len);
                    try transaction.client.lookup_rows(keys, rows);
                    // The whole document as of chunk 0's version (N48): every write rewrites every
                    // chunk in one transaction, so a tail at another op was rewritten since chunk 0
                    // was read, and is read from its history at chunk 0's version.
                    for (rows, chunks[1..]) |*row, *chunk| {
                        if (row.flags.exists and row.op == chunk0.op) {
                            chunk.* = row.value;
                        } else {
                            if (row.op < chunk0.op) return error.Corrupt;
                            const change = try transaction.client.row_as_of(
                                transaction.table,
                                row.id,
                                chunk0.op,
                            ) orelse return error.Corrupt;
                            if (change.op != chunk0.op or change.kind != .put) return error.Corrupt;
                            chunk.* = change.value;
                        }
                        try transaction.read_record_at(row.id, chunk0.op);
                    }
                }
                const decoded = try chunks_decode(arena, chunks);
                // A hash collision, or a row of another namespace.
                if (!std.mem.eql(u8, decoded.key, key)) return error.Corrupt;
                if (decoded.namespace != transaction.namespace) return error.Corrupt;
                break :value decoded.value;
            };
            try transaction.cache.put(arena, try arena.dupe(u8, key), value);
            return value;
        }

        pub fn put(transaction: *DocumentsTransaction, key: []const u8, value: []const u8) Error!void {
            if (key.len > key_size_max or value.len > value_size_max) return error.TooLarge;
            const arena = transaction.arena;
            const chunks = try chunks_encode(arena, transaction.namespace, key, value);
            for (chunks, 0..) |*chunk, index| {
                const id = chunk_id(transaction.namespace, key, @intCast(index));
                try transaction.writes.put(arena, id, .{
                    .id = id,
                    .table = transaction.table,
                    .kind = .put,
                    .op_seen = 0,
                    .value = chunk.*,
                });
            }
            try transaction.cache.put(arena, try arena.dupe(u8, key), try arena.dupe(u8, value));
        }

        /// Commits every read (at the version seen) and every write as one transaction.
        pub fn commit(transaction: *DocumentsTransaction) Error!Outcome {
            const count = transaction.reads.count() + transaction.writes.count();
            if (count == 0) return .committed;
            const batch_size_limit = transaction.client.vsr_client.batch_size_limit.?;
            if (count > nerva.Operation.commit.event_max(batch_size_limit)) return error.TooLarge;

            const entries = try transaction.arena.alloc(Entry, count);
            var index: usize = 0;
            for (transaction.reads.keys(), transaction.reads.values()) |id, op_seen| {
                entries[index] = .{
                    .id = id,
                    .table = transaction.table,
                    .kind = .read,
                    .op_seen = op_seen,
                    .value = @splat(0),
                };
                index += 1;
            }
            for (transaction.writes.values()) |entry| {
                entries[index] = entry;
                index += 1;
            }
            assert(index == count);

            const results = try transaction.arena.alloc(EntryResult, count);
            try transaction.client.commit(entries, results);
            for (results) |result| {
                switch (result.status) {
                    .ok, .aborted => {},
                    .conflict => return .conflict,
                    else => std.debug.panic("documents: commit rejected an entry: {s}", .{
                        @tagName(result.status),
                    }),
                }
            }
            assert(results[0].status == .ok);
            return .committed;
        }

        fn lookup(transaction: *DocumentsTransaction, id: u64) Error!RowValue {
            var row: [1]RowValue = undefined;
            try transaction.client.lookup_rows(&.{.{ .id = id, .table = transaction.table }}, &row);
            try transaction.read_record(&row[0]);
            return row[0];
        }

        /// Records the version seen, unless this transaction already wrote the row.
        fn read_record(transaction: *DocumentsTransaction, row: *const RowValue) Error!void {
            assert(row.table == transaction.table);
            try transaction.read_record_at(row.id, row.op);
        }

        /// Records that row `id` was read at version `op`, unless this transaction already wrote it.
        fn read_record_at(transaction: *DocumentsTransaction, id: u64, op: u64) Error!void {
            if (transaction.writes.contains(id)) return;
            const entry = try transaction.reads.getOrPut(transaction.arena, id);
            // Two lookups in one transaction may see different versions; keep the first: commit
            // reports the conflict.
            if (!entry.found_existing) entry.value_ptr.* = op;
        }
    };
}

pub const Transaction = TransactionType(Client);

const testing = std.testing;

test "documents: chunks round-trip" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (0..200) |_| {
        const key = try arena.alloc(u8, random.intRangeAtMost(usize, 1, 200));
        random.bytes(key);
        const value = try arena.alloc(u8, random.intRangeAtMost(usize, 0, 3000));
        random.bytes(value);

        const namespace = random.int(u64);
        const chunks = try chunks_encode(arena, namespace, key, value);
        try testing.expectEqual(chunk_count(key.len, value.len), chunks.len);
        try testing.expectEqual(@as(u32, @intCast(chunks.len)), try chunk0_count(&chunks[0]));
        const decoded = try chunks_decode(arena, chunks);
        try testing.expectEqual(namespace, decoded.namespace);
        try testing.expectEqualSlices(u8, key, decoded.key);
        try testing.expectEqualSlices(u8, value, decoded.value.?);

        const tombstone = try chunks_encode(arena, namespace, key, null);
        try testing.expectEqual(chunk_count(key.len, 0), tombstone.len);
        const deleted = try chunks_decode(arena, tombstone);
        try testing.expectEqualSlices(u8, key, deleted.key);
        try testing.expectEqual(null, deleted.value);
    }
}

test "documents: headers that cannot be chunk 0 are refused" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const chunks = try chunks_encode(arena, 7, "key", "value");
    const header = std.mem.bytesToValue(Header, chunks[0][0..@sizeOf(Header)]);
    const cases = [_]Header{
        h: {
            var h = header;
            h.reserved_a = 1;
            break :h h;
        },
        h: {
            var h = header;
            h.flags.padding = 1;
            break :h h;
        },
        h: {
            var h = header;
            h.payload_size = h.key_size - 1;
            break :h h;
        },
        h: {
            var h = header;
            h.key_size = key_size_max + 1;
            h.payload_size = key_size_max + 1;
            break :h h;
        },
        h: {
            // A tombstone has no value.
            var h = header;
            h.flags.deleted = true;
            break :h h;
        },
    };
    for (cases) |case| {
        var chunk0 = chunks[0];
        @memcpy(chunk0[0..@sizeOf(Header)], std.mem.asBytes(&case));
        try testing.expectError(error.Corrupt, chunk0_count(&chunk0));
    }
}

test "documents: chunk counts at the boundaries" {
    try testing.expectEqual(@as(u32, 1), chunk_count(10, chunk0_payload - 10));
    try testing.expectEqual(@as(u32, 2), chunk_count(10, chunk0_payload - 9));
    try testing.expectEqual(@as(u32, 2), chunk_count(0, chunk0_payload + value_size));
    try testing.expectEqual(@as(u32, 3), chunk_count(0, chunk0_payload + value_size + 1));
}

test "documents: row ids are stable and separate keys, chunks and namespaces" {
    // A fixed vector (computed with Python's hashlib): changing the derivation would orphan
    // every stored document.
    try testing.expectEqual(@as(u64, 14508685050127223560), row_id(0, "table.5"));
    try testing.expect(row_id(0, "table.5") != row_id(1, "table.5"));
    try testing.expect(row_id(0, "ab") != row_id(0, "a"));
    try testing.expectEqual(row_id(0, "k"), chunk_id(0, "k", 0));
    try testing.expectEqual(tail_id(row_id(0, "k"), 3), chunk_id(0, "k", 3));
    try testing.expect(chunk_id(0, "k", 1) != chunk_id(0, "k", 2));
}

/// A client over rows held in memory, with their history, for `TransactionType`. A test can have
/// writes land just before a given lookup, as a concurrent commit would.
const TestClient = struct {
    const Write = struct { id: u64, op: u64, value: [value_size]u8 };

    /// Every write, in op order.
    writes: std.ArrayListUnmanaged(Write) = .{},
    /// Applied just before lookup number `lookup` (counting from zero) executes.
    interleaved: ?struct { lookup: u32, writes: []const Write } = null,
    lookups: u32 = 0,
    history_reads: u32 = 0,

    const table = 9;

    fn document_writes(
        arena: std.mem.Allocator,
        namespace: u64,
        key: []const u8,
        value: []const u8,
        op: u64,
    ) ![]const Write {
        const chunks = try chunks_encode(arena, namespace, key, value);
        const writes = try arena.alloc(Write, chunks.len);
        for (writes, chunks, 0..) |*write, *chunk, index| {
            write.* = .{ .id = chunk_id(namespace, key, @intCast(index)), .op = op, .value = chunk.* };
        }
        return writes;
    }

    fn latest(client: *const TestClient, id: u64, op_max: u64) ?Write {
        var found: ?Write = null;
        for (client.writes.items) |write| {
            if (write.id == id and write.op <= op_max) found = write;
        }
        return found;
    }

    pub fn lookup_rows(client: *TestClient, keys: []const RowKey, results: []RowValue) Error!void {
        if (client.interleaved) |interleaved| {
            if (interleaved.lookup == client.lookups) {
                client.writes.appendSliceAssumeCapacity(interleaved.writes);
                client.interleaved = null;
            }
        }
        client.lookups += 1;
        for (keys, results) |*key, *result| {
            assert(key.table == table);
            const write = client.latest(key.id, std.math.maxInt(u64));
            result.* = .{
                .id = key.id,
                .table = table,
                .flags = .{ .exists = write != null },
                .op = if (write) |w| w.op else 0,
                .op_read = 100,
                .value = if (write) |w| w.value else @splat(0),
            };
        }
    }

    pub fn row_as_of(client: *TestClient, table_: u32, id: u64, op: u64) Error!?nerva.Change {
        assert(table_ == table);
        client.history_reads += 1;
        const write = client.latest(id, op) orelse return null;
        return .{
            .id = id,
            .table = table,
            .kind = .put,
            .flags = .{},
            .op = write.op,
            .timestamp = write.op,
            .value = write.value,
        };
    }
};

test "documents: a document rewritten while it is read is read whole at chunk 0's version" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const namespace = 3;
    const key = "table.5";
    const old: [150]u8 = @splat('o');
    const new: [150]u8 = @splat('n');
    var client: TestClient = .{};
    try client.writes.ensureTotalCapacity(arena, 16);
    const old_writes = try TestClient.document_writes(arena, namespace, key, &old, 5);
    assert(old_writes.len == 3);
    client.writes.appendSliceAssumeCapacity(old_writes);
    // A rewrite commits between the lookup of chunk 0 and the lookup of the tails (issue #7).
    client.interleaved = .{
        .lookup = 1,
        .writes = try TestClient.document_writes(arena, namespace, key, &new, 9),
    };

    var transaction: TransactionType(TestClient) = .{
        .client = &client,
        .table = TestClient.table,
        .namespace = namespace,
    };
    transaction.begin(arena);
    try testing.expectEqualSlices(u8, &old, (try transaction.get(key)).?);
    try testing.expectEqual(2, client.lookups);
    try testing.expectEqual(2, client.history_reads);
    // Every chunk is recorded at the version read, so a commit after this read conflicts.
    for (0..3) |chunk| {
        const id = chunk_id(namespace, key, @intCast(chunk));
        try testing.expectEqual(5, transaction.reads.get(id).?);
    }
}

test "documents: a document read without a race needs no history" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const value: [150]u8 = @splat('v');
    var client: TestClient = .{};
    try client.writes.ensureTotalCapacity(arena, 16);
    client.writes.appendSliceAssumeCapacity(
        try TestClient.document_writes(arena, 3, "key", &value, 5),
    );
    var transaction: TransactionType(TestClient) = .{
        .client = &client,
        .table = TestClient.table,
        .namespace = 3,
    };
    transaction.begin(arena);
    try testing.expectEqualSlices(u8, &value, (try transaction.get("key")).?);
    try testing.expectEqual(2, client.lookups);
    try testing.expectEqual(0, client.history_reads);
}

test "documents: a tail older than its chunk 0 is corrupt" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const value: [150]u8 = @splat('v');
    var client: TestClient = .{};
    try client.writes.ensureTotalCapacity(arena, 16);
    const writes = try TestClient.document_writes(arena, 3, "key", &value, 5);
    client.writes.appendSliceAssumeCapacity(writes);
    // Chunk 0 alone rewritten: no write of a document does that.
    var chunk0 = writes[0];
    chunk0.op = 7;
    client.writes.appendAssumeCapacity(chunk0);

    var transaction: TransactionType(TestClient) = .{
        .client = &client,
        .table = TestClient.table,
        .namespace = 3,
    };
    transaction.begin(arena);
    try testing.expectError(error.Corrupt, transaction.get("key"));
}
