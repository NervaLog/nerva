//! The memory a replica may use, read once at start (R3 slice 2, P406d).
//!
//! `nerva start` allocates every cache before it serves anything. A replica whose caches exceed
//! what the machine or its cgroup allows is OOM-killed with no message of Nerva's. So `start`
//! reads what it can see and budgets its allocator to that, less `memory_reserve`: an allocation
//! past the budget fails before the memory is touched, and `command_start` reports it as
//! NRV-E0723.
//!
//! What it can see is the smallest of `MemTotal` (`/proc/meminfo`) and every cgroup limit from
//! the process's cgroup up to the root (a limit is often on an ancestor: a systemd slice, a pod
//! above its container):
//!
//! - v2: the `0::<path>` line of `/proc/self/cgroup`; `memory.max` at `<path>` and each parent,
//!   `max` meaning no limit at that level.
//! - v1: the line whose controllers include `memory`; `memory.limit_in_bytes` at each level, a
//!   value of at least 2^62 meaning no limit (v1 reports 9223372036854771712).
//! - A `<path>` that is not under the mount (a container without a cgroup namespace) reads the
//!   mount root's limit alone.
//!
//! A file that is absent is no limit at its level. One that cannot be parsed, is over
//! `file_size_max`, or sits deeper than `cgroup_depth_max` is a refusal naming the file, never a
//! guess. Every read takes a root directory, so that tests use a fake `/proc` and `/sys`.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const stdx = @import("stdx");
const MemoryBudget = @import("api/memory_budget.zig");

/// What the process beyond its counted allocations needs: the binary, stacks, page tables, the
/// `Tracer`, `IO` and `Storage` allocated before `command_start`, and the base allocator's page
/// rounding and THP (#127: about 10 MiB at the defaults; the rest is margin).
pub const memory_reserve: u64 = 256 * stdx.MiB;
/// The most of one `/proc` or cgroup file read; a longer file is a refusal.
pub const file_size_max = 4096;
/// The most levels walked, the root included; a deeper cgroup is a refusal.
pub const cgroup_depth_max = 32;
/// v1 reports "no limit" as a value at or above this.
const v1_unlimited_min: u64 = 1 << 62;
const path_size_max = 512;
/// The longest file name read: a cgroup path of `path_size_max`, the longer base
/// (`sys/fs/cgroup/memory`), the longer file (`memory.limit_in_bytes`) and two slashes, with room.
const name_size_max = path_size_max + 64;

pub const Source = enum { meminfo, cgroup_v2, cgroup_v1 };

/// Where the smallest limit came from.
pub const Visible = struct {
    bytes: u64,
    source: Source,
    /// For a cgroup: its `memory.max` or `memory.limit_in_bytes` level, as a cgroup path
    /// (`/system.slice/run-r1.scope`; `/` for the root). Empty for `meminfo`.
    path_buffer: [path_size_max]u8 = undefined,
    path_length: usize = 0,

    pub fn path(self: *const Visible) []const u8 {
        return self.path_buffer[0..self.path_length];
    }

    pub fn file_name(self: *const Visible) []const u8 {
        return switch (self.source) {
            .meminfo => "MemTotal",
            .cgroup_v2 => "memory.max",
            .cgroup_v1 => "memory.limit_in_bytes",
        };
    }
};

/// Why a file could not be used: `absent` (a /proc or a controller directory that is not there),
/// `unreadable` (it is there and cannot be read), the rest are about what it holds.
pub const Reason = enum { unparsable, too_large, too_deep, absent, unreadable };

/// A file the walk could not use: named, never guessed around.
pub const Refusal = struct {
    reason: Reason,
    file_buffer: [name_size_max]u8 = undefined,
    file_length: usize = 0,

    pub fn file(self: *const Refusal) []const u8 {
        return self.file_buffer[0..self.file_length];
    }
};

pub const Result = union(enum) {
    visible: Visible,
    refused: Refusal,
};

/// What `command_start` may allocate: what it can see less the reserve, or null when it can see
/// no more than the reserve (and so has nothing to allocate with).
pub fn budget(visible: u64) ?u64 {
    if (visible <= memory_reserve) return null;
    return visible - memory_reserve;
}

