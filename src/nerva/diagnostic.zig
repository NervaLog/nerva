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
const builtin = @import("builtin");
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
    .{ .code = "NRV-E0010", .summary = "A replica or gateway cannot send its metrics to `--statsd`", .exit = exit_operator },
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
    .{ .code = "NRV-E0717", .summary = "A test build with commit-key deduplication off was started without `--development`", .exit = exit_operator },
    .{ .code = "NRV-E0719", .summary = "The binary's bundled release is damaged, or the bundle cannot be read", .exit = exit_operator },
    .{ .code = "NRV-E0725", .summary = "A past release cannot be bundled: its release, format digest or `release_client_min` does not fit this build, or it does not run here", .exit = exit_operator },
    .{ .code = "NRV-E0727", .summary = "`nerva_pack` did not read an input in full: the file changed while it was read, or its size is not its length", .exit = exit_operator },
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

/// A file this run created that must not outlive a failed startup: `start --trace` (#197). One
/// path, the identity of the file it was created as, and the path's bytes. One thread. The buffer
/// has a byte past the longest path, always 0, so a signal handler can pass it to `unlink`.
const cleanup_path_buffer_size = std.fs.max_path_bytes + 1;
var cleanup_path_buffer: [cleanup_path_buffer_size]u8 = [_]u8{0} ** cleanup_path_buffer_size;
var cleanup_path_length: usize = 0;
var cleanup_inode: std.posix.ino_t = 0;
var cleanup_device: std.posix.dev_t = 0;

/// SIGINT and SIGTERM, while a file is registered (P208).
const cleanup_signals = [_]u6{ std.posix.SIG.INT, std.posix.SIG.TERM };
/// What each signal did before `cleanup_register`; restored by `cleanup_clear`. A signal that was
/// ignored (a shell's `&`, `nohup`) gets no handler, so that it stays ignored.
var cleanup_signal_saved: [cleanup_signals.len]std.posix.Sigaction = undefined;
var cleanup_signal_installed: [cleanup_signals.len]bool = [_]bool{false} ** cleanup_signals.len;
/// Set by the first panic, so a panic inside the cleanup does not run it again (P208).
var cleanup_panicking: bool = false;

/// Records `path`, which `file` was just created at, to be removed if the command exits through
/// `fail`, `fail_file`, `unexpected` or `fail_error` (every coded exit through this module), a
/// panic (`panic`), or SIGINT or SIGTERM, before `cleanup_clear`. A vendored `vsr.fatal` exit
/// (NRV-E0707, for example) leaves the file (#206, option 2).
pub fn cleanup_register(path: []const u8, file: std.fs.File) void {
    assert(cleanup_path_length == 0);
    assert(path.len > 0 and path.len <= std.fs.max_path_bytes);
    const stat = std.posix.fstat(file.handle) catch |err| {
        std.fs.cwd().deleteFile(path) catch {};
        fail_file(path, err);
    };
    @memcpy(cleanup_path_buffer[0..path.len], path);
    cleanup_path_buffer[path.len] = 0;
    cleanup_inode = stat.ino;
    cleanup_device = stat.dev;
    cleanup_path_length = path.len;
    cleanup_signals_install();
}

/// The command got past startup: the file is the operator's now.
pub fn cleanup_clear() void {
    // Registration first: a signal between the two steps must not unlink the operator's file.
    cleanup_path_length = 0;
    cleanup_signals_restore();
}

fn cleanup_signals_install() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = cleanup_signal_handler },
        // Neither signal interrupts the other's handler.
        .mask = cleanup_signal_mask(),
        .flags = 0,
    };
    for (cleanup_signals, 0..) |signal, index| {
        if (cleanup_signal_installed[index]) continue;
        std.posix.sigaction(signal, null, &cleanup_signal_saved[index]);
        if (cleanup_signal_saved[index].handler.handler == std.posix.SIG.IGN) continue;
        std.posix.sigaction(signal, &action, null);
        cleanup_signal_installed[index] = true;
    }
}

fn cleanup_signals_restore() void {
    for (cleanup_signals, 0..) |signal, index| {
        if (!cleanup_signal_installed[index]) continue;
        std.posix.sigaction(signal, &cleanup_signal_saved[index], null);
        cleanup_signal_installed[index] = false;
    }
}

