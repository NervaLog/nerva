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

/// Why a file `--timeline`, `--gateway-pid-file` or `--output` names cannot be written, in words (NRV-E0728).
pub fn path_error_reason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "its directory does not exist",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "it is a directory",
        error.NotDir => "a part of its path is not a directory",
        error.NameTooLong => "the path is too long",
        error.NoSpaceLeft => "no space left on the device",
        error.ReadOnlyFileSystem => "the file system is read-only",
        error.SymLinkLoop => "it is a loop of symbolic links",
        else => "it cannot be written",
    };
}

/// A file the run could not write, kept until the cluster and the gateway are torn down.
pub const FileFailure = struct {
    flag: []const u8,
    path: []const u8,
    err: anyerror,

    /// The one NRV-E0728 line, on stderr.
    pub fn report(failure: *const FileFailure) void {
        std.io.getStdErr().writer().print(
            "error[NRV-E0728]: bench-load: {s}: cannot write {s}: {s}\n",
            .{ failure.flag, failure.path, path_error_reason(failure.err) },
        ) catch {};
    }
};

/// An output file of `bench-load` (`--timeline`, `--gateway-pid-file`, `--output`), opened as
/// `--output` is on `main`: created, or truncated if it is there (P414d). There is no temporary
/// file, no rename and no check that two flags name different files.
pub const OutFile = struct {
    file: std.fs.File,
    path: []const u8,
    /// A regular file, which a stopped gateway's PID file may delete; a device or a pipe is not.
    regular: bool,

    /// Opens `path` for writing (NRV-E0728 if it cannot be).
    pub fn open(path: []const u8) !OutFile {
        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();
        const kind = (try file.stat()).kind;
        return .{ .file = file, .path = path, .regular = kind == .file };
    }

    pub fn write(out: *OutFile, content: []const u8) !void {
        try out.file.writeAll(content);
    }

    pub fn deinit(out: *OutFile) void {
        out.file.close();
    }
};

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

test "OutFile: a new file is created, an existing one truncated, a device is not regular (P414d)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "out.json" });
    defer testing.allocator.free(path);

    {
        var out = try OutFile.open(path);
        defer out.deinit();
        try testing.expect(out.regular);
        try out.write("first\n");
    }
    {
        // Opened, not yet written: the earlier content is already gone (P414d).
        var out = try OutFile.open(path);
        defer out.deinit();
        try testing.expectEqual(@as(u64, 0), (try out.file.stat()).size);
        try out.write("second\n");
    }
    const content = try tmp.dir.readFileAlloc(testing.allocator, "out.json", 64);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("second\n", content);

    var device = try OutFile.open("/dev/null");
    defer device.deinit();
    try testing.expect(!device.regular);
}

test "OutFile: a directory that does not exist is refused, with words for NRV-E0728" {
    try testing.expectError(error.FileNotFound, OutFile.open("/no/such/dir/out.json"));
    const failure: FileFailure = .{ .flag = "--timeline", .path = "/x", .err = error.FileNotFound };
    try testing.expectEqualStrings("its directory does not exist", path_error_reason(failure.err));
}
