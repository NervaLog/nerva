//! `zig build bench:load`: a load generator for a Nerva cluster, for the nightly performance
//! job and for measuring a change by hand (docs/DECISIONS.md N55).
//!
//! One thread and one blocking `Client` per `--clients`. Closed loop (`--rate=0`) sends the next
//! request as soon as the last one answers; open loop (`--rate=<n>`) sends at fixed times and
//! measures each latency from the time the request was due, so a slow reply delays the samples
//! behind it instead of hiding them. The result is one JSON object (`--output`, or stdout).
//!
//! An executable rather than a `zig test`: the client must use the production configuration of
//! the `nerva` binary it talks to (as `integration_tests.zig`).

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");
const vsr = @import("vsr.zig");
const nerva = @import("nerva.zig");
const Client = @import("nerva/client.zig").Client;
const LatencyHistogram = @import("nerva/latency_histogram.zig").LatencyHistogram;
const bench_timeline = @import("nerva/bench_timeline.zig");
const Timeline = bench_timeline.Timeline;
const Counts = bench_timeline.Counts;

const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
const Change = nerva.Change;

const botpike = @import("bench_botpike.zig");

const nerva_exe_built = @import("bench_load_options").nerva_exe;

pub const tigerbeetle_config = @import("config.zig").configs.default_production;

// Replicas refuse connections while they start; only errors are worth printing.
pub const std_options: std.Options = .{ .log_level = .err };

const table: u32 = 1;
/// `--local` runs a `--development` cluster, which accepts this many client connections.
const local_clients_max = 6;
const batch_max = 1024;
const history_limit = 64;
const timeout = stdx.Duration.seconds(30);

const Workload = enum {
    /// Blind puts of `--batch` rows.
    c1,
    /// Read-modify-write of one row at the version read (two requests per transaction).
    c2,
    /// Read-modify-write of `--hot` rows, retried until it commits.
    c3,
    /// The same hot rows changed by `add` entries, which never conflict (N42).
    c3_adds,
    /// Lookups of `--batch` rows.
    c4,
    /// Change feed pages of `--batch` changes, from the start and round again.
    c5,
    /// 70% lookups, 20% read-modify-write, 5% feed pages, 5% history reads.
    c7,
    /// Submits like Botpike's (a lookup, then a commit with an add pair) through one `nerva api`
    /// gateway over HTTP, `--clients` at a time; `--keys` accounts (src/bench_botpike.zig).
    botpike,
};

