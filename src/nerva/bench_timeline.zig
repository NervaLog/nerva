//! The per-second timeline of `bench:load` (R3, docs/briefs/r3.md "`bench-load`: `--timeline`,
//! `--warmup` and the gateway's flags").
//!
//! Every operation belongs to the second in which it **ended**, counted from the run's start. An
//! operation that began before the end of the run but ended after it (up to the client timeout
//! later) belongs to no second: it is counted apart, as `late` (P414). Each
//! second holds a `LatencyHistogram` and the counters of its operations. The run's summary is the
//! merge of the seconds after the warm-up, so the warm-up's operations are left out of it (and of
//! its counters), and the lines `--timeline` writes merge back to exactly that histogram.
//!
//! Workers do not share a histogram: each has a `Recorder` that fills its current second and
//! merges it into the timeline, under a mutex, when its operations move to a later second (once a
//! second per worker). It lives under `src/nerva/` so that its tests run in `test:unit`;
//! `bench_load.zig` is an executable with no test root.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const vsr = @import("../vsr.zig");
const LatencyHistogram = @import("latency_histogram.zig").LatencyHistogram;

/// `--warmup` + `--seconds` at most: one timeline line a second for an hour, so at most
/// `seconds_max` histograms (about 4 KiB each) are held.
pub const seconds_max: u32 = 3_600;

/// What the operations of a second counted, besides their latencies.
pub const Counts = struct {
    requests: u64 = 0,
    entries: u64 = 0,
    conflicts: u64 = 0,
    retries: u64 = 0,
    /// Entries or requests refused for a reason other than a conflict.
    errors: u64 = 0,

    pub fn sub(after: Counts, before: Counts) Counts {
        return .{
            .requests = after.requests - before.requests,
            .entries = after.entries - before.entries,
            .conflicts = after.conflicts - before.conflicts,
            .retries = after.retries - before.retries,
            .errors = after.errors - before.errors,
        };
    }

    fn add(counts: *Counts, other: Counts) void {
        counts.requests += other.requests;
        counts.entries += other.entries;
        counts.conflicts += other.conflicts;
        counts.retries += other.retries;
        counts.errors += other.errors;
    }
};

const Second = struct {
    histogram: LatencyHistogram = .{},
    counts: Counts = .{},
};

pub const Summary = struct {
    histogram: LatencyHistogram = .{},
    counts: Counts = .{},
    /// Operations that ended after the run's last second: in no histogram and no counter.
    late: u64 = 0,
};

/// Why a file `--timeline` or `--gateway-pid-file` names cannot be written, in words (NRV-E0728).
pub fn path_error_reason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "its directory does not exist",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "it is a directory",
        error.NotDir => "a part of its path is not a directory",
        error.NameTooLong => "the path is too long",
        error.NoSpaceLeft => "no space left on the device",
        error.OutputsCollide => "another output flag names the same file",
        error.PathAlreadyExists => "every temporary file name next to it is taken",
        error.ReadOnlyFileSystem => "the file system is read-only",
        error.SymLinkLoop => "it is a loop of symbolic links",
        else => "it cannot be written",
    };
}

/// The process ID; `std.os.linux.getpid` is a raw Linux system call, so other systems ask libc.
fn process_id() std.posix.pid_t {
    return if (builtin.os.tag == .linux) std.os.linux.getpid() else std.c.getpid();
}

fn effective_user() std.posix.uid_t {
    return if (builtin.os.tag == .linux) std.os.linux.geteuid() else std.c.geteuid();
}

/// A file the run could not write, kept until the cluster and the gateway are torn down.
pub const FileFailure = struct {
    flag: []const u8,
    path: []const u8,
    err: anyerror,
    /// Where the finished result was kept instead (a copy: the `OutFile` is gone when this is
    /// reported); empty if it was not.
    kept_buffer: [std.fs.max_path_bytes]u8 = undefined,
    kept_len: usize = 0,

    /// Records the failure of `out` at `flag`, with the temporary file it kept, if any.
    pub fn of(flag: []const u8, out: *const OutFile, err: anyerror) FileFailure {
        var failure: FileFailure = .{ .flag = flag, .path = out.requested, .err = err };
        if (out.kept_path()) |kept| {
            if (kept.len <= failure.kept_buffer.len) {
                @memcpy(failure.kept_buffer[0..kept.len], kept);
                failure.kept_len = kept.len;
            }
        }
        return failure;
    }

    /// The one NRV-E0728 line, on stderr.
    pub fn report(failure: *const FileFailure) void {
        const writer = std.io.getStdErr().writer();
        writer.print(
            "error[NRV-E0728]: bench-load: {s}: cannot write {s}: {s}",
            .{ failure.flag, failure.path, path_error_reason(failure.err) },
        ) catch {};
        if (failure.kept_len > 0) {
            writer.print("; the result is kept in {s}", .{failure.kept_buffer[0..failure.kept_len]}) catch {};
        }
        writer.writeAll("\n") catch {};
    }
};

