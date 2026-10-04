//! A Nerva-backed key-value store for the ledger routes: one transaction per route.
//!
//! `begin` starts a transaction; `get` reads rows through the client and records each row's
//! version; `put`, `remove` and `reset` are buffered; `commit` sends every read (asserting its
//! version) and every write as one Nerva transaction. A `conflict` means another writer got in
//! first: the caller re-runs the route (docs/DECISIONS.md N11).
//!
//! Storage (N12–N15): each key's value is chunked over 80-byte rows of table `table_rows`, with
//! ids derived from (ledger, generation, key, chunk). Chunk 0 holds a header, then the key, then
//! the value; chunks 1.. continue the stream. The ledger's root row (`table_roots`, id = ledger)
//! holds the generation.
//!
//! `get_as_of` reads a key as it was at any op, from the rows' histories (G6).

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");

const nerva = @import("../../nerva.zig");
const Client = @import("../client.zig").Client;

const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
const value_size = nerva.value_size;

pub const table_rows: u32 = 1000;
pub const table_roots: u32 = 1001;
/// The runtime's `Store` ability (agent state: continuations, code, receipts): chunked like
/// `table_rows`, but outside the ledger's generations, so `/v1/admin/init` keeps it (N29).
pub const table_store: u32 = 1002;

/// The longest value a key may hold.
pub const value_size_max = 64 * 1024;
pub const key_size_max = 1024;

/// Chunk 0's header. Ledger and generation let a view attribute the row (N25).
pub const Header = extern struct {
    ledger: u64,
    generation: u64,
    key_size: u16,
    reserved: u16 = 0,
    /// Key plus value.
    payload_size: u32,

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

/// The row id of chunk `chunk` of `key`: chunk 0 from the key (N13), later chunks from chunk 0's
/// id, so that a reader holding only chunk 0 can find the rest (N25).
pub fn chunk_id(ledger: u64, generation: u64, key: []const u8, chunk: u32) u64 {
    const id0 = row_id(ledger, generation, key, 0);
    return if (chunk == 0) id0 else tail_id(id0, chunk);
}

/// The id of tail chunk `chunk` (≥ 1) of the value whose chunk 0 has id `id0`.
pub fn tail_id(id0: u64, chunk: u32) u64 {
    assert(chunk > 0);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva.ledgerd.tail.v1");
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, id0)));
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, chunk)));
    const digest = hash.finalResult();
    return std.mem.readInt(u64, digest[0..8], .little);
}

/// The id of chunk 0 of `key` (N13): the first 8 bytes of SHA-256, little-endian.
pub fn row_id(ledger: u64, generation: u64, key: []const u8, chunk: u32) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva.ledgerd.v1");
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, ledger)));
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, generation)));
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(key.len))));
    hash.update(key);
    hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, chunk)));
    const digest = hash.finalResult();
    return std.mem.readInt(u64, digest[0..8], .little);
}

/// Splits `key` and `value` into row values: chunk 0 first.
pub fn chunks_encode(
    arena: std.mem.Allocator,
    ledger: u64,
    generation: u64,
    key: []const u8,
    value: []const u8,
) error{OutOfMemory}![]const [value_size]u8 {
    assert(key.len <= key_size_max);
    assert(value.len <= value_size_max);
    const count = chunk_count(key.len, value.len);
    const chunks = try arena.alloc([value_size]u8, count);
    for (chunks) |*chunk| chunk.* = @splat(0);

    const header: Header = .{
        .ledger = ledger,
        .generation = generation,
        .key_size = @intCast(key.len),
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
    ledger: u64,
    generation: u64,
    key: []const u8,
    value: []const u8,
};

/// Reassembles chunks written by `chunks_encode`. `chunks` must hold `chunk_count` rows.
pub fn chunks_decode(
    arena: std.mem.Allocator,
    chunks: []const [value_size]u8,
) error{ OutOfMemory, Corrupt }!Decoded {
    const header = std.mem.bytesToValue(Header, chunks[0][0..@sizeOf(Header)]);
    if (header.key_size > key_size_max) return error.Corrupt;
    if (header.payload_size < header.key_size) return error.Corrupt;
    if (header.payload_size - header.key_size > value_size_max) return error.Corrupt;
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
        .ledger = header.ledger,
        .generation = header.generation,
        .key = payload[0..header.key_size],
        .value = payload[header.key_size..],
    };
}