fn cleanup_signal_mask() std.posix.sigset_t {
    var mask = std.posix.empty_sigset;
    for (cleanup_signals) |signal| sigaddset(&mask, signal);
    return mask;
}

/// `std.posix` has no `sigaddset`: Linux's sigset is a bit array, macOS's a `u32`, each with its own.
fn sigaddset(mask: *std.posix.sigset_t, signal: u6) void {
    if (builtin.os.tag == .linux) {
        std.os.linux.sigaddset(mask, signal);
    } else {
        std.c.sigaddset(mask, @intCast(signal));
    }
}

/// Async-signal-safe: system calls on the fixed buffer only, no allocation, no logging, no error
/// reporting. Removes the registered file if it is still the one this run created. Returns whether
/// it unlinked. Does not clear the registration: the command is about to die.
fn cleanup_unlink_raw() bool {
    const length = cleanup_path_length;
    if (length == 0) return false;
    const path: [*:0]const u8 = @ptrCast(&cleanup_path_buffer);
    assert(cleanup_path_buffer[length] == 0);
    // The raw system calls, not `std.posix.fstatatZ`: those turn some errnos into `unreachable`
    // or a stack trace, which a signal handler must not reach. `system` is the Linux system call
    // layer on Linux and libc on macOS, and `errno` reads either result.
    var stat: std.posix.Stat = undefined;
    const AT = std.posix.AT;
    const stat_result = std.posix.system.fstatat(AT.FDCWD, path, &stat, AT.SYMLINK_NOFOLLOW);
    if (std.posix.errno(stat_result) != .SUCCESS) return false;
    if (stat.ino != cleanup_inode or stat.dev != cleanup_device) return false;
    return std.posix.errno(std.posix.system.unlink(path)) == .SUCCESS;
}

/// SIGINT or SIGTERM while the trace file is registered (P208): remove it, then die of the same
/// signal, so the exit status still says so. Async-signal-safe (`cleanup_unlink_raw`, `sigaction`,
/// `raise`). The signal is blocked until the handler returns, so the re-raised default action
/// runs then.
fn cleanup_signal_handler(signal: i32) callconv(.c) void {
    _ = cleanup_unlink_raw();
    const default: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(@intCast(signal), &default, null);
    std.posix.raise(@intCast(signal)) catch {};
}

/// Whether this is the first panic: only the first runs the cleanup (P208).
fn cleanup_panic_enter() bool {
    if (cleanup_panicking) return false;
    cleanup_panicking = true;
    return true;
}

/// The program's panic handler (P208): removes the registered file, then the default handler
/// prints the message and the stack trace as it would have. A panic inside the cleanup, or any
/// later one, goes straight to the default handler. The cleanup runs first on purpose: the file
/// must be gone even if printing the message hangs or is killed (a closed pipe, a full terminal),
/// and the cleanup writes nothing unless a removal fails (NRV-W0011), so no message precedes the
/// panic's own.
pub fn panic(message: []const u8, first_trace_addr: ?usize) noreturn {
    if (cleanup_panic_enter()) cleanup_run();
    std.debug.defaultPanic(message, first_trace_addr);
}

/// Removes the registered file, unless something else has taken its path since (another inode),
/// in which case it is not ours to remove. The guard is check-then-act, not atomic: a file put at
/// the path between the check and the unlink is still removed (Linux has no unlink-if-inode). A
/// removal that fails is NRV-W0011. The registration stays until the removal is done, so a signal
/// that interrupts it still removes the file.
fn cleanup_run() void {
    if (cleanup_path_length == 0) return;
    defer cleanup_path_length = 0;
    if (cleanup_remove()) |err| cleanup_warn(cleanup_path_buffer[0..cleanup_path_length], err);
}

