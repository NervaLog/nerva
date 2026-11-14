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
/// the lock is refused as held (NRV-E0703). A lock whose holder `/proc/locks` shows alive is
/// refused at the first attempt, naming its pid (#294, P431).
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
    /// Held by another process: the pid of the live holder `/proc/locks` showed, else null.
    locked: ?posix.pid_t,
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

    switch (try lock_wait(&LockProbe{ .fd = fd, .stat = stat })) {
        .free => {},
        .held => |pid| return .{ .locked = pid },
    }
    if (try superblock_refusal(gpa, fd)) |refusal| return refusal;
    if (direct_io == .required and posix.S.ISREG(stat.mode) and
        !try direct_io_supported(path, fd)) return .direct_io_unsupported;
    return null;
}

/// The outcome of waiting for the data file's lock.
const LockWait = union(enum) {
    free,
    /// Still held: by this live process, or by one `/proc/locks` did not show alive (null).
    held: ?posix.pid_t,
};

/// Waits for no other open file description to hold the lock, taking it and dropping it at once.
/// `probe` has `try_lock() !bool` (true: taken and dropped), `live_holder() ?pid` and `sleep()`.
/// A live holder ends the wait at once; otherwise at most `lock_attempts` attempts, none followed
/// by a sleep after the last.
fn lock_wait(probe: anytype) !LockWait {
    for (0..lock_attempts) |attempt| {
        if (try probe.try_lock()) return .free;
        if (probe.live_holder()) |pid| return .{ .held = pid };
        if (attempt + 1 < lock_attempts) probe.sleep();
    }
    return .{ .held = null };
}

const LockProbe = struct {
    fd: posix.fd_t,
    stat: posix.Stat,

    fn try_lock(probe: *const LockProbe) !bool {
        posix.flock(probe.fd, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return err,
        };
        try posix.flock(probe.fd, posix.LOCK.UN);
        return true;
    }

    /// The pid `/proc/locks` shows holding this file's `flock`, if that process is alive. Null
    /// when it is gone, or when this cannot be told (not Linux, `/proc/locks` unreadable or over
    /// `proc_locks_size_max`, a file system whose device `/proc/locks` names differently): the
    /// caller then keeps the bounded wait.
    fn live_holder(probe: *const LockProbe) ?posix.pid_t {
        if (!posix.S.ISREG(probe.stat.mode)) return null;
        var buffer: [proc_locks_size_max + 1]u8 = undefined;
        const file = std.fs.openFileAbsolute("/proc/locks", .{}) catch return null;
        defer file.close();
        const length = file.readAll(&buffer) catch return null;
        if (length > proc_locks_size_max) return null;
        const pid = proc_locks_holder(
            buffer[0..length],
            device_major(probe.stat.dev),
            device_minor(probe.stat.dev),
            probe.stat.ino,
        ) orelse return null;
        return if (process_alive(pid)) pid else null;
    }

    fn sleep(_: *const LockProbe) void {
        std.time.sleep(lock_retry_ms * std.time.ns_per_ms);
    }
};

/// The most of `/proc/locks` read; a longer table is not used.
const proc_locks_size_max = 1 << 16;

fn device_major(dev: u64) u32 {
    return @intCast(((dev >> 8) & 0xfff) | ((dev >> 32) & ~@as(u64, 0xfff)));
}

fn device_minor(dev: u64) u32 {
    return @intCast((dev & 0xff) | ((dev >> 12) & ~@as(u64, 0xff)));
}

/// The pid of the first `FLOCK` holder (not a waiter) of the file `major:minor:inode` in the text
/// of `/proc/locks` (`1: FLOCK  ADVISORY  WRITE 2145 00:27:20 0 EOF`), or null: no such lock, or
/// a pid of 0 (a holder in another pid namespace).
fn proc_locks_holder(text: []const u8, major: u32, minor: u32, inode: u64) ?posix.pid_t {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // "1:"
        const kind = fields.next() orelse continue;
        if (!std.mem.eql(u8, kind, "FLOCK")) continue; // also skips a waiter's "->"
        _ = fields.next() orelse continue; // ADVISORY
        _ = fields.next() orelse continue; // WRITE
        const pid_text = fields.next() orelse continue;
        const file_text = fields.next() orelse continue;
        var parts = std.mem.splitScalar(u8, file_text, ':');
        const line_major = std.fmt.parseInt(u32, parts.next() orelse continue, 16) catch continue;
        const line_minor = std.fmt.parseInt(u32, parts.next() orelse continue, 16) catch continue;
        const line_inode = std.fmt.parseInt(u64, parts.next() orelse continue, 10) catch continue;
        if (parts.next() != null) continue;
        if (line_major != major or line_minor != minor or line_inode != inode) continue;
        const pid = std.fmt.parseInt(posix.pid_t, pid_text, 10) catch continue;
        return if (pid > 0) pid else null;
    }
    return null;
}

