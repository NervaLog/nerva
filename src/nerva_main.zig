//! The `nerva` binary: `format`, `start`, `view`, `api`, `export`, `import` and `version`.
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
const view_server = @import("nerva/view/server.zig");
const api_server = @import("nerva/api/server.zig");
const http_connection = @import("nerva/http_connection.zig");
const export_file = @import("nerva/export_file.zig");
const export_ = @import("nerva/export.zig");
const import_ = @import("nerva/import.zig");

const IO = @import("io.zig").IO;
const Tracer = @import("trace.zig").Tracer;
const TraceFile = @import("nerva/trace_file.zig").TraceFile;
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
        .view => |*args| {
            log_level_runtime = if (args.log_debug) .debug else .info;
            try command_view(gpa, args);
        },
        .api => |*args| {
            log_level_runtime = if (args.log_debug) .debug else .info;
            try command_api(gpa, args);
        },
        .@"export" => |*args| {
            log_level_runtime = if (args.log_debug) .debug else .info;
            command_export(gpa, args) catch |err| {
                std.fs.cwd().deleteFile(args.output) catch {};
                switch (err) {
                    error.Timeout => vsr.fatal(
                        .cli,
                        "export: no reply from the cluster: check --cluster and --addresses",
                        .{},
                    ),
                    error.AsOfAhead => vsr.fatal(
                        .cli,
                        "export: --as-of is past the cluster's latest op",
                        .{},
                    ),
                    error.TooManyTables => vsr.fatal(
                        .cli,
                        "export: more than {} tables hold rows; an export checks at most that many",
                        .{export_file.tables_max},
                    ),
                    error.TooManyCatalogRows, error.ViewRefused => vsr.fatal(
                        .cli,
                        "export: `nerva import` would refuse this export (see above)",
                        .{},
                    ),
                    else => vsr.fatal(.cli, "export: {s}", .{@errorName(err)}),
                }
            };
        },
        .import => |*args| {
            log_level_runtime = if (args.log_debug) .debug else .info;
            // Before reading the export, which may be large: the data file must be new. The
            // import writes `<path>.importing` and links it to `<path>` once its checks pass,
            // so a failed or killed import never leaves a file a replica would start from (#78).
            if (std.fs.cwd().access(args.path, .{})) {
                vsr.fatal(.cli, "import: {s} exists; give a new file", .{args.path});
            } else |_| {}
            var path_importing_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const path_importing = std.fmt.bufPrint(
                &path_importing_buffer,
                "{s}.importing",
                .{args.path},
            ) catch vsr.fatal(.cli, "import: {s}: the path is too long", .{args.path});
            if (std.fs.cwd().access(path_importing, .{})) {
                vsr.fatal(
                    .cli,
                    "import: {s} is left from an import that did not finish; remove it",
                    .{path_importing},
                );
            } else |_| {}
            // Pass 1, before the data file exists: the whole export is checked.
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const plan = import_.plan(arena.allocator(), args.input) catch |err| switch (err) {
                error.Corrupt => vsr.fatal(.cli, "import: {s}: {s}", .{
                    args.input,
                    export_file.corrupt_reason,
                }),
                else => vsr.fatal(.cli, "import: {s}: {s}", .{ args.input, @errorName(err) }),
            };
            // Pass 2. Any failure removes the data file, which the import created.
            command_import(gpa, args, path_importing, &plan) catch |err| {
                std.fs.cwd().deleteFile(path_importing) catch {};
                switch (err) {
                    error.Corrupt => vsr.fatal(.cli, "import: {s}: {s}", .{
                        args.input,
                        export_file.corrupt_reason,
                    }),
                    else => vsr.fatal(.cli, "import: {s}", .{@errorName(err)}),
                }
            };
            // Every write is on disk: the data file is complete, and takes its name.
            const cwd = std.posix.AT.FDCWD;
            std.posix.linkat(cwd, path_importing, cwd, args.path, 0) catch |err| {
                std.fs.cwd().deleteFile(path_importing) catch {};
                vsr.fatal(.cli, "import: {s}: {s}", .{ args.path, @errorName(err) });
            };
            std.fs.cwd().deleteFile(path_importing) catch |err| {
                vsr.fatal(.cli, "import: {s}: {s}", .{ path_importing, @errorName(err) });
            };
            directory_sync(args.path) catch |err| {
                vsr.fatal(.cli, "import: {s}: {s}", .{ args.path, @errorName(err) });
            };
        },
        inline .format, .start => |*args, tag| {
            log_level_runtime = if (args.log_debug) .debug else .info;

            // Initialise IO before creating any file, so a failure leaves nothing behind.
            var io = try IO.init(if (tag == .format) 2048 else 128, 0);
            defer io.deinit();

            var time_os: stdx.TimeOS = .{};
            const time = time_os.interface();

            // `start --trace` writes spans to a file; `start --statsd` sends metrics over UDP.
            // Never an existing file: a path given by mistake (the data file's, say) would be
            // truncated (#29).
            const trace_file: ?std.fs.File = if (tag == .start and args.trace != null)
                std.fs.cwd().createFile(args.trace.?, .{ .exclusive = true }) catch |err|
                    switch (err) {
                        error.PathAlreadyExists => vsr.fatal(
                            .cli,
                            "--trace: {s} exists; give a new file",
                            .{args.trace.?},
                        ),
                        else => return err,
                    }
            else
                null;
            defer if (trace_file) |file| file.close();
            var trace_file_writer: ?std.fs.File.Writer =
                if (trace_file) |file| file.writer() else null;
            // Buffered, bounded, and never failing: a trace write error must not panic the
            // replica (#30).
            var trace_writer: ?TraceFile = if (trace_file_writer) |*writer|
                .init(writer.any(), if (tag == .start) args.trace_size_max else unreachable)
            else
                null;
            defer if (trace_writer) |*writer| writer.flush();

            var tracer = try Tracer.init(gpa, time, .unknown, if (tag == .start) .{
                .writer = if (trace_writer) |*writer| writer.writer() else null,
                .statsd_options = if (args.statsd) |address|
                    .{ .udp = .{ .io = &io, .address = address } }
                else
                    .log,
            } else .{});
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
                .version, .view, .api, .@"export", .import => comptime unreachable,
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

/// Makes a new directory entry durable: the directory holding `path` is synced.
fn directory_sync(path: []const u8) !void {
    // Read-only, not `openDir`'s default `O_PATH`, which `fsync` refuses.
    const fd = try std.posix.open(std.fs.path.dirname(path) orelse ".", .{ .DIRECTORY = true }, 0);
    defer std.posix.close(fd);
    try std.posix.fsync(fd);
}

/// Formats the data file at `path`, then restores the export into it (N80).
fn command_import(
    gpa: std.mem.Allocator,
    args: *const cli.Command.Import,
    path: []const u8,
    plan: *const import_.Plan,
) !void {
    var io = try IO.init(2048, 0);
    defer io.deinit();
    var time_os: stdx.TimeOS = .{};
    const time = time_os.interface();
    var tracer = try Tracer.init(gpa, time, .unknown, .{});
    defer tracer.deinit(gpa);

    var storage = try Storage.init(&io, &tracer, .{
        .path = path,
        .size_min = data_file_size_min,
        .purpose = .format,
        .direct_io = if (!constants.direct_io)
            .direct_io_disabled
        else if (args.development)
            .direct_io_optional
        else
            .direct_io_required,
    });
    defer storage.deinit();

    try vsr.format(Storage, gpa, &storage, .{
        .cluster = args.cluster,
        .replica = args.replica,
        .replica_count = args.replica_count,
        .release = config.process.release,
        .view = null,
    });
    try import_.ImporterType(Storage).run(gpa, time, &tracer, &storage, .{
        .cluster = args.cluster,
        .release = config.process.release,
        .input = args.input,
    }, plan);
    log.info("{}: imported {s}: cluster={} replica_count={} op={}", .{
        args.replica,
        args.input,
        args.cluster,
        args.replica_count,
        plan.summary.as_of,
    });
}

/// Writes the export to a new file; a failure leaves the caller to remove it (N80).
fn command_export(gpa: std.mem.Allocator, args: *const cli.Command.Export) !void {
    // Never an existing file: a path given by mistake would be truncated.
    const file = std.fs.cwd().createFile(args.output, .{ .exclusive = true }) catch |err|
        switch (err) {
            error.PathAlreadyExists => vsr.fatal(
                .cli,
                "export: {s} exists; give a new file",
                .{args.output},
            ),
            else => return err,
        };
    defer file.close();

    var client: Client = undefined;
    try client.init(gpa, .{
        .cluster = args.cluster,
        .addresses = args.addresses.slice(),
        .timeout = stdx.Duration.seconds(30),
    });
    defer client.deinit();

    var buffered = std.io.bufferedWriter(file.writer());
    var writer = try export_file.WriterType(@TypeOf(buffered).Writer).init(buffered.writer());
    const summary = try export_.run(gpa, &client, &writer, args.as_of);
    try buffered.flush();
    try file.sync();
    log.info("exported to {s}: op {}, {} changes, {} views, {} ledgers, {} tables", .{
        args.output,
        summary.as_of,
        summary.change_count,
        summary.view_count,
        summary.ledger_count,
        summary.table_count,
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
        // Nerva bundles only its own release: peers of another release are ignored (N61, #34).
        .release_peers_strict = true,
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
            .cache_entries_rows = args.cache_rows_count,
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

fn command_view(gpa: std.mem.Allocator, args: *const cli.Command.View) !void {
    const keys = gateway_keys("view");

    var client: Client = undefined;
    try client.init(gpa, .{
        .cluster = args.cluster,
        .addresses = args.addresses.slice(),
        .timeout = stdx.Duration.seconds(30),
    });
    defer client.deinit();

    try view_server.serve(gpa, &client, .{
        .listen = args.listen,
        .keys = keys,
        .on_listening = on_listening,
    });
}

fn command_api(gpa: std.mem.Allocator, args: *const cli.Command.Api) !void {
    const keys = gateway_keys("api");

    var client: Client = undefined;
    try client.init(gpa, .{
        .cluster = args.cluster,
        .addresses = args.addresses.slice(),
        .timeout = stdx.Duration.seconds(30),
    });
    defer client.deinit();

    try api_server.serve(gpa, &client, .{
        .listen = args.listen,
        .keys = keys,
        .on_listening = on_listening,
    });
}

/// `NERVA_KEY` and, during a rotation, `NERVA_KEY_NEXT` (P96). Exits if they cannot be used; the
/// message never names a key.
fn gateway_keys(comptime command: []const u8) http_connection.Keys {
    const current = std.posix.getenv("NERVA_KEY") orelse "";
    const next = std.posix.getenv("NERVA_KEY_NEXT");
    if (http_connection.Keys.invalid(current, next)) |reason| {
        vsr.fatal(.cli, command ++ ": {s}", .{reason});
    }
    if (next != null) log.info(command ++ ": accepting NERVA_KEY and NERVA_KEY_NEXT", .{});
    return .{ .current = current, .next = next };
}

/// For `--listen=…:0`: print the bound port, alone, so a parent process can learn it.
fn on_listening(address: std.net.Address) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("{}\n", .{address.getPort()}) catch {};
}
