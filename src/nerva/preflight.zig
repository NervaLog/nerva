//! Pre-flight checks for the data file and the kernel (R5 slice 2, P149).
//!
//! Operator input must never reach a vendored panic: a missing file, a lock another process
//! holds, a file of another release or with no superblock quorum, a file system without direct
//! IO. Each is checked here, in Nerva's own code, before `Storage.init`, with the vendored
//! header types and quorum code unmodified, and refused with its code (`docs/ERRORS.md`). The
//! vendored panics stay as the backstop for a race between these checks and the open.
//!
//! Linux only: elsewhere the checks that need `flock`, `O_DIRECT` and `uname` are skipped and
//! the vendored behaviour is unchanged.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;

const stdx = @import("stdx");
const vsr = @import("../vsr.zig");
const constants = @import("../constants.zig");
const diagnostic = @import("diagnostic.zig");
const superblock = vsr.superblock;
const SuperBlockHeader = superblock.SuperBlockHeader;

/// The oldest kernel Nerva runs on: `io_uring` as the vendored IO uses it (NRV-E0705).
pub const kernel_version_min = Version{ .major = 5, .minor = 11 };
/// A killed process's lock can linger while `io_uring` tears its ring down (the vendored open
/// waits 250 ms for it; a loaded host needs longer, #288, P290). Bounded: 40 x 50 ms = 2 s, then
/// the lock is refused as held (NRV-E0703).
const lock_retry_ms = 50;
const lock_wait_ms = 2000;
const lock_attempts = lock_wait_ms / lock_retry_ms;
comptime {
    assert(lock_attempts * lock_retry_ms == lock_wait_ms);
}

pub const Version = struct {
    major: u32,
    minor: u32,

    fn less_than(a: Version, b: Version) bool {
        return a.major < b.major or (a.major == b.major and a.minor < b.minor);
    }
};

pub const DirectIO = enum { disabled, optional, required };

/// Why a data file is not opened. The `Error` of `superblock.Quorums.working` is named in
/// `damaged`.
pub const Refusal = union(enum) {
    missing,
    not_a_file,
    damaged: []const u8,
    other_release: vsr.Release,
    locked,
    direct_io_unsupported,
};

/// The version in a `uname` release string such as `6.8.0-45-generic`, or null if it has none.
pub fn kernel_version_parse(release: []const u8) ?Version {
    var parts = std.mem.splitScalar(u8, release, '.');
    const major = parts.next() orelse return null;
    const minor_text = parts.next() orelse return null;
    var minor_end: usize = 0;
    while (minor_end < minor_text.len and std.ascii.isDigit(minor_text[minor_end])) minor_end += 1;
    return .{
        .major = std.fmt.parseInt(u32, major, 10) catch return null,
        .minor = std.fmt.parseInt(u32, minor_text[0..minor_end], 10) catch return null,
    };
}

/// The kernel when it is older than `kernel_version_min`.
pub fn kernel_refusal(release: []const u8) ?Version {
    const version = kernel_version_parse(release) orelse return null;
    return if (version.less_than(kernel_version_min)) version else null;
}

/// Refuses (NRV-E0705) on a kernel below `kernel_version_min`. Before the first `IO.init`.
pub fn kernel_check() void {
    if (builtin.os.tag != .linux) return;
    const uname = posix.uname();
    const release = std.mem.sliceTo(&uname.release, 0);
    const version = kernel_refusal(release) orelse return;
    diagnostic.fail(
        "NRV-E0705",
        "{s}: the kernel is {}.{}; Nerva needs {}.{} or newer",
        .{ diagnostic.command, version.major, version.minor, kernel_version_min.major, kernel_version_min.minor },
        "upgrade the kernel (uname -r says {s})",
        .{release},
    );
}

/// Checks the data file `path` that `nerva start` is about to open. Returns the refusal, or null
/// when the vendored open should succeed. An I/O error reading the file is the caller's.
pub fn open_check(
    gpa: std.mem.Allocator,
    path: []const u8,
    direct_io: DirectIO,
) !?Refusal {
    if (builtin.os.tag != .linux) return null;

    const fd = posix.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer posix.close(fd);

    const stat = try posix.fstat(fd);
    if (!posix.S.ISREG(stat.mode) and !posix.S.ISBLK(stat.mode)) return .not_a_file;

    if (!try lock_free(fd)) return .locked;
    if (try superblock_refusal(gpa, fd)) |refusal| return refusal;
    if (direct_io == .required and posix.S.ISREG(stat.mode) and
        !try direct_io_supported(path, fd)) return .direct_io_unsupported;
    return null;
}