const CLIArgs = struct {
    addresses: ?[]const u8 = null,
    cluster: u128 = 0,
    local: bool = false,
    workload: Workload,
    clients: u32 = 4,
    batch: u32 = 1,
    keys: u64 = 10_000,
    hot: u32 = 4,
    seconds: u32 = 10,
    /// The first `--warmup` seconds run as usual but are left out of the summary.
    warmup: u32 = 0,
    rate: u32 = 0,
    seed: ?u64 = null,
    output: ?[]const u8 = null,
    /// One JSON line a second (`bench_timeline.zig`), warm-up included and flagged.
    timeline: ?[]const u8 = null,
    /// The `nerva` binary the `botpike` workload starts its gateway from (default: the one built
    /// with this generator).
    nerva: ?[]const u8 = null,
    /// botpike only: the gateway's `nerva api --statsd`.
    @"gateway-statsd": ?[]const u8 = null,
    /// botpike only: where the gateway's PID is written, right after it spawns.
    @"gateway-pid-file": ?[]const u8 = null,
    /// botpike only: `inherit` passes the gateway's stderr to this process's (the default is
    /// `ignore`; any explicit value is refused for the other workloads).
    @"gateway-stderr": ?GatewayStderr = null,

    pub const help =
        \\Usage:
        \\
        \\  bench-load (--local | --addresses=<addresses> [--cluster=<id>]) --workload=<workload>
        \\             [--clients=<n>] [--batch=<n>] [--keys=<n>] [--hot=<n>] [--seconds=<n>]
        \\             [--warmup=<seconds>] [--rate=<requests per second>] [--seed=<n>]
        \\             [--output=<file>] [--timeline=<file>] [--nerva=<path>]
        \\             [--gateway-statsd=<host:port>] [--gateway-pid-file=<file>]
        \\             [--gateway-stderr=inherit|ignore]
        \\
        \\Workloads: c1 puts, c2 read-modify-write, c3 hot rows with retries, c3_adds hot rows
        \\with add entries, c4 lookups, c5 change feed, c7 mixed, botpike submits through one
        \\`nerva api` gateway (--clients callers, --keys accounts, --nerva the binary to start it
        \\from). See src/bench_load.zig.
        \\
        \\--warmup runs the first <seconds> as usual and leaves them out of the summary;
        \\--warmup + --seconds is at most 3600. --timeline writes one JSON line per second
        \\(t_us, count, p50_us, p99_us, max_us, errors, the second's non-zero histogram
        \\buckets, and "warmup":true for the warm-up's). The --gateway-* flags are for botpike:
        \\the gateway's statsd address, a file for its PID, and whether its stderr is passed on.
        \\
    ;
};

const GatewayStderr = enum { inherit, ignore };

const Config = struct {
    workload: Workload,
    clients: u32,
    batch: u32,
    keys: u64,
    hot: u32,
    /// The measured seconds, after the warm-up.
    seconds: u32,
    warmup: u32,
    rate: u32,
    seed: u64,
};

pub fn main() !void {
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }) = .init;
    defer switch (gpa_instance.deinit()) {
        .ok => {},
        .leak => @panic("memory leaked"),
    };
    const gpa = gpa_instance.allocator();

    stdx.Flags.fatal_hook = flag_fatal;
    var flags = stdx.Flags.init(gpa);
    defer flags.deinit(gpa);
    const args = flags.parse(CLIArgs);

    var failure: ?bench_timeline.FileFailure = null;
    const failed = run_flags(gpa, args, &failure) catch |err| switch (err) {
        // Everything is torn down by now: report the file, then leave.
        error.FileWriteFailed => {
            failure.?.report();
            std.process.exit(1);
        },
        else => return err,
    };
    if (failed) std.process.exit(1);
}

