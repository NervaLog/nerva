//! Command-line arguments for the `nerva` binary.
//!
//! `CLIArgs` is what the operator typed; `Command` is what the binary runs, with every limit
//! resolved and validated. Validation is in pure functions returning errors, so that it can be
//! unit tested; `parse_args` turns those errors into a fatal exit.

const std = @import("std");

const stdx = @import("stdx");
const vsr = @import("../vsr.zig");
const nerva = @import("../nerva.zig");
const constants = @import("../constants.zig");
const IO = @import("../io.zig").IO;
const Storage = @import("../storage.zig").StorageType(IO);
const ByteSize = stdx.ByteSize;
const trace_size_default = @import("trace_file.zig").size_max_default;

const StateMachine = @import("state_machine.zig").StateMachineType(Storage);
const Grid = vsr.GridType(Storage);

const CLIArgs = union(enum) {
    format: struct {
        cluster: u128,
        replica: u8,
        replica_count: u8,
        development: bool = false,
        log_debug: bool = false,

        @"--": void,
        path: []const u8,
    },

    start: struct {
        addresses: vsr.ClusterAddress,
        cache_grid: ?ByteSize = null,
        cache_rows: ?ByteSize = null,
        statsd: ?[]const u8 = null,
        trace: ?[]const u8 = null,
        trace_size_max: ?ByteSize = null,
        development: bool = false,
        log_debug: bool = false,

        @"--": void,
        path: []const u8,
    },

    view: struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        listen: []const u8,
        log_debug: bool = false,
    },

    api: struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        listen: []const u8,
        log_debug: bool = false,
    },

    version: struct {},

    pub const help =
        \\Usage:
        \\
        \\  nerva [-h | --help]
        \\
        \\  nerva format --cluster=<integer> --replica=<index> --replica-count=<integer>
        \\               [--development] [--log-debug] <path>
        \\
        \\  nerva start --addresses=<addresses> [--cache-grid=<size><KiB|MiB|GiB>]
        \\              [--cache-rows=<size><KiB|MiB|GiB>]
        \\              [--statsd=<host:port>] [--trace=<path>]
        \\              [--development] [--log-debug] <path>
        \\
        \\  nerva view --cluster=<integer> --addresses=<addresses> --listen=<host:port>
        \\             [--log-debug]
        \\
        \\  nerva api --cluster=<integer> --addresses=<addresses> --listen=<host:port>
        \\            [--log-debug]
        \\
        \\  nerva version
        \\
        \\Commands:
        \\
        \\  format   Create a replica's data file at <path>.
        \\
        \\  start    Run a replica from the data file at <path>.
        \\
        \\  view     Follow the cluster's change feed and serve declared views. The key is
        \\           read from NERVA_KEY.
        \\
        \\  api      Serve the cluster's operations (lookup, commit, changes, history) as JSON
        \\           over HTTP. The key is read from the NERVA_KEY environment variable.
        \\
        \\  version  Print the version.
        \\
        \\Options:
        \\
        \\  --cluster=<integer>
        \\        The cluster id. 0 is reserved for testing.
        \\
        \\  --replica=<index>
        \\        This replica's index, from 0 to replica-count - 1.
        \\
        \\  --replica-count=<integer>
        \\        The number of replicas in the cluster, at most 6.
        \\
        \\  --addresses=<addresses>
        \\        Comma-separated host:port of every replica, in replica index order.
        \\        `--addresses=0` binds an ephemeral port, prints it to stdout, and exits when
        \\        stdin closes (for tests).
        \\
        \\  --cache-grid=<size><KiB|MiB|GiB>
        \\        Memory for caching data file blocks.
        \\
        \\  --cache-rows=<size><KiB|MiB|GiB>
        \\        Memory for caching rows (128 bytes each), rounded down to a whole number of
        \\        cache sets. The default is the minimum, one set.
        \\
        \\  --statsd=<host:port>
        \\        Send the replica's metrics as statsd over UDP every 10 seconds. The port
        \\        defaults to 8125; a bare port means 127.0.0.1. IPv6 goes in brackets.
        \\
        \\  --trace=<path>
        \\        Write a JSON trace of the replica's spans to <path> (Perfetto,
        \\        chrome://tracing). For short diagnostic runs: tracing slows the replica
        \\        down. Tracing stops, and the replica runs on, if writing fails or the file
        \\        reaches --trace-size-max.
        \\
        \\  --trace-size-max=<size><KiB|MiB|GiB>
        \\        The largest trace file (default 1GiB).
        \\
        \\  --listen=<host:port>
        \\        Where to serve HTTP. The bound port is printed to stdout (use port 0 for an
        \\        ephemeral one).
        \\
        \\  --development
        \\        Allow running without Direct IO, with small default caches.
        \\
        \\  --log-debug
        \\        Log at debug level.
        \\
    ;
};

