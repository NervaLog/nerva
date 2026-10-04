//! The `nerva` binary: `format`, `start` and `version`.
//!
//! Trimmed from TigerBeetle's `src/tigerbeetle/main.zig`: no REPL, benchmark, inspection, AOF or
//! upgrades between releases (every replica runs the single bundled release).

const std = @import("std");
const log = std.log.scoped(.main);

const stdx = @import("stdx");
const vsr = @import("vsr.zig");
const constants = @import("constants.zig");
const config = constants.config;
const cli = @import("nerva/cli.zig");
const Client = @import("nerva/client.zig").Client;
const ledgerd = @import("nerva/ledgerd/server.zig");
const view_server = @import("nerva/view/server.zig");

const IO = @import("io.zig").IO;
const Tracer = @import("trace.zig").Tracer;
const Storage = @import("storage.zig").StorageType(IO);
const AOF = @import("aof.zig").AOFType(IO);
const MessageBus = @import("message_bus.zig").MessageBusType(IO);
const MessagePool = @import("message_pool.zig").MessagePool;
const StateMachine = @import("nerva/state_machine.zig").StateMachineType(Storage);
const Replica = vsr.ReplicaType(StateMachine, MessageBus, Storage, AOF);
const data_file_size_min = @import("vsr/superblock.zig").data_file_size_min;

const MiB = stdx.MiB;

/// The runtime maximum log level: `.info`, or `.debug` with `--log-debug`.
pub var log_level_runtime: std.log.Level = .info;

pub fn log_runtime(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(log_level_runtime)) {
        stdx.log_with_timestamp(message_level, scope, format, args);
    }
}

pub const std_options: std.Options = .{
    // Messages are filtered at runtime by `log_level_runtime`.
    .log_level = .debug,
    .logFn = log_runtime,
};

pub fn main() !void {
    var allocator: std.heap.GeneralPurposeAllocator(.{}) = .init;
    allocator.backing_allocator = stdx.huge_page_allocator;
    const gpa = allocator.allocator();
    defer switch (allocator.deinit()) {
        .ok => {},
        .leak => @panic("memory leaked"),
    };

    var flags = stdx.Flags.init(gpa);
    defer flags.deinit(gpa);

    const command = cli.parse_args(&flags);
    switch (command) {
        .version => {
            try std.io.getStdOut().writer().print("Nerva version {}\n", .{constants.semver});
            return;
        },
        .ledgerd => |*args| {
            log_level_runtime = if (args.log_debug) .debug else .info;
            try command_ledgerd(gpa, args);
        },
        .view => |*args| {
            log_level_runtime = if (args.log_debug) .debug else .info;
            try command_view(gpa, args);
        },
        inline .format, .start => |*args, tag| {
            log_level_runtime = if (args.log_debug) .debug else .info;

            // Initialise IO before creating any file, so a failure leaves nothing behind.
            var io = try IO.init(if (tag == .format) 2048 else 128, 0);
            defer io.deinit();

            var time_os: stdx.TimeOS = .{};
            const time = time_os.interface();

            var tracer = try Tracer.init(gpa, time, .unknown, .{});
            defer tracer.deinit(gpa);

            var storage = try Storage.init(&io, &tracer, .{
                .path = args.path,
                .size_min = data_file_size_min,
                .purpose = if (tag == .format) .format else .open,
                .direct_io = if (!constants.direct_io)
                    .direct_io_disabled
                else if (args.development)
                    .direct_io_optional
                else
                    .direct_io_required,
            });
            defer storage.deinit();

            switch (tag) {
                .format => try command_format(gpa, &storage, args),
                .start => try command_start(gpa, &io, time, &tracer, &storage, args),
                .version, .ledgerd, .view => comptime unreachable,
            }
        },
    }
}

fn command_format(
    gpa: std.mem.Allocator,
    storage: *Storage,
    args: *const cli.Command.Format,
) !void {
    try vsr.format(Storage, gpa, storage, .{
        .cluster = args.cluster,
        .replica = args.replica,
        .replica_count = args.replica_count,
        .release = config.process.release,
        .view = null,
    });
    log.info("{}: formatted: cluster={} replica_count={}", .{
        args.replica,
        args.cluster,
        args.replica_count,
    });
}