/// An output file of `bench-load` (`--timeline`, `--gateway-pid-file`, `--output`) (P414b, P414c).
///
/// A path that is not there yet, or that names a regular file this process owns, with one link and
/// writable, is written as a temporary file in the same directory and renamed into place by
/// `finish`, so that the path holds either its earlier content or the whole new content. The
/// temporary file is created exclusively (`O_EXCL`, so a symbolic link planted at its name is never
/// followed) under a random name, retried a bounded number of times, and gets the file's permission
/// bits and group. Every other path is opened as a plain open for writing does: a file of another
/// owner (the rename would fail in a sticky directory, or change the owner), a file with several
/// links (the rename would break the link), a file in a directory that cannot be written, a
/// dangling symbolic link (it is followed) and anything that is not a regular file (a device such
/// as `/dev/full`, a pipe, a socket, `/dev/fd/N`). That open is **not atomic**, but, as on `main`,
/// it changes nothing until `finish`: the file is opened for writing (a missing one is created
/// empty) and truncated only when the finished result is written, so a run that fails leaves the
/// earlier content. A FIFO blocks the open until a reader opens it.
///
/// If the rename is refused at `finish` and the copy into the path fails too, the temporary file
/// is **kept** and `kept_path` names it, so that the result is not lost; the path itself may then
/// be emptied.
///
/// Between looking at a path and opening it another process may replace what it names; a benchmark
/// that writes into a directory someone else is renaming in is not defended against.
pub const OutFile = struct {
    file: std.fs.File,
    /// The path as given (borrowed, for messages).
    requested: []const u8,
    /// Where the content ends up (owned).
    final: []const u8,
    /// The temporary file, until `finish` or `deinit`; null for one written in place.
    temp: ?[]const u8,
    gpa: std.mem.Allocator,
    committed: bool = false,
    /// Whether `final` is a regular file (a reader may delete it), however it is written.
    regular_file: bool = false,
    /// The temporary file holds a result that could not be put at its path: `deinit` leaves it.
    kept: bool = false,

    /// How many temporary names are tried before the path is refused.
    pub const temp_attempts_max = 8;

    /// Opens (creating; changing no content) what `path` names, or returns the error that
    /// `path_error_reason` words (NRV-E0728).
    pub fn open(gpa: std.mem.Allocator, path: []const u8) !OutFile {
        var salts: [temp_attempts_max]u32 = undefined;
        std.crypto.random.bytes(std.mem.sliceAsBytes(&salts));
        return open_salted(gpa, path, &salts);
    }

    /// `open`, with the suffixes of the temporary names given (one attempt each).
    fn open_salted(gpa: std.mem.Allocator, path: []const u8, salts: []const u32) !OutFile {
        assert(salts.len > 0 and salts.len <= temp_attempts_max);
        // What `path` names is looked at as given: `/dev/stdout` resolves to `pipe:[N]` when
        // stdout is a pipe, which is no path to write.
        const found = look(path, 0);
        if (found) |st| {
            if (st.mode & std.posix.S.IFMT == std.posix.S.IFDIR) return error.IsDir;
        }
        const regular_file = if (found) |st| st.mode & std.posix.S.IFMT == std.posix.S.IFREG else true;
        const atomic = if (found) |st|
            regular_file and st.nlink == 1 and st.uid == effective_user() and
                access_writable(path)
        else
            // Nothing there: a dangling link is followed by a plain open, so it is not replaced.
            !is_link(path);
        if (atomic) {
            if (try open_temp(gpa, path, found, salts)) |out| return out;
        }
        // Not truncated: the earlier content stays until `finish`.
        const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
        errdefer file.close();
        // A link is followed, so that `stop` of a PID file deletes the file that was written, as
        // for a renamed one (P414c).
        const resolved: ?[]u8 = if (regular_file) std.fs.cwd().realpathAlloc(gpa, path) catch null else null;
        const final = resolved orelse try gpa.dupe(u8, path);
        return .{
            .file = file,
            .requested = path,
            .final = final,
            .temp = null,
            .gpa = gpa,
            .regular_file = regular_file,
        };
    }

    /// The temporary file for `path`, or null if its directory cannot be written (a plain open
    /// of the target is then the way, if it can be written at all).
    fn open_temp(
        gpa: std.mem.Allocator,
        path: []const u8,
        found: ?std.posix.Stat,
        salts: []const u32,
    ) !?OutFile {
        const resolved: ?[]u8 = std.fs.cwd().realpathAlloc(gpa, path) catch null;
        const final = resolved orelse try gpa.dupe(u8, path);
        errdefer gpa.free(final);
        var temp: []u8 = &.{};
        var created: ?std.fs.File = null;
        for (salts) |salt| {
            temp = try temp_path(gpa, final, salt);
            // Exclusive: a file or a link already at the name (planted by someone else) is never
            // opened or followed.
            created = std.fs.cwd().createFile(temp, .{ .read = true, .exclusive = true }) catch |err| {
                gpa.free(temp);
                switch (err) {
                    error.PathAlreadyExists => continue,
                    error.AccessDenied => {
                        gpa.free(final);
                        return null;
                    },
                    else => return err,
                }
            };
            break;
        }
        const file = created orelse return error.PathAlreadyExists;
        errdefer gpa.free(temp);
        errdefer {
            file.close();
            std.fs.cwd().deleteFile(temp) catch {};
        }
        if (found) |st| {
            // What a plain open keeps: the permission bits (the temporary file's came from the
            // umask) and the group. Best effort for the group: the owner may not be in it.
            try file.chmod(@intCast(st.mode & 0o7777));
            std.posix.fchown(file.handle, null, st.gid) catch {};
        }
        return .{
            .file = file,
            .requested = path,
            .final = final,
            .temp = temp,
            .gpa = gpa,
            .regular_file = true,
        };
    }

    /// The temporary file beside `final`: `.nerva-<hash of the name>.<pid>.<salt>.tmp`, whose
    /// length does not depend on the name's, so that a name of `NAME_MAX` bytes still has one.
    fn temp_path(gpa: std.mem.Allocator, final: []const u8, salt: u32) ![]u8 {
        const hash = std.hash.Wyhash.hash(0, std.fs.path.basename(final));
        const base = try std.fmt.allocPrint(
            gpa,
            ".nerva-{x:0>16}.{d}.{x:0>8}.tmp",
            .{ hash, process_id(), salt },
        );
        defer gpa.free(base);
        const directory = std.fs.path.dirname(final) orelse return gpa.dupe(u8, base);
        return std.fs.path.join(gpa, &.{ directory, base });
    }

    /// Whether `final` is a regular file this run makes (a reader may delete it).
    pub fn regular(out: *const OutFile) bool {
        return out.regular_file;
    }

    /// The temporary file that holds a result `finish` could not put at its path, if any.
    pub fn kept_path(out: *const OutFile) ?[]const u8 {
        return if (out.kept) out.temp else null;
    }

    /// Writes the finished `content` and puts it at its path. Nothing is written before: a run
    /// that fails leaves the path as it was. A renamed file is atomic. If the rename is refused
    /// (the directory changed under the run), the content is written into the path in place,
    /// which is not atomic; if that fails too, the temporary file is kept (`kept_path`) and the
    /// error returned. A path written in place is truncated here and then written.
    pub fn finish(out: *OutFile, content: []const u8) !void {
        assert(!out.committed);
        const temp = out.temp orelse {
            if (out.regular_file) try out.file.setEndPos(0);
            try out.file.writeAll(content);
            out.committed = true;
            return;
        };
        try out.file.writeAll(content);
        std.fs.cwd().rename(temp, out.final) catch {
            const target = std.fs.cwd().createFile(out.final, .{}) catch |err| {
                out.kept = true;
                return err;
            };
            defer target.close();
            target.writeAll(content) catch |err| {
                out.kept = true;
                return err;
            };
            std.fs.cwd().deleteFile(temp) catch {};
            out.gpa.free(temp);
            out.temp = null;
            out.committed = true;
            return;
        };
        out.gpa.free(temp);
        out.temp = null;
        out.committed = true;
    }

    /// Closes the file and removes a temporary file that was never committed (not a kept one).
    pub fn deinit(out: *OutFile) void {
        out.file.close();
        if (out.temp) |temp| {
            if (!out.kept) std.fs.cwd().deleteFile(temp) catch {};
            out.gpa.free(temp);
        }
        out.gpa.free(out.final);
    }
};

fn look(path: []const u8, flags: u32) ?std.posix.Stat {
    return std.posix.fstatat(std.posix.AT.FDCWD, path, flags) catch null;
}

fn is_link(path: []const u8) bool {
    const st = look(path, std.posix.AT.SYMLINK_NOFOLLOW) orelse return false;
    return st.mode & std.posix.S.IFMT == std.posix.S.IFLNK;
}

fn access_writable(path: []const u8) bool {
    std.posix.access(path, std.posix.W_OK) catch return false;
    return true;
}

