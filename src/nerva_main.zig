//! The `nerva` binary: `format`, `start`, `view`, `api`, `export`, `import`, `recover` and
//! `version`.
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
const diagnostic = @import("nerva/diagnostic.zig");
const timings = @import("nerva/timings.zig");
const Client = @import("nerva/client.zig").Client;
const view_server = @import("nerva/view/server.zig");
const api_server = @import("nerva/api/server.zig");
const http_connection = @import("nerva/http_connection.zig");
const export_file = @import("nerva/export_file.zig");
const export_ = @import("nerva/export.zig");
const import_ = @import("nerva/import.zig");
const recover = @import("nerva/recover.zig");
const backup = @import("nerva/backup.zig");
const release_peers = @import("nerva/release_peers.zig");
const peer_auth = @import("nerva/peer_auth.zig");
const preflight = @import("nerva/preflight.zig");

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
    // The first reason an export or an import logs goes into the failure that follows.
    if (message_level == .err and (scope == .import_ or scope == .export_)) {
        diagnostic.note(format, args);
    }
    if (@intFromEnum(message_level) <= @intFromEnum(log_level_runtime)) {
        stdx.log_with_timestamp(message_level, scope, format, args);
    }
}

pub const std_options: std.Options = .{
    // Messages are filtered at runtime by `log_level_runtime`.
    .log_level = .debug,
    .logFn = log_runtime,
};

pub fn main() void {
    run() catch |err| diagnostic.fail_error(err);
}

fn log_level_set(log_debug: bool) void {
    log_level_runtime = if (log_debug) .debug else .info;
    diagnostic.debug = log_debug;
}