pub const Command = union(enum) {
    format: Format,
    start: Start,
    view: View,
    api: Api,
    version,

    pub const Api = struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        listen: std.net.Address,
        log_debug: bool,
    };

    pub const View = struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        listen: std.net.Address,
        log_debug: bool,
    };

    pub const Format = struct {
        cluster: u128,
        replica: u8,
        replica_count: u8,
        development: bool,
        log_debug: bool,
        path: []const u8,
    };

    pub const Start = struct {
        addresses: vsr.ClusterAddress,
        cache_grid_blocks: u32,
        cache_rows_count: u32,
        storage_size_limit: u64,
        pipeline_requests_limit: u32,
        request_size_limit: u32,
        lsm_forest_compaction_block_count: u32,
        lsm_forest_node_count: u32,
        statsd: ?stdx.SocketAddress,
        trace: ?[]const u8,
        trace_size_max: u64,
        development: bool,
        log_debug: bool,
        path: []const u8,
    };
};

pub fn parse_args(flags: *stdx.Flags) Command {
    return switch (flags.parse(CLIArgs)) {
        .format => |format| .{ .format = format_validate(.{
            .cluster = format.cluster,
            .replica = format.replica,
            .replica_count = format.replica_count,
            .development = format.development,
            .log_debug = format.log_debug,
            .path = format.path,
        }) catch |err| vsr.fatal(.cli, "format: {s}", .{error_message(err)}) },
        .start => |start| .{ .start = start_resolve(.{
            .addresses = start.addresses,
            .cache_grid = start.cache_grid,
            .cache_rows = start.cache_rows,
            .statsd = start.statsd,
            .trace = start.trace,
            .trace_size_max = start.trace_size_max,
            .development = start.development,
            .log_debug = start.log_debug,
            .path = start.path,
        }) catch |err| vsr.fatal(.cli, "start: {s}", .{error_message(err)}) },
        .view => |view| .{ .view = .{
            .cluster = view.cluster,
            .addresses = view.addresses,
            .listen = listen_parse(view.listen) orelse
                vsr.fatal(.cli, "view: --listen must be <ipv4>:<port>", .{}),
            .log_debug = view.log_debug,
        } },
        .api => |api| .{ .api = .{
            .cluster = api.cluster,
            .addresses = api.addresses,
            .listen = listen_parse(api.listen) orelse
                vsr.fatal(.cli, "api: --listen must be <ipv4>:<port>", .{}),
            .log_debug = api.log_debug,
        } },
        .version => .version,
    };
}

fn listen_parse(text: []const u8) ?std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    return std.net.Address.parseIp4(text[0..colon], port) catch null;
}

test listen_parse {
    try std.testing.expectEqual(@as(u16, 8090), listen_parse("127.0.0.1:8090").?.getPort());
    try std.testing.expectEqual(@as(u16, 0), listen_parse("0.0.0.0:0").?.getPort());
    try std.testing.expect(listen_parse("8090") == null);
    try std.testing.expect(listen_parse("localhost:8090") == null);
    try std.testing.expect(listen_parse("127.0.0.1:99999") == null);
}

