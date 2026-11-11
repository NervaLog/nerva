//! The text of the vendored `vsr.fatal` exits that Nerva codes (docs/ERRORS.md, P147c). Kept here,
//! beside the unit test that holds them to the register, so that a patch to a vendored file is
//! one line that names a constant. Each message names its code and only flags Nerva has.

const std = @import("std");
const testing = std.testing;

/// Exit 3 (`manifest_node_pool_exhausted`, `src/lsm/node_pool.zig`).
pub const manifest_node_pool_exhausted =
    "NRV-E0721: out of memory for the manifest: the data file has more tables than this " ++
    "build's manifest memory holds. Nerva has no flag to raise it (docs/ERRORS.md)";

/// Exit 6 (`forest_tables_count_would_exceed_limit`, `src/lsm/manifest_log.zig`). Its arguments
/// are the table count and the limit.
pub const forest_tables_count_would_exceed_limit =
    "NRV-E0722: the forest's table count would exceed its limit " ++
    "(tables_count={} tables_max={}). Nerva has no flag to raise it (docs/ERRORS.md)";

/// Exit 2 (`no_space_left`, `src/storage.zig`). Its arguments are the write's offset and size.
pub const no_space_left =
    "NRV-E0706: write failed: no space left on device (offset={} size={})";

test "fatal messages: each names its registered code and no flag Nerva lacks" {
    const register = try std.fs.cwd().readFileAlloc(testing.allocator, "docs/ERRORS.md", 1 << 20);
    defer testing.allocator.free(register);
    const cases = [_]struct { text: []const u8, code: []const u8 }{
        .{ .text = manifest_node_pool_exhausted, .code = "NRV-E0721" },
        .{ .text = forest_tables_count_would_exceed_limit, .code = "NRV-E0722" },
        .{ .text = no_space_left, .code = "NRV-E0706" },
    };
    for (cases) |case| {
        try testing.expect(std.mem.indexOf(u8, case.text, case.code) != null);
        var row: [16]u8 = undefined;
        const needle = try std.fmt.bufPrint(&row, "| {s} | ", .{case.code});
        try testing.expect(std.mem.indexOf(u8, register, needle) != null);
        for ([_][]const u8{ "--memory-lsm", "--limit-storage", "the team" }) |banned| {
            try testing.expect(std.mem.indexOf(u8, case.text, banned) == null);
        }
    }
}

test "fatal messages: they format with their arguments" {
    var buffer: [256]u8 = undefined;
    const tables = try std.fmt.bufPrint(
        &buffer,
        forest_tables_count_would_exceed_limit,
        .{ @as(u32, 9), @as(u32, 8) },
    );
    try testing.expect(std.mem.indexOf(u8, tables, "tables_count=9 tables_max=8") != null);
    const space = try std.fmt.bufPrint(&buffer, no_space_left, .{ @as(u64, 4096), @as(usize, 512) });
    try testing.expect(std.mem.indexOf(u8, space, "offset=4096 size=512") != null);
}