/// Whether two paths name the same file: the same path once resolved, or the same device and
/// inode. A path that does not exist is resolved through its directory. A device (`/dev/null`,
/// `/dev/stdout`) is written in place and never replaced, so two flags may name one.
pub fn same_file(gpa: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const identity_a = try identity(gpa, a);
    defer identity_a.deinit(gpa);
    const identity_b = try identity(gpa, b);
    defer identity_b.deinit(gpa);
    if (identity_a.device or identity_b.device) return false;
    if (std.mem.eql(u8, identity_a.path, identity_b.path)) return true;
    if (identity_a.node != null and identity_b.node != null) {
        return identity_a.node.?.dev == identity_b.node.?.dev and
            identity_a.node.?.ino == identity_b.node.?.ino;
    }
    return false;
}

const Identity = struct {
    path: []const u8,
    node: ?struct { dev: u64, ino: u64 },
    device: bool = false,

    fn deinit(identity_: Identity, gpa: std.mem.Allocator) void {
        gpa.free(identity_.path);
    }
};

/// Looks at `path` as given, so that `/dev/stdout` on a pipe (which resolves to `pipe:[N]`) is
/// a pipe and not a missing file. A file that is not regular is written in place and never
/// replaced (`device`). An error other than "nothing there" is returned (NRV-E0728 words it).
fn identity(gpa: std.mem.Allocator, path: []const u8) !Identity {
    if (std.posix.fstatat(std.posix.AT.FDCWD, path, 0)) |st| {
        const device = st.mode & std.posix.S.IFMT != std.posix.S.IFREG and
            st.mode & std.posix.S.IFMT != std.posix.S.IFDIR;
        const resolved: []u8 = std.fs.cwd().realpathAlloc(gpa, path) catch
            try gpa.dupe(u8, path);
        return .{
            .path = resolved,
            .node = .{ .dev = @intCast(st.dev), .ino = @intCast(st.ino) },
            .device = device,
        };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    // Nothing is there. A dangling symbolic link is followed by a plain open, which makes its
    // target, so the target's name is the file's identity: a link and its target, or two links
    // to one missing file, are one file.
    const final = try dangling_target(gpa, path);
    defer gpa.free(final);
    const directory = std.fs.path.dirname(final) orelse ".";
    const base = std.fs.path.basename(final);
    const parent = std.fs.cwd().realpathAlloc(gpa, directory) catch
        return .{ .path = try gpa.dupe(u8, final), .node = null };
    defer gpa.free(parent);
    return .{ .path = try std.fs.path.join(gpa, &.{ parent, base }), .node = null };
}

/// The most symbolic links `dangling_target` follows, as the kernel's own limit of 40.
const symlinks_max = 40;

/// The path a plain open of `path` would create: `path` itself, or, while it is a symbolic link,
/// the link's target (relative to the link's directory). A chain of more than `symlinks_max` links
/// is `error.SymLinkLoop`. The caller frees the result.
fn dangling_target(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var current = try gpa.dupe(u8, path);
    errdefer gpa.free(current);
    var hops: u32 = 0;
    while (true) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.posix.readlinkat(std.posix.AT.FDCWD, current, &buffer) catch
            return current; // Not a link (or nothing there): `current` is what an open makes.
        if (hops == symlinks_max) return error.SymLinkLoop;
        hops += 1;
        const next = if (std.fs.path.isAbsolute(target))
            try gpa.dupe(u8, target)
        else
            try std.fs.path.join(gpa, &.{ std.fs.path.dirname(current) orelse ".", target });
        gpa.free(current);
        current = next;
    }
}

/// Why `--warmup` and `--seconds` are refused, or null if they are accepted.
pub fn seconds_refusal(warmup: u32, seconds: u32) ?[]const u8 {
    if (seconds == 0) return "--seconds must be at least 1";
    // Each is checked alone first, so that their sum cannot overflow.
    if (warmup > seconds_max or seconds > seconds_max or warmup + seconds > seconds_max) {
        return "--warmup plus --seconds must be at most 3600 (the timeline's bound)";
    }
    return null;
}

/// The longest `--gateway-statsd` the gateway's command line holds (`--statsd=` takes 9 of 128).
pub const statsd_length_max = 119;

/// Why `--gateway-statsd` is refused, or null if the gateway's `--statsd` will take it (NRV-E0736).
/// The rule is `nerva api --statsd`'s: a non-zero port and an address in `<host:port>` form.
pub fn statsd_refusal(text: []const u8) ?[]const u8 {
    if (text.len == 0 or text.len > statsd_length_max) {
        return "--gateway-statsd must be 1 to 119 bytes long";
    }
    const address = vsr.parse_address_and_port(.{ .string = text, .port_default = 8125 }) catch
        return "--gateway-statsd must be <host:port>, for example 127.0.0.1:8125";
    if (address.port == 0) return "--gateway-statsd must be <host:port> with a port above 0";
    return null;
}

/// Why the gateway's flags are refused for this workload, or null. They only mean something for
/// the `botpike` workload, which starts a gateway; `--gateway-stderr` is refused when given at all.
pub fn gateway_flags_refusal(
    gateway_workload: bool,
    statsd_set: bool,
    pid_file_set: bool,
    stderr_set: bool,
) ?[]const u8 {
    if (gateway_workload) return null;
    if (statsd_set) return "--gateway-statsd is only for the botpike workload";
    if (pid_file_set) return "--gateway-pid-file is only for the botpike workload";
    if (stderr_set) return "--gateway-stderr is only for the botpike workload";
    return null;
}

