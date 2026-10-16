//! Declared views computed on read (N35): the latest answer aggregates every current row, then
//! sorts the groups and hashes the JSON; an answer as of an op first replays the changes.

const std = @import("std");
const stdx = @import("stdx");
const assert = std.debug.assert;

const nerva = @import("../../nerva.zig");
const catalog = @import("../catalog.zig");
const documents = @import("../documents.zig");
const DeclaredViews = @import("declared.zig").DeclaredViews;
const Change = nerva.Change;
const Bench = stdx.Bench;

const table = 5;

test "benchmark: declared views" {
    var bench: Bench = .init();
    defer bench.deinit();

    const row_count = bench.parameter("row_count", 1_000, 1_000_000);
    const group_count = bench.parameter("group_count", 16, 4_096);

    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var views = DeclaredViews.init(std.testing.allocator);
    defer views.deinit();

    // The layout packs `group` (u32) at offset 0 and `price` (u64) at offset 8 (N34).
    const layout_json =
        \\{"name":"orders","fields":[{"name":"group","type":"u32"},{"name":"price","type":"u64"}]}
    ;
    const view_json =
        \\{"table":5,"group_by":["group"],"aggregates":[{"fn":"count"},{"fn":"sum","field":"price"}]}
    ;
    const layout = try catalog.layout_parse(arena, layout_json, 5);
    var op: u64 = 1;
    var timestamp: u64 = 1;
    for ([_][2][]const u8{
        .{ "table.5", try catalog.layout_render(arena, &layout) },
        .{ "view.by_group", view_json },
    }) |document| {
        const chunks = try documents.chunks_encode(arena, 0, document[0], document[1]);
        // Chunk 0 last, as the API writes documents.
        const changes = try arena.alloc(Change, chunks.len);
        for (changes, 0..) |*change, position| {
            const index = chunks.len - 1 - position;
            const chunk = &chunks[index];
            change.* = .{
                .id = documents.chunk_id(0, document[0], @intCast(index)),
                .table = catalog.table_catalog,
                .kind = .put,
                .flags = .{},
                .op = op,
                .timestamp = timestamp,
                .value = chunk.*,
            };
            timestamp += 1;
        }
        try views.apply(op, changes);
        op += 1;
    }

    // Rows arrive in ops of up to 1024 changes, as the follower pages the feed.
    var prng = stdx.PRNG.from_seed(bench.seed);
    var batch: [1024]Change = undefined;
    var row: u64 = 0;
    const op_first = op;
    while (row < row_count) {
        const batch_size: usize = @intCast(@min(batch.len, row_count - row));
        for (batch[0..batch_size]) |*change| {
            var value: [nerva.value_size]u8 = @splat(0);
            std.mem.writeInt(u32, value[0..4], @intCast(prng.int_inclusive(u64, group_count - 1)), .little);
            std.mem.writeInt(u64, value[8..16], prng.int_inclusive(u64, 10_000), .little);
            change.* = .{
                .id = row + 1,
                .table = table,
                .kind = .put,
                .flags = .{},
                .op = op,
                .timestamp = timestamp,
                .value = value,
            };
            row += 1;
            timestamp += 1;
        }
        try views.apply(op, batch[0..batch_size]);
        op += 1;
    }
    const op_middle = op_first + (op - op_first) / 2;

    var latest_samples: [8]stdx.Duration = undefined;
    var as_of_samples: [8]stdx.Duration = undefined;
    var hash_checksum: u8 = 0;
    for (&latest_samples, &as_of_samples) |*latest_sample, *as_of_sample| {
        var compute_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer compute_arena.deinit();

        bench.start();
        const latest = try views.compute(compute_arena.allocator(), "by_group", null);
        latest_sample.* = bench.stop();

        bench.start();
        const middle = try views.compute(compute_arena.allocator(), "by_group", op_middle);
        as_of_sample.* = bench.stop();

        hash_checksum ^= latest.hash[0] ^ middle.hash[0];
    }

    const latest = bench.estimate(&latest_samples);
    const as_of = bench.estimate(&as_of_samples);
    bench.report("hash checksum {}", .{hash_checksum});
    bench.report("latest {}, as of the middle op {}", .{ latest, as_of });
    bench.metric("declared_views.latest_ns", latest.ns, "ns");
    bench.metric("declared_views.as_of_middle_ns", as_of.ns, "ns");
}