/// Whether `pid` is a process that is not exiting: a zombie has released its files, so its lock
/// is only lingering (#288).
fn process_alive(pid: posix.pid_t) bool {
    posix.kill(pid, 0) catch |err| switch (err) {
        error.PermissionDenied => {},
        else => return false,
    };
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/proc/{}/stat", .{pid}) catch unreachable;
    const file = std.fs.openFileAbsolute(path, .{}) catch return true;
    defer file.close();
    var buffer: [512]u8 = undefined;
    const length = file.readAll(&buffer) catch return true;
    // `pid (comm) S ...`: the state follows the last ')', as comm may hold one.
    const close = std.mem.lastIndexOfScalar(u8, buffer[0..length], ')') orelse return true;
    if (close + 2 >= length) return true;
    return buffer[close + 2] != 'Z' and buffer[close + 2] != 'X';
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
        .locked => |holder| if (holder) |pid| diagnostic.fail(
            "NRV-E0703",
            "{s}: another process holds {s} (pid {})",
            .{ diagnostic.command, path, pid },
            "stop the other replica that uses this data file",
            .{},
        ) else diagnostic.fail(
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

test "preflight: a lock held by a live process is refused at once, naming its pid" {
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
    const started = std.time.milliTimestamp();
    const refusal = (try open_check(testing.allocator, path, .disabled)).?;
    // The holder is this process: alive, so no 2 s wait. Skipped where /proc/locks does not name
    // the file (it then waits the bound and names no pid).
    if (refusal.locked) |pid| {
        try testing.expectEqual(std.os.linux.getpid(), pid);
        try testing.expect(std.time.milliTimestamp() - started < lock_wait_ms / 2);
    }
    try testing.expect(refusal == .locked);
    try posix.flock(file.handle, posix.LOCK.UN);
    // Free: the next check goes on to the superblock, which an empty file lacks.
    try testing.expect((try open_check(testing.allocator, path, .disabled)).? == .damaged);
}

/// A probe that frees the lock after `free_after` failed attempts, and counts what it is asked.
const FakeProbe = struct {
    free_after: u32,
    holder: ?posix.pid_t = null,
    tries: u32 = 0,
    sleeps: u32 = 0,

    fn try_lock(probe: *FakeProbe) !bool {
        probe.tries += 1;
        return probe.tries > probe.free_after;
    }

    fn live_holder(probe: *const FakeProbe) ?posix.pid_t {
        return probe.holder;
    }

    fn sleep(probe: *FakeProbe) void {
        probe.sleeps += 1;
    }
};

test "preflight: a lock whose holder is gone is retried up to the bound and no further" {
    // At the bound: free on the last attempt.
    var at = FakeProbe{ .free_after = lock_attempts - 1 };
    try testing.expect(try lock_wait(&at) == .free);
    try testing.expectEqual(@as(u32, lock_attempts), at.tries);
    try testing.expectEqual(@as(u32, lock_attempts - 1), at.sleeps);

    // One past it: refused after `lock_attempts` attempts, and no sleep after the last.
    var past = FakeProbe{ .free_after = lock_attempts };
    const waited = try lock_wait(&past);
    try testing.expect(waited == .held and waited.held == null);
    try testing.expectEqual(@as(u32, lock_attempts), past.tries);
    try testing.expectEqual(@as(u32, lock_attempts - 1), past.sleeps);

    // Free at once: no sleep.
    var now = FakeProbe{ .free_after = 0 };
    try testing.expect(try lock_wait(&now) == .free);
    try testing.expectEqual(@as(u32, 0), now.sleeps);
}

test "preflight: a lock whose holder is alive is refused on the first attempt" {
    var probe = FakeProbe{ .free_after = lock_attempts, .holder = 4242 };
    const waited = try lock_wait(&probe);
    try testing.expectEqual(@as(?posix.pid_t, 4242), waited.held);
    try testing.expectEqual(@as(u32, 1), probe.tries);
    try testing.expectEqual(@as(u32, 0), probe.sleeps);
}

test "preflight: /proc/locks names the holder of a file" {
    const text =
        "1: POSIX  ADVISORY  WRITE 900 08:01:77 0 EOF\n" ++
        "2: FLOCK  ADVISORY  WRITE 2145 00:27:20 0 EOF\n" ++
        "2: -> FLOCK  ADVISORY  WRITE 3000 00:27:20 0 EOF\n" ++
        "3: FLOCK  ADVISORY  WRITE 0 00:27:21 0 EOF\n" ++
        "4: OFDLCK ADVISORY  READ -1 00:27:22 0 EOF\n" ++
        "bad line\n";
    try testing.expectEqual(@as(?posix.pid_t, 2145), proc_locks_holder(text, 0, 0x27, 20));
    // Not that file, a POSIX lock, a holder in another pid namespace, no table.
    try testing.expectEqual(@as(?posix.pid_t, null), proc_locks_holder(text, 0, 0x27, 99));
    try testing.expectEqual(@as(?posix.pid_t, null), proc_locks_holder(text, 8, 1, 77));
    try testing.expectEqual(@as(?posix.pid_t, null), proc_locks_holder(text, 0, 0x27, 21));
    try testing.expectEqual(@as(?posix.pid_t, null), proc_locks_holder(text, 0, 0x27, 22));
    try testing.expectEqual(@as(?posix.pid_t, null), proc_locks_holder("", 0, 0, 1));
}

test "preflight: a process is alive unless it is gone" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try testing.expect(process_alive(std.os.linux.getpid()));
    // The kernel's pid_max is at most 2^22: above it, no such process.
    try testing.expect(!process_alive(1 << 23));
}

/// glibc's `makedev`, the inverse of the splits above.
fn makedev(major: u64, minor: u64) u64 {
    return ((major & 0xfff) << 8) | ((major & ~@as(u64, 0xfff)) << 32) |
        (minor & 0xff) | ((minor & ~@as(u64, 0xff)) << 12);
}

test "preflight: device numbers split as the kernel prints them" {
    // makedev(8, 1) and a device with a minor over 255.
    try testing.expectEqual(@as(u32, 8), device_major(makedev(8, 1)));
    try testing.expectEqual(@as(u32, 1), device_minor(makedev(8, 1)));
    try testing.expectEqual(@as(u32, 259), device_major(makedev(259, 300)));
    try testing.expectEqual(@as(u32, 300), device_minor(makedev(259, 300)));
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