/// What a host without `/proc` and cgroups (macOS) is taken to see: no limit. P416b: only Linux
/// has the OOM killer this refusal answers, and the release targets include Macs.
pub const unlimited: u64 = 1 << 62;

/// Reads what this process can see from the real `/proc` and `/sys/fs/cgroup`.
pub fn read() Result {
    if (builtin.os.tag != .linux) return .{ .visible = .{ .bytes = unlimited, .source = .meminfo } };
    var root = std.fs.openDirAbsolute("/", .{}) catch return refuse(.unreadable, "/");
    defer root.close();
    return read_from(root);
}

/// `read` over any root directory holding `proc/` and `sys/fs/cgroup/`.
pub fn read_from(root: std.fs.Dir) Result {
    var buffer: [file_size_max + 1]u8 = undefined;

    // MemTotal: absent or unparsable is a refusal; a machine always has it.
    const meminfo = file_read(root, "proc/meminfo", &buffer) catch |err|
        return refuse(reason_of(err), "/proc/meminfo");
    const total = meminfo_total(meminfo orelse return refuse(.absent, "/proc/meminfo")) orelse
        return refuse(.unparsable, "/proc/meminfo");
    var result: Visible = .{ .bytes = total, .source = .meminfo };

    const cgroup_file = file_read(root, "proc/self/cgroup", &buffer) catch |err|
        return refuse(reason_of(err), "/proc/self/cgroup");
    const membership = cgroup_membership(cgroup_file orelse return .{ .visible = result }) orelse
        return .{ .visible = result };

    const base = switch (membership.source) {
        .cgroup_v2 => "sys/fs/cgroup",
        .cgroup_v1 => "sys/fs/cgroup/memory",
        .meminfo => unreachable,
    };
    const limit_file = switch (membership.source) {
        .cgroup_v2 => "memory.max",
        .cgroup_v1 => "memory.limit_in_bytes",
        .meminfo => unreachable,
    };

    // A path not under the mount (no cgroup namespace): the mount root's limit alone.
    // `membership.path` points into `buffer`, which the reads below reuse: keep a copy.
    var path_buffer: [name_size_max]u8 = undefined;
    var cgroup_buffer: [path_size_max]u8 = undefined;
    if (membership.path.len > path_size_max) {
        return refuse(.too_large, "/proc/self/cgroup");
    }
    // A v1 `memory` line with no `memory` directory: the controller is mounted somewhere this
    // walk does not look (`cpu,memory`), and no limit may be guessed.
    if (membership.source == .cgroup_v1 and !dir_exists(root, base, "/", &path_buffer)) {
        return refuse(.absent, "/sys/fs/cgroup/memory");
    }
    @memcpy(cgroup_buffer[0..membership.path.len], membership.path);
    const cgroup_path = cgroup_buffer[0..membership.path.len];
    const under_mount = dir_exists(root, base, cgroup_path, &path_buffer);
    const walk_path: []const u8 = if (under_mount) cgroup_path else "/";

    // From the process's cgroup up to the root, `levels` counting the root.
    var levels: u32 = 1;
    for (walk_path) |byte| {
        if (byte == '/') levels += 1;
    }
    if (std.mem.eql(u8, walk_path, "/")) levels = 1;
    if (levels > cgroup_depth_max) {
        return refuse(.too_deep, join(&path_buffer, base, walk_path, ""));
    }

    var level_path: []const u8 = walk_path;
    while (true) {
        var file_buffer: [name_size_max]u8 = undefined;
        const name = join(&file_buffer, base, level_path, limit_file);
        const content = file_read(root, name, &buffer) catch |err|
            return refuse(reason_of(err), name);
        if (content) |text| {
            if (limit_parse(text, membership.source)) |parsed| {
                if (parsed) |limit| {
                    if (limit < result.bytes) {
                        result.bytes = limit;
                        result.source = membership.source;
                        assert(level_path.len <= path_size_max);
                        @memcpy(result.path_buffer[0..level_path.len], level_path);
                        result.path_length = level_path.len;
                    }
                }
            } else return refuse(.unparsable, name);
        }
        if (std.mem.eql(u8, level_path, "/")) break;
        level_path = parent(level_path);
    }
    return .{ .visible = result };
}

