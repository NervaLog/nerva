//! Command-line arguments for the `nerva` binary.
//!
//! `CLIArgs` is what the operator typed; `Command` is what the binary runs, with every limit
//! resolved and validated. Validation is in pure functions returning errors, so that it can be
//! unit tested; `parse_args` turns those errors into a fatal exit.

const std = @import("std");

const stdx = @import("stdx");
const vsr = @import("../vsr.zig");
const constants = @import("../constants.zig");
const IO = @import("../io.zig").IO;
const Storage = @import("../storage.zig").StorageType(IO);
const ByteSize = stdx.ByteSize;

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
        development: bool = false,
        log_debug: bool = false,

        @"--": void,
        path: []const u8,
    },

    ledgerd: struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        ledger: u64,
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
        \\              [--development] [--log-debug] <path>
        \\
        \\  nerva ledgerd --cluster=<integer> --addresses=<addresses> --ledger=<integer>
        \\                --listen=<host:port> [--log-debug]
        \\
        \\  nerva version
        \\
        \\Commands:
        \\
        \\  format   Create a replica's data file at <path>.
        \\
        \\  start    Run a replica from the data file at <path>.
        \\
        \\  ledgerd  Serve the Botpike runtime's ledger protocol from the cluster at
        \\           <addresses>. The key is read from the LEDGER_KEY environment variable.
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
        \\  --ledger=<integer>
        \\        Which ledger of the cluster to serve; one cluster holds many.
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
    ledgerd: Ledgerd,
    version,

    pub const Ledgerd = struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        ledger: u64,
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
        storage_size_limit: u64,
        pipeline_requests_limit: u32,
        request_size_limit: u32,
        lsm_forest_compaction_block_count: u32,
        lsm_forest_node_count: u32,
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
            .development = start.development,
            .log_debug = start.log_debug,
            .path = start.path,
        }) catch |err| vsr.fatal(.cli, "start: {s}", .{error_message(err)}) },
        .ledgerd => |ledgerd| .{ .ledgerd = .{
            .cluster = ledgerd.cluster,
            .addresses = ledgerd.addresses,
            .ledger = ledgerd.ledger,
            .listen = listen_parse(ledgerd.listen) orelse
                vsr.fatal(.cli, "ledgerd: --listen must be <ipv4>:<port>", .{}),
            .log_debug = ledgerd.log_debug,
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
    development: bool,
    log_debug: bool,
    path: []const u8,
};

fn start_resolve(start: StartArgs) Error!Command.Start {
    const cache_grid_size: u64 = if (start.cache_grid) |size|
        size.bytes()
    else if (start.development)
        cache_grid_size_min
    else
        constants.grid_cache_size_default;
    if (cache_grid_size < cache_grid_size_min) return error.CacheGridTooSmall;
    if (cache_grid_size % constants.block_size != 0) return error.CacheGridNotBlockMultiple;

    const compaction_block_count_min = StateMachine.Forest.Options.compaction_block_count_min;
    return .{
        .addresses = start.addresses,
        .cache_grid_blocks = @intCast(@divExact(cache_grid_size, constants.block_size)),
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

test start_resolve {
    var diagnostic: ?[]const u8 = null;
    const addresses = try vsr.ClusterAddress.parse_flag_value("3001,3002,3003", &diagnostic);
    const start: StartArgs = .{
        .addresses = addresses,
        .cache_grid = null,
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