/// The decision of `cleanup_run`, apart from its logging: removes the registered file if it is
/// ours, and returns the error that makes it NRV-W0011, or null when the file is gone or not ours.
fn cleanup_remove() ?anyerror {
    assert(cleanup_path_length > 0);
    const path = cleanup_path_buffer[0..cleanup_path_length];
    const stat = std.posix.fstatat(
        std.posix.AT.FDCWD,
        path,
        std.posix.AT.SYMLINK_NOFOLLOW,
    ) catch |err| switch (err) {
        error.FileNotFound => return null, // Already gone.
        else => return err,
    };
    if (stat.ino != cleanup_inode or stat.dev != cleanup_device) return null;
    std.fs.cwd().deleteFile(path) catch |err| return err;
    return null;
}

fn cleanup_warn(path: []const u8, err: anyerror) void {
    std.log.warn("NRV-W0011 {s}: could not remove the unused trace file {s}: {s}; remove it " ++
        "before the next start, which refuses an existing file (NRV-E0004)", .{
        command,
        path,
        cleanup_reason(err),
    });
}

/// `file_reason` for the errors a removal commonly hits; anything else is "the system refused".
fn cleanup_reason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.IsDir,
        error.NotDir,
        error.NameTooLong,
        error.ReadOnlyFileSystem,
        => file_reason(err),
        error.SymLinkLoop => "a symbolic link in its path loops",
        else => "the system refused",
    };
}

fn print_and_exit(block: []const u8, status: u8) noreturn {
    assert(status == exit_operator or status == exit_environment or status == exit_internal);
    cleanup_run();
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

test "cleanup removes the file it registered and only that file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/trace", .{dir});

    const file = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    cleanup_register(path, file);
    defer cleanup_clear();
    file.close();
    try testing.expectEqual(@as(?anyerror, null), cleanup_remove());
    cleanup_run();
    try testing.expectError(error.FileNotFound, tmp.dir.access("trace", .{}));

    // The path now names a different file: not ours, so it stays.
    const first = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    cleanup_register(path, first);
    defer cleanup_clear();
    try tmp.dir.deleteFile("trace");
    (try tmp.dir.createFile("trace", .{})).close();
    first.close();
    try testing.expectEqual(@as(?anyerror, null), cleanup_remove());
    cleanup_run();
    try tmp.dir.access("trace", .{});

    // Cleared: nothing is removed.
    const third = try std.fs.cwd().createFile(path, .{ .truncate = false });
    cleanup_register(path, third);
    defer cleanup_clear();
    third.close();
    cleanup_clear();
    cleanup_run();
    try tmp.dir.access("trace", .{});
}

test "cleanup: a parent that became a file is not an error, a path that cannot be removed is" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/d/trace", .{dir});

    try tmp.dir.makeDir("d");
    const file = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    cleanup_register(path, file);
    defer cleanup_clear();
    file.close();
    try tmp.dir.rename("d", "d2");
    (try tmp.dir.createFile("d", .{})).close();
    // `fstatat` answers FileNotFound for NotDir: gone from where we put it, nothing to warn about,
    // and the file at its new place is untouched.
    try testing.expectEqual(@as(?anyerror, null), cleanup_remove());
    cleanup_run();
    try tmp.dir.access("d2/trace", .{});
    try testing.expectEqual(@as(usize, 0), cleanup_path_length);

    // The warning's own case, which holds for root too: the registered identity is a directory's,
    // so the check passes and `unlink` refuses it.
    const path_dir = try std.fmt.bufPrint(&path_buffer, "{s}/d2", .{dir});
    var directory = try tmp.dir.openDir("d2", .{});
    defer directory.close();
    cleanup_register(path_dir, .{ .handle = directory.fd });
    try testing.expectEqual(@as(?anyerror, error.IsDir), cleanup_remove());
    cleanup_run();
    try tmp.dir.access("d2/trace", .{});
    cleanup_clear();

    // And the check's own: a symbolic link that points at itself, as a parent of the path.
    try tmp.dir.symLink("loop", "loop", .{});
    const path_loop = try std.fmt.bufPrint(&path_buffer, "{s}/loop/trace", .{dir});
    cleanup_register(path_loop, .{ .handle = directory.fd });
    try testing.expectEqual(@as(?anyerror, error.SymLinkLoop), cleanup_remove());
    cleanup_run();
    try testing.expectEqualStrings("it is a directory", cleanup_reason(error.IsDir));
    try testing.expectEqualStrings(
        "a parent of it is not a directory",
        cleanup_reason(error.NotDir),
    );
    try testing.expectEqualStrings(
        "a symbolic link in its path loops",
        cleanup_reason(error.SymLinkLoop),
    );
    try testing.expectEqualStrings("the system refused", cleanup_reason(error.FileBusy));
}

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