/// Checks the flags, runs the workload and writes the files; true if a request failed. Returns
/// (never exits) once a cluster or gateway exists, so that `defer` tears them down.
fn run_flags(gpa: std.mem.Allocator, args: CLIArgs, failure: *?bench_timeline.FileFailure) !bool {
    if (args.local == (args.addresses != null)) {
        stdx.Flags.fatal("exactly one of --local and --addresses is required", .{});
    }
    if (args.clients == 0) range_fatal("--clients must be at least 1", .{});
    const gateway_workload = args.workload == .botpike;
    if (gateway_workload) {
        if (args.clients > botpike.callers_max) {
            range_fatal("--clients allows at most {} for botpike", .{botpike.callers_max});
        }
        if (args.batch != 1) stdx.Flags.fatal("botpike takes no --batch", .{});
        if (args.rate != 0) stdx.Flags.fatal("botpike is a closed loop: no --rate", .{});
        if (args.keys < 2 or args.keys > 1_000_000) {
            range_fatal("--keys (accounts) must be from 2 to 1000000 for botpike", .{});
        }
    }
    if (args.local and !gateway_workload and args.clients > local_clients_max) {
        range_fatal("--local allows at most {} clients", .{local_clients_max});
    }
    if (args.batch == 0 or args.batch > batch_max) {
        range_fatal("--batch must be from 1 to {}", .{batch_max});
    }
    if (args.keys < args.batch) range_fatal("--keys must be at least --batch", .{});
    if (args.hot == 0 or args.hot > args.keys) {
        range_fatal("--hot must be from 1 to --keys", .{});
    }
    if (bench_timeline.seconds_refusal(args.warmup, args.seconds)) |reason| {
        range_fatal("{s}", .{reason});
    }
    if (bench_timeline.gateway_flags_refusal(
        gateway_workload,
        args.@"gateway-statsd" != null,
        args.@"gateway-pid-file" != null,
        args.@"gateway-stderr" != null,
    )) |reason| stdx.Flags.fatal("{s}", .{reason});

    if (args.@"gateway-statsd") |text| {
        if (bench_timeline.statsd_refusal(text)) |reason| {
            std.io.getStdErr().writer().print("error[NRV-E0736]: bench-load: {s}\n", .{reason}) catch {};
            std.process.exit(1);
        }
    }

    // The files this run writes are opened now, so that a bad path costs no measurement
    // (NRV-E0728). Every one is opened before any is emptied: a refusal then leaves an earlier
    // file at a path untouched, and removes only the files this run made. After the run, a regular
    // file that does not end with its content is removed too (an empty or truncated file would
    // pass for a result); a device such as /dev/full is never removed.
    var finished = false;
    var timeline_made: ?[]const u8 = null;
    var pid_made: ?[]const u8 = null;
    var output_made: ?[]const u8 = null;
    defer if (!finished) {
        if (timeline_made) |path| std.fs.cwd().deleteFile(path) catch {};
        if (pid_made) |path| std.fs.cwd().deleteFile(path) catch {};
        if (output_made) |path| std.fs.cwd().deleteFile(path) catch {};
    };
    const timeline_file: ?std.fs.File = if (args.timeline) |path|
        try file_open("--timeline", path, &timeline_made, failure)
    else
        null;
    defer if (timeline_file) |file| file.close();
    const pid_file: ?std.fs.File = if (args.@"gateway-pid-file") |path|
        try file_open("--gateway-pid-file", path, &pid_made, failure)
    else
        null;
    defer if (pid_file) |file| file.close();
    const output_file: ?std.fs.File = if (args.output) |path|
        try file_open("--output", path, &output_made, failure)
    else
        null;
    defer if (output_file) |file| file.close();
    // All three opened: now they may be emptied.
    inline for (.{ timeline_file, pid_file, output_file }) |file| {
        if (file) |f| if (is_regular(f)) f.setEndPos(0) catch {};
    }

    const config: Config = .{
        .workload = args.workload,
        .clients = args.clients,
        .batch = args.batch,
        .keys = args.keys,
        .hot = args.hot,
        .seconds = args.seconds,
        .warmup = args.warmup,
        .rate = args.rate,
        .seed = args.seed orelse std.crypto.random.int(u64),
    };

    var local: ?LocalCluster = null;
    defer if (local) |*cluster| cluster.deinit(gpa);
    var addresses_buffer: [vsr.constants.replicas_max]stdx.SocketAddress = undefined;
    const addresses = if (args.local) addresses: {
        local = try LocalCluster.init(gpa);
        break :addresses try vsr.parse_addresses(local.?.addresses_flag, &addresses_buffer);
    } else try vsr.parse_addresses(args.addresses.?, &addresses_buffer);

    const addresses_text = if (args.local) local.?.addresses_flag else args.addresses.?;
    var timeline = try Timeline.init(gpa, config.warmup, config.seconds);
    defer timeline.deinit(gpa);
    const result = if (gateway_workload)
        try run_botpike(gpa, args.cluster, addresses_text, args.nerva orelse nerva_exe_built, &config, &timeline, .{
            .statsd = args.@"gateway-statsd",
            .pid_file = args.@"gateway-pid-file",
            .inherit_stderr = args.@"gateway-stderr" == @as(?GatewayStderr, .inherit),
            .failure = failure,
        })
    else result: {
        try preload(gpa, args.cluster, addresses, &config);
        break :result try run(gpa, args.cluster, addresses, &config, &timeline);
    };
    var json = std.ArrayList(u8).init(gpa);
    defer json.deinit();
    try result_write(json.writer(), &config, &result);
    try json.append('\n');
    if (timeline_file) |file| {
        var lines = std.ArrayList(u8).init(gpa);
        defer lines.deinit();
        try timeline.write(lines.writer());
        file.writeAll(lines.items) catch |err| {
            failure.* = .{ .flag = "--timeline", .path = args.timeline.?, .err = err };
            return error.FileWriteFailed;
        };
        // The finished timeline survives whatever happens to the summary after it.
        timeline_made = null;
    }
    if (output_file) |file| {
        file.writeAll(json.items) catch |err| {
            failure.* = .{ .flag = "--output", .path = args.output.?, .err = err };
            return error.FileWriteFailed;
        };
    } else {
        try std.io.getStdOut().writeAll(json.items);
    }
    finished = true;
    return result.failures > 0;
}