/// True if no other open file description holds the lock; takes it and drops it at once.
fn lock_free(fd: posix.fd_t) !bool {
    for (0..lock_attempts) |_| {
        posix.flock(fd, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
            error.WouldBlock => {
                std.time.sleep(lock_retry_ms * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        try posix.flock(fd, posix.LOCK.UN);
        return true;
    }
    return false;
}

fn superblock_refusal(gpa: std.mem.Allocator, fd: posix.fd_t) !?Refusal {
    const copies = try gpa.create([constants.superblock_copies]SuperBlockHeader);
    defer gpa.destroy(copies);
    for (copies, 0..) |*copy, index| {
        const bytes = std.mem.asBytes(copy);
        const offset = superblock.superblock_copy_size * index;
        // A file shorter than its superblock zone reads short: the rest is zeros, which have no
        // valid checksum, so the copy is not counted.
        const count = try posix.pread(fd, bytes, offset);
        @memset(bytes[count..], 0);
    }
    var quorums = superblock.Quorums{};
    const quorum = quorums.working(copies, .open) catch |err| return .{ .damaged = @errorName(err) };
    const header = quorum.header;
    if (header.version != superblock.SuperBlockVersion) return .{ .damaged = "IncompatibleVersion" };
    const release = header.vsr_state.checkpoint.release;
    if (release.value != constants.config.process.release.value) return .{ .other_release = release };
    return null;
}

/// As the vendored open decides it, but on the file itself: `O_DIRECT` is refused with
/// `EINVAL` where it is not supported. tmpfs is allowed, as the vendored open allows it.
fn direct_io_supported(path: []const u8, fd: posix.fd_t) !bool {
    if (!@hasField(posix.O, "DIRECT")) return false;
    var statfs: stdx.StatFs = undefined;
    while (true) {
        switch (std.os.linux.E.init(stdx.fstatfs(fd, &statfs))) {
            .SUCCESS => break,
            .INTR => continue,
            else => |err| return stdx.unexpected_errno("preflight statfs", err),
        }
    }
    if (statfs.f_type == stdx.TmpfsMagic) return true;
    // `posix.open` has no error for `EINVAL`; ask the kernel directly, as the vendored probe does.
    const flags: posix.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECT = true };
    const path_z = try posix.toPosixPath(path);
    while (true) {
        const result = std.os.linux.open(&path_z, flags, 0);
        switch (std.os.linux.E.init(result)) {
            .SUCCESS => {
                posix.close(@intCast(result));
                return true;
            },
            .INTR => continue,
            .INVAL => return false,
            else => |err| return stdx.unexpected_errno("preflight direct io", err),
        }
    }
}

/// Refuses with the code for `refusal`; never returns.
pub fn refuse(path: []const u8, refusal: Refusal) noreturn {
    switch (refusal) {
        .missing => diagnostic.fail(
            "NRV-E0006",
            "{s}: {s} does not exist",
            .{ diagnostic.command, path },
            "run nerva format first, or fix the path",
            .{},
        ),
        .not_a_file => diagnostic.fail(
            "NRV-E0702",
            "{s}: {s} is not a file or a block device",
            .{ diagnostic.command, path },
            "check the path",
            .{},
        ),
        .damaged => |reason| diagnostic.fail(
            "NRV-E0702",
            "{s}: {s} has no usable superblock ({s})",
            .{ diagnostic.command, path, reason },
            "check the path; restore the replica from a backup, or replace it",
            .{},
        ),
        .other_release => |release| diagnostic.fail(
            "NRV-E0701",
            "{s}: {s} was written by release {}, and this is release {}",
            .{ diagnostic.command, path, release, constants.config.process.release },
            "upgrade by export and import (README, \"Upgrading a cluster\"); nothing was changed",
            .{},
        ),
        .locked => diagnostic.fail(
            "NRV-E0703",
            "{s}: another process holds {s}",
            .{ diagnostic.command, path },
            "stop the other replica that uses this data file",
            .{},
        ),
        .direct_io_unsupported => diagnostic.fail(
            "NRV-E0704",
            "{s}: the file system of {s} does not support direct IO",
            .{ diagnostic.command, path },
            "put the data file on ext4 or XFS, or pass --development for a throwaway replica",
            .{},
        ),
    }
}

/// The pre-flight of `nerva start`: refuses or returns.
pub fn start(gpa: std.mem.Allocator, path: []const u8, direct_io: DirectIO) void {
    const refusal = open_check(gpa, path, direct_io) catch |err| diagnostic.fail_file(path, err);
    if (refusal) |reason| refuse(path, reason);
}

const testing = std.testing;

test "preflight: kernel versions" {
    try testing.expectEqual(Version{ .major = 6, .minor = 8 }, kernel_version_parse("6.8.0-45-generic").?);
    try testing.expectEqual(Version{ .major = 5, .minor = 4 }, kernel_version_parse("5.4.0").?);
    try testing.expectEqual(Version{ .major = 6, .minor = 18 }, kernel_version_parse("6.18.44-fc-v236").?);
    try testing.expect(kernel_version_parse("weird") == null);
    try testing.expect(kernel_refusal("5.10.200") != null);
    try testing.expect(kernel_refusal("5.11.0") == null);
    try testing.expect(kernel_refusal("4.19.0") != null);
    try testing.expect(kernel_refusal("6.1.0") == null);
}

test "preflight: a missing file, a directory, zeros, a short file" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buffer);
    const gpa = testing.allocator;

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(&path_buffer, "{s}/missing", .{dir});
    try testing.expect((try open_check(gpa, missing, .disabled)).? == .missing);

    const zeros = try std.fmt.bufPrint(&path_buffer, "{s}/zeros", .{dir});
    {
        const file = try std.fs.createFileAbsolute(zeros, .{});
        defer file.close();
        try file.setEndPos(superblock.superblock_zone_size);
    }
    try testing.expect((try open_check(gpa, zeros, .disabled)).? == .damaged);

    const short = try std.fmt.bufPrint(&path_buffer, "{s}/short", .{dir});
    {
        const file = try std.fs.createFileAbsolute(short, .{});
        defer file.close();
        try file.writeAll("not a data file");
    }
    try testing.expect((try open_check(gpa, short, .disabled)).? == .damaged);

    const empty = try std.fmt.bufPrint(&path_buffer, "{s}/empty", .{dir});
    (try std.fs.createFileAbsolute(empty, .{})).close();
    try testing.expect((try open_check(gpa, empty, .disabled)).? == .damaged);
}

