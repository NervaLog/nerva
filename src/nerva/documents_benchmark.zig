//! Documents: chunking a value into rows (with each chunk's id, one SHA-256 each) and
//! reassembling it, as `nerva api` does for every document write and read.

const std = @import("std");
const stdx = @import("stdx");
const assert = std.debug.assert;

const nerva = @import("../nerva.zig");
const documents = @import("documents.zig");
const Bench = stdx.Bench;

test "benchmark: documents" {
    var bench: Bench = .init();
    defer bench.deinit();

    const value_size = bench.parameter("value_size", 4 * stdx.KiB, documents.value_size_max);
    const document_count = bench.parameter("document_count", 2, 200);

    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var prng = stdx.PRNG.from_seed(bench.seed);
    // Outside the arena, which is reset for every sample.
    const value = try std.testing.allocator.alloc(u8, value_size);
    defer std.testing.allocator.free(value);
    prng.fill(value);
    const key = "orders/2026/10/05/receipt-0001";

    var encode_samples: [16]stdx.Duration = undefined;
    var decode_samples: [16]stdx.Duration = undefined;
    var checksum: u64 = 0;
    for (&encode_samples, &decode_samples) |*encode_sample, *decode_sample| {
        _ = arena_instance.reset(.retain_capacity);

        const encoded: [][]const [nerva.value_size]u8 =
            try arena.alloc([]const [nerva.value_size]u8, document_count);
        bench.start();
        for (encoded, 0..) |*chunks, index| {
            chunks.* = try documents.chunks_encode(arena, index, key, value);
            for (0..chunks.len) |chunk| {
                checksum +%= documents.chunk_id(index, key, @intCast(chunk));
            }
        }
        encode_sample.* = bench.stop();

        bench.start();
        for (encoded) |chunks| {
            const decoded = try documents.chunks_decode(arena, chunks);
            checksum +%= decoded.value.?.len;
        }
        decode_sample.* = bench.stop();
    }

    const encode = bench.estimate(&encode_samples);
    const decode = bench.estimate(&decode_samples);
    bench.report("checksum {}", .{checksum});
    bench.report("encode {} per document, decode {} per document", .{
        stdx.Duration{ .ns = encode.ns / document_count },
        stdx.Duration{ .ns = decode.ns / document_count },
    });
    bench.metric("documents.encode_ns_per_document", encode.ns / document_count, "ns");
    bench.metric("documents.decode_ns_per_document", decode.ns / document_count, "ns");
}