/// Opens (creating, never emptying) the file a flag names, or records the failure and returns
/// `error.FileWriteFailed` (NRV-E0728; `main` reports it after the defers have run). `made` is set
/// to the path if this call created a regular file, and not for one that was already there.
fn file_open(
    flag: []const u8,
    path: []const u8,
    made: *?[]const u8,
    failure: *?bench_timeline.FileFailure,
) !std.fs.File {
    const existed = if (std.fs.cwd().access(path, .{})) true else |_| false;
    const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |err| {
        failure.* = .{ .flag = flag, .path = path, .err = err };
        return error.FileWriteFailed;
    };
    if (!existed and is_regular(file)) made.* = path;
    return file;
}

fn is_regular(file: std.fs.File) bool {
    const stat = file.stat() catch return false;
    return stat.kind == .file;
}

/// A flag's value out of range, as NRV-E0002 (one line), like `cli.zig`.
fn range_fatal(comptime format: []const u8, arguments: anytype) noreturn {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, arguments) catch "a flag is out of range";
    std.io.getStdErr().writer().print("error[NRV-E0002]: bench-load: {s}\n", .{message}) catch {};
    std.process.exit(1);
}

/// The flag parser's failures, and this command's own flag checks, as NRV-E0001 (one line).
fn flag_fatal(message: []const u8) noreturn {
    std.io.getStdErr().writer().print("error[NRV-E0001]: bench-load: {s}\n", .{message}) catch {};
    std.process.exit(1);
}

/// Writes every key once (in batches), so that reads find rows and versions.
fn preload(
    gpa: std.mem.Allocator,
    cluster: u128,
    addresses: []const stdx.SocketAddress,
    config: *const Config,
) !void {
    switch (config.workload) {
        .c1, .c3_adds => return, // Blind writes and adds (with `create`) need no rows.
        .botpike => unreachable, // Set up through the gateway (`run_botpike`).
        .c2, .c3, .c4, .c5, .c7 => {},
    }
    const client = try gpa.create(Client);
    defer gpa.destroy(client);
    try client.init(gpa, .{ .cluster = cluster, .addresses = addresses, .timeout = timeout });
    defer client.deinit();

    var entries: [batch_max]Entry = undefined;
    var results: [batch_max]EntryResult = undefined;
    var id: u64 = 1;
    while (id <= config.keys) {
        const count: usize = @intCast(@min(batch_max, config.keys - id + 1));
        for (entries[0..count], 0..) |*entry, index| entry.* = put(id + index, 0);
        try client.commit(entries[0..count], results[0..count]);
        for (results[0..count]) |result| assert(result.status == .ok);
        id += count;
    }
}

/// The workers count into these as they go; the summary is the timeline's seconds after the
/// warm-up (`Timeline.summary`), with the failures of every worker.
const Result = struct {
    histogram: LatencyHistogram = .{},
    /// Latency samples: one per request, or per transaction for c2 and c3.
    operations: u64 = 0,
    requests: u64 = 0,
    entries: u64 = 0,
    conflicts: u64 = 0,
    retries: u64 = 0,
    /// Entries refused for a reason other than a conflict (a bug in this generator).
    errors: u64 = 0,
    /// Clients that stopped with an error (timeout, eviction).
    failures: u64 = 0,
    /// Operations that ended after the run (`Timeline`'s `late`): in no other number.
    late: u64 = 0,
    duration: stdx.Duration = .{ .ns = 0 },

    fn counts(result: *const Result) Counts {
        return .{
            .requests = result.requests,
            .entries = result.entries,
            .conflicts = result.conflicts,
            .retries = result.retries,
            .errors = result.errors,
        };
    }

    /// The measured seconds' histogram and counters, and `failures` of the whole run.
    fn from_timeline(timeline: *Timeline, failures: u64, config: *const Config) Result {
        const summary = timeline.summary();
        return .{
            .histogram = summary.histogram,
            .operations = summary.histogram.count,
            .requests = summary.counts.requests,
            .entries = summary.counts.entries,
            .conflicts = summary.counts.conflicts,
            .retries = summary.counts.retries,
            .errors = summary.counts.errors,
            .failures = failures,
            .late = summary.late,
            .duration = .{ .ns = @as(u64, config.seconds) * std.time.ns_per_s },
        };
    }
};