const Error = error{
    ReplicaCountZero,
    ReplicaCountTooLarge,
    ReplicaIndexOutOfRange,
    CacheGridTooSmall,
    CacheGridNotBlockMultiple,
    CacheRowsTooSmall,
    CacheRowsTooLarge,
    StatsdAddressInvalid,
    TracePathEmpty,
    TraceSizeMaxWithoutTrace,
    TraceSizeMaxZero,
};

fn error_message(err: Error) []const u8 {
    return switch (err) {
        error.ReplicaCountZero => "--replica-count must be greater than zero",
        error.ReplicaCountTooLarge => std.fmt.comptimePrint(
            "--replica-count must be at most {}",
            .{constants.replicas_max},
        ),
        error.ReplicaIndexOutOfRange => "--replica must be less than --replica-count",
        error.CacheGridTooSmall => std.fmt.comptimePrint(
            "--cache-grid must be at least {} bytes",
            .{cache_grid_size_min},
        ),
        error.CacheGridNotBlockMultiple => std.fmt.comptimePrint(
            "--cache-grid must be a multiple of the block size ({} bytes)",
            .{constants.block_size},
        ),
        error.CacheRowsTooSmall => std.fmt.comptimePrint(
            "--cache-rows must be at least {} bytes",
            .{cache_rows_size_multiple},
        ),
        error.CacheRowsTooLarge => "--cache-rows must hold fewer than 2^32 rows",
        error.StatsdAddressInvalid => "--statsd must be <host:port> with a non-zero port " ++
            "(IPv6 in brackets)",
        error.TracePathEmpty => "--trace must name a file",
        error.TraceSizeMaxWithoutTrace => "--trace-size-max needs --trace",
        error.TraceSizeMaxZero => "--trace-size-max must be positive",
    };
}

fn format_validate(format: Command.Format) Error!Command.Format {
    if (format.replica_count == 0) return error.ReplicaCountZero;
    if (format.replica_count > constants.replicas_max) return error.ReplicaCountTooLarge;
    if (format.replica >= format.replica_count) return error.ReplicaIndexOutOfRange;
    return format;
}

const cache_grid_size_min = constants.block_size * Grid.Cache.value_count_max_multiple;

const StartArgs = struct {
    addresses: vsr.ClusterAddress,
    cache_grid: ?ByteSize,
    cache_rows: ?ByteSize,
    statsd: ?[]const u8,
    trace: ?[]const u8,
    trace_size_max: ?ByteSize,
    development: bool,
    log_debug: bool,
    path: []const u8,
};

const cache_rows_multiple = StateMachine.cache_entries_rows_multiple;
const cache_rows_size_multiple = cache_rows_multiple * @sizeOf(nerva.Row);

/// Rows that fit in `size`, rounded down to whole cache sets.
fn cache_rows_resolve(size: ?ByteSize) Error!u32 {
    const bytes = if (size) |value| value.bytes() else return cache_rows_multiple;
    const rows = @divFloor(bytes, @sizeOf(nerva.Row));
    const rows_rounded = rows - rows % cache_rows_multiple;
    if (rows_rounded == 0) return error.CacheRowsTooSmall;
    if (rows_rounded > std.math.maxInt(u32)) return error.CacheRowsTooLarge;
    return @intCast(rows_rounded);
}

const statsd_port_default = 8125;

fn statsd_parse(text: []const u8) Error!stdx.SocketAddress {
    if (text.len == 0) return error.StatsdAddressInvalid;
    const address = vsr.parse_address_and_port(.{
        .string = text,
        .port_default = statsd_port_default,
    }) catch return error.StatsdAddressInvalid;
    if (address.port == 0) return error.StatsdAddressInvalid;
    return address;
}