pub const Timeline = struct {
    /// `warmup + seconds` entries.
    seconds: []Second,
    warmup: u32,
    /// Monotonic ns, and `CLOCK_REALTIME` µs, at the start of second 0; set by `begin`.
    start_ns: u64 = 0,
    start_wall_us: u64 = 0,
    /// Operations that ended after the last second (`Summary.late`).
    late: u64 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn init(gpa: std.mem.Allocator, warmup: u32, seconds: u32) !Timeline {
        assert(seconds_refusal(warmup, seconds) == null);
        const slots = try gpa.alloc(Second, warmup + seconds);
        for (slots) |*slot| slot.* = .{};
        return .{ .seconds = slots, .warmup = warmup };
    }

    pub fn deinit(timeline: *Timeline, gpa: std.mem.Allocator) void {
        gpa.free(timeline.seconds);
        timeline.* = undefined;
    }

    /// Fixes the run's start, before any worker records.
    pub fn begin(timeline: *Timeline, start_ns: u64, start_wall_us: u64) void {
        timeline.start_ns = start_ns;
        timeline.start_wall_us = start_wall_us;
    }

    /// The second an operation that ended at `end_ns` belongs to, or null if it ended after the
    /// last second (it began before the end of the run, and is `late`). No operation ends before
    /// the start: the workers start at it.
    pub fn second_of(timeline: *const Timeline, end_ns: u64) ?u32 {
        assert(end_ns >= timeline.start_ns);
        const second = (end_ns - timeline.start_ns) / std.time.ns_per_s;
        if (second >= timeline.seconds.len) return null;
        return @intCast(second);
    }

    pub fn recorder(timeline: *Timeline) Recorder {
        return .{ .timeline = timeline };
    }

    /// The seconds after the warm-up, merged.
    pub fn summary(timeline: *Timeline) Summary {
        timeline.mutex.lock();
        defer timeline.mutex.unlock();
        var result: Summary = .{ .late = timeline.late };
        for (timeline.seconds[timeline.warmup..]) |*second| {
            result.histogram.merge(&second.histogram);
            result.counts.add(second.counts);
        }
        return result;
    }

    /// One JSON line per second, warm-up included and flagged, empty seconds too: always
    /// `warmup + seconds` lines.
    pub fn write(timeline: *Timeline, writer: anytype) !void {
        timeline.mutex.lock();
        defer timeline.mutex.unlock();
        for (timeline.seconds, 0..) |*second, index| {
            const histogram = &second.histogram;
            try writer.print(
                "{{\"t_us\":{},\"count\":{},\"p50_us\":{},\"p99_us\":{},\"max_us\":{},\"errors\":{}," ++
                    "\"buckets\":[",
                .{
                    timeline.start_wall_us + index * std.time.us_per_s,
                    histogram.count,
                    histogram.percentile_us(0.5),
                    histogram.percentile_us(0.99),
                    histogram.max_us,
                    second.counts.errors,
                },
            );
            var first = true;
            for (histogram.counts, 0..) |count, bucket| {
                if (count == 0) continue;
                try writer.print("{s}[{},{}]", .{ if (first) "" else ",", bucket, count });
                first = false;
            }
            try writer.writeAll(if (index < timeline.warmup) "],\"warmup\":true}\n" else "]}\n");
        }
    }
};

/// One worker's view: its operations of the current second, merged into the timeline when the
/// worker moves on. Not shared between threads.
pub const Recorder = struct {
    timeline: *Timeline,
    second: u32 = 0,
    histogram: LatencyHistogram = .{},
    counts: Counts = .{},
    late: u64 = 0,

    /// An operation that ended at `end_ns` (monotonic). `latency_ns` is null for one that is not
    /// a latency sample (a failed submit) but whose counters still count.
    pub fn record(recorder: *Recorder, end_ns: u64, latency_ns: ?u64, counts: Counts) void {
        const second = recorder.timeline.second_of(end_ns) orelse {
            recorder.late += 1;
            return;
        };
        // A worker's operations end in time order, so its seconds never go backwards.
        assert(second >= recorder.second);
        if (second != recorder.second) {
            recorder.flush();
            recorder.second = second;
        }
        if (latency_ns) |latency| recorder.histogram.record(latency);
        recorder.counts.add(counts);
    }

    /// Merges what is held into the timeline. Called by `record` and, once, when the worker stops.
    pub fn flush(recorder: *Recorder) void {
        const timeline = recorder.timeline;
        timeline.mutex.lock();
        defer timeline.mutex.unlock();
        const slot = &timeline.seconds[recorder.second];
        slot.histogram.merge(&recorder.histogram);
        slot.counts.add(recorder.counts);
        timeline.late += recorder.late;
        recorder.histogram = .{};
        recorder.counts = .{};
        recorder.late = 0;
    }
};

const testing = std.testing;

const second_ns = std.time.ns_per_s;

