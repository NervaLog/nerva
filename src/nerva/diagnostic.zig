//! Coded diagnostics for `nerva` commands (P147c, R5).
//!
//! A command that refuses prints one `error[NRV-…]` block and exits with a status that says who
//! is to blame: 1 the operator, 2 the environment (disk, kernel, file system), 70 Nerva itself
//! (P149e). The summary of each code is the one registered in `docs/ERRORS.md`; a unit test keeps
//! the two in agreement. `nerva start`'s runtime exits (2 to 8) are not commands' and keep their
//! statuses.
//!
//! ```
//! error[NRV-E0004]: export: cluster.export exists
//!   cause  An output file already exists
//!   fix    give a new path: nerva never overwrites
//! ```
//!
//! Nothing here prints a Zig error name in the first line. An error a command did not expect is
//! `bug[NRV-B0004]`, and its name appears only on a `detail` line under `--log-debug`.

const std = @import("std");
const assert = std.debug.assert;

pub const exit_operator: u8 = 1;
pub const exit_environment: u8 = 2;
pub const exit_internal: u8 = 70;

/// The longest block printed; a longer headline is cut.
const block_size_max = 4096;
/// The longest reason captured from a log line (`note`).
const reason_size_max = 512;

const Entry = struct {
    code: []const u8,
    /// Equal to the "Summary" column of `docs/ERRORS.md`.
    summary: []const u8,
    exit: u8,
};

/// The codes commands emit. Never renumber or reuse one.
pub const table = [_]Entry{
    .{ .code = "NRV-E0001", .summary = "A command or flag is unknown, repeated or malformed", .exit = exit_operator },
    .{ .code = "NRV-E0002", .summary = "A flag's value is out of range", .exit = exit_operator },
    .{ .code = "NRV-E0003", .summary = "`--listen` is not an address", .exit = exit_operator },
    .{ .code = "NRV-E0004", .summary = "An output file already exists", .exit = exit_operator },
    .{ .code = "NRV-E0005", .summary = "A data file already exists at `format`'s path", .exit = exit_operator },
    .{ .code = "NRV-E0006", .summary = "A data file is missing at `start`'s path", .exit = exit_operator },
    .{ .code = "NRV-E0007", .summary = "A replica, gateway or view server cannot listen", .exit = exit_operator },
    .{ .code = "NRV-E0008", .summary = "`NERVA_KEY` is missing or invalid", .exit = exit_operator },
    .{ .code = "NRV-E0009", .summary = "`--listen` is not loopback and `--listen-remote` was not given", .exit = exit_operator },
    .{ .code = "NRV-E0604", .summary = "A gateway or view server could not reach the cluster", .exit = exit_operator },
    .{ .code = "NRV-E0701", .summary = "The data file was written by another release", .exit = exit_operator },
    .{ .code = "NRV-E0702", .summary = "The data file is not a Nerva data file, or is damaged", .exit = exit_operator },
    .{ .code = "NRV-E0703", .summary = "Another process holds the data file", .exit = exit_operator },
    .{ .code = "NRV-E0704", .summary = "The file system cannot do direct IO", .exit = exit_environment },
    .{ .code = "NRV-E0705", .summary = "The kernel is older than 5.11", .exit = exit_environment },
    .{ .code = "NRV-E0706", .summary = "The disk is full", .exit = exit_environment },
    .{ .code = "NRV-E0708", .summary = "The disk failed a read, a write or an fsync", .exit = exit_environment },
    .{ .code = "NRV-E0710", .summary = "Not every replica address was given", .exit = exit_operator },
    .{ .code = "NRV-E0712", .summary = "`nerva recover`: the other replicas did not commit its requests; they have no quorum", .exit = exit_operator },
    .{ .code = "NRV-E0713", .summary = "`nerva recover`: the replica it would replace still answers at its address", .exit = exit_operator },
    .{ .code = "NRV-E0714", .summary = "`nerva recover` needs a cluster of at least three replicas", .exit = exit_operator },
    .{ .code = "NRV-E0715", .summary = "An earlier `nerva recover` did not finish", .exit = exit_operator },
    .{ .code = "NRV-E0716", .summary = "`nerva recover`'s session was evicted before it finished", .exit = exit_operator },
    .{ .code = "NRV-E0801", .summary = "The cluster did not answer the export", .exit = exit_operator },
    .{ .code = "NRV-E0802", .summary = "`--as-of` is past the latest op", .exit = exit_operator },
    .{ .code = "NRV-E0803", .summary = "The export would be refused by `nerva import`", .exit = exit_operator },
    .{ .code = "NRV-E0804", .summary = "The file is not an export, or is damaged or truncated", .exit = exit_operator },
    .{ .code = "NRV-E0805", .summary = "The export's version is not one this release imports", .exit = exit_operator },
    .{ .code = "NRV-E0806", .summary = "An earlier import did not finish", .exit = exit_operator },
    .{ .code = "NRV-E0807", .summary = "The imported data failed its checks", .exit = exit_operator },
    .{ .code = "NRV-E0808", .summary = "A backup's manifest is missing, malformed, too large or of an unknown version", .exit = exit_operator },
    .{ .code = "NRV-E0809", .summary = "A backup does not match its manifest: size, SHA-256, op, version, a view hash or a ledger total", .exit = exit_operator },
    .{ .code = "NRV-E0810", .summary = "A file `export` or `import` was given cannot be opened, read or written", .exit = exit_operator },
    .{ .code = "NRV-E0901", .summary = "`NERVA_CLUSTER_KEY` is missing, short, or wrongly paired with `_NEXT`", .exit = exit_operator },
    .{ .code = "NRV-B0004", .summary = "A `nerva` command hit an error it did not expect", .exit = exit_internal },
};