/// Chunk 0's header: how many rows the value occupies.
pub fn chunk0_count(chunk0: *const [value_size]u8) error{Corrupt}!u32 {
    const header = std.mem.bytesToValue(Header, chunk0[0..@sizeOf(Header)]);
    if (header.payload_size < header.key_size) return error.Corrupt;
    if (header.payload_size - header.key_size > value_size_max) return error.Corrupt;
    return chunk_count(header.key_size, header.payload_size - header.key_size);
}

pub const Error = Client.Error || error{
    OutOfMemory,
    /// Two keys hash to one row id, or a row does not decode: answered 500.
    Corrupt,
    /// A key or value over the limits, or a transaction over one request: answered 500.
    TooLarge,
};

pub const Store = struct {
    client: *Client,
    ledger: u64,
    /// `table_rows` (the ledger, with generations), or any other table (`table_store`, the
    /// catalog), whose generation is always 0.
    table: u32 = table_rows,

    arena: std.mem.Allocator = undefined,
    generation: u64 = undefined,
    /// Row key → the version this transaction saw.
    reads: std.AutoArrayHashMapUnmanaged(RowId, u64) = .{},
    /// Row key → the write to commit (a later write to the same row replaces an earlier one).
    writes: std.AutoArrayHashMapUnmanaged(RowId, Entry) = .{},
    /// Key → value as this transaction sees it, including its own writes.
    cache: std.StringHashMapUnmanaged(?[]const u8) = .{},

    const RowId = struct { table: u32, id: u64 };

    pub const Outcome = enum { committed, conflict };

    /// Starts a transaction whose memory comes from `arena` (reset by the caller per attempt).
    pub fn begin(store: *Store, arena: std.mem.Allocator) Error!void {
        store.arena = arena;
        store.reads = .{};
        store.writes = .{};
        store.cache = .{};

        assert(store.table != table_roots);
        if (store.table != table_rows) {
            store.generation = 0;
            return;
        }
        const root = try store.lookup(table_roots, store.ledger);
        store.generation = if (root.flags.exists)
            std.mem.readInt(u64, root.value[0..8], .little)
        else
            0;
    }

    pub fn get(store: *Store, key: []const u8) Error!?[]const u8 {
        if (store.cache.get(key)) |cached| return cached;
        if (key.len > key_size_max) return error.TooLarge;

        const id0 = row_id(store.ledger, store.generation, key, 0);
        const chunk0 = try store.lookup(store.table, id0);
        const value: ?[]const u8 = if (!chunk0.flags.exists) null else value: {
            const count = try chunk0_count(&chunk0.value);
            const chunks = try store.arena.alloc([value_size]u8, count);
            chunks[0] = chunk0.value;
            if (count > 1) {
                const keys = try store.arena.alloc(RowKey, count - 1);
                for (keys, 1..) |*row_key, chunk| {
                    row_key.* = .{
                        .id = chunk_id(store.ledger, store.generation, key, @intCast(chunk)),
                        .table = store.table,
                    };
                }
                const rows = try store.arena.alloc(RowValue, keys.len);
                try store.client.lookup_rows(keys, rows);
                for (rows, chunks[1..]) |*row, *chunk| {
                    if (!row.flags.exists) return error.Corrupt;
                    try store.read_record(row);
                    chunk.* = row.value;
                }
            }
            const decoded = try chunks_decode(store.arena, chunks);
            // A hash collision, or a row of another ledger or generation.
            if (!std.mem.eql(u8, decoded.key, key)) return error.Corrupt;
            if (decoded.ledger != store.ledger) return error.Corrupt;
            if (decoded.generation != store.generation) return error.Corrupt;
            break :value decoded.value;
        };
        try store.cache.put(store.arena, try store.arena.dupe(u8, key), value);
        return value;
    }

    pub fn put(store: *Store, key: []const u8, value: []const u8) Error!void {
        if (key.len > key_size_max or value.len > value_size_max) return error.TooLarge;
        const chunks = try chunks_encode(store.arena, store.ledger, store.generation, key, value);
        for (chunks, 0..) |*chunk, index| {
            try store.write(.{
                .id = chunk_id(store.ledger, store.generation, key, @intCast(index)),
                .table = store.table,
                .kind = .put,
                .op_seen = 0,
                .value = chunk.*,
            });
        }
        try store.cache.put(
            store.arena,
            try store.arena.dupe(u8, key),
            try store.arena.dupe(u8, value),
        );
    }

    /// Deletes chunk 0; the tail chunks become unreachable.
    pub fn remove(store: *Store, key: []const u8) Error!void {
        try store.write(.{
            .id = row_id(store.ledger, store.generation, key, 0),
            .table = store.table,
            .kind = .delete,
            .op_seen = 0,
            .value = @splat(0),
        });
        try store.cache.put(store.arena, try store.arena.dupe(u8, key), null);
    }

    /// A random id for a journal key: unique across gateways without coordination (N19).
    pub fn unique(store: *Store) u128 {
        _ = store;
        return stdx.crypto_u128();
    }

    /// Starts a new generation: every key reads as absent (N15).
    pub fn reset(store: *Store) Error!void {
        assert(store.table == table_rows);
        store.generation += 1;
        var root: [value_size]u8 = @splat(0);
        std.mem.writeInt(u64, root[0..8], store.generation, .little);
        try store.write(.{
            .id = store.ledger,
            .table = table_roots,
            .kind = .put,
            .op_seen = 0,
            .value = root,
        });
        store.cache.clearRetainingCapacity();
        // Writes buffered for the previous generation are still committed: they are
        // unreachable once the generation moves, exactly as `ledgerd.py` discards its dict.
    }

    /// Commits every read and write as one transaction.
    pub fn commit(store: *Store) Error!Outcome {
        const count = store.reads.count() + store.writes.count();
        if (count == 0) return .committed;
        if (count > nerva.Operation.commit.event_max(store.client.vsr_client.batch_size_limit.?)) {
            return error.TooLarge;
        }

        const entries = try store.arena.alloc(Entry, count);
        var index: usize = 0;
        for (store.reads.keys(), store.reads.values()) |row, op_seen| {
            entries[index] = .{
                .id = row.id,
                .table = row.table,
                .kind = .read,
                .op_seen = op_seen,
                .value = @splat(0),
            };
            index += 1;
        }
        for (store.writes.values()) |entry| {
            entries[index] = entry;
            index += 1;
        }
        assert(index == count);

        const results = try store.arena.alloc(EntryResult, count);
        try store.client.commit(entries, results);
        for (results) |result| {
            switch (result.status) {
                .ok, .aborted => {},
                .conflict => return .conflict,
                else => std.debug.panic("ledgerd: commit rejected an entry: {s}", .{
                    @tagName(result.status),
                }),
            }
        }
        assert(results[0].status == .ok);
        return .committed;
    }

    fn lookup(store: *Store, table: u32, id: u64) Error!RowValue {
        var row: [1]RowValue = undefined;
        try store.client.lookup_rows(&.{.{ .id = id, .table = table }}, &row);
        try store.read_record(&row[0]);
        return row[0];
    }

    /// Records the version seen, unless this transaction already wrote the row.
    fn read_record(store: *Store, row: *const RowValue) Error!void {
        const row_key: RowId = .{ .table = row.table, .id = row.id };
        if (store.writes.contains(row_key)) return;
        const entry = try store.reads.getOrPut(store.arena, row_key);
        if (entry.found_existing) {
            // Two lookups in one transaction saw different versions: another writer committed
            // in between. Keep the first; commit will report the conflict.
            return;
        }
        entry.value_ptr.* = row.op;
    }

    fn write(store: *Store, entry: Entry) Error!void {
        try store.writes.put(store.arena, .{ .table = entry.table, .id = entry.id }, entry);
    }
};