fn parse_lines(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(std.json.Parsed(Line)) {
    var lines = std.ArrayList(std.json.Parsed(Line)).init(gpa);
    errdefer {
        for (lines.items) |*line| line.deinit();
        lines.deinit();
    }
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |text_line| {
        if (text_line.len == 0) continue;
        try lines.append(try std.json.parseFromSlice(Line, gpa, text_line, .{}));
    }
    return lines;
}

const Line = struct {
    t_us: u64,
    count: u64,
    p50_us: u64,
    p99_us: u64,
    max_us: u64,
    errors: u64,
    buckets: []const [2]u64,
    warmup: bool = false,
};

fn lines_free(lines: *std.ArrayList(std.json.Parsed(Line))) void {
    for (lines.items) |*line| line.deinit();
    lines.deinit();
}

test "Timeline: three seconds from a fake clock, buckets merge back to the run's histogram" {
    var timeline = try Timeline.init(testing.allocator, 0, 3);
    defer timeline.deinit(testing.allocator);
    const start_ns = 7 * second_ns + 123;
    timeline.begin(start_ns, 1_700_000_000_000_000);
    var recorder = timeline.recorder();
    var expected: LatencyHistogram = .{};

    // Latencies in µs, with the (fake) time each ended at, as offsets from the start.
    const operations = [_]struct { end_ms: u64, latency_us: u64, errors: u64 }{
        .{ .end_ms = 10, .latency_us = 200, .errors = 0 },
        .{ .end_ms = 900, .latency_us = 5, .errors = 1 },
        .{ .end_ms = 1_000, .latency_us = 12_345, .errors = 0 }, // exactly at the second's start
        .{ .end_ms = 1_999, .latency_us = 700, .errors = 0 },
        .{ .end_ms = 2_500, .latency_us = 150_000, .errors = 2 },
    };
    for (operations) |operation| {
        recorder.record(
            start_ns + operation.end_ms * std.time.ns_per_ms,
            operation.latency_us * std.time.ns_per_us,
            .{ .requests = 1, .errors = operation.errors },
        );
        expected.record(operation.latency_us * std.time.ns_per_us);
    }
    recorder.flush();

    var text = std.ArrayList(u8).init(testing.allocator);
    defer text.deinit();
    try timeline.write(text.writer());
    var lines = try parse_lines(testing.allocator, text.items);
    defer lines_free(&lines);

    try testing.expectEqual(@as(usize, 3), lines.items.len);
    try testing.expectEqual(@as(u64, 1_700_000_000_000_000), lines.items[0].value.t_us);
    try testing.expectEqual(@as(u64, 1_700_000_001_000_000), lines.items[1].value.t_us);
    try testing.expectEqual(@as(u64, 1_700_000_002_000_000), lines.items[2].value.t_us);
    try testing.expectEqual(@as(u64, 2), lines.items[0].value.count);
    try testing.expectEqual(@as(u64, 2), lines.items[1].value.count);
    try testing.expectEqual(@as(u64, 1), lines.items[2].value.count);
    try testing.expectEqual(@as(u64, 1), lines.items[0].value.errors);
    try testing.expectEqual(@as(u64, 2), lines.items[2].value.errors);
    try testing.expectEqual(@as(u64, 200), lines.items[0].value.max_us);
    try testing.expectEqual(@as(u64, 150_000), lines.items[2].value.max_us);
    for (lines.items) |line| try testing.expect(!line.value.warmup);

    // The buckets of every line, added, are the run's histogram.
    var merged: LatencyHistogram = .{};
    for (lines.items) |line| {
        var line_count: u64 = 0;
        for (line.value.buckets) |bucket| {
            try testing.expect(bucket[1] > 0);
            merged.counts[bucket[0]] += bucket[1];
            merged.count += bucket[1];
            line_count += bucket[1];
        }
        try testing.expectEqual(line.value.count, line_count);
    }
    try testing.expectEqualSlices(u64, &expected.counts, &merged.counts);

    const summary = timeline.summary();
    try testing.expectEqualSlices(u64, &expected.counts, &summary.histogram.counts);
    try testing.expectEqual(expected.max_us, summary.histogram.max_us);
    try testing.expectEqual(@as(u64, 5), summary.counts.requests);
    try testing.expectEqual(@as(u64, 3), summary.counts.errors);
}

test "Timeline: --warmup leaves its seconds out of the summary and flags their lines" {
    var timeline = try Timeline.init(testing.allocator, 2, 3);
    defer timeline.deinit(testing.allocator);
    timeline.begin(0, 1_000_000);
    var recorder = timeline.recorder();
    // One operation of 1 ms in each of the five seconds; the first two are warm-up.
    for (0..5) |second| {
        recorder.record(
            second * second_ns + 1,
            std.time.ns_per_ms,
            .{ .requests = 1, .entries = 10, .conflicts = 1, .retries = 1 },
        );
    }
    recorder.flush();

    const summary = timeline.summary();
    try testing.expectEqual(@as(u64, 3), summary.histogram.count);
    try testing.expectEqual(@as(u64, 3), summary.counts.requests);
    try testing.expectEqual(@as(u64, 30), summary.counts.entries);
    try testing.expectEqual(@as(u64, 3), summary.counts.conflicts);
    try testing.expectEqual(@as(u64, 3), summary.counts.retries);

    var text = std.ArrayList(u8).init(testing.allocator);
    defer text.deinit();
    try timeline.write(text.writer());
    var lines = try parse_lines(testing.allocator, text.items);
    defer lines_free(&lines);
    try testing.expectEqual(@as(usize, 5), lines.items.len);
    for (lines.items, 0..) |line, index| {
        try testing.expectEqual(index < 2, line.value.warmup);
        // The warm-up's operations are in the timeline, flagged, though not in the summary.
        try testing.expectEqual(@as(u64, 1), line.value.count);
    }
}

test "Timeline: a line for every second, empty ones too; an operation ending after the run is late" {
    var timeline = try Timeline.init(testing.allocator, 1, 3);
    defer timeline.deinit(testing.allocator);
    timeline.begin(10 * second_ns, 0);
    var recorder = timeline.recorder();
    recorder.record(10 * second_ns, 1000, .{}); // at the start: second 0
    recorder.record(10 * second_ns + 3 * second_ns + 999_999_999, 2000, .{}); // the last second's end
    recorder.record(10 * second_ns + 4 * second_ns, 2500, .{ .requests = 1 }); // just past the end
    recorder.record(10 * second_ns + 90 * second_ns, 3000, .{ .requests = 1 }); // far past
    recorder.flush();
    const summary = timeline.summary();
    try testing.expectEqual(@as(u64, 2), summary.late);
    // A late operation is in no histogram and no counter.
    try testing.expectEqual(@as(u64, 1), summary.histogram.count);
    try testing.expectEqual(@as(u64, 0), summary.counts.requests);

    var text = std.ArrayList(u8).init(testing.allocator);
    defer text.deinit();
    try timeline.write(text.writer());
    var lines = try parse_lines(testing.allocator, text.items);
    defer lines_free(&lines);
    try testing.expectEqual(@as(usize, 4), lines.items.len);
    try testing.expectEqual(@as(u64, 1), lines.items[0].value.count);
    try testing.expectEqual(@as(u64, 0), lines.items[1].value.count);
    try testing.expectEqual(@as(u64, 0), lines.items[2].value.count);
    try testing.expectEqual(@as(u64, 1), lines.items[3].value.count);
    // An empty second reads as zeros with no buckets.
    try testing.expectEqual(@as(u64, 0), lines.items[1].value.p99_us);
    try testing.expectEqual(@as(usize, 0), lines.items[1].value.buckets.len);
}

test "Timeline: a failed submit counts its counters but is no latency sample" {
    var timeline = try Timeline.init(testing.allocator, 0, 2);
    defer timeline.deinit(testing.allocator);
    timeline.begin(0, 0);
    var recorder = timeline.recorder();
    recorder.record(100, null, .{ .requests = 1, .errors = 1 });
    recorder.record(200, 5_000, .{ .requests = 2 });
    recorder.flush();
    const summary = timeline.summary();
    try testing.expectEqual(@as(u64, 1), summary.histogram.count);
    try testing.expectEqual(@as(u64, 3), summary.counts.requests);
    try testing.expectEqual(@as(u64, 1), summary.counts.errors);
}

test "Timeline: workers on several threads add up" {
    var timeline = try Timeline.init(testing.allocator, 0, 4);
    defer timeline.deinit(testing.allocator);
    timeline.begin(0, 0);
    const Worker = struct {
        fn run(shared: *Timeline) void {
            var recorder = shared.recorder();
            for (0..1000) |index| {
                // 250 operations in each of the four seconds.
                recorder.record((index / 250) * second_ns + index, 1_000 * (index + 1), .{ .requests = 1 });
            }
            recorder.flush();
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{&timeline});
    for (threads) |thread| thread.join();
    const summary = timeline.summary();
    try testing.expectEqual(@as(u64, 4000), summary.histogram.count);
    try testing.expectEqual(@as(u64, 4000), summary.counts.requests);
    for (timeline.seconds) |second| try testing.expectEqual(@as(u64, 1000), second.histogram.count);
}

test "Timeline: --warmup plus --seconds at 3600 is accepted and 3601 refused" {
    try testing.expectEqual(@as(?[]const u8, null), seconds_refusal(0, 3600));
    try testing.expect(seconds_refusal(0, 3601) != null);
    try testing.expectEqual(@as(?[]const u8, null), seconds_refusal(30, 3570));
    try testing.expect(seconds_refusal(30, 3571) != null);
    try testing.expect(seconds_refusal(3600, 1) != null);
    try testing.expect(seconds_refusal(std.math.maxInt(u32), std.math.maxInt(u32)) != null);
    try testing.expect(seconds_refusal(0, 0) != null);
    try testing.expectEqual(@as(?[]const u8, null), seconds_refusal(0, 1));

    // The bound's timeline is the bound's size: one line a second.
    var timeline = try Timeline.init(testing.allocator, 30, 3570);
    defer timeline.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, seconds_max), timeline.seconds.len);
}