const Shared = struct {
    config: *const Config,
    cluster: u128,
    addresses: []const stdx.SocketAddress,
    gpa: std.mem.Allocator,
    timeline: *Timeline,
    ready: std.atomic.Value(u32) = .init(0),
    /// Monotonic ns at which every worker starts; zero until all are ready.
    start_ns: std.atomic.Value(u64) = .init(0),
};

fn run(
    gpa: std.mem.Allocator,
    cluster: u128,
    addresses: []const stdx.SocketAddress,
    config: *const Config,
    timeline: *Timeline,
) !Result {
    var shared: Shared = .{
        .config = config,
        .cluster = cluster,
        .addresses = addresses,
        .gpa = gpa,
        .timeline = timeline,
    };
    const workers = try gpa.alloc(Worker, config.clients);
    defer gpa.free(workers);
    const threads = try gpa.alloc(std.Thread, config.clients);
    defer gpa.free(threads);

    for (workers, threads, 0..) |*worker, *thread, index| {
        worker.* = .{
            .shared = &shared,
            .index = @intCast(index),
            .prng = stdx.PRNG.from_seed(config.seed +% index),
            .recorder = timeline.recorder(),
        };
        thread.* = try std.Thread.spawn(.{}, Worker.main, .{worker});
    }

    var time_os: stdx.TimeOS = .{};
    const time = time_os.interface();
    while (shared.ready.load(.acquire) < config.clients) std.time.sleep(std.time.ns_per_ms);
    // Workers whose client failed to connect are ready too; they report a failure.
    const start = time.monotonic().add(.ms(100));
    // The timeline is fixed before the workers are released: they read `start_ns` with acquire.
    timeline.begin(start.ns, wall_us() + 100 * std.time.us_per_ms);
    shared.start_ns.store(start.ns, .release);

    var failures: u64 = 0;
    for (workers, threads) |*worker, thread| {
        thread.join();
        failures += worker.result.failures;
    }
    return Result.from_timeline(timeline, failures, config);
}

/// `CLOCK_REALTIME` in µs: what `node.py` stamps log lines with, so the timeline can be placed
/// beside them. Latencies are timed with the monotonic clock.
fn wall_us() u64 {
    return @intCast(std.time.microTimestamp());
}

/// The `botpike` workload: a gateway in front of the cluster, and callers of the gateway.
fn run_botpike(
    gpa: std.mem.Allocator,
    cluster: u128,
    addresses: []const u8,
    nerva_exe: []const u8,
    config: *const Config,
    timeline: *Timeline,
    gateway_options: botpike.GatewayOptions,
) !Result {
    var gateway = try botpike.Gateway.start(gpa, nerva_exe, cluster, addresses, gateway_options);
    defer gateway.stop();
    const failures = try botpike.run(gpa, &.{
        .address = gateway.address,
        .callers = config.clients,
        .accounts = config.keys,
        .seconds = config.warmup + config.seconds,
        .seed = config.seed,
        .cluster = cluster,
        .timeline = timeline,
    });
    return Result.from_timeline(timeline, failures, config);
}