test "cleanup: the panic guard lets only the first panic run the cleanup" {
    cleanup_panicking = false;
    defer cleanup_panicking = false;
    try testing.expect(cleanup_panic_enter());
    try testing.expect(!cleanup_panic_enter());
    try testing.expect(!cleanup_panic_enter());
}

test "cleanup: the signal path unlinks by the fixed buffer, and only our file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/trace", .{dir});

    // Nothing registered: nothing happens, whatever is at the path.
    cleanup_clear();
    try testing.expect(!cleanup_unlink_raw());

    const file = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    cleanup_register(path, file);
    defer cleanup_clear();
    file.close();
    try testing.expectEqual(@as(u8, 0), cleanup_path_buffer[path.len]);
    try testing.expect(cleanup_unlink_raw());
    try testing.expectError(error.FileNotFound, tmp.dir.access("trace", .{}));
    try testing.expect(!cleanup_unlink_raw()); // Already gone.

    // Another file at the path is not ours.
    cleanup_clear();
    const first = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    cleanup_register(path, first);
    defer cleanup_clear();
    try tmp.dir.deleteFile("trace");
    (try tmp.dir.createFile("trace", .{})).close();
    first.close();
    try testing.expect(!cleanup_unlink_raw());
    try tmp.dir.access("trace", .{});
    cleanup_clear();
}

/// How long the parent waits for a forked test child: a child that spins or deadlocks is killed
/// and the test fails, instead of hanging and leaking a process.
const cleanup_child_wait_ms_max = 10_000;
const cleanup_child_poll_ms = 10;

/// In the forked child: take the signals the test relies on out of whatever the test binary
/// inherited (ignored, blocked), and silence stderr (the panic test prints a trace).
fn cleanup_child_prepare() void {
    var default = std.mem.zeroes(std.posix.Sigaction);
    default.handler.handler = std.posix.SIG.DFL;
    var mask = std.posix.empty_sigset;
    const signals = [_]u6{ std.posix.SIG.INT, std.posix.SIG.TERM };
    for (signals) |signal| {
        std.posix.sigaction(signal, &default, null);
        sigaddset(&mask, signal);
    }
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &mask, null);
    const null_fd = std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch std.posix.exit(3);
    std.posix.dup2(null_fd, std.posix.STDERR_FILENO) catch std.posix.exit(3);
    if (null_fd != std.posix.STDERR_FILENO) std.posix.close(null_fd);
}

/// Forks a child that registers `trace` in `dir`, then runs `act`; returns how the child ended.
fn cleanup_child(dir: std.fs.Dir, comptime act: fn () void) !u32 {
    // A test runner started with SIGCHLD ignored makes std's `waitpid` fail with ECHILD, which std
    // treats as unreachable: take the default action for the fork and put the old one back.
    var default = std.mem.zeroes(std.posix.Sigaction);
    default.handler.handler = std.posix.SIG.DFL;
    var inherited: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.CHLD, &default, &inherited);
    defer std.posix.sigaction(std.posix.SIG.CHLD, &inherited, null);
    const pid = try std.posix.fork();
    if (pid == 0) {
        cleanup_child_prepare();
        const file = dir.createFile("trace", .{ .exclusive = true }) catch std.posix.exit(3);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = dir.realpath("trace", &buffer) catch std.posix.exit(3);
        cleanup_register(path, file);
        act();
        std.posix.exit(4); // Not reached: `act` must kill the process.
    }
    var waited_ms: u64 = 0;
    while (waited_ms < cleanup_child_wait_ms_max) : (waited_ms += cleanup_child_poll_ms) {
        const result = std.posix.waitpid(pid, std.posix.W.NOHANG);
        if (result.pid == pid) return result.status;
        assert(result.pid == 0);
        std.Thread.sleep(cleanup_child_poll_ms * std.time.ns_per_ms);
    }
    std.posix.kill(pid, std.posix.SIG.KILL) catch unreachable; // Our own unreaped child.
    const reaped = std.posix.waitpid(pid, 0);
    assert(reaped.pid == pid);
    return error.ChildDidNotEnd;
}