test "gateway flags are refused for a direct workload" {
    try testing.expectEqual(@as(?[]const u8, null), gateway_flags_refusal(true, true, true, true));
    try testing.expectEqual(@as(?[]const u8, null), gateway_flags_refusal(false, false, false, false));
    try testing.expect(gateway_flags_refusal(false, true, false, false) != null);
    try testing.expect(gateway_flags_refusal(false, false, true, false) != null);
    // Any explicit --gateway-stderr is refused, `ignore` too.
    try testing.expect(gateway_flags_refusal(false, false, false, true) != null);
}

test "path_error_reason names no Zig error" {
    for ([_]anyerror{ error.FileNotFound, error.AccessDenied, error.IsDir, error.Unexpected }) |err| {
        try testing.expect(std.mem.indexOf(u8, path_error_reason(err), "error.") == null);
    }
    try testing.expectEqualStrings("its directory does not exist", path_error_reason(error.FileNotFound));
}

test "statsd_refusal: the rule of nerva api --statsd, and the command line's length" {
    for ([_][]const u8{ "127.0.0.1:8125", "10.0.0.7", "9125", "[fdaa::2]:9125" }) |text| {
        try testing.expectEqual(@as(?[]const u8, null), statsd_refusal(text));
    }
    for ([_][]const u8{ "", "notanaddress", "127.0.0.1:0", "127.0.0.1:65536", "[fdaa::2", "localhost:8125" }) |text| {
        try testing.expect(statsd_refusal(text) != null);
    }
    // The longest address `nerva api --statsd` accepts, a bracketed IPv6 address with a port, is
    // far under the bound, so no accepted value reaches 119 bytes: the length check only guards
    // `statsd_buffer`, and a text of exactly that length is refused as an address, not as too long.
    const ipv6_longest = "[ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535";
    try testing.expectEqual(@as(?[]const u8, null), statsd_refusal(ipv6_longest));
    try testing.expect(ipv6_longest.len < statsd_length_max);
    // Too long: the refusal comes from the length, whatever the text.
    const long = "a" ** (statsd_length_max - 5) ++ ":8125";
    try testing.expectEqual(@as(usize, statsd_length_max), long.len);
    const exact = statsd_refusal(long).?; // within the length, so refused only as an address
    try testing.expect(std.mem.indexOf(u8, exact, "119 bytes") == null);
    try testing.expect(statsd_refusal(long ++ "0") != null);
    try testing.expect(std.mem.indexOf(u8, statsd_refusal(long ++ "0").?, "119") != null);
}

test "same_file: one path twice, a hard link and a path not made yet; not two files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a", .data = "x" });
    try tmp.dir.writeFile(.{ .sub_path = "b", .data = "x" });
    try std.posix.linkat(tmp.dir.fd, "a", tmp.dir.fd, "c", 0);
    const gpa = testing.allocator;
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const a = try std.fs.path.join(gpa, &.{ root, "a" });
    defer gpa.free(a);
    const b = try std.fs.path.join(gpa, &.{ root, "b" });
    defer gpa.free(b);
    const c = try std.fs.path.join(gpa, &.{ root, "c" });
    defer gpa.free(c);
    const new1 = try std.fs.path.join(gpa, &.{ root, "new" });
    defer gpa.free(new1);
    const new2 = try std.fs.path.join(gpa, &.{ root, ".", "new" });
    defer gpa.free(new2);
    try testing.expect(try same_file(gpa, a, a));
    try testing.expect(try same_file(gpa, a, c));
    try testing.expect(!(try same_file(gpa, a, b)));
    try testing.expect(try same_file(gpa, new1, new2));
    try testing.expect(!(try same_file(gpa, new1, a)));
}

test "same_file: a dangling symbolic link and its target, or two links to one missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    try tmp.dir.makeDir("sub");
    try tmp.dir.writeFile(.{ .sub_path = "other", .data = "x" });
    try tmp.dir.symLink("target", "link", .{}); // relative to the link's directory
    try tmp.dir.symLink("link", "chain", .{}); // a link to a link
    try tmp.dir.symLink("../target", "sub/up", .{});
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const target = try std.fs.path.join(gpa, &.{ root, "target" });
    defer gpa.free(target);
    const link = try std.fs.path.join(gpa, &.{ root, "link" });
    defer gpa.free(link);
    const chain = try std.fs.path.join(gpa, &.{ root, "chain" });
    defer gpa.free(chain);
    const up = try std.fs.path.join(gpa, &.{ root, "sub", "up" });
    defer gpa.free(up);
    const other = try std.fs.path.join(gpa, &.{ root, "other" });
    defer gpa.free(other);
    try testing.expect(try same_file(gpa, link, target));
    try testing.expect(try same_file(gpa, target, link));
    try testing.expect(try same_file(gpa, link, chain));
    try testing.expect(try same_file(gpa, up, link));
    try testing.expect(try same_file(gpa, up, target));
    try testing.expect(!(try same_file(gpa, link, other)));
    // The target now exists: the links resolve to it, and are still the same file.
    try tmp.dir.writeFile(.{ .sub_path = "target", .data = "x" });
    try testing.expect(try same_file(gpa, link, target));
    try testing.expect(try same_file(gpa, up, chain));
}

test "OutFile: the path keeps its content until commit; a device is written in place" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "keep", .data = "earlier\n" });
    const gpa = testing.allocator;
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const path = try std.fs.path.join(gpa, &.{ root, "keep" });
    defer gpa.free(path);
    {
        var out = try OutFile.open(gpa, path);
        defer out.deinit();
        // Never finished: the earlier content stays, and no temporary file is left.
    }
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("earlier\n", try tmp.dir.readFile("keep", &buffer));
    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
    {
        var out = try OutFile.open(gpa, path);
        defer out.deinit();
        try out.finish("new\n");
    }
    try testing.expectEqualStrings("new\n", try tmp.dir.readFile("keep", &buffer));
    var device = try OutFile.open(gpa, "/dev/null");
    defer device.deinit();
    try testing.expect(device.temp == null);
    try device.finish("");
}

test "OutFile: a pipe (/dev/fd/N) is written in place, never resolved to pipe:[N] and renamed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    const path = try std.fmt.allocPrint(gpa, "/dev/fd/{d}", .{fds[1]});
    defer gpa.free(path);
    {
        var out = try OutFile.open(gpa, path);
        defer out.deinit();
        try testing.expect(out.temp == null);
        try out.finish("piped\n");
    }
    var buffer: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], &buffer);
    try testing.expectEqualStrings("piped\n", buffer[0..n]);
    // Two flags naming one pipe do not collide: it is written in place.
    try testing.expect(!(try same_file(gpa, path, path)));
}

fn tmp_path(gpa: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    return std.fs.path.join(gpa, &.{ root, name });
}

fn link_count(dir: std.fs.Dir, name: []const u8) !usize {
    const st = try std.posix.fstatat(dir.fd, name, 0);
    return @intCast(st.nlink);
}

