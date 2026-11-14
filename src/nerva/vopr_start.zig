//! The VOPR's imported start (R5, P159): one deterministic export, built from the seed in
//! memory, that the simulator's testing cluster imports into every replica's simulated storage
//! after its format, so that a seed starts at an imported checkpoint C, as an imported cluster
//! does, with the replicas' journals empty and their state in the grid.
//!
//! The export holds no changes, views or ledgers: the workload's model starts empty and the
//! state it reads is the same. What the import writes is the importer's own, every op up to C's
//! trigger (versions, checkpoints), which is state the cluster must keep, repair and sync.
//!
//! Deterministic: the seed and nothing else (no clock, no files).

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");
const vsr = @import("../vsr.zig");
const constants = @import("../constants.zig");
const export_file = @import("export_file.zig");
const import_ = @import("import.zig");
const Storage = @import("../testing/storage.zig").Storage;
const Tracer = vsr.trace.Tracer;

/// The export is a header, a summary and an end record.
pub const bytes_max = 256;

const salt_drawn: u64 = 0x7c41_0be9_d3a5_62f8;

/// Kept apart from the VOPR's own draws: a seed's other draws do not move (P143b).
const salt: u64 = 0x1d6a_93c7_5b24_e8f1;

/// Whether the seed starts imported: half of them.
pub fn drawn(seed: u64) bool {
    var prng = stdx.PRNG.from_seed(seed ^ salt_drawn);
    return prng.boolean();
}

/// The checkpoints an export may reach: C is the first, second or third.
const checkpoints_max = 3;

pub const Built = struct {
    bytes: []const u8,
    /// The export's identity: every data file imported from it records it (P90).
    origin: [32]u8,
};

/// The seed's export, written into `buffer`.
pub fn build(buffer: *[bytes_max]u8, seed: u64) Built {
    var prng = stdx.PRNG.from_seed(seed ^ salt);
    const version: u32 = if (prng.boolean()) 1 else 2;
    var as_of_max: u64 = 0;
    for (0..checkpoints_max) |_| as_of_max = vsr.Checkpoint.checkpoint_after(as_of_max);
    // An export of op zero is refused.
    const as_of = 1 + prng.int_inclusive(u64, as_of_max - 1);

    var stream = std.io.fixedBufferStream(buffer);
    var writer = export_file.WriterType(@TypeOf(stream).Writer)
        .init(stream.writer(), version, 0) catch unreachable;
    writer.write(&.{ .summary = .{
        .as_of = as_of,
        .change_count = 0,
        .view_count = 0,
        .ledger_count = 0,
        .table_count = 0,
    } }) catch unreachable;
    writer.finish() catch unreachable;
    return .{ .bytes = buffer[0..stream.pos], .origin = writer.digest };
}

/// The export's identity for `seed` (`Options.origin` of the cluster that imports it).
pub fn origin(seed: u64) [32]u8 {
    var buffer: [bytes_max]u8 = undefined;
    return build(&buffer, seed).origin;
}

/// `Cluster.Options.import`: restores the seed's export into `storage`, newly formatted.
pub fn import_storage(
    allocator: std.mem.Allocator,
    storage: *Storage,
    seed: u64,
    cluster_id: u128,
    release: vsr.Release,
    storage_size_limit: u64,
) anyerror!void {
    var buffer: [bytes_max]u8 = undefined;
    const built = build(&buffer, seed);

    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer arena_instance.deinit();
    const plan = try import_.plan_bytes(arena_instance.allocator(), built.bytes);
    assert(std.mem.eql(u8, &plan.origin, &built.origin));

    var time: stdx.TimeSim = .{
        .resolution = 10 * std.time.ns_per_ms,
        .offset_type = .linear,
        .offset_coefficient_A = 0,
        .offset_coefficient_B = 0,
    };
    var tracer = try Tracer.init(allocator, time.interface(), .unknown, .{});
    defer tracer.deinit(allocator);

    try import_.ImporterType(Storage).run(allocator, time.interface(), &tracer, storage, .{
        .cluster = cluster_id,
        .release = release,
        .input = "",
        .bytes = built.bytes,
        .storage_size_limit = storage_size_limit,
    }, &plan);
}

test "vopr start: an export is deterministic, valid, and named by its end record" {
    var buffer_a: [bytes_max]u8 = undefined;
    var buffer_b: [bytes_max]u8 = undefined;
    var origins: [4][32]u8 = undefined;
    for (&origins, 1..) |*origin_, seed| {
        const a = build(&buffer_a, seed);
        const b = build(&buffer_b, seed);
        try std.testing.expectEqualSlices(u8, a.bytes, b.bytes);
        try std.testing.expectEqualSlices(u8, &a.origin, &b.origin);
        var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_instance.deinit();
        const plan = try import_.plan_bytes(arena_instance.allocator(), a.bytes);
        try std.testing.expectEqualSlices(u8, &a.origin, &plan.origin);
        try std.testing.expectEqual(@as(u64, 0), plan.summary.change_count);
        origin_.* = a.origin;
    }
    try std.testing.expect(!std.mem.eql(u8, &origins[0], &std.mem.zeroes([32]u8)));
}

test "vopr start: every replica imports the export into a formatted storage" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");
    const replica_format = @import("../vsr/replica_format.zig");
    const size = 64 * stdx.MiB;

    var checkpoint_ops: [3]u64 = @splat(0);
    for (1..65) |seed| {
        var header: ?vsr.Header.Prepare = null;
        for (0..3) |replica| {
            var storage = try fixtures.init_storage(allocator, .{
                .size = size,
                .iops_write_max = replica_format.writes_max,
            });
            defer storage.deinit(allocator);
            try replica_format.format(Storage, allocator, &storage, .{
                .cluster = 0,
                .release = vsr.Release.minimum,
                .replica = @intCast(replica),
                .replica_count = 3,
                .view = null,
                .origin = origin(seed),
            });
            import_storage(allocator, &storage, seed, 0, vsr.Release.minimum, size) catch |err| {
                std.debug.print("seed {} replica {}: {s}: {s}\n", .{
                    seed,
                    replica,
                    @errorName(err),
                    export_file.corrupt_reason,
                });
                return err;
            };
            const state = storage.superblock_header(0).vsr_state;
            try std.testing.expectEqualSlices(u8, &origin(seed), &state.origin);
            // The same checkpoint on every replica, a checkpoint op of the cluster.
            if (header) |expected| {
                try std.testing.expectEqual(expected.checksum, state.checkpoint.header.checksum);
            }
            header = state.checkpoint.header;
        }
        const op = header.?.op;
        try std.testing.expect(vsr.Checkpoint.valid(op) and op > 0);
        const first = vsr.Checkpoint.checkpoint_after(0);
        const index = for (0..checkpoint_ops.len) |i| {
            if (op == first + i * constants.vsr_checkpoint_ops) break i;
        } else unreachable;
        checkpoint_ops[index] += 1;
    }
    for (checkpoint_ops) |count| try std.testing.expect(count > 0);
}