/// A ledger key's value as it was at `op` (G6), or null if the key did not exist then. Reads
/// each row as of `op`: the ledger's generation, then the key's chunks in that generation.
pub fn get_as_of(
    client: *Client,
    arena: std.mem.Allocator,
    ledger: u64,
    key: []const u8,
    op: u64,
) Error!?[]const u8 {
    assert(op != 0);
    if (key.len > key_size_max) return error.TooLarge;

    const generation: u64 = if (try client.row_as_of(table_roots, ledger, op)) |root|
        std.mem.readInt(u64, root.value[0..8], .little)
    else
        0;
    const chunk0 = try client.row_as_of(table_rows, chunk_id(ledger, generation, key, 0), op) orelse
        return null;
    const count = try chunk0_count(&chunk0.value);
    const chunks = try arena.alloc([value_size]u8, count);
    chunks[0] = chunk0.value;
    for (chunks[1..], 1..) |*chunk, index| {
        const tail = try client.row_as_of(
            table_rows,
            chunk_id(ledger, generation, key, @intCast(index)),
            op,
        ) orelse return error.Corrupt;
        // A value's chunks are written together, in one op.
        if (tail.op != chunk0.op) return error.Corrupt;
        chunk.* = tail.value;
    }
    const decoded = try chunks_decode(arena, chunks);
    if (!std.mem.eql(u8, decoded.key, key)) return error.Corrupt;
    if (decoded.ledger != ledger or decoded.generation != generation) return error.Corrupt;
    return decoded.value;
}