fn command_start(
    base_allocator: std.mem.Allocator,
    io: *IO,
    time: stdx.Time,
    tracer: *Tracer,
    storage: *Storage,
    args: *const cli.Command.Start,
) !void {
    var counting_allocator = vsr.CountingAllocator.init(base_allocator);
    const gpa = counting_allocator.allocator();

    var message_pool = try MessagePool.init(gpa, .{ .replica = .{
        .members_count = args.addresses.members_count(),
        .pipeline_requests_limit = args.pipeline_requests_limit,
        .message_bus = .tcp,
    } });
    defer message_pool.deinit(gpa);

    var replica: Replica = undefined;
    replica.open(gpa, time, storage, &message_pool, .{
        .node_count = args.addresses.members_count(),
        .release = config.process.release,
        .release_client_min = config.process.release_client_min,
        .multiversion = .single_release(config.process.release),
        .pipeline_requests_limit = args.pipeline_requests_limit,
        .storage_size_limit = args.storage_size_limit,
        .aof = null,
        .aof_recovery = false,
        .random_nonce = stdx.crypto_u128(),
        .timeout_prepare_ticks = null,
        .timeout_grid_repair_message_ticks = null,
        .commit_stall_probability = null,
        .commit_stall_lag_min = null,
        .commit_stall_lag_max = null,
        .commit_stall_multiple_max = null,
        .state_machine_options = .{
            .batch_size_limit = args.request_size_limit - @sizeOf(vsr.Header),
            .lsm_forest_compaction_block_count = args.lsm_forest_compaction_block_count,
            .lsm_forest_node_count = args.lsm_forest_node_count,
        },
        .message_bus_options = .{
            .configuration = args.addresses.slice(),
            .io = io,
            .trace = tracer,
            .time = time,
            .clients_limit = constants.pipeline_prepare_queue_max + args.pipeline_requests_limit,
        },
        .grid_cache_blocks_count = args.cache_grid_blocks,
        .tracer = tracer,
    }) catch |err| switch (err) {
        error.NoAddress => vsr.fatal(.cli, "all --addresses must be provided", .{}),
        else => |e| return e,
    };

    log.info("{}: allocated {}MiB during replica init", .{
        replica.replica,
        @divFloor(counting_allocator.live_size(), MiB),
    });
    log.info("{}: cluster={}: listening on {}", .{
        replica.replica,
        replica.cluster,
        replica.message_bus.accept_address.?,
    });

    // `--addresses=0`: the OS picks a free port, which is printed (alone) to stdout so a parent
    // process can learn it, and the replica exits when its stdin closes. For tests.
    if (args.addresses.zero) {
        const stdout = std.io.getStdOut();
        try stdout.writer().print("{}\n", .{replica.message_bus.accept_address.?.port});
        stdout.close();

        const watchdog = try std.Thread.spawn(.{}, struct {
            fn thread_main() void {
                var buffer: [1]u8 = .{0};
                _ = std.io.getStdIn().read(&buffer) catch {};
                log.info("stdin closed, exiting", .{});
                std.process.exit(0);
            }
        }.thread_main, .{});
        watchdog.detach();
    }

    if (config.process.release.testing() and replica.cluster != 0) {
        // Guard against running test binaries against production clusters.
        @panic("This is a test binary, but the cluster id is non-zero.");
    }

    while (true) {
        replica.tick();
        try io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
    }
}

fn command_ledgerd(gpa: std.mem.Allocator, args: *const cli.Command.Ledgerd) !void {
    const key = std.posix.getenv("LEDGER_KEY") orelse "";
    if (key.len == 0) vsr.fatal(.cli, "ledgerd: set LEDGER_KEY", .{});

    var client: Client = undefined;
    try client.init(gpa, .{
        .cluster = args.cluster,
        .addresses = args.addresses.slice(),
        .timeout = stdx.Duration.seconds(30),
    });
    defer client.deinit();

    try ledgerd.serve(gpa, &client, .{
        .listen = args.listen,
        .key = key,
        .ledger = args.ledger,
        .on_listening = on_listening,
    });
}

fn command_view(gpa: std.mem.Allocator, args: *const cli.Command.View) !void {
    const key = std.posix.getenv("LEDGER_KEY") orelse "";
    if (key.len == 0) vsr.fatal(.cli, "view: set LEDGER_KEY", .{});

    var client: Client = undefined;
    try client.init(gpa, .{
        .cluster = args.cluster,
        .addresses = args.addresses.slice(),
        .timeout = stdx.Duration.seconds(30),
    });
    defer client.deinit();

    try view_server.serve(gpa, &client, .{
        .listen = args.listen,
        .key = key,
        .on_listening = on_listening,
    });
}

/// For `--listen=…:0`: print the bound port, alone, so a parent process can learn it.
fn on_listening(address: std.net.Address) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("{}\n", .{address.getPort()}) catch {};
}