fn entry(comptime code: []const u8) Entry {
    comptime {
        for (table) |candidate| {
            if (std.mem.eql(u8, candidate.code, code)) return candidate;
        }
        @compileError("diagnostic code " ++ code ++ " is not in the table");
    }
}

fn kind_name(comptime code: []const u8) []const u8 {
    return switch (code[4]) {
        'E' => "error",
        'W' => "warning",
        'B' => "bug",
        else => @compileError("a code's kind is E, W or B"),
    };
}

/// The command being run, for messages about errors it did not expect. Set once by `main`.
pub var command: []const u8 = "nerva";
/// `--log-debug`: the error name of a bug goes on a `detail` line.
pub var debug: bool = false;

var reason_buffer: [reason_size_max]u8 = undefined;
var reason_length: usize = 0;
var reasons_more: u32 = 0;

/// Remembers the first `error` log line of an export or an import, so that the failure that
/// follows can say why (NRV-E0807), not only that the log above says so. One thread.
pub fn note(comptime format: []const u8, args: anytype) void {
    if (reason_length > 0) {
        reasons_more +|= 1;
        return;
    }
    const text = std.fmt.bufPrint(&reason_buffer, format, args) catch &reason_buffer;
    reason_length = text.len;
}

/// The first noted reason, with how many others were logged, or null if none was.
pub fn reason_take(buffer: []u8) ?[]const u8 {
    if (reason_length == 0) return null;
    const first = reason_buffer[0..reason_length];
    const text = if (reasons_more == 0)
        std.fmt.bufPrint(buffer, "{s}", .{first}) catch buffer
    else
        std.fmt.bufPrint(buffer, "{s} (and {} more in the log above)", .{ first, reasons_more }) catch buffer;
    return text;
}

/// Writes the block for `code` to `writer`: a headline, the code's summary as the cause, and a fix.
pub fn render(
    writer: anytype,
    comptime code: []const u8,
    comptime headline: []const u8,
    headline_args: anytype,
    comptime fix: []const u8,
    fix_args: anytype,
) !void {
    try writer.print(kind_name(code) ++ "[" ++ code ++ "]: " ++ headline ++ "\n", headline_args);
    try writer.print("  cause  " ++ entry(code).summary ++ "\n", .{});
    try writer.print("  fix    " ++ fix ++ "\n", fix_args);
}

fn print_and_exit(block: []const u8, status: u8) noreturn {
    assert(status == exit_operator or status == exit_environment or status == exit_internal);
    std.io.getStdErr().writeAll(block) catch {};
    std.process.exit(status);
}

/// Prints the block for `code` and exits with the status its table entry names.
pub fn fail(
    comptime code: []const u8,
    comptime headline: []const u8,
    headline_args: anytype,
    comptime fix: []const u8,
    fix_args: anytype,
) noreturn {
    var buffer: [block_size_max]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    // A block that does not fit is cut, never dropped.
    render(stream.writer(), code, headline, headline_args, fix, fix_args) catch {};
    print_and_exit(stream.getWritten(), comptime entry(code).exit);
}

/// An error a command did not expect: `bug[NRV-B0004]`, the name only under `--log-debug`.
pub fn unexpected(err: anyerror) noreturn {
    var buffer: [block_size_max]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();
    render(
        writer,
        "NRV-B0004",
        "{s} hit an error it did not expect",
        .{command},
        "report it with the command line and its output under --log-debug",
        .{},
    ) catch {};
    if (debug) writer.print("  detail error.{s}\n", .{@errorName(err)}) catch {};
    print_and_exit(stream.getWritten(), exit_internal);
}

/// A file the command was given failed: the code follows the error, never its name.
pub fn fail_file(path: []const u8, err: anyerror) noreturn {
    switch (err) {
        error.NoSpaceLeft => fail(
            "NRV-E0706",
            "{s}: no space left writing {s}",
            .{ command, path },
            "free space or use a larger volume, then run {s} again",
            .{command},
        ),
        error.InputOutput => fail(
            "NRV-E0708",
            "{s}: the disk failed a read or a write of {s}",
            .{ command, path },
            "check the disk; nothing was named {s}",
            .{path},
        ),
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.IsDir,
        error.NotDir,
        error.NameTooLong,
        error.ReadOnlyFileSystem,
        error.FileTooBig,
        error.BadPathName,
        => fail(
            "NRV-E0810",
            "{s}: cannot use {s}: {s}",
            .{ command, path, file_reason(err) },
            "check the path and its permissions",
            .{},
        ),
        else => unexpected(err),
    }
}