const Worker = struct {
    shared: *Shared,
    index: u32,
    prng: stdx.PRNG,
    result: Result = .{},
    recorder: bench_timeline.Recorder,
    sequence: u64 = 0,
    feed_cursor: u64 = 0,

    entries: [batch_max]Entry = undefined,
    results: [batch_max]EntryResult = undefined,
    keys: [batch_max]RowKey = undefined,
    rows: [batch_max]RowValue = undefined,
    changes: [batch_max + 1]Change = undefined,

    fn main(worker: *Worker) void {
        worker.run() catch |err| {
            std.log.err("client {}: {}", .{ worker.index, err });
            worker.result.failures += 1;
        };
    }

    fn run(worker: *Worker) !void {
        const shared = worker.shared;
        const config = shared.config;
        const client = shared.gpa.create(Client) catch |err| {
            _ = shared.ready.fetchAdd(1, .release);
            return err;
        };
        defer shared.gpa.destroy(client);
        client.init(shared.gpa, .{
            .cluster = shared.cluster,
            .addresses = shared.addresses,
            .timeout = timeout,
        }) catch |err| {
            _ = shared.ready.fetchAdd(1, .release);
            return err;
        };
        defer client.deinit();
        defer worker.recorder.flush();
        _ = shared.ready.fetchAdd(1, .release);

        var time_os: stdx.TimeOS = .{};
        const time = time_os.interface();
        while (shared.start_ns.load(.acquire) == 0) std.time.sleep(std.time.ns_per_ms / 10);
        const start: stdx.Instant = .{ .ns = shared.start_ns.load(.acquire) };
        // Released a little before the start: no operation may end before the timeline begins.
        const early = time.monotonic();
        if (early.ns < start.ns) std.time.sleep(start.ns - early.ns);
        const end = start.add(.{ .ns = @as(u64, config.warmup + config.seconds) * std.time.ns_per_s });

        // Open loop: this client's share of the rate, staggered so clients do not send at once.
        const interval_ns: u64 = if (config.rate == 0)
            0
        else
            @as(u64, config.clients) * std.time.ns_per_s / config.rate;
        var due = start.add(.{ .ns = interval_ns * worker.index / config.clients });

        while (true) {
            var now = time.monotonic();
            if (now.ns >= end.ns) break;
            if (interval_ns > 0) {
                if (due.ns >= end.ns) break;
                if (now.ns < due.ns) {
                    std.time.sleep(due.ns - now.ns);
                    now = time.monotonic();
                }
            } else {
                due = now;
            }
            const counts_before = worker.result.counts();
            worker.operation(client) catch |err| {
                // What the operation counted before it failed still counts (P414).
                worker.recorder.record(time.monotonic().ns, null, worker.result.counts().sub(counts_before));
                return err;
            };
            const ended = time.monotonic();
            worker.recorder.record(
                ended.ns,
                due.elapsed(ended).ns,
                worker.result.counts().sub(counts_before),
            );
            due = due.add(.{ .ns = interval_ns });
        }
    }

    fn operation(worker: *Worker, client: *Client) !void {
        const config = worker.shared.config;
        switch (config.workload) {
            .c1 => try worker.puts(client),
            .c2 => try worker.read_modify_write(client, config.keys, false),
            .c3 => try worker.read_modify_write(client, config.hot, true),
            .c3_adds => try worker.add(client),
            .c4 => try worker.lookups(client),
            .c5 => try worker.feed_page(client),
            .botpike => unreachable,
            .c7 => {
                const roll = worker.prng.int_inclusive(u8, 99);
                if (roll < 70) {
                    try worker.lookups(client);
                } else if (roll < 90) {
                    try worker.read_modify_write(client, config.keys, false);
                } else if (roll < 95) {
                    try worker.feed_page(client);
                } else {
                    try worker.history(client);
                }
            },
        }
    }

    fn key_random(worker: *Worker, keys: u64) u64 {
        return 1 + worker.prng.int_inclusive(u64, keys - 1);
    }

    fn puts(worker: *Worker, client: *Client) !void {
        const config = worker.shared.config;
        // Distinct rows within a batch (a row written twice is `write_duplicate`).
        const base = config.keys / config.clients * worker.index + worker.sequence * config.batch;
        worker.sequence += 1;
        const entries = worker.entries[0..config.batch];
        for (entries, 0..) |*entry, index| {
            entry.* = put(1 + (base + index) % config.keys, worker.sequence);
        }
        try worker.commit(client, entries);
    }

    fn lookups(worker: *Worker, client: *Client) !void {
        const config = worker.shared.config;
        const keys = worker.keys[0..config.batch];
        for (keys) |*key| key.* = .{ .id = worker.key_random(config.keys), .table = table };
        try client.lookup_rows(keys, worker.rows[0..config.batch]);
        worker.result.requests += 1;
        worker.result.entries += config.batch;
    }

    fn read_modify_write(worker: *Worker, client: *Client, keys: u64, retry: bool) !void {
        const id = worker.key_random(keys);
        while (true) {
            var row: [1]RowValue = undefined;
            try client.lookup_rows(&.{.{ .id = id, .table = table }}, &row);
            worker.sequence += 1;
            var entry_put = put(id, worker.sequence);
            std.mem.writeInt(u64, entry_put.value[8..16], row[0].op, .little);
            const entries = [2]Entry{
                .{ .id = id, .table = table, .kind = .read, .op_seen = row[0].op, .value = @splat(0) },
                entry_put,
            };
            var results: [2]EntryResult = undefined;
            try client.commit(&entries, &results);
            worker.result.requests += 2;
            if (results[0].status == .ok) {
                worker.result.entries += 2;
                return;
            }
            if (results[0].status != .conflict) {
                worker.result.errors += 1;
                return;
            }
            worker.result.conflicts += 1;
            if (!retry) return;
            worker.result.retries += 1;
        }
    }

    fn add(worker: *Worker, client: *Client) !void {
        const config = worker.shared.config;
        var entry: Entry = .{
            .id = worker.key_random(config.hot),
            .table = table,
            .kind = .add,
            .op_seen = 0,
            .value = undefined,
        };
        const parameters: nerva.Add = .{
            .delta = 1,
            .min = 0,
            .max = 0,
            .delta_from = 0,
            .offset = 0,
            .field = .u64,
            .flags = .{ .create = true },
        };
        entry.value = @bitCast(parameters);
        try worker.commit(client, (&entry)[0..1]);
    }

    fn feed_page(worker: *Worker, client: *Client) !void {
        const config = worker.shared.config;
        const count = try client.get_changes(.{
            .timestamp_min = worker.feed_cursor,
            .limit = config.batch,
        }, worker.changes[0 .. config.batch + 1]);
        assert(count >= 1);
        const end = worker.changes[count - 1];
        assert(end.kind == .end);
        worker.result.requests += 1;
        worker.result.entries += count - 1;
        worker.feed_cursor = if (end.flags.more) end.timestamp else 0;
    }

    fn history(worker: *Worker, client: *Client) !void {
        const config = worker.shared.config;
        const count = try client.get_history(.{
            .table = table,
            .id = worker.key_random(config.keys),
            .limit = history_limit,
            .op_max = std.math.maxInt(u64),
            .timestamp_max = 0,
        }, worker.changes[0 .. history_limit + 1]);
        assert(count >= 1);
        worker.result.requests += 1;
        worker.result.entries += count - 1;
    }

    fn commit(worker: *Worker, client: *Client, entries: []const Entry) !void {
        const results = worker.results[0..entries.len];
        try client.commit(entries, results);
        worker.result.requests += 1;
        for (results) |result| switch (result.status) {
            .ok => worker.result.entries += 1,
            .conflict => worker.result.conflicts += 1,
            .aborted => {},
            else => worker.result.errors += 1,
        };
    }
};