fn run() !void {
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
    diagnostic.command = @tagName(command);
    switch (command) {
        .version => {
            try std.io.getStdOut().writer().print("Nerva version {}\n", .{constants.semver});
            return;
        },
        .view => |*args| {
            log_level_set(args.log_debug);
            try command_view(gpa, args);
        },
        .api => |*args| {
            log_level_set(args.log_debug);
            try command_api(gpa, args);
        },
        .@"export" => |*args| {
            log_level_set(args.log_debug);
            command_export("export", gpa, args) catch |err| {
                std.fs.cwd().deleteFile(args.output) catch {};
                export_failed("export", args.output, err);
            };
        },
        .backup => |*args| {
            log_level_set(args.log_debug);
            command_backup(gpa, args);
        },
        .import => |*args| {
            log_level_set(args.log_debug);
            import_run("import", gpa, args, null);
        },
        .restore => |*args| {
            log_level_set(args.import.log_debug);
            import_run("restore", gpa, &args.import, args.manifest);
        },
        .recover => |*args| {
            log_level_runtime = if (args.log_debug) .debug else .info;
            recover.run(gpa, .{
                .cluster = args.cluster,
                .replica = args.replica,
                .replica_count = args.replica_count,
                .addresses = args.addresses.slice(),
                .origin = args.origin,
                .development = args.development,
                .path = args.path,
            });
        },
        inline .format, .start => |*args, tag| {
            log_level_set(args.log_debug);

            // Operator input never reaches a vendored panic: check the kernel, and for `start`
            // the data file, before the vendored open (R5, P149).
            preflight.kernel_check();
            if (tag == .start) preflight.start(gpa, args.path, if (!constants.direct_io)
                .disabled
            else if (args.development)
                .optional
            else
                .required);

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
                        error.PathAlreadyExists => diagnostic.fail(
                            "NRV-E0004",
                            "start: --trace {s} exists",
                            .{args.trace.?},
                            "give a new path: nerva never overwrites a file",
                            .{},
                        ),
                        else => diagnostic.fail_file(args.trace.?, err),
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

            var storage = Storage.init(&io, &tracer, .{
                .path = args.path,
                .size_min = data_file_size_min,
                .purpose = if (tag == .format) .format else .open,
                .direct_io = if (!constants.direct_io)
                    .direct_io_disabled
                else if (args.development)
                    .direct_io_optional
                else
                    .direct_io_required,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => diagnostic.fail(
                    "NRV-E0005",
                    "format: {s} exists",
                    .{args.path},
                    "give a new path, or remove the old file if it is really unwanted",
                    .{},
                ),
                else => return err,
            };
            defer storage.deinit();

            switch (tag) {
                .format => try command_format(gpa, &storage, args),
                .start => try command_start(gpa, &io, time, &tracer, &storage, args),
                .version, .view, .api, .@"export", .backup, .import, .restore, .recover => comptime unreachable,
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

/// The first reason an export or import logged, for a failure's headline.
fn refusal_reason() []const u8 {
    const buffer = struct {
        var bytes: [768]u8 = undefined;
    };
    return diagnostic.reason_take(&buffer.bytes) orelse "see the log above";
}

/// Exits with the code for an export that failed; `output` is the file it was writing.
fn export_failed(comptime command: []const u8, output: []const u8, err: anyerror) noreturn {
    switch (err) {
        error.Timeout => diagnostic.fail(
            "NRV-E0801",
            command ++ ": no reply from the cluster",
            .{},
            "check --cluster and --addresses, and that a quorum of replicas is running",
            .{},
        ),
        error.AsOfAhead => diagnostic.fail(
            "NRV-E0802",
            command ++ ": --as-of is past the cluster's latest op",
            .{},
            "give --as-of=latest or an op the cluster has reached",
            .{},
        ),
        error.TooManyTables => diagnostic.fail(
            "NRV-E0803",
            command ++ ": more than {} tables hold rows; an export checks at most that many",
            .{export_file.tables_max},
            "keep fewer tables with rows, then export again",
            .{},
        ),
        error.TooManyCatalogRows, error.ViewRefused => diagnostic.fail(
            "NRV-E0803",
            command ++ ": `nerva import` would refuse this export: {s}",
            .{refusal_reason()},
            "fix what the log names, then export again",
            .{},
        ),
        error.RecordsAppeared => diagnostic.fail(
            "NRV-E0803",
            command ++ ": records or an index appeared during the export",
            .{},
            "export again",
            .{},
        ),
        else => diagnostic.fail_file(output, err),
    }
}

/// `import` and `restore`: creates the data file at `args.path` from an export. With a manifest
/// (`restore`) the manifest is read first and the export is compared with it before any file
/// exists (R5, P149).
fn import_run(
    comptime command: []const u8,
    gpa: std.mem.Allocator,
    args: *const cli.Command.Import,
    manifest_path: ?[]const u8,
) void {
    preflight.kernel_check();
    // Before reading the export, which may be large: the data file must be new. The
    // import writes `<path>.importing` and links it to `<path>` once its checks pass,
    // so a failed or killed import never leaves a file a replica would start from (#78).
    if (std.fs.cwd().access(args.path, .{})) {
        diagnostic.fail(
            "NRV-E0004",
            command ++ ": {s} exists",
            .{args.path},
            "give a new path: nerva never overwrites a data file",
            .{},
        );
    } else |_| {}
    var path_importing_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_importing = std.fmt.bufPrint(
        &path_importing_buffer,
        "{s}.importing",
        .{args.path},
    ) catch diagnostic.fail_file(args.path, error.NameTooLong);
    if (std.fs.cwd().access(path_importing, .{})) {
        diagnostic.fail(
            "NRV-E0806",
            command ++ ": {s} is left from an import that did not finish",
            .{path_importing},
            "remove {s}, then {s} again",
            .{ path_importing, command },
        );
    } else |_| {}
    // The manifest first: a backup is compared with a record it did not carry.
    var manifest: backup.Manifest = undefined;
    if (manifest_path) |path| manifest_read(command, path, &manifest);
    // Pass 1, before the data file exists: the whole export is checked.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const plan = import_.plan(arena.allocator(), args.input) catch |err|
        import_failed(command, args.input, args.path, err);
    if (manifest_path) |path| manifest_compare(command, args, path, &manifest, &plan);
    // Pass 2. Any failure removes the data file, which the import created.
    command_import(gpa, args, path_importing, &plan) catch |err| {
        std.fs.cwd().deleteFile(path_importing) catch {};
        import_failed(command, args.input, path_importing, err);
    };
    // Every write is on disk: the data file is complete, and takes its name.
    const cwd = std.posix.AT.FDCWD;
    std.posix.linkat(cwd, path_importing, cwd, args.path, 0) catch |err| {
        std.fs.cwd().deleteFile(path_importing) catch {};
        diagnostic.fail_file(args.path, err);
    };
    std.fs.cwd().deleteFile(path_importing) catch |err| {
        diagnostic.fail_file(path_importing, err);
    };
    directory_sync(args.path) catch |err| {
        diagnostic.fail_file(args.path, err);
    };
    if (manifest_path != null) {
        var counts_buffer: [64]u8 = undefined;
        std.io.getStdOut().writer().print(
            "restored replica {} from backup {} at op {}: {s} match the manifest\n",
            .{
                args.replica,
                std.fmt.fmtSliceHexLower(&plan.origin),
                plan.summary.as_of,
                backup.counts_text(&counts_buffer, &manifest),
            },
        ) catch {};
    }
}

/// Reads and parses the manifest at `path`; exits with NRV-E0808 if it is not one.
fn manifest_read(comptime command: []const u8, path: []const u8, manifest: *backup.Manifest) void {
    const fix = "give the .manifest.json that nerva backup wrote beside the backup";
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => diagnostic.fail(
            "NRV-E0808",
            command ++ ": {s}: the manifest does not exist",
            .{path},
            fix,
            .{},
        ),
        else => diagnostic.fail_file(path, err),
    };
    defer file.close();
    // One byte more than the bound, to tell a manifest at the bound from one past it.
    var buffer: [backup.manifest_size_max + 1]u8 = undefined;
    const size = file.readAll(&buffer) catch |err| diagnostic.fail_file(path, err);
    backup.parse(buffer[0..size], manifest) catch |err| diagnostic.fail(
        "NRV-E0808",
        command ++ ": {s}: {s}",
        .{ path, switch (err) {
            error.Malformed => "it is not a manifest this release writes",
            error.TooLarge => "it is larger than a manifest can be",
            error.UnknownVersion => "its version is not one this release reads",
        } },
        fix,
        .{},
    );
}

/// Exits with NRV-E0809 unless the verified export (`plan`) is the one `manifest` describes.
fn manifest_compare(
    comptime command: []const u8,
    args: *const cli.Command.Import,
    manifest_path: []const u8,
    manifest: *const backup.Manifest,
    plan: *const import_.Plan,
) void {
    const stat = std.fs.cwd().statFile(args.input) catch |err|
        diagnostic.fail_file(args.input, err);
    const actual = backup.from_plan(plan, manifest.release_slice(), manifest.cluster, stat.size);
    var difference_buffer: [512]u8 = undefined;
    const difference = backup.first_difference(&difference_buffer, manifest, &actual) orelse
        return;
    diagnostic.fail(
        "NRV-E0809",
        command ++ ": {s} does not match {s}: {s}",
        .{ args.input, manifest_path, difference },
        "use the backup the manifest names, or another backup with its own manifest",
        .{},
    );
}

/// `nerva backup`: an export, read back as `import` reads it, and its manifest beside it.
fn command_backup(gpa: std.mem.Allocator, args: *const cli.Command.Backup) void {
    var manifest_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_path = std.fmt.bufPrint(
        &manifest_path_buffer,
        "{s}" ++ backup.manifest_suffix,
        .{args.output},
    ) catch diagnostic.fail_file(args.output, error.NameTooLong);
    // Neither file is ever overwritten; the manifest is checked first so that no backup is
    // made that could not be completed.
    if (std.fs.cwd().access(manifest_path, .{})) {
        manifest_exists(manifest_path);
    } else |_| {}

    command_export("backup", gpa, args) catch |err| {
        std.fs.cwd().deleteFile(args.output) catch {};
        export_failed("backup", args.output, err);
    };
    // A backup that `restore` would refuse is refused now.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const plan = import_.plan(arena.allocator(), args.output) catch |err| {
        std.fs.cwd().deleteFile(args.output) catch {};
        backup_unreadable(args.output, err);
    };
    const size = (std.fs.cwd().statFile(args.output) catch |err| {
        std.fs.cwd().deleteFile(args.output) catch {};
        diagnostic.fail_file(args.output, err);
    }).size;
    const release = config.process.release.triple();
    var release_buffer: [backup.release_size_max]u8 = undefined;
    const release_text = std.fmt.bufPrint(&release_buffer, "{}.{}.{}", .{
        release.major,
        release.minor,
        release.patch,
    }) catch unreachable; // Three u16 and two dots fit.
    const manifest = backup.from_plan(&plan, release_text, args.cluster, size);
    var buffer: [backup.manifest_size_max]u8 = undefined;
    const bytes = backup.render(&manifest, &buffer);

    const file = std.fs.cwd().createFile(manifest_path, .{ .exclusive = true }) catch |err| {
        std.fs.cwd().deleteFile(args.output) catch {};
        if (err == error.PathAlreadyExists) manifest_exists(manifest_path);
        diagnostic.fail_file(manifest_path, err);
    };
    manifest_write(file, bytes, args.output) catch |err| {
        file.close();
        std.fs.cwd().deleteFile(manifest_path) catch {};
        std.fs.cwd().deleteFile(args.output) catch {};
        diagnostic.fail_file(manifest_path, err);
    };
    file.close();
    log.info("backup {s}: op {}, {} bytes, SHA-256 {}", .{
        args.output,
        plan.summary.as_of,
        size,
        std.fmt.fmtSliceHexLower(&plan.origin),
    });
    std.io.getStdOut().writer().print("backup {s}: op {}, sha256 {}\nmanifest {s}\n", .{
        args.output,
        plan.summary.as_of,
        std.fmt.fmtSliceHexLower(&plan.origin),
        manifest_path,
    }) catch {};
}

fn manifest_exists(manifest_path: []const u8) noreturn {
    diagnostic.fail(
        "NRV-E0004",
        "backup: {s} exists",
        .{manifest_path},
        "give a new --output: nerva never overwrites a file",
        .{},
    );
}

/// Writes and syncs the manifest, then makes it and the backup durable.
fn manifest_write(file: std.fs.File, bytes: []const u8, output: []const u8) !void {
    try file.writeAll(bytes);
    try file.sync();
    try directory_sync(output);
}

/// The backup just written does not read back as `import` reads it.
fn backup_unreadable(output: []const u8, err: anyerror) noreturn {
    switch (err) {
        error.Corrupt => diagnostic.fail(
            "NRV-E0804",
            "backup: {s}: {s}",
            .{ output, export_file.corrupt_reason },
            "check the disk, then back up again; nothing was named {s}",
            .{output},
        ),
        error.VersionUnsupported => diagnostic.fail(
            "NRV-E0805",
            "backup: {s}: the export's version is not one this release reads",
            .{output},
            "back up again; nothing was named {s}",
            .{output},
        ),
        error.Refused, error.ChecksFailed => diagnostic.fail(
            "NRV-E0803",
            "backup: `nerva import` would refuse this export: {s}",
            .{refusal_reason()},
            "fix what the log names, then back up again; nothing was named {s}",
            .{output},
        ),
        else => diagnostic.fail_file(output, err),
    }
}

/// Exits with the code for an import that failed in `plan` or while restoring.
fn import_failed(
    comptime command: []const u8,
    input: []const u8,
    output: []const u8,
    err: anyerror,
) noreturn {
    switch (err) {
        error.Corrupt => diagnostic.fail(
            "NRV-E0804",
            command ++ ": {s}: {s}",
            .{ input, export_file.corrupt_reason },
            "use an intact export, or export again",
            .{},
        ),
        error.VersionUnsupported => diagnostic.fail(
            "NRV-E0805",
            command ++ ": {s}: the export's version is not one this release reads",
            .{input},
            "import it with a release that reads it, or export again with this one",
            .{},
        ),
        error.Refused, error.ChecksFailed => diagnostic.fail(
            "NRV-E0807",
            command ++ ": the export was refused: {s}",
            .{refusal_reason()},
            "read the log lines above; nothing was named {s}",
            .{output},
        ),
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.IsDir,
        => diagnostic.fail_file(input, err),
        else => diagnostic.fail_file(output, err),
    }
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
        .origin = plan.origin,
    });
    try import_.ImporterType(Storage).run(gpa, time, &tracer, &storage, .{
        .cluster = args.cluster,
        .release = config.process.release,
        .input = args.input,
    }, plan);
    // Import cannot see the cluster, so it says what it needs (P90): a replica imported alone
    // into a cluster that ran on has forgotten the prepares the replica it replaces acknowledged.
    log.warn("{}: start this replica only with every replica imported from {s}, before the " ++
        "cluster runs; to replace a replica of a running cluster, export it again and import " ++
        "every replica", .{ args.replica, args.input });
    log.info("{}: imported {s}: cluster={} replica_count={} op={} export={s}", .{
        args.replica,
        args.input,
        args.cluster,
        args.replica_count,
        plan.summary.as_of,
        release_peers.origin_name(&plan.origin),
    });
}

/// Writes the export to a new file; a failure leaves the caller to remove it (N80).
fn command_export(
    comptime command: []const u8,
    gpa: std.mem.Allocator,
    args: *const cli.Command.Export,
) !void {
    // Never an existing file: a path given by mistake would be truncated.
    const file = std.fs.cwd().createFile(args.output, .{ .exclusive = true }) catch |err|
        switch (err) {
            error.PathAlreadyExists => diagnostic.fail(
                "NRV-E0004",
                command ++ ": {s} exists",
                .{args.output},
                "give a new path: nerva never overwrites a file",
                .{},
            ),
            else => diagnostic.fail_file(args.output, err),
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
    // Version 1 unless the cluster holds records or indexes (P123b), so that the release
    // before can import it.
    var writer = try export_file.WriterType(@TypeOf(buffered).Writer).init(
        buffered.writer(),
        try export_.format_version(&client),
    );
    const summary = try export_.run(gpa, &client, &writer, args.as_of);
    try buffered.flush();
    try file.sync();
    log.info("exported to {s}: op {}, {} changes, {} views, {} ledgers, {} tables, " ++
        "export {s}", .{
        args.output,
        summary.as_of,
        summary.change_count,
        summary.view_count,
        summary.ledger_count,
        summary.table_count,
        release_peers.origin_name(&writer.digest),
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
    const peer_keys = cluster_keys(args);

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
        // Replicas prove to each other that they hold the cluster key (P102).
        .peer_keys = peer_keys,
        .pipeline_requests_limit = args.pipeline_requests_limit,
        .storage_size_limit = args.storage_size_limit,
        .aof = null,
        .aof_recovery = false,
        .random_nonce = stdx.crypto_u128(),
        .timeout_prepare_ticks = null,
        .timeout_grid_repair_message_ticks = null,
        .commit_stall_probability = args.commit_stall_probability,
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
        error.NoAddress => diagnostic.fail(
            "NRV-E0710",
            "start: all --addresses must be provided",
            .{},
            "give every replica's address, in replica order",
            .{},
        ),
        else => |e| return e,
    };

    log.info("{}: allocated {}MiB during replica init", .{
        replica.replica,
        @divFloor(counting_allocator.live_size(), MiB),
    });
    log.info("{}: cluster={}: listening on {}; data file from export {s}", .{
        replica.replica,
        replica.cluster,
        replica.message_bus.accept_address.?,
        release_peers.origin_name(&replica.superblock.working.vsr_state.origin),
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

/// The cluster keys replicas authenticate each other with (P102), from `NERVA_CLUSTER_KEY` and
/// `NERVA_CLUSTER_KEY_NEXT`. Exits, naming the variable and never a key, when they cannot be used.
fn cluster_keys(args: *const cli.Command.Start) peer_auth.Keys {
    const resolved = peer_auth.keys_resolve(
        std.posix.getenv("NERVA_CLUSTER_KEY"),
        std.posix.getenv("NERVA_CLUSTER_KEY_NEXT"),
        args.development,
        args.addresses.slice(),
    );
    return switch (resolved) {
        .keys => |keys| keys,
        .development => keys: {
            log.warn("NERVA_CLUSTER_KEY is unset: replicas authenticate each other with the " ++
                "public development key (--development, loopback addresses only)", .{});
            break :keys .{ .current = peer_auth.development_key };
        },
        .refused => |reason| diagnostic.fail(
            "NRV-E0901",
            "start: {s}",
            .{reason},
            "set NERVA_CLUSTER_KEY (and NERVA_CLUSTER_KEY_NEXT during a rotation) as the message says",
            .{},
        ),
    };
}

fn command_view(gpa: std.mem.Allocator, args: *const cli.Command.View) !void {
    const keys = gateway_keys("view");

    var client: Client = undefined;
    try client.init(gpa, .{
        .cluster = args.cluster,
        .addresses = args.addresses.slice(),
        .timeout = stdx.Duration.ms(args.request_timeout_ms),
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

    // Outside the client, which is replaced when it breaks: what the gateway reports survives it.
    var tally: timings.Tally = .{};
    var client: Client = undefined;
    try client.init(gpa, .{
        .cluster = args.cluster,
        .addresses = args.addresses.slice(),
        .timeout = stdx.Duration.ms(args.request_timeout_ms),
        .tally = &tally,
    });
    defer client.deinit();

    try api_server.serve(gpa, &client, .{
        .listen = args.listen,
        .keys = keys,
        .on_listening = on_listening,
        .statsd = args.statsd,
        .cluster = args.cluster,
        .tally = &tally,
    });
}

/// `NERVA_KEY` and, during a rotation, `NERVA_KEY_NEXT` (P96). Exits if they cannot be used; the
/// message never names a key.
fn gateway_keys(comptime command: []const u8) http_connection.Keys {
    const current = std.posix.getenv("NERVA_KEY") orelse "";
    const next = std.posix.getenv("NERVA_KEY_NEXT");
    if (http_connection.Keys.invalid(current, next)) |reason| {
        diagnostic.fail(
            "NRV-E0008",
            command ++ ": {s}",
            .{reason},
            "set NERVA_KEY; during a rotation NERVA_KEY_NEXT differs from it",
            .{},
        );
    }
    if (next != null) log.info(command ++ ": accepting NERVA_KEY and NERVA_KEY_NEXT", .{});
    return .{ .current = current, .next = next };
}

/// For `--listen=…:0`: print the bound port, alone, so a parent process can learn it.
fn on_listening(address: std.net.Address) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("{}\n", .{address.getPort()}) catch {};
}