const Membership = struct { source: Source, path: []const u8 };

/// The line of `/proc/self/cgroup` that carries memory: v1's `N:<controllers>:<path>` whose
/// controllers include `memory`, else v2's `0::<path>`. Null if neither.
fn cgroup_membership(text: []const u8) ?Membership {
    var v2: ?Membership = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const hierarchy = fields.next() orelse continue;
        const controllers = fields.next() orelse continue;
        const path = fields.rest();
        if (path.len == 0 or path[0] != '/') continue;
        if (std.mem.eql(u8, hierarchy, "0") and controllers.len == 0) {
            v2 = .{ .source = .cgroup_v2, .path = path };
            continue;
        }
        var names = std.mem.splitScalar(u8, controllers, ',');
        while (names.next()) |name| {
            if (std.mem.eql(u8, name, "memory")) return .{ .source = .cgroup_v1, .path = path };
        }
    }
    return v2;
}

/// `MemTotal:  16384000 kB` in bytes, or null if absent or malformed.
fn meminfo_total(text: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemTotal:")) continue;
        var fields = std.mem.tokenizeAny(u8, line["MemTotal:".len..], " \t");
        const number = fields.next() orelse return null;
        const unit = fields.next() orelse return null;
        if (!std.mem.eql(u8, unit, "kB") or fields.next() != null) return null;
        const kib = std.fmt.parseInt(u64, number, 10) catch return null;
        return std.math.mul(u64, kib, 1024) catch null;
    }
    return null;
}

/// A cgroup limit: outer null if the text is not one; inner null if the level has no limit.
fn limit_parse(text: []const u8, source: Source) ??u64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (source == .cgroup_v2 and std.mem.eql(u8, trimmed, "max")) return @as(?u64, null);
    const value = std.fmt.parseInt(u64, trimmed, 10) catch return null;
    if (source == .cgroup_v1 and value >= v1_unlimited_min) return @as(?u64, null);
    return @as(?u64, value);
}

const ReadError = error{ TooLarge, Unreadable };

fn reason_of(err: ReadError) Reason {
    return switch (err) {
        error.TooLarge => .too_large,
        error.Unreadable => .unreadable,
    };
}

/// The file's bytes (at most `file_size_max`), null if it does not exist.
fn file_read(root: std.fs.Dir, name: []const u8, buffer: *[file_size_max + 1]u8) ReadError!?[]const u8 {
    const file = root.openFile(name, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return error.Unreadable,
    };
    defer file.close();
    const length = file.readAll(buffer) catch return error.Unreadable;
    if (length > file_size_max) return error.TooLarge;
    return buffer[0..length];
}

fn dir_exists(root: std.fs.Dir, base: []const u8, path: []const u8, buffer: *[name_size_max]u8) bool {
    const name = join(buffer, base, path, "");
    var dir = root.openDir(name, .{}) catch return false;
    dir.close();
    return true;
}

/// `<base>/<path>/<file>` without a doubled slash. It always fits: `path` is at most
/// `path_size_max` (checked by the caller), and `name_size_max` has room for the rest.
fn join(buffer: *[name_size_max]u8, base: []const u8, path: []const u8, file: []const u8) []const u8 {
    assert(path.len <= path_size_max);
    const trimmed = std.mem.trim(u8, path, "/");
    const text = if (trimmed.len == 0)
        std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ base, if (file.len > 0) "/" else "", file })
    else
        std.fmt.bufPrint(buffer, "{s}/{s}{s}{s}", .{ base, trimmed, if (file.len > 0) "/" else "", file });
    return text catch unreachable;
}

fn parent(path: []const u8) []const u8 {
    assert(path.len > 0 and path[0] == '/');
    const end = std.mem.lastIndexOfScalar(u8, path, '/').?;
    return if (end == 0) "/" else path[0..end];
}

fn refuse(reason: Reason, file: []const u8) Result {
    var refusal: Refusal = .{ .reason = reason };
    const length = @min(file.len, name_size_max);
    @memcpy(refusal.file_buffer[0..length], file[0..length]);
    refusal.file_length = length;
    return .{ .refused = refusal };
}