const testing = std.testing;

test "ledgerd store: chunks round-trip" {
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

        const ledger = random.int(u64);
        const generation = random.int(u64);
        const chunks = try chunks_encode(arena, ledger, generation, key, value);
        try testing.expectEqual(chunk_count(key.len, value.len), chunks.len);
        try testing.expectEqual(@as(u32, @intCast(chunks.len)), try chunk0_count(&chunks[0]));
        const decoded = try chunks_decode(arena, chunks);
        try testing.expectEqual(ledger, decoded.ledger);
        try testing.expectEqual(generation, decoded.generation);
        try testing.expectEqualSlices(u8, key, decoded.key);
        try testing.expectEqualSlices(u8, value, decoded.value);
    }
}

test "ledgerd store: chunk counts at the boundaries" {
    try testing.expectEqual(@as(u32, 1), chunk_count(10, chunk0_payload - 10));
    try testing.expectEqual(@as(u32, 2), chunk_count(10, chunk0_payload - 9));
    try testing.expectEqual(@as(u32, 2), chunk_count(0, chunk0_payload + value_size));
    try testing.expectEqual(@as(u32, 3), chunk_count(0, chunk0_payload + value_size + 1));
}

test "ledgerd store: row ids are stable and separate keys, chunks and generations" {
    // A fixed vector (computed with Python's hashlib): changing the derivation would orphan
    // every stored row.
    try testing.expectEqual(@as(u64, 8139021218198995970), row_id(7, 0, "available", 0));
    try testing.expect(row_id(7, 0, "available", 0) != row_id(7, 0, "available", 1));
    try testing.expect(row_id(7, 0, "available", 0) != row_id(7, 1, "available", 0));
    try testing.expect(row_id(7, 0, "available", 0) != row_id(8, 0, "available", 0));
    try testing.expect(row_id(7, 0, "ab", 0) != row_id(7, 0, "a", 0));
    try testing.expectEqual(row_id(7, 0, "available", 0), chunk_id(7, 0, "available", 0));
    try testing.expectEqual(tail_id(row_id(7, 0, "k", 0), 3), chunk_id(7, 0, "k", 3));
    try testing.expect(chunk_id(7, 0, "k", 1) != chunk_id(7, 0, "k", 2));
}