fn start_resolve(start: StartArgs) Error!Command.Start {
    const cache_grid_size: u64 = if (start.cache_grid) |size|
        size.bytes()
    else if (start.development)
        cache_grid_size_min
    else
        constants.grid_cache_size_default;
    if (cache_grid_size < cache_grid_size_min) return error.CacheGridTooSmall;
    if (cache_grid_size % constants.block_size != 0) return error.CacheGridNotBlockMultiple;

    const cache_rows_count = try cache_rows_resolve(start.cache_rows);
    const statsd: ?stdx.SocketAddress = if (start.statsd) |text| try statsd_parse(text) else null;
    if (start.trace) |path| {
        if (path.len == 0) return error.TracePathEmpty;
    }
    if (start.trace_size_max != null and start.trace == null) {
        return error.TraceSizeMaxWithoutTrace;
    }
    const trace_size_max: u64 = if (start.trace_size_max) |size| size.bytes() else trace_size_default;
    if (trace_size_max == 0) return error.TraceSizeMaxZero;

    const compaction_block_count_min = StateMachine.Forest.Options.compaction_block_count_min;
    return .{
        .addresses = start.addresses,
        .cache_grid_blocks = @intCast(@divExact(cache_grid_size, constants.block_size)),
        .cache_rows_count = cache_rows_count,
        .storage_size_limit = constants.storage_size_limit_default,
        .pipeline_requests_limit = if (start.development)
            0
        else
            stdx.div_ceil(constants.clients_max, 2) - constants.pipeline_prepare_queue_max,
        .request_size_limit = constants.message_size_max,
        .lsm_forest_compaction_block_count = if (start.development)
            compaction_block_count_min
        else
            compaction_block_count_min + constants.lsm_compaction_iops_write_max,
        .lsm_forest_node_count = @intCast(@divExact(
            constants.lsm_manifest_memory_size_default,
            constants.lsm_manifest_node_size,
        )),
        .statsd = statsd,
        .trace = start.trace,
        .trace_size_max = trace_size_max,
        .development = start.development,
        .log_debug = start.log_debug,
        .path = start.path,
    };
}

test format_validate {
    const valid: Command.Format = .{
        .cluster = 1,
        .replica = 2,
        .replica_count = 3,
        .development = false,
        .log_debug = false,
        .path = "0_2.nerva",
    };
    try std.testing.expectEqual(valid, try format_validate(valid));

    var format = valid;
    format.replica_count = 0;
    try std.testing.expectError(error.ReplicaCountZero, format_validate(format));

    format = valid;
    format.replica_count = constants.replicas_max + 1;
    try std.testing.expectError(error.ReplicaCountTooLarge, format_validate(format));

    format = valid;
    format.replica = 3;
    try std.testing.expectError(error.ReplicaIndexOutOfRange, format_validate(format));
}

test statsd_parse {
    const ipv4 = try statsd_parse("10.0.0.7:9125");
    try std.testing.expectEqual(@as(u16, 9125), ipv4.port);
    try std.testing.expectEqual(stdx.IPAddress.Family.IPv4, ipv4.ip.family());

    const ipv6 = try statsd_parse("[fdaa::2]:9125");
    try std.testing.expectEqual(@as(u16, 9125), ipv6.port);
    try std.testing.expectEqual(stdx.IPAddress.Family.IPv6, ipv6.ip.family());

    try std.testing.expectEqual(@as(u16, statsd_port_default), (try statsd_parse("10.0.0.7")).port);
    try std.testing.expectEqual(@as(u16, 9125), (try statsd_parse("9125")).port);

    for ([_][]const u8{
        "",
        "10.0.0.7:",
        "10.0.0.7:0",
        "10.0.0.7:65536",
        "[fdaa::2",
        "fdaa::2:9125",
        "localhost:9125",
    }) |text| {
        try std.testing.expectError(error.StatsdAddressInvalid, statsd_parse(text));
    }
}