// Tests build a fake root: `proc/meminfo`, `proc/self/cgroup` and `sys/fs/cgroup/...`.

const Fixture = struct {
    tmp: std.testing.TmpDir,

    fn init() Fixture {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, name: []const u8, content: []const u8) !void {
        if (std.fs.path.dirname(name)) |dirname| try self.tmp.dir.makePath(dirname);
        try self.tmp.dir.writeFile(.{ .sub_path = name, .data = content });
    }

    fn meminfo(self: *Fixture, kib: u64) !void {
        var text: [64]u8 = undefined;
        try self.write("proc/meminfo", try std.fmt.bufPrint(&text, "MemTotal:       {d} kB\nMemFree: 1 kB\n", .{kib}));
    }
};

const mib = stdx.MiB;

test "start_memory: MemTotal alone when the process has no cgroup file" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.meminfo(8 * 1024 * 1024);
    const result = read_from(fixture.tmp.dir);
    try std.testing.expectEqual(@as(u64, 8 * 1024 * mib), result.visible.bytes);
    try std.testing.expectEqual(Source.meminfo, result.visible.source);
}

test "start_memory: v2 limit on its own cgroup" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.meminfo(8 * 1024 * 1024);
    try fixture.write("proc/self/cgroup", "0::/system.slice/run-r1.scope\n");
    try fixture.write("sys/fs/cgroup/system.slice/run-r1.scope/memory.max", "3221225472\n");
    const result = read_from(fixture.tmp.dir);
    try std.testing.expectEqual(@as(u64, 3072 * mib), result.visible.bytes);
    try std.testing.expectEqual(Source.cgroup_v2, result.visible.source);
    try std.testing.expectEqualStrings("/system.slice/run-r1.scope", result.visible.path());
}

test "start_memory: v2 limit on an ancestor only" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.meminfo(8 * 1024 * 1024);
    try fixture.write("proc/self/cgroup", "0::/a/b/c\n");
    try fixture.write("sys/fs/cgroup/a/b/c/memory.max", "max\n");
    try fixture.write("sys/fs/cgroup/a/b/memory.max", "max\n");
    try fixture.write("sys/fs/cgroup/a/memory.max", "1073741824\n");
    const result = read_from(fixture.tmp.dir);
    try std.testing.expectEqual(@as(u64, 1024 * mib), result.visible.bytes);
    try std.testing.expectEqualStrings("/a", result.visible.path());
}

test "start_memory: v2 max everywhere is MemTotal; the smaller of two limits wins" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.meminfo(2 * 1024 * 1024);
    try fixture.write("proc/self/cgroup", "0::/a/b\n");
    try fixture.write("sys/fs/cgroup/a/b/memory.max", "max\n");
    try fixture.write("sys/fs/cgroup/a/memory.max", "max\n");
    try fixture.write("sys/fs/cgroup/memory.max", "max\n");
    try std.testing.expectEqual(Source.meminfo, read_from(fixture.tmp.dir).visible.source);

    try fixture.write("sys/fs/cgroup/a/b/memory.max", "1610612736\n");
    try fixture.write("sys/fs/cgroup/a/memory.max", "1073741824\n");
    const result = read_from(fixture.tmp.dir);
    try std.testing.expectEqual(@as(u64, 1024 * mib), result.visible.bytes);

    // A limit above MemTotal is not the smallest.
    try fixture.write("sys/fs/cgroup/a/memory.max", "9999999999999\n");
    try std.testing.expectEqual(@as(u64, 1536 * mib), read_from(fixture.tmp.dir).visible.bytes);
}

test "start_memory: a path not under the mount reads the mount root alone" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.meminfo(8 * 1024 * 1024);
    try fixture.write("proc/self/cgroup", "0::/elsewhere/deep\n");
    try fixture.write("sys/fs/cgroup/memory.max", "2147483648\n");
    const result = read_from(fixture.tmp.dir);
    try std.testing.expectEqual(@as(u64, 2048 * mib), result.visible.bytes);
    try std.testing.expectEqualStrings("/", result.visible.path());
}

