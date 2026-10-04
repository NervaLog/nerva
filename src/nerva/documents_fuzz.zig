//! Fuzzes how documents are chunked over rows (`documents.zig`; docs/DECISIONS.md N41, N46).
//!
//! - Encoding then decoding returns the namespace, key and value (or tombstone), in exactly
//!   `chunk_count` rows with distinct ids; sizes are weighted to chunk boundaries.
//! - Random and damaged chunks never crash `chunk0_count` or `chunks_decode`: they decode within
//!   the limits or are `Corrupt`, and the wrong number of chunks is always `Corrupt`.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.fuzz_nerva_documents);

const stdx = @import("stdx");
const fuzz = @import("../testing/fuzz.zig");
const nerva = @import("../nerva.zig");
const documents = @import("documents.zig");

const value_size = nerva.value_size;
const Chunk = [value_size]u8;

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    var prng = stdx.PRNG.from_seed(args.seed);
    const events_max = args.events_max orelse 20_000;

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();

    const key_buffer = try gpa.alloc(u8, documents.key_size_max);
    defer gpa.free(key_buffer);
    const value_buffer = try gpa.alloc(u8, documents.value_size_max);
    defer gpa.free(value_buffer);
    const chunks_buffer = try gpa.alloc(Chunk, 2 + documents.chunk_count(
        documents.key_size_max,
        documents.value_size_max,
    ));
    defer gpa.free(chunks_buffer);

    var counts: struct { round_trips: u64 = 0, decoded: u64 = 0, corrupt: u64 = 0 } = .{};
    for (0..events_max) |_| {
        _ = arena_instance.reset(.retain_capacity);
        const arena = arena_instance.allocator();

        const namespace = prng.int(u64);
        const key = key_buffer[0..size_random(&prng, documents.key_size_max)];
        prng.fill(key);
        const value: ?[]u8 = if (prng.chance(stdx.PRNG.ratio(1, 8)))
            null
        else
            value_buffer[0..size_random(&prng, documents.value_size_max)];
        if (value) |bytes| prng.fill(bytes);

        const encoded = try documents.chunks_encode(arena, namespace, key, value);
        round_trip_check(arena, namespace, key, value, encoded) catch |err|
            std.debug.panic("round trip: {} (key {}, value {?})", .{
                err,
                key.len,
                if (value) |bytes| bytes.len else null,
            });
        counts.round_trips += 1;

        // Damage it: random chunks, bytes changed, or a chunk missing or extra.
        const chunks = chunks_buffer[0..@min(chunks_buffer.len, encoded.len)];
        @memcpy(chunks, encoded[0..chunks.len]);
        var count = chunks.len;
        switch (prng.int_inclusive(u8, 3)) {
            0 => {
                count = prng.range_inclusive(usize, 1, 4);
                for (chunks_buffer[0..count]) |*chunk| prng.fill(chunk);
            },
            1 => for (0..prng.range_inclusive(u8, 1, 4)) |_| {
                const chunk = &chunks_buffer[prng.index(chunks_buffer[0..count])];
                chunk[prng.index(chunk)] ^= prng.range_inclusive(u8, 1, 255);
            },
            2 => if (count > 1) {
                count -= 1;
            } else {
                count += 1;
                prng.fill(&chunks_buffer[1]);
            },
            3 => {
                count += 1;
                prng.fill(&chunks_buffer[count - 1]);
            },
            else => unreachable,
        }
        if (decode_check(arena, chunks_buffer[0..count])) {
            counts.decoded += 1;
        } else {
            counts.corrupt += 1;
        }
    }
    log.info("{} round trips; damaged chunks: {} decoded, {} corrupt", .{
        counts.round_trips,
        counts.decoded,
        counts.corrupt,
    });
    if (events_max >= 100) assert(counts.decoded > 0 and counts.corrupt > 0);
}

/// A size up to `size_max`, usually at or next to a chunk boundary (the key and value share the
/// rows: chunk 0 holds `value_size - @sizeOf(Header)` payload bytes, every tail `value_size`).
fn size_random(prng: *stdx.PRNG, size_max: usize) usize {
    const chunk0_payload = value_size - @sizeOf(documents.Header);
    const size: usize = switch (prng.int_inclusive(u8, 3)) {
        0 => prng.int_inclusive(usize, size_max),
        1 => prng.int_inclusive(usize, 2 * value_size),
        2 => chunk0_payload + value_size * prng.int_inclusive(usize, size_max / value_size),
        3 => size_max,
        else => unreachable,
    };
    const near = @as(i64, @intCast(size)) + @as(i64, prng.int_inclusive(u8, 2)) - 1;
    return @intCast(std.math.clamp(near, 0, @as(i64, @intCast(size_max))));
}

fn round_trip_check(
    arena: std.mem.Allocator,
    namespace: u64,
    key: []const u8,
    value: ?[]const u8,
    encoded: []const Chunk,
) !void {
    const value_bytes = value orelse "";
    if (encoded.len != documents.chunk_count(key.len, value_bytes.len)) return error.ChunkCount;
    if (try documents.chunk0_count(&encoded[0]) != encoded.len) return error.Chunk0Count;

    // Distinct row ids, chunk 0's derived from the key.
    const ids = try arena.alloc(u64, encoded.len);
    for (ids, 0..) |*id, chunk| id.* = documents.chunk_id(namespace, key, @intCast(chunk));
    if (ids[0] != documents.row_id(namespace, key)) return error.RowId;
    std.mem.sort(u64, ids, {}, std.sort.asc(u64));
    for (ids[0 .. ids.len - 1], ids[1..]) |a, b| if (a == b) return error.IdRepeated;

    const decoded = try documents.chunks_decode(arena, encoded);
    if (decoded.namespace != namespace) return error.Namespace;
    if (!std.mem.eql(u8, decoded.key, key)) return error.Key;
    if ((decoded.value == null) != (value == null)) return error.Tombstone;
    if (value) |bytes| if (!std.mem.eql(u8, decoded.value.?, bytes)) return error.Value;
}

/// Decodes arbitrary chunks: never crashes, and decodes only within the limits and only from the
/// number of chunks the header names. Returns whether it decoded.
fn decode_check(arena: std.mem.Allocator, chunks: []const Chunk) bool {
    assert(chunks.len > 0);
    const count = documents.chunk0_count(&chunks[0]) catch |err| {
        assert(err == error.Corrupt);
        // `chunks_decode` checks the same header.
        assert(documents.chunks_decode(arena, chunks) == error.Corrupt);
        return false;
    };
    const decoded = documents.chunks_decode(arena, chunks) catch |err| {
        assert(err == error.Corrupt);
        assert(count != chunks.len);
        return false;
    };
    assert(count == chunks.len);
    assert(decoded.key.len <= documents.key_size_max);
    if (decoded.value) |value| assert(value.len <= documents.value_size_max);
    return true;
}