fn file_reason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "it is a directory",
        error.NotDir => "a parent of it is not a directory",
        error.NameTooLong => "the path is too long",
        error.ReadOnlyFileSystem => "the file system is read-only",
        error.FileTooBig => "the file is too large",
        else => "the path is not valid",
    };
}

/// Any error that reached `main`: known environmental causes get their code, the rest are bugs.
pub fn fail_error(err: anyerror) noreturn {
    switch (err) {
        error.AddressInUse,
        error.AddressNotAvailable,
        error.AddressFamilyNotSupported,
        error.AccessDenied,
        => fail(
            "NRV-E0007",
            "{s}: cannot listen: {s}",
            .{ command, file_reason_listen(err) },
            "free the port, or give another address",
            .{},
        ),
        error.Timeout => fail(
            "NRV-E0604",
            "{s}: no reply from the cluster",
            .{command},
            "check --cluster and --addresses, and that a quorum of replicas is running",
            .{},
        ),
        error.NoSpaceLeft, error.InputOutput => fail_file("the data file", err),
        else => unexpected(err),
    }
}

fn file_reason_listen(err: anyerror) []const u8 {
    return switch (err) {
        error.AddressInUse => "the address is in use",
        error.AddressNotAvailable => "the address is not on this host",
        error.AddressFamilyNotSupported => "this host cannot open a socket for that address",
        else => "permission denied",
    };
}

const testing = std.testing;

fn expect_render(
    comptime code: []const u8,
    comptime headline: []const u8,
    headline_args: anytype,
    comptime fix: []const u8,
    expected: []const u8,
) !void {
    var buffer: [block_size_max]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try render(stream.writer(), code, headline, headline_args, fix, .{});
    try testing.expectEqualStrings(expected, stream.getWritten());
}

test "diagnostic: rendering, one code per kind" {
    try expect_render(
        "NRV-E0004",
        "export: {s} exists",
        .{"cluster.export"},
        "give a new path: nerva never overwrites",
        "error[NRV-E0004]: export: cluster.export exists\n" ++
            "  cause  An output file already exists\n" ++
            "  fix    give a new path: nerva never overwrites\n",
    );
    try expect_render(
        "NRV-B0004",
        "{s} hit an error it did not expect",
        .{"import"},
        "report it",
        "bug[NRV-B0004]: import hit an error it did not expect\n" ++
            "  cause  A `nerva` command hit an error it did not expect\n" ++
            "  fix    report it\n",
    );
    try expect_render(
        "NRV-E0706",
        "import: no space left",
        .{},
        "free space",
        "error[NRV-E0706]: import: no space left\n" ++
            "  cause  The disk is full\n" ++
            "  fix    free space\n",
    );
}

test "diagnostic: exit statuses follow blame" {
    try testing.expectEqual(exit_operator, comptime entry("NRV-E0004").exit);
    try testing.expectEqual(exit_environment, comptime entry("NRV-E0706").exit);
    try testing.expectEqual(exit_internal, comptime entry("NRV-B0004").exit);
}

test "diagnostic: note keeps the first reason and counts the rest" {
    reason_length = 0;
    reasons_more = 0;
    defer reason_length = 0;
    var buffer: [reason_size_max + 64]u8 = undefined;
    try testing.expect(reason_take(&buffer) == null);
    note("view {s}: bad", .{"a"});
    try testing.expectEqualStrings("view a: bad", reason_take(&buffer).?);
    note("second", .{});
    note("third", .{});
    try testing.expectEqualStrings(
        "view a: bad (and 2 more in the log above)",
        reason_take(&buffer).?,
    );
}

test "diagnostic: the table agrees with docs/ERRORS.md" {
    const text = try std.fs.cwd().readFileAlloc(testing.allocator, "docs/ERRORS.md", 1 << 20);
    defer testing.allocator.free(text);
    for (table, 0..) |candidate, index| {
        // Codes are unique.
        for (table[0..index]) |earlier| {
            try testing.expect(!std.mem.eql(u8, earlier.code, candidate.code));
        }
        // The row: `| CODE | Summary | …`.
        var row_start: usize = 0;
        const needle = try std.fmt.allocPrint(testing.allocator, "| {s} | ", .{candidate.code});
        defer testing.allocator.free(needle);
        row_start = std.mem.indexOf(u8, text, needle) orelse {
            std.debug.print("{s} is not registered in docs/ERRORS.md\n", .{candidate.code});
            return error.TestUnexpectedResult;
        };
        const summary_start = row_start + needle.len;
        const summary_end = std.mem.indexOfPos(u8, text, summary_start, " | ").?;
        try testing.expectEqualStrings(candidate.summary, text[summary_start..summary_end]);
    }
}