fn put(id: u64, stamp: u64) Entry {
    var value: [nerva.value_size]u8 = @splat(0);
    std.mem.writeInt(u64, value[0..8], stamp, .little);
    return .{ .id = id, .table = table, .kind = .put, .op_seen = 0, .value = value };
}

fn result_write(writer: anytype, config: *const Config, result: *const Result) !void {
    const seconds: f64 = @as(f64, @floatFromInt(result.duration.ns)) / std.time.ns_per_s;
    const histogram = &result.histogram;
    try writer.print(
        "{{\"workload\":\"{s}\",\"clients\":{},\"batch\":{},\"keys\":{},\"hot\":{}," ++
            "\"seconds\":{},\"warmup\":{},\"rate\":{},\"seed\":{},",
        .{
            @tagName(config.workload), config.clients, config.batch, config.keys, config.hot,
            config.seconds,            config.warmup,  config.rate,  config.seed,
        },
    );
    try writer.print(
        "\"operations\":{},\"requests\":{},\"entries\":{},\"conflicts\":{},\"retries\":{}," ++
            "\"errors\":{},\"failures\":{},\"late_operations\":{},\"operations_per_s\":{d:.1},\"requests_per_s\":{d:.1}," ++
            "\"entries_per_s\":{d:.1},",
        .{
            result.operations,                                    result.requests,
            result.entries,                                       result.conflicts,
            result.retries,                                       result.errors,
            result.failures,                                      result.late,
            @as(f64, @floatFromInt(result.operations)) / seconds, @as(f64, @floatFromInt(result.requests)) / seconds,
            @as(f64, @floatFromInt(result.entries)) / seconds,
        },
    );
    try writer.print(
        "\"latency_us\":{{\"p50\":{},\"p90\":{},\"p99\":{},\"p999\":{},\"max\":{}}}}}",
        .{
            histogram.percentile_us(0.5),  histogram.percentile_us(0.9),
            histogram.percentile_us(0.99), histogram.percentile_us(0.999),
            histogram.max_us,
        },
    );
}