test "OutFile: a read-only file is refused, a writable file in a read-only directory is written in place" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Root bypasses the mode bits.
    if (std.os.linux.getuid() == 0) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    var buffer: [16]u8 = undefined;

    try tmp.dir.writeFile(.{ .sub_path = "locked", .data = "earlier\n" });
    {
        try std.posix.fchmodat(tmp.dir.fd, "locked", 0o444, 0);
        const path = try tmp_path(gpa, &tmp, "locked");
        defer gpa.free(path);
        try testing.expectError(error.AccessDenied, OutFile.open(gpa, path));
        try testing.expectEqualStrings("earlier\n", try tmp.dir.readFile("locked", &buffer));
    }

    try tmp.dir.makeDir("sealed");
    var sealed = try tmp.dir.openDir("sealed", .{});
    defer sealed.close();
    try sealed.writeFile(.{ .sub_path = "open", .data = "earlier\n" });
    try std.posix.fchmodat(tmp.dir.fd, "sealed", 0o555, 0);
    defer std.posix.fchmodat(tmp.dir.fd, "sealed", 0o755, 0) catch {};
    {
        const path = try tmp_path(gpa, &tmp, "sealed/open");
        defer gpa.free(path);
        var out = try OutFile.open(gpa, path);
        defer out.deinit();
        // Not atomic: written in place, but changed only at `finish`, as on main (P414c).
        try testing.expect(out.temp == null);
        try testing.expect(out.regular());
        try testing.expectEqualStrings("earlier\n", try sealed.readFile("open", &buffer));
        try out.finish("new\n");
        try testing.expectEqualStrings("new\n", try sealed.readFile("open", &buffer));
        // A file that is not there yet in that directory cannot be made.
        const fresh = try tmp_path(gpa, &tmp, "sealed/fresh");
        defer gpa.free(fresh);
        try testing.expectError(error.AccessDenied, OutFile.open(gpa, fresh));
    }
}

test "OutFile: the file's permission bits survive the rename" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    var buffer: [16]u8 = undefined;
    for ([_]u32{ 0o600, 0o664, 0o640 }) |mode| {
        try tmp.dir.writeFile(.{ .sub_path = "m", .data = "earlier\n" });
        try std.posix.fchmodat(tmp.dir.fd, "m", @intCast(mode), 0);
        const path = try tmp_path(gpa, &tmp, "m");
        defer gpa.free(path);
        var out = try OutFile.open(gpa, path);
        defer out.deinit();
        try testing.expect(out.temp != null);
        try out.finish("new\n");
        try testing.expectEqualStrings("new\n", try tmp.dir.readFile("m", &buffer));
        const st = try std.posix.fstatat(tmp.dir.fd, "m", 0);
        try testing.expectEqual(mode, @as(u32, st.mode) & 0o7777);
    }
}

test "OutFile: a file with another link is written in place, and both names see it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    var buffer: [16]u8 = undefined;
    try tmp.dir.writeFile(.{ .sub_path = "a", .data = "earlier\n" });
    try std.posix.linkat(tmp.dir.fd, "a", tmp.dir.fd, "b", 0);
    const path = try tmp_path(gpa, &tmp, "a");
    defer gpa.free(path);
    var out = try OutFile.open(gpa, path);
    defer out.deinit();
    try testing.expect(out.temp == null);
    try out.finish("new\n");
    try testing.expectEqual(@as(usize, 2), try link_count(tmp.dir, "a"));
    try testing.expectEqualStrings("new\n", try tmp.dir.readFile("b", &buffer));
}

test "OutFile: a dangling symbolic link is followed, not replaced" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    var buffer: [16]u8 = undefined;
    try tmp.dir.symLink("target", "link", .{});
    const path = try tmp_path(gpa, &tmp, "link");
    defer gpa.free(path);
    var out = try OutFile.open(gpa, path);
    defer out.deinit();
    try testing.expect(out.temp == null);
    try out.finish("new\n");
    try testing.expectEqualStrings("new\n", try tmp.dir.readFile("target", &buffer));
    const st = try std.posix.fstatat(tmp.dir.fd, "link", std.posix.AT.SYMLINK_NOFOLLOW);
    try testing.expectEqual(@as(u32, std.posix.S.IFLNK), st.mode & std.posix.S.IFMT);
}

test "OutFile: a file of another user in a sticky directory is written in place (root)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Only root can make a file of another user; a plain open writes it, the rename could not.
    if (std.os.linux.getuid() != 0) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    var buffer: [16]u8 = undefined;
    try tmp.dir.writeFile(.{ .sub_path = "theirs", .data = "earlier\n" });
    try std.posix.fchmodat(tmp.dir.fd, "theirs", 0o666, 0);
    {
        const theirs = try tmp.dir.openFile("theirs", .{});
        defer theirs.close();
        try std.posix.fchown(theirs.handle, 12345, 12345);
    }
    // The directory belongs to the file's owner too: with `fs.protected_regular` set (the systemd
    // default) the kernel refuses an O_CREAT open, even by root, of a file in a sticky,
    // world-writable directory that is neither the opener's nor the directory owner's. This test
    // is about `OutFile`'s choice, not about that sysctl, so it does not depend on it.
    try std.posix.fchown(tmp.dir.fd, 12345, 12345);
    try std.posix.fchmodat(tmp.dir.fd, ".", 0o1777, 0);
    const path = try tmp_path(gpa, &tmp, "theirs");
    defer gpa.free(path);
    var out = try OutFile.open(gpa, path);
    defer out.deinit();
    try testing.expect(out.temp == null);
    try out.finish("new\n");
    try testing.expectEqualStrings("new\n", try tmp.dir.readFile("theirs", &buffer));
    const st = try std.posix.fstatat(tmp.dir.fd, "theirs", 0);
    try testing.expectEqual(@as(u32, 12345), st.uid);
    try testing.expectEqual(@as(u32, 0o666), st.mode & 0o7777);
}

test "OutFile: a rename refused at commit falls back to writing in place, so the result is kept" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (std.os.linux.getuid() == 0) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    var buffer: [16]u8 = undefined;
    try tmp.dir.makeDir("d");
    var dir = try tmp.dir.openDir("d", .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = "f", .data = "earlier\n" });
    const path = try tmp_path(gpa, &tmp, "d/f");
    defer gpa.free(path);
    var out = try OutFile.open(gpa, path);
    defer out.deinit();
    try testing.expect(out.temp != null);
    // The directory stops being writable under the run.
    try std.posix.fchmodat(tmp.dir.fd, "d", 0o555, 0);
    defer std.posix.fchmodat(tmp.dir.fd, "d", 0o755, 0) catch {};
    try out.finish("new\n");
    try testing.expect(out.temp == null);
    try testing.expectEqualStrings("new\n", try dir.readFile("f", &buffer));
}