test cache_rows_resolve {
    try std.testing.expectEqual(cache_rows_multiple, try cache_rows_resolve(null));

    const mib_64: ByteSize = .{ .value = 64 * stdx.MiB };
    const rows_64 = try cache_rows_resolve(mib_64);
    try std.testing.expectEqual(@as(u32, 0), rows_64 % cache_rows_multiple);
    try std.testing.expect(rows_64 <= 64 * stdx.MiB / @sizeOf(nerva.Row));
    try std.testing.expect(rows_64 > 64 * stdx.MiB / @sizeOf(nerva.Row) - cache_rows_multiple);

    // One byte short of a set rounds down to nothing; exactly a set is the minimum.
    try std.testing.expectError(
        error.CacheRowsTooSmall,
        cache_rows_resolve(.{ .value = cache_rows_size_multiple - 1 }),
    );
    try std.testing.expectEqual(
        cache_rows_multiple,
        try cache_rows_resolve(.{ .value = cache_rows_size_multiple }),
    );
    // A size just over a set rounds down to one set.
    try std.testing.expectEqual(
        cache_rows_multiple,
        try cache_rows_resolve(.{ .value = cache_rows_size_multiple + @sizeOf(nerva.Row) }),
    );
}

test start_resolve {
    var diagnostic: ?[]const u8 = null;
    const addresses = try vsr.ClusterAddress.parse_flag_value("3001,3002,3003", &diagnostic);
    const start: StartArgs = .{
        .addresses = addresses,
        .cache_grid = null,
        .cache_rows = null,
        .statsd = null,
        .trace = null,
        .trace_size_max = null,
        .development = true,
        .log_debug = false,
        .path = "0_0.nerva",
    };

    const development = try start_resolve(start);
    try std.testing.expectEqual(@as(u8, 3), development.addresses.members_count());
    try std.testing.expectEqual(
        @divExact(cache_grid_size_min, constants.block_size),
        development.cache_grid_blocks,
    );
    try std.testing.expectEqual(@as(u32, 0), development.pipeline_requests_limit);
    try std.testing.expectEqual(constants.message_size_max, development.request_size_limit);
    try std.testing.expect(development.statsd == null);
    try std.testing.expect(development.trace == null);

    var observed = start;
    observed.statsd = "10.0.0.7:9125";
    observed.trace = "trace.json";
    const observed_start = try start_resolve(observed);
    try std.testing.expectEqual(@as(u16, 9125), observed_start.statsd.?.port);
    try std.testing.expectEqualStrings("trace.json", observed_start.trace.?);
    try std.testing.expectEqual(trace_size_default, observed_start.trace_size_max);

    var trace_bounded = observed;
    trace_bounded.trace_size_max = .{ .value = 64, .unit = .kib };
    try std.testing.expectEqual(64 * 1024, (try start_resolve(trace_bounded)).trace_size_max);

    var trace_size_alone = start;
    trace_size_alone.trace_size_max = .{ .value = 64, .unit = .kib };
    try std.testing.expectError(error.TraceSizeMaxWithoutTrace, start_resolve(trace_size_alone));

    var trace_size_zero = observed;
    trace_size_zero.trace_size_max = .{ .value = 0 };
    try std.testing.expectError(error.TraceSizeMaxZero, start_resolve(trace_size_zero));

    var trace_empty = start;
    trace_empty.trace = "";
    try std.testing.expectError(error.TracePathEmpty, start_resolve(trace_empty));

    var statsd_invalid = start;
    statsd_invalid.statsd = "10.0.0.7:";
    try std.testing.expectError(error.StatsdAddressInvalid, start_resolve(statsd_invalid));

    var production_args = start;
    production_args.development = false;
    const production = try start_resolve(production_args);
    try std.testing.expect(production.cache_grid_blocks >= development.cache_grid_blocks);
    try std.testing.expect(production.lsm_forest_compaction_block_count >
        development.lsm_forest_compaction_block_count);

    var small = start;
    small.cache_grid = .{ .value = constants.block_size };
    if (cache_grid_size_min > constants.block_size) {
        try std.testing.expectError(error.CacheGridTooSmall, start_resolve(small));
    }

    var unaligned = start;
    unaligned.cache_grid = .{ .value = cache_grid_size_min + 1 };
    try std.testing.expectError(error.CacheGridNotBlockMultiple, start_resolve(unaligned));
}