/// A three-replica `--development` cluster of real `nerva` processes on free local ports.
const LocalCluster = struct {
    tmp_path: []const u8,
    addresses_flag: []const u8,
    processes: [3]std.process.Child,

    fn init(gpa: std.mem.Allocator) !LocalCluster {
        var name_buffer: [128]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(
            &name_buffer,
            ".zig-cache/tmp/nerva-bench-{x}",
            .{std.crypto.random.int(u64)},
        );
        try std.fs.cwd().makePath(tmp_name);
        errdefer std.fs.cwd().deleteTree(tmp_name) catch {};
        const tmp_path = try std.fs.cwd().realpathAlloc(gpa, tmp_name);
        errdefer gpa.free(tmp_path);

        var ports: [3]u16 = undefined;
        for (&ports) |*port| port.* = try port_free();
        const addresses_flag = try std.fmt.allocPrint(
            gpa,
            "127.0.0.1:{},127.0.0.1:{},127.0.0.1:{}",
            .{ ports[0], ports[1], ports[2] },
        );
        errdefer gpa.free(addresses_flag);

        var cluster: LocalCluster = .{
            .tmp_path = tmp_path,
            .addresses_flag = addresses_flag,
            .processes = undefined,
        };
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var replica_buffer: [32]u8 = undefined;
        var addresses_buffer: [256]u8 = undefined;
        for (0..3) |replica| {
            const path = try std.fmt.bufPrint(&path_buffer, "{s}/0_{}.nerva", .{ tmp_path, replica });
            const format = try std.process.Child.run(.{ .allocator = gpa, .argv = &.{
                nerva_exe_built,
                "format",
                "--cluster=0",
                try std.fmt.bufPrint(&replica_buffer, "--replica={}", .{replica}),
                "--replica-count=3",
                "--development",
                path,
            } });
            defer gpa.free(format.stdout);
            defer gpa.free(format.stderr);
            if (format.term != .Exited or format.term.Exited != 0) return error.FormatFailed;
        }
        var started: usize = 0;
        errdefer for (cluster.processes[0..started]) |*process| {
            _ = process.kill() catch {};
        };
        for (&cluster.processes, 0..) |*process, replica| {
            const path = try std.fmt.bufPrint(&path_buffer, "{s}/0_{}.nerva", .{ tmp_path, replica });
            process.* = std.process.Child.init(&.{
                nerva_exe_built,
                "start",
                try std.fmt.bufPrint(&addresses_buffer, "--addresses={s}", .{addresses_flag}),
                "--development",
                path,
            }, gpa);
            process.stdin_behavior = .Ignore;
            process.stdout_behavior = .Ignore;
            process.stderr_behavior = .Ignore;
            try process.spawn();
            started += 1;
        }
        return cluster;
    }

    fn deinit(cluster: *LocalCluster, gpa: std.mem.Allocator) void {
        for (&cluster.processes) |*process| _ = process.kill() catch {};
        std.fs.deleteTreeAbsolute(cluster.tmp_path) catch {};
        gpa.free(cluster.addresses_flag);
        gpa.free(cluster.tmp_path);
        cluster.* = undefined;
    }
};

fn port_free() !u16 {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    return server.listen_address.getPort();
}