test "start_memory: v1 limit, and its unlimited sentinel" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.meminfo(8 * 1024 * 1024);
    try fixture.write("proc/self/cgroup", "12:cpu,cpuacct:/x\n4:memory:/docker/abc\n1:name=systemd:/x\n");
    try fixture.write("sys/fs/cgroup/memory/docker/abc/memory.limit_in_bytes", "9223372036854771712\n");
    try fixture.write("sys/fs/cgroup/memory/docker/memory.limit_in_bytes", "536870912\n");
    const result = read_from(fixture.tmp.dir);
    try std.testing.expectEqual(@as(u64, 512 * mib), result.visible.bytes);
    try std.testing.expectEqual(Source.cgroup_v1, result.visible.source);
    try std.testing.expectEqualStrings("/docker", result.visible.path());

    // 2^62 exactly is the sentinel; one below it is a limit (larger than MemTotal here).
    try fixture.write("sys/fs/cgroup/memory/docker/memory.limit_in_bytes", "4611686018427387904\n");
    try std.testing.expectEqual(Source.meminfo, read_from(fixture.tmp.dir).visible.source);
    try fixture.write("sys/fs/cgroup/memory/docker/memory.limit_in_bytes", "4611686018427387903\n");
    try std.testing.expectEqual(Source.meminfo, read_from(fixture.tmp.dir).visible.source);
}

test "start_memory: unparsable and oversized files are refusals naming the file" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.meminfo(8 * 1024 * 1024);
    try fixture.write("proc/self/cgroup", "0::/a\n");
    try fixture.write("sys/fs/cgroup/a/memory.max", "lots\n");
    const bad = read_from(fixture.tmp.dir);
    try std.testing.expectEqual(Reason.unparsable, bad.refused.reason);
    try std.testing.expectEqualStrings("sys/fs/cgroup/a/memory.max", bad.refused.file());

    // 4,096 bytes are read; 4,097 are a refusal.
    var text: [file_size_max + 1]u8 = undefined;
    @memset(&text, ' ');
    @memcpy(text[0..4], "4096");
    try fixture.write("sys/fs/cgroup/a/memory.max", text[0..file_size_max]);
    try std.testing.expectEqual(@as(u64, 4096), read_from(fixture.tmp.dir).visible.bytes);
    try fixture.write("sys/fs/cgroup/a/memory.max", text[0 .. file_size_max + 1]);
    const large = read_from(fixture.tmp.dir);
    try std.testing.expectEqual(Reason.too_large, large.refused.reason);

    try fixture.write("sys/fs/cgroup/a/memory.max", "max\n");
    try fixture.write("proc/meminfo", "MemTotal: lots kB\n");
    try std.testing.expectEqual(Reason.unparsable, read_from(fixture.tmp.dir).refused.reason);
}

test "start_memory: 32 levels are walked and 33 are a refusal" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.meminfo(8 * 1024 * 1024);

    // The root counts as a level: 31 directories below it make 32.
    var path: [128]u8 = undefined;
    var length: usize = 0;
    var depth: u32 = 0;
    while (depth < cgroup_depth_max - 1) : (depth += 1) {
        path[length] = '/';
        path[length + 1] = 'd';
        length += 2;
    }
    var name: [256]u8 = undefined;
    try fixture.write("proc/self/cgroup", try std.fmt.bufPrint(&name, "0::{s}\n", .{path[0..length]}));
    try fixture.write(try std.fmt.bufPrint(&name, "sys/fs/cgroup{s}/memory.max", .{path[0..length]}), "1073741824\n");
    try std.testing.expectEqual(@as(u64, 1024 * mib), read_from(fixture.tmp.dir).visible.bytes);

    path[length] = '/';
    path[length + 1] = 'd';
    length += 2;
    try fixture.write("proc/self/cgroup", try std.fmt.bufPrint(&name, "0::{s}\n", .{path[0..length]}));
    try fixture.write(try std.fmt.bufPrint(&name, "sys/fs/cgroup{s}/memory.max", .{path[0..length]}), "1073741824\n");
    try std.testing.expectEqual(Reason.too_deep, read_from(fixture.tmp.dir).refused.reason);
}