fn cleanup_child_term() void {
    std.posix.raise(std.posix.SIG.TERM) catch {};
}

fn cleanup_child_int() void {
    std.posix.raise(std.posix.SIG.INT) catch {};
}

fn cleanup_child_panic() void {
    panic("cleanup test panic", null);
}

const cleanup_child_exit_code = 7;

fn cleanup_child_exit() void {
    std.posix.exit(cleanup_child_exit_code);
}

test "cleanup: SIGTERM and SIGINT remove the file and still kill the process" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const term = try cleanup_child(tmp.dir, cleanup_child_term);
    try testing.expect(std.posix.W.IFSIGNALED(term));
    try testing.expectEqual(@as(u32, std.posix.SIG.TERM), std.posix.W.TERMSIG(term));
    try testing.expectError(error.FileNotFound, tmp.dir.access("trace", .{}));

    const interrupt = try cleanup_child(tmp.dir, cleanup_child_int);
    try testing.expect(std.posix.W.IFSIGNALED(interrupt));
    try testing.expectEqual(@as(u32, std.posix.SIG.INT), std.posix.W.TERMSIG(interrupt));
    try testing.expectError(error.FileNotFound, tmp.dir.access("trace", .{}));
}

test "cleanup: a panic removes the file and still ends the process abnormally" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const status = try cleanup_child(tmp.dir, cleanup_child_panic);
    try testing.expect(std.posix.W.IFSIGNALED(status));
    try testing.expectEqual(@as(u32, std.posix.SIG.ABRT), std.posix.W.TERMSIG(status));
    try testing.expectError(error.FileNotFound, tmp.dir.access("trace", .{}));
}

test "cleanup: the child helper takes SIGCHLD to the default for the fork and restores it" {
    // With SIGCHLD ignored, std's `waitpid` fails with ECHILD: the status coming back proves the
    // default action was in force during the fork; SIG_IGN again afterwards proves the restore.
    var ignore = std.mem.zeroes(std.posix.Sigaction);
    ignore.handler.handler = std.posix.SIG.IGN;
    var original: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.CHLD, &ignore, &original);
    defer std.posix.sigaction(std.posix.SIG.CHLD, &original, null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const status = try cleanup_child(tmp.dir, cleanup_child_exit);
    try testing.expect(std.posix.W.IFEXITED(status));
    try testing.expectEqual(@as(u32, cleanup_child_exit_code), std.posix.W.EXITSTATUS(status));

    var after: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.CHLD, null, &after);
    try testing.expect(after.handler.handler == std.posix.SIG.IGN);
}

test "cleanup: handlers are installed while registered and restored after" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/trace", .{dir});

    cleanup_clear();
    // SIGINT ignored beforehand stays ignored; SIGTERM is taken over and given back.
    var ignore = std.mem.zeroes(std.posix.Sigaction);
    ignore.handler.handler = std.posix.SIG.IGN;
    var before_int: std.posix.Sigaction = undefined;
    var before_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &ignore, &before_int);
    std.posix.sigaction(std.posix.SIG.TERM, null, &before_term);
    defer std.posix.sigaction(std.posix.SIG.INT, &before_int, null);

    const file = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    cleanup_register(path, file);
    defer cleanup_clear();
    file.close();
    var now: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, null, &now);
    try testing.expectEqual(@intFromPtr(&cleanup_signal_handler), @intFromPtr(now.handler.handler));
    std.posix.sigaction(std.posix.SIG.INT, null, &now);
    try testing.expectEqual(@intFromPtr(std.posix.SIG.IGN), @intFromPtr(now.handler.handler));

    cleanup_clear();
    std.posix.sigaction(std.posix.SIG.TERM, null, &now);
    try testing.expectEqual(
        @intFromPtr(before_term.handler.handler),
        @intFromPtr(now.handler.handler),
    );
    try tmp.dir.deleteFile("trace");
}