test "OutFile: a copy that fails keeps the temporary file and names it; deinit leaves it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (std.os.linux.getuid() == 0) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    var buffer: [16]u8 = undefined;
    try tmp.dir.makeDir("d");
    var dir = try tmp.dir.openDir("d", .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = "f", .data = "earlier\n" });
    const path = try tmp_path(gpa, &tmp, "d/f");
    defer gpa.free(path);
    var kept: [std.fs.max_path_bytes]u8 = undefined;
    var kept_len: usize = 0;
    {
        var out = try OutFile.open(gpa, path);
        defer out.deinit();
        try testing.expect(out.temp != null);
        // The rename is refused (the directory is read-only now), and so is the copy (the file).
        try std.posix.fchmodat(tmp.dir.fd, "d", 0o555, 0);
        try std.posix.fchmodat(dir.fd, "f", 0o444, 0);
        defer std.posix.fchmodat(tmp.dir.fd, "d", 0o755, 0) catch {};
        try testing.expectError(error.AccessDenied, out.finish("new\n"));
        const path_kept = out.kept_path() orelse return error.TestUnexpectedResult;
        @memcpy(kept[0..path_kept.len], path_kept);
        kept_len = path_kept.len;
        const failure = FileFailure.of("--output", &out, error.AccessDenied);
        try testing.expectEqualStrings(path_kept, failure.kept_buffer[0..failure.kept_len]);
    }
    // The earlier content is intact (the copy was refused) and the result is in the kept file.
    try testing.expectEqualStrings("earlier\n", try dir.readFile("f", &buffer));
    const kept_name = std.fs.path.basename(kept[0..kept_len]);
    try testing.expectEqualStrings("new\n", try dir.readFile(kept_name, &buffer));
}

test "OutFile: a symbolic link planted at the temporary name is never followed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    var buffer: [16]u8 = undefined;
    try tmp.dir.writeFile(.{ .sub_path = "victim", .data = "victim\n" });
    try std.posix.fchmodat(tmp.dir.fd, "victim", 0o600, 0);
    const path = try tmp_path(gpa, &tmp, "out");
    defer gpa.free(path);
    // The names the first two attempts will try, planted: one link to the victim, one dangling.
    const victim = try tmp_path(gpa, &tmp, "victim");
    defer gpa.free(victim);
    const salts = [_]u32{ 1, 2, 3 };
    for ([_][]const u8{ victim, "nowhere" }, salts[0..2]) |target, salt| {
        const name = try OutFile.temp_path(gpa, path, salt);
        defer gpa.free(name);
        try tmp.dir.symLink(target, std.fs.path.basename(name), .{});
    }
    {
        var out = try OutFile.open_salted(gpa, path, &salts);
        defer out.deinit();
        try testing.expect(out.temp != null);
        try testing.expect(std.mem.indexOf(u8, out.temp.?, "00000003") != null);
        try out.finish("new\n");
    }
    try testing.expectEqualStrings("new\n", try tmp.dir.readFile("out", &buffer));
    // The victim is untouched: its content and its mode.
    try testing.expectEqualStrings("victim\n", try tmp.dir.readFile("victim", &buffer));
    const st = try std.posix.fstatat(tmp.dir.fd, "victim", 0);
    try testing.expectEqual(@as(u32, 0o600), @as(u32, st.mode) & 0o7777);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile("nowhere"));
}

test "OutFile: when every temporary name is taken the path is refused, victims untouched" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    var buffer: [16]u8 = undefined;
    try tmp.dir.writeFile(.{ .sub_path = "victim", .data = "victim\n" });
    const path = try tmp_path(gpa, &tmp, "out");
    defer gpa.free(path);
    const victim = try tmp_path(gpa, &tmp, "victim");
    defer gpa.free(victim);
    const salts = [_]u32{ 1, 2 };
    for (salts) |salt| {
        const name = try OutFile.temp_path(gpa, path, salt);
        defer gpa.free(name);
        try tmp.dir.symLink(victim, std.fs.path.basename(name), .{});
    }
    try testing.expectError(error.PathAlreadyExists, OutFile.open_salted(gpa, path, &salts));
    try testing.expectEqualStrings("victim\n", try tmp.dir.readFile("victim", &buffer));
    try testing.expectEqualStrings(
        "every temporary file name next to it is taken",
        path_error_reason(error.PathAlreadyExists),
    );
}

test "OutFile: a path written in place changes nothing until finish, as on main" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    var buffer: [16]u8 = undefined;
    try tmp.dir.writeFile(.{ .sub_path = "a", .data = "earlier\n" });
    try std.posix.linkat(tmp.dir.fd, "a", tmp.dir.fd, "b", 0);
    const path = try tmp_path(gpa, &tmp, "a");
    defer gpa.free(path);
    {
        var out = try OutFile.open(gpa, path);
        defer out.deinit();
        try testing.expect(out.temp == null);
        // A failed run never reaches `finish`: the content is what it was.
    }
    try testing.expectEqualStrings("earlier\n", try tmp.dir.readFile("a", &buffer));
    // A shorter result replaces a longer one completely.
    var out = try OutFile.open(gpa, path);
    defer out.deinit();
    try out.finish("x\n");
    try testing.expectEqualStrings("x\n", try tmp.dir.readFile("b", &buffer));
}

test "OutFile: a link is resolved, so a PID file's stop deletes the file that was written" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    // Dangling link (plain open creates the target) and a link to a file with two links.
    try tmp.dir.symLink("target", "dangling", .{});
    const dangling = try tmp_path(gpa, &tmp, "dangling");
    defer gpa.free(dangling);
    var out = try OutFile.open(gpa, dangling);
    defer out.deinit();
    try testing.expect(std.mem.endsWith(u8, out.final, "/target"));
}

test "OutFile: a plain-open file is a regular file the PID file's reader may delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    try tmp.dir.writeFile(.{ .sub_path = "a", .data = "x" });
    try std.posix.linkat(tmp.dir.fd, "a", tmp.dir.fd, "b", 0);
    const path = try tmp_path(gpa, &tmp, "a");
    defer gpa.free(path);
    var out = try OutFile.open(gpa, path);
    defer out.deinit();
    try testing.expect(out.regular());
    var device = try OutFile.open(gpa, "/dev/null");
    defer device.deinit();
    try testing.expect(!device.regular());
}

test "OutFile: a name of NAME_MAX bytes still has a temporary file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const name = try gpa.alloc(u8, std.fs.max_name_bytes);
    defer gpa.free(name);
    @memset(name, 'n');
    const path = try std.fs.path.join(gpa, &.{ root, name });
    defer gpa.free(path);
    var out = try OutFile.open(gpa, path);
    defer out.deinit();
    try out.finish("long\n");
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("long\n", try tmp.dir.readFile(name, &buffer));
}

test "same_file: a path that cannot be looked at is an error, and leaks nothing" {
    const gpa = testing.allocator;
    const long = try gpa.alloc(u8, 5000);
    defer gpa.free(long);
    @memset(long, 'a');
    try testing.expectError(error.NameTooLong, same_file(gpa, long, "/dev/null"));
    try testing.expectError(error.NameTooLong, same_file(gpa, "/dev/null", long));
    try testing.expectEqualStrings(
        "the path is too long",
        path_error_reason(error.NameTooLong),
    );
}