test "preflight: a held lock" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/held", .{dir});
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try posix.flock(file.handle, posix.LOCK.EX | posix.LOCK.NB);
    try testing.expect((try open_check(testing.allocator, path, .disabled)).? == .locked);
    try posix.flock(file.handle, posix.LOCK.UN);
    // Free: the next check goes on to the superblock, which an empty file lacks.
    try testing.expect((try open_check(testing.allocator, path, .disabled)).? == .damaged);
}

test "preflight: a lock released within the wait is not refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/lingering", .{dir});
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try posix.flock(file.handle, posix.LOCK.EX | posix.LOCK.NB);
    // Another thread frees the lock after 1 s, beyond the vendored open's 250 ms, as the kernel
    // does when it finishes tearing a killed process's ring down.
    const releaser = try std.Thread.spawn(.{}, struct {
        fn run(fd: posix.fd_t) void {
            std.time.sleep(1000 * std.time.ns_per_ms);
            posix.flock(fd, posix.LOCK.UN) catch @panic("unlock");
        }
    }.run, .{file.handle});
    defer releaser.join();
    // Free by then: the check goes on to the superblock, which an empty file lacks.
    try testing.expect((try open_check(testing.allocator, path, .disabled)).? == .damaged);
}

test "preflight: every refusal has a registered code and a message" {
    // Rendering must not trip an assertion; `refuse` exits, so render through the table.
    inline for (.{ "NRV-E0006", "NRV-E0701", "NRV-E0702", "NRV-E0703", "NRV-E0704", "NRV-E0705" }) |code| {
        var found = false;
        for (diagnostic.table) |candidate| {
            if (std.mem.eql(u8, candidate.code, code)) found = true;
        }
        try testing.expect(found);
    }
}