test "start_memory: the budget is what it sees less the reserve, and refuses at the reserve" {
    try std.testing.expectEqual(@as(?u64, null), budget(0));
    try std.testing.expectEqual(@as(?u64, null), budget(memory_reserve));
    try std.testing.expectEqual(@as(?u64, 1), budget(memory_reserve + 1));
    try std.testing.expectEqual(@as(?u64, 2816 * mib), budget(3072 * mib));
}

test "start_memory: through MemoryBudget, a cgroup at budget + reserve fits and one byte under does not" {
    const wanted = 4096;
    const fits = budget(memory_reserve + wanted).?;
    var counting = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = counting.deinit();
    var at = MemoryBudget.init(counting.allocator(), fits);
    const block = try at.allocator().alloc(u8, wanted);
    at.allocator().free(block);
    try std.testing.expect(!at.exceeded);

    var under = MemoryBudget.init(counting.allocator(), budget(memory_reserve + wanted - 1).?);
    try std.testing.expectError(error.OutOfMemory, under.allocator().alloc(u8, wanted));
    try std.testing.expect(under.exceeded);
}

test "start_memory: the real machine can be read" {
    const result = read();
    switch (result) {
        .visible => |visible| try std.testing.expect(visible.bytes > 0),
        .refused => {},
    }
}

test "start_memory: a host without /proc is unlimited, with room for the reserve" {
    try std.testing.expect(budget(unlimited) != null);
    try std.testing.expect(budget(unlimited).? > 1 << 61);
}

test "start_memory: a 500-byte cgroup path is read in full, never truncated into no limit" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.meminfo(8 * 1024 * 1024);
    // 500 bytes: more than 470, where the joined v1 name used to overflow 512.
    var path: [500]u8 = undefined;
    @memset(&path, 'c');
    var at: usize = 0;
    while (at < path.len) : (at += 100) path[at] = '/';
    var name: [1200]u8 = undefined;
    try fixture.write("proc/self/cgroup", try std.fmt.bufPrint(&name, "4:memory:{s}\n", .{path[0..]}));
    // 5 levels of 100 bytes: the process's own level carries the limit.
    try fixture.write(try std.fmt.bufPrint(&name, "sys/fs/cgroup/memory{s}/memory.limit_in_bytes", .{path[0..]}), "1073741824\n");
    const result = read_from(fixture.tmp.dir);
    try std.testing.expectEqual(@as(u64, 1024 * mib), result.visible.bytes);
    try std.testing.expectEqual(Source.cgroup_v1, result.visible.source);

    // 513 bytes is a refusal, not a guess.
    var long: [513]u8 = undefined;
    @memset(&long, 'c');
    long[0] = '/';
    try fixture.write("proc/self/cgroup", try std.fmt.bufPrint(&name, "4:memory:{s}\n", .{long[0..]}));
    try std.testing.expectEqual(Reason.too_large, read_from(fixture.tmp.dir).refused.reason);
}

test "start_memory: absent and unreadable files are told apart from unparsable ones" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    // No /proc at all (a chroot): absent.
    const none = read_from(fixture.tmp.dir);
    try std.testing.expectEqual(Reason.absent, none.refused.reason);
    try std.testing.expectEqualStrings("/proc/meminfo", none.refused.file());

    // A directory where a file belongs cannot be read: unreadable.
    try fixture.tmp.dir.makePath("proc/meminfo");
    try std.testing.expectEqual(Reason.unreadable, read_from(fixture.tmp.dir).refused.reason);
    try fixture.tmp.dir.deleteTree("proc/meminfo");

    // A v1 `memory` line with no memory directory: the controller is mounted elsewhere.
    try fixture.meminfo(8 * 1024 * 1024);
    try fixture.write("proc/self/cgroup", "4:cpu,memory:/a\n");
    const elsewhere = read_from(fixture.tmp.dir);
    try std.testing.expectEqual(Reason.absent, elsewhere.refused.reason);
    try std.testing.expectEqualStrings("/sys/fs/cgroup/memory", elsewhere.refused.file());
}
