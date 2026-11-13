//! `nerva_pack`: the build step behind `zig build -Dbundle=<path>` (R6 slice 3, P259d, P417).
//!
//! ```
//! nerva_pack --input <nerva> --past <past nerva> --output <path> [--debug] [--size-max <bytes>]
//! ```
//!
//! Writes `--output`: `--input` (this release's executable, unpacked) with `--past` (an earlier
//! release's executable, packed or not) bundled, in the layout `bundle.zig` describes. The facts
//! of both come from `<exe> version --verbose`, so each must run here: a pack is native. It refuses
//! (NRV-E0721, nothing written) a past release that is not lower, of another format digest, or
//! whose clients this release would refuse, and a result over the size limit (NRV-E0719).
//! It is a build tool: `zig build` runs it, and `tests/release/bundle.py` runs it on stubs.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const bundle = @import("nerva/bundle.zig");
const diagnostic = @import("nerva/diagnostic.zig");

/// The largest executable read: upstream's overall bound (`multiversion_binary_size_max`) is
/// 256 MiB; a past release over it was never packable.
const file_size_max = 256 * 1024 * 1024;
const facts_size_max = 64 * 1024;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    diagnostic.command = "pack";

    var input: ?[]const u8 = null;
    var past_path: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var debug = false;
    var size_max: ?u64 = null;

    const args = try std.process.argsAlloc(allocator);
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (mem.eql(u8, arg, "--debug")) {
            debug = true;
        } else if (index + 1 < args.len and mem.eql(u8, arg, "--input")) {
            index += 1;
            input = args[index];
        } else if (index + 1 < args.len and mem.eql(u8, arg, "--past")) {
            index += 1;
            past_path = args[index];
        } else if (index + 1 < args.len and mem.eql(u8, arg, "--output")) {
            index += 1;
            output = args[index];
        } else if (index + 1 < args.len and mem.eql(u8, arg, "--size-max")) {
            index += 1;
            size_max = std.fmt.parseInt(u64, args[index], 10) catch usage();
        } else usage();
    }
    if (input == null or past_path == null or output == null) usage();

    const current_facts = try facts_read(allocator, input.?);
    const past_facts = try facts_read(allocator, past_path.?);
    if (bundle.refusal(current_facts, past_facts)) |refusal| {
        diagnostic.fail(
            "NRV-E0721",
            "pack: {s} cannot be bundled: {s}",
            .{ past_path.?, refusal.text() },
            "build with the previous release's `nerva` of the same format (README, \"Upgrading a cluster\")",
            .{},
        );
    }

    const input_bytes = try file_read(allocator, input.?);
    const past_loaded = try file_read(allocator, past_path.?);
    const past_bytes = (try bundle.strip(allocator, past_loaded)) orelse diagnostic.fail(
        "NRV-E0719",
        "pack: {s} has a bundle this packer did not write; it cannot be bundled",
        .{past_path.?},
        "pack from the release's own build, not from a rewritten copy",
        .{},
    );

    const packed_bytes = bundle.pack(allocator, input_bytes, current_facts, .{
        .facts = past_facts,
        .bytes = past_bytes,
    }, .{
        .debug = debug,
        .size_max = size_max orelse bundle.size_max_default(debug),
    }) catch |err| switch (err) {
        error.SizeMax => diagnostic.fail(
            "NRV-E0719",
            "pack: the bundle would be over the size limit ({} bytes, from {s} and {s})",
            .{ size_max orelse bundle.size_max_default(debug), input.?, past_path.? },
            "this is a packing bug: report it with both binaries' sizes",
            .{},
        ),
        error.NotElf, error.AlreadyPacked => diagnostic.fail(
            "NRV-E0719",
            "pack: {s} is not a plain ELF executable of this platform",
            .{input.?},
            "pack on Linux, from a `zig build` output",
            .{},
        ),
        error.OutOfMemory => return err,
    };

    // Written whole, then renamed: a failed build leaves no half-packed `nerva`.
    const directory = std.fs.cwd();
    var atomic = try directory.atomicFile(output.?, .{ .mode = 0o755 });
    defer atomic.deinit();
    try atomic.file.writeAll(packed_bytes);
    try atomic.finish();
}

fn usage() noreturn {
    diagnostic.fail(
        "NRV-E0001",
        "pack: usage: nerva_pack --input <nerva> --past <past nerva> --output <path>",
        .{},
        "see the header of src/nerva_pack.zig",
        .{},
    );
}

fn file_read(allocator: mem.Allocator, path: []const u8) ![]align(8) u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| diagnostic.fail_file(path, err);
    defer file.close();
    const size = try file.getEndPos();
    if (size > file_size_max) diagnostic.fail(
        "NRV-E0719",
        "pack: {s} is over {} bytes",
        .{ path, file_size_max },
        "pack executables, not archives",
        .{},
    );
    const bytes = try allocator.alignedAlloc(u8, 8, size);
    assert(try file.readAll(bytes) == size);
    return bytes;
}

/// What `<exe> version --verbose` says. An executable that does not run, or does not say the
/// four facts (a build without its commit), cannot be bundled or bundle.
fn facts_read(allocator: mem.Allocator, exe: []const u8) !bundle.Facts {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ exe, "version", "--verbose" },
        .max_output_bytes = facts_size_max,
    }) catch diagnostic.fail(
        "NRV-E0721",
        "pack: {s} does not run here (`version --verbose`)",
        .{exe},
        "pack on the platform both binaries are for",
        .{},
    );
    const facts = bundle.Facts.parse(result.stdout) catch diagnostic.fail(
        "NRV-E0721",
        "pack: {s} does not say its release, format and commit (`version --verbose`)",
        .{exe},
        "build it from a git checkout of the release, with its commit",
        .{},
    );
    return facts;
}
