//! Command-line arguments for the `nerva` binary.
//!
//! `CLIArgs` is what the operator typed; `Command` is what the binary runs, with every limit
//! resolved and validated. Validation is in pure functions returning errors, so that it can be
//! unit tested; `parse_args` turns those errors into a fatal exit.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");
const vsr = @import("../vsr.zig");
const diag = @import("diagnostic.zig");
const nerva = @import("../nerva.zig");
const constants = @import("../constants.zig");
const IO = @import("../io.zig").IO;
const Storage = @import("../storage.zig").StorageType(IO);
const ByteSize = stdx.ByteSize;
const trace_size_default = @import("trace_file.zig").size_max_default;

const StateMachine = @import("state_machine.zig").StateMachineType(Storage);
const recover = @import("recover.zig");
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
        commit_stall_probability: ?stdx.PRNG.Ratio = null,
        development: bool = false,
        log_debug: bool = false,

        @"--": void,
        path: []const u8,
    },

    view: struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        listen: []const u8,
        listen_remote: bool = false,
        request_timeout: u32 = request_timeout_default_ms,
        log_debug: bool = false,
    },

    api: struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        listen: []const u8,
        listen_remote: bool = false,
        request_timeout: u32 = request_timeout_default_ms,
        statsd: ?[]const u8 = null,
        log_debug: bool = false,
    },

    @"export": struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        as_of: []const u8 = "latest",
        output: []const u8,
        log_debug: bool = false,
    },

    import: struct {
        cluster: u128,
        replica: u8,
        replica_count: u8,
        input: []const u8,
        development: bool = false,
        log_debug: bool = false,

        @"--": void,
        path: []const u8,
    },

    backup: struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        as_of: []const u8 = "latest",
        output: []const u8,
        log_debug: bool = false,
    },

    restore: struct {
        cluster: u128,
        replica: u8,
        replica_count: u8,
        input: []const u8,
        manifest: []const u8,
        development: bool = false,
        log_debug: bool = false,

        @"--": void,
        path: []const u8,
    },

    recover: struct {
        cluster: u128,
        replica: u8,
        replica_count: u8,
        addresses: vsr.ClusterAddress,
        origin: []const u8,
        development: bool = false,
        log_debug: bool = false,

        @"--": void,
        path: []const u8,
    },

    version: struct { verbose: bool = false },

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
        \\              [--trace-size-max=<size><KiB|MiB|GiB>]
        \\              [--commit-stall-probability=<numerator>/<denominator>]
        \\              [--development] [--log-debug] <path>
        \\
        \\  nerva view --cluster=<integer> --addresses=<addresses> --listen=<host:port>
        \\             [--listen-remote] [--request-timeout=<milliseconds>] [--log-debug]
        \\
        \\  nerva api --cluster=<integer> --addresses=<addresses> --listen=<host:port>
        \\            [--listen-remote] [--request-timeout=<milliseconds>] [--statsd=<host:port>]
        \\            [--log-debug]
        \\
        \\  nerva export --cluster=<integer> --addresses=<addresses> [--as-of=<op>|latest]
        \\               --output=<path> [--log-debug]
        \\
        \\  nerva import --cluster=<integer> --replica=<index> --replica-count=<integer>
        \\               --input=<path> [--development] [--log-debug] <path>
        \\
        \\  nerva backup --cluster=<integer> --addresses=<addresses> [--as-of=<op>|latest]
        \\               --output=<path> [--log-debug]
        \\
        \\  nerva restore --cluster=<integer> --replica=<index> --replica-count=<integer>
        \\                --input=<path> --manifest=<path> [--development] [--log-debug] <path>
        \\
        \\  nerva recover --cluster=<integer> --replica=<index> --replica-count=<integer>
        \\               --addresses=<addresses> --origin=<sha256>|none
        \\               [--development] [--log-debug] <path>
        \\
        \\  nerva version [--verbose]
        \\
        \\Commands:
        \\
        \\  format   Create a replica's data file at <path>.
        \\
        \\  start    Run a replica from the data file at <path>. Replicas prove to each other
        \\           that they hold the cluster key, NERVA_CLUSTER_KEY (at least 32 bytes;
        \\           NERVA_CLUSTER_KEY_NEXT is also accepted, to rotate it). Without it, only
        \\           --development with loopback addresses runs, on a public key.
        \\
        \\  view     Follow the cluster's change feed and serve declared views. The key is
        \\           read from NERVA_KEY (and, during a rotation, NERVA_KEY_NEXT).
        \\
        \\  api      Serve the cluster as JSON over HTTP: rows, transactions, the feed,
        \\           history, layouts, views, ledgers and documents. The key is read from the
        \\           NERVA_KEY environment variable; during a rotation, NERVA_KEY_NEXT is
        \\           accepted too.
        \\
        \\  export   Write the cluster's changes up to an op, its views and ledgers, and
        \\           checks, to a new file at --output, for `import` of another release.
        \\
        \\  import   Create a replica's data file at <path> from an export: run once per
        \\           replica, on the same export, then start the replicas. Fails, and
        \\           removes <path>, if the export is damaged or the checks do not match.
        \\
        \\  backup   Write an export of the cluster to --output, check it as `import` would, and
        \\           write <output>.manifest.json beside it: the op, the SHA-256 and size of
        \\           the export, and every view's hash and ledger's total. Prints the SHA-256.
        \\           Neither file is overwritten.
        \\
        \\  restore  Create a replica's data file at <path> from a backup, as `import`, after
        \\           checking the backup against its manifest: run once per replica, on the
        \\           same backup. --cluster may differ from the backup's (a restore drill).
        \\
        \\  recover  Create the data file of a replica whose disk is gone, at <path>, as a
        \\           replica of the running cluster, then exit: run nerva start on it. Stop
        \\           the lost replica and destroy its data file first: it must never start
        \\           again. One replica at a time, each caught up before the next; at least
        \\           three replicas. Writes <path>.recovering and renames it once complete.
        \\
        \\  version  Print the release, the oldest client release it serves, the format digest and
        \\           the releases the binary bundles, then a last line `version <release>`: the
        \\           release this binary was built as, as people name it. --verbose adds the
        \\           digest's inputs and the commit.
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
        \\        Send the replica's (or, for api, the gateway's) metrics as statsd over UDP every
        \\        10 seconds. The port defaults to 8125; a bare port means 127.0.0.1. IPv6 goes
        \\        in brackets.
        \\
        \\  --request-timeout=<milliseconds>
        \\        view and api: how long a request to the cluster may wait for its reply,
        \\        1000 to 60000 (default 30000): one deadline for the whole request, not for
        \\        each cluster call it makes. A gateway answers a request within the queue
        \\        wait (1 s) plus this plus 1 s, so a client whose own timeout is longer
        \\        always gets an answer. A request that times out may still commit; one that
        \\        runs out of time before a call is sent is refused NRV-E0606, unsent.
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
        \\  --commit-stall-probability=<numerator>/<denominator>
        \\        How often the primary pauses its commit for one tick (10 ms) to give backups
        \\        breathing room, when no backup is lagging and another prepare is already
        \\        acknowledged by all replicas. A ratio from 0 to 1, for example 1/5; 0 never
        \\        pauses. The pause when a backup lags is not affected. Default 2/5.
        \\
        \\  --as-of=<op>|latest
        \\        Export every change at or before this op (default: the op of the export's
        \\        first read).
        \\
        \\  --origin=<sha256>|none
        \\        The export the cluster was imported from (the SHA-256 that export prints,
        \\        and import and start log), or none for a cluster that was formatted. A
        \\        replica recovered with the wrong one exits with status 8 and NRV-E0711 when it
        \\        starts, naming the export its peers announce.
        \\
        \\  --output=<path>, --input=<path>
        \\        The export file. `export` and `backup` refuse an existing file.
        \\
        \\  --manifest=<path>
        \\        The manifest `backup` wrote beside the backup (<output>.manifest.json).
        \\
        \\  --listen=<host:port>
        \\        Where to serve HTTP: <ipv4>:<port>, or [<ipv6>]:<port>. The bound port is printed
        \\        to stdout (use port 0 for an ephemeral one). Only loopback (127.0.0.0/8, ::1) is
        \\        accepted unless --listen-remote is given; 0.0.0.0 and [::] are not loopback.
        \\
        \\  --listen-remote
        \\        Serve on an address that is not loopback. The gateway speaks plain HTTP, so its
        \\        key and every reply cross the network in the clear: put it behind TLS. Logs one
        \\        warning.
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
    @"export": Export,
    import: Import,
    backup: Backup,
    restore: Restore,
    recover: Recover,
    version: Version,

    pub const Version = struct { verbose: bool };

    pub const Export = struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        /// Null: the op of the export's first read.
        as_of: ?u64,
        output: []const u8,
        log_debug: bool,
    };

    pub const Backup = Export;

    /// `import`, with the backup's manifest checked first.
    pub const Restore = struct {
        import: Import,
        manifest: []const u8,
    };

    pub const Import = struct {
        cluster: u128,
        replica: u8,
        replica_count: u8,
        input: []const u8,
        development: bool,
        log_debug: bool,
        path: []const u8,
    };

    pub const Recover = struct {
        cluster: u128,
        replica: u8,
        replica_count: u8,
        addresses: vsr.ClusterAddress,
        /// The export the cluster was imported from; zeroes if it was formatted (P90).
        origin: [32]u8,
        development: bool,
        log_debug: bool,
        path: []const u8,
    };

    pub const Api = struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        listen: std.net.Address,
        /// `--listen-remote`: the address is not loopback, and the operator said so (NRV-E0009).
        listen_remote: bool,
        /// How long a cluster request may wait for its reply, in milliseconds.
        request_timeout_ms: u32,
        /// Where the gateway sends its metrics as statsd, if anywhere.
        statsd: ?stdx.SocketAddress,
        log_debug: bool,
    };

    pub const View = struct {
        cluster: u128,
        addresses: vsr.ClusterAddress,
        listen: std.net.Address,
        /// `--listen-remote`: the address is not loopback, and the operator said so (NRV-E0009).
        listen_remote: bool,
        /// How long a cluster request may wait for its reply, in milliseconds.
        request_timeout_ms: u32,
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
        commit_stall_probability: stdx.PRNG.Ratio,
        development: bool,
        log_debug: bool,
        path: []const u8,
    };
};

/// The vendored flag parser's failures (unknown or repeated flag, missing or malformed value,
/// unexpected argument) as NRV-E0001, through `stdx.Flags.fatal_hook`.
fn flag_fatal(message: []const u8) noreturn {
    diag.fail(
        "NRV-E0001",
        "{s}",
        .{message},
        "run nerva --help, or nerva <command> --help, for the flags it takes",
        .{},
    );
}

pub fn parse_args(flags: *stdx.Flags) Command {
    stdx.Flags.fatal_hook = flag_fatal;
    return switch (flags.parse(CLIArgs)) {
        .format => |format| .{ .format = format_validate(.{
            .cluster = format.cluster,
            .replica = format.replica,
            .replica_count = format.replica_count,
            .development = format.development,
            .log_debug = format.log_debug,
            .path = format.path,
        }) catch |err| flag_range("format", err) },
        .start => |start| .{ .start = start_resolve(.{
            .addresses = start.addresses,
            .cache_grid = start.cache_grid,
            .cache_rows = start.cache_rows,
            .statsd = start.statsd,
            .trace = start.trace,
            .trace_size_max = start.trace_size_max,
            .commit_stall_probability = start.commit_stall_probability,
            .development = start.development,
            .log_debug = start.log_debug,
            .path = start.path,
        }) catch |err| flag_range("start", err) },
        .view => |view| .{ .view = .{
            .cluster = view.cluster,
            .addresses = view.addresses,
            .listen = listen_resolve("view", view.listen, view.listen_remote),
            .listen_remote = view.listen_remote,
            .request_timeout_ms = request_timeout_validate(view.request_timeout) catch |err|
                flag_range("view", err),
            .log_debug = view.log_debug,
        } },
        .api => |api| .{ .api = .{
            .cluster = api.cluster,
            .addresses = api.addresses,
            .listen = listen_resolve("api", api.listen, api.listen_remote),
            .listen_remote = api.listen_remote,
            .request_timeout_ms = request_timeout_validate(api.request_timeout) catch |err|
                flag_range("api", err),
            .statsd = if (api.statsd) |text| statsd_parse(text) catch |err|
                flag_range("api", err) else null,
            .log_debug = api.log_debug,
        } },
        .@"export" => |args| .{ .@"export" = export_resolve("export", args) },
        .backup => |args| .{ .backup = export_resolve("backup", args) },
        .import => |args| .{ .import = import_resolve("import", args) },
        .restore => |args| .{ .restore = .{
            .import = import_resolve("restore", args),
            .manifest = if (args.manifest.len == 0)
                diag.fail(
                    "NRV-E0001",
                    "restore: --manifest must name a file",
                    .{},
                    "give --manifest=<path> of the .manifest.json that nerva backup wrote",
                    .{},
                )
            else
                args.manifest,
        } },
        .recover => |args| .{ .recover = recover_resolve(args) },
        .version => |args| .{ .version = .{ .verbose = args.verbose } },
    };
}

/// `export`'s and `backup`'s flags, checked before anything runs.
fn export_resolve(comptime command: []const u8, args: anytype) Command.Export {
    return .{
        .cluster = args.cluster,
        .addresses = args.addresses,
        .as_of = as_of_parse(args.as_of) catch
            diag.fail(
                "NRV-E0001",
                command ++ ": --as-of must be an op above zero, or latest",
                .{},
                "give --as-of=latest or an op above zero",
                .{},
            ),
        .output = if (args.output.len == 0)
            diag.fail(
                "NRV-E0001",
                command ++ ": --output must name a file",
                .{},
                "give --output=<path> for a file that does not exist yet",
                .{},
            )
        else
            args.output,
        .log_debug = args.log_debug,
    };
}

/// `import`'s and `restore`'s flags, checked before anything runs.
fn import_resolve(comptime command: []const u8, args: anytype) Command.Import {
    const format = format_validate(.{
        .cluster = args.cluster,
        .replica = args.replica,
        .replica_count = args.replica_count,
        .development = args.development,
        .log_debug = args.log_debug,
        .path = args.path,
    }) catch |err| flag_range(command, err);
    if (args.input.len == 0) diag.fail(
        "NRV-E0001",
        command ++ ": --input must name a file",
        .{},
        "give --input=<path> of an export made by nerva export",
        .{},
    );
    return .{
        .cluster = format.cluster,
        .replica = format.replica,
        .replica_count = format.replica_count,
        .input = args.input,
        .development = format.development,
        .log_debug = format.log_debug,
        .path = format.path,
    };
}

fn flag_range(comptime command: []const u8, err: Error) noreturn {
    diag.fail(
        "NRV-E0002",
        command ++ ": {s}",
        .{error_message(err)},
        "nerva " ++ command ++ " --help names every flag and its bounds",
        .{},
    );
}

/// `--listen`, parsed, and refused (NRV-E0009) when it is not loopback and `--listen-remote` was
/// not given (P168, owner question 2).
fn listen_resolve(comptime command: []const u8, text: []const u8, remote: bool) std.net.Address {
    const address = listen_parse(text) orelse listen_invalid(command);
    if (!remote and !listen_is_loopback(address)) {
        diag.fail(
            "NRV-E0009",
            command ++ ": --listen={s} is not loopback; the gateway speaks plain HTTP",
            .{text},
            "listen on 127.0.0.1 beside the client, or pass --listen-remote and put TLS in front",
            .{},
        );
    }
    return address;
}

/// Plain loopback: 127.0.0.0/8 or ::1. `0.0.0.0` and `[::]` serve every interface; an IPv4-mapped
/// address such as `::ffff:127.0.0.1` is not plain loopback and is refused too (write `127.0.0.1`).
pub fn listen_is_loopback(address: std.net.Address) bool {
    switch (address.any.family) {
        std.posix.AF.INET => return @as([4]u8, @bitCast(address.in.sa.addr))[0] == 127,
        std.posix.AF.INET6 => return std.mem.eql(u8, &address.in6.sa.addr, &loopback_ipv6),
        else => unreachable,
    }
}

const loopback_ipv6 = [_]u8{0} ** 15 ++ [_]u8{1};

test listen_is_loopback {
    const accepted = [_][]const u8{
        "127.0.0.1:0",       "127.255.255.254:80",  "[::1]:8080", "127.0.0.0:1",
        "127.255.255.255:1", "[0:0:0:0:0:0:0:1]:1", "[::0:1]:1",
    };
    for (accepted) |text| try std.testing.expect(listen_is_loopback(listen_parse(text).?));
    const refused = [_][]const u8{
        "0.0.0.0:0",   "[::]:8080", "10.0.0.1:80", "[::ffff:127.0.0.1]:80", "126.255.255.255:1",
        "128.0.0.1:1", "[::2]:1",   "128.0.0.0:1",
    };
    for (refused) |text| try std.testing.expect(!listen_is_loopback(listen_parse(text).?));
}

fn listen_invalid(comptime command: []const u8) noreturn {
    diag.fail(
        "NRV-E0003",
        command ++ ": --listen must be <ipv4>:<port> or [<ipv6>]:<port>",
        .{},
        "give --listen=host:port, with an IPv6 host in brackets",
        .{},
    );
}

/// `recover`'s flags, checked before anything runs; exits with a coded line if they are wrong.
fn recover_resolve(args: anytype) Command.Recover {
    const origin = recover.flags_check(.{
        .replica = args.replica,
        .replica_count = args.replica_count,
        .address_count = args.addresses.members_count(),
        .addresses_zero = args.addresses.zero,
        .origin = args.origin,
    }) catch |err| switch (err) {
        error.ReplicaCountTooSmall => diag.fail(
            "NRV-E0714",
            "recover: --replica-count={} is too small; recover needs at least {} replicas",
            .{ args.replica_count, recover.replica_count_min },
            "restore a cluster of fewer replicas from a backup",
            .{},
        ),
        error.ReplicaCountTooLarge => flag_range("recover", error.ReplicaCountTooLarge),
        error.ReplicaOutOfRange => flag_range("recover", error.ReplicaIndexOutOfRange),
        error.AddressesZero => diag.fail(
            "NRV-E0002",
            "recover: --addresses=0 is for tests of start",
            .{},
            "give --addresses=<host:port of each replica, in order>",
            .{},
        ),
        error.AddressCount => diag.fail(
            "NRV-E0710",
            "recover: --addresses gave {} addresses; the cluster has {} replicas",
            .{ args.addresses.members_count(), args.replica_count },
            "give every replica's address, in replica order, the lost one's included",
            .{},
        ),
        error.OriginInvalid => diag.fail(
            "NRV-E0001",
            "recover: --origin must be an export's 64 hex digits, or none",
            .{},
            "give the SHA-256 that export prints, or none for a cluster that was formatted",
            .{},
        ),
    };
    return .{
        .cluster = args.cluster,
        .replica = args.replica,
        .replica_count = args.replica_count,
        .addresses = args.addresses,
        .origin = origin,
        .development = args.development,
        .log_debug = args.log_debug,
        .path = args.path,
    };
}

/// `--as-of`: an op above zero, or `latest` (null).
fn as_of_parse(text: []const u8) error{Invalid}!?u64 {
    if (std.mem.eql(u8, text, "latest")) return null;
    const op = std.fmt.parseInt(u64, text, 10) catch return error.Invalid;
    if (op == 0) return error.Invalid;
    return op;
}

test as_of_parse {
    try std.testing.expectEqual(@as(?u64, null), try as_of_parse("latest"));
    try std.testing.expectEqual(@as(?u64, 1234), try as_of_parse("1234"));
    for ([_][]const u8{ "", "0", "-1", "12x", "Latest" }) |text| {
        try std.testing.expectError(error.Invalid, as_of_parse(text));
    }
}

/// `<ipv4>:<port>`, or `[<ipv6>]:<port>` as `--addresses` takes it (Fly's private network is
/// IPv6 only).
fn listen_parse(text: []const u8) ?std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    const host = text[0..colon];
    if (host.len > 0 and host[0] == '[') {
        if (host.len < 3 or host[host.len - 1] != ']') return null;
        // No zone ids: `parseIp6` takes a numeric one (`fe80::1%2`), which a gateway never needs.
        if (std.mem.indexOfScalar(u8, host, '%') != null) return null;
        return std.net.Address.parseIp6(host[1 .. host.len - 1], port) catch null;
    }
    return std.net.Address.parseIp4(host, port) catch null;
}

test listen_parse {
    try std.testing.expectEqual(@as(u16, 8090), listen_parse("127.0.0.1:8090").?.getPort());
    try std.testing.expectEqual(@as(u16, 0), listen_parse("0.0.0.0:0").?.getPort());
    try std.testing.expect(listen_parse("8090") == null);
    try std.testing.expect(listen_parse("localhost:8090") == null);
    try std.testing.expect(listen_parse("127.0.0.1:99999") == null);

    const loopback = listen_parse("[::1]:8090").?;
    try std.testing.expectEqual(@as(u16, 8090), loopback.getPort());
    try std.testing.expectEqual(std.posix.AF.INET6, loopback.any.family);
    try std.testing.expect((try std.net.Address.parseIp6("::1", 8090)).eql(loopback));
    try std.testing.expectEqual(
        @as(u16, 0),
        listen_parse("[fdaa:0:1:a7b:1::2]:0").?.getPort(),
    );
    try std.testing.expectEqual(std.posix.AF.INET6, listen_parse("[::]:8080").?.any.family);
    // Bracketed only, as `--addresses` takes them; no names, no zone ids.
    try std.testing.expect(listen_parse("::1:8090") == null);
    try std.testing.expect(listen_parse("[::1]8090") == null);
    try std.testing.expect(listen_parse("[::1:8090") == null);
    try std.testing.expect(listen_parse("[]:8090") == null);
    try std.testing.expect(listen_parse("[localhost]:8090") == null);
    try std.testing.expect(listen_parse("[127.0.0.1]:8090") == null);
    try std.testing.expect(listen_parse("[::1]:99999") == null);
    try std.testing.expect(listen_parse("[fe80::1%2]:8090") == null);
    try std.testing.expect(listen_parse("[fe80::1%eth0]:8090") == null);
}

/// `--request-timeout`, in milliseconds (P168d, P195): the one deadline for an HTTP request's
/// cluster calls, which bounds how long a gateway takes to answer one (README, "The answer bound").
pub const request_timeout_min_ms: u32 = 1_000;
pub const request_timeout_max_ms: u32 = 60_000;
pub const request_timeout_default_ms: u32 = 30_000;

fn request_timeout_validate(milliseconds: u32) Error!u32 {
    if (milliseconds < request_timeout_min_ms or milliseconds > request_timeout_max_ms) {
        return error.RequestTimeoutOutOfRange;
    }
    return milliseconds;
}

test "--request-timeout is 1,000 to 60,000 ms" {
    try std.testing.expectError(error.RequestTimeoutOutOfRange, request_timeout_validate(999));
    try std.testing.expectEqual(@as(u32, 1_000), try request_timeout_validate(1_000));
    try std.testing.expectEqual(@as(u32, 30_000), try request_timeout_validate(request_timeout_default_ms));
    try std.testing.expectEqual(@as(u32, 60_000), try request_timeout_validate(60_000));
    try std.testing.expectError(error.RequestTimeoutOutOfRange, request_timeout_validate(60_001));
    try std.testing.expectError(error.RequestTimeoutOutOfRange, request_timeout_validate(0));
}

const Error = error{
    RequestTimeoutOutOfRange,
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
    CommitStallProbabilityInvalid,
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
        error.RequestTimeoutOutOfRange => std.fmt.comptimePrint(
            "--request-timeout must be {} to {} milliseconds",
            .{ request_timeout_min_ms, request_timeout_max_ms },
        ),
        error.CommitStallProbabilityInvalid => "--commit-stall-probability must be a ratio " ++
            "from 0 to 1, such as 1/5",
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
    commit_stall_probability: ?stdx.PRNG.Ratio,
    development: bool,
    log_debug: bool,
    path: []const u8,
};

/// TigerBeetle's default (`replica.zig` falls back to it when the option is null); Nerva
/// passes the value explicitly, so the shipped default is visible here (P136).
const commit_stall_probability_default = stdx.PRNG.ratio(2, 5);

/// A `--development` replica queues no requests beyond its prepare pipeline, but it still takes
/// this many extra client connections. Each gateway is a client on every replica, so with 0 a
/// cluster of ten gateways (Jepsen's `--gateways 2` on 5 nodes) had its last connections closed
/// (#231). It stays far below the production limit, and within the build's request queue (the
/// test configuration's is smaller).
const development_pipeline_requests_limit: u32 = @min(8, constants.pipeline_request_queue_max);

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

    const commit_stall_probability = start.commit_stall_probability orelse
        commit_stall_probability_default;
    // The flag parser already refuses these; a caller that builds `StartArgs` by hand gets the
    // same refusal.
    assert(commit_stall_probability.denominator > 0);
    if (commit_stall_probability.numerator > commit_stall_probability.denominator) {
        return error.CommitStallProbabilityInvalid;
    }

    const compaction_block_count_min = StateMachine.Forest.Options.compaction_block_count_min;
    return .{
        .addresses = start.addresses,
        .cache_grid_blocks = @intCast(@divExact(cache_grid_size, constants.block_size)),
        .cache_rows_count = cache_rows_count,
        .storage_size_limit = constants.storage_size_limit_default,
        .pipeline_requests_limit = if (start.development)
            development_pipeline_requests_limit
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
        .commit_stall_probability = commit_stall_probability,
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
        .commit_stall_probability = null,
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
    // #231: a development replica takes client slots beyond its prepare pipeline. With the
    // production configuration that is room for ten gateways (two on each of five nodes).
    try std.testing.expectEqual(development_pipeline_requests_limit, development.pipeline_requests_limit);
    try std.testing.expect(development.pipeline_requests_limit > 0);
    if (constants.clients_max >= 64) {
        try std.testing.expect(constants.pipeline_prepare_queue_max +
            development.pipeline_requests_limit >= 10);
    }
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

    try std.testing.expectEqual(commit_stall_probability_default, development.commit_stall_probability);
    var stalled = start;
    stalled.commit_stall_probability = stdx.PRNG.ratio(1, 5);
    try std.testing.expectEqual(
        stdx.PRNG.ratio(1, 5),
        (try start_resolve(stalled)).commit_stall_probability,
    );
    stalled.commit_stall_probability = stdx.PRNG.Ratio.zero();
    try std.testing.expectEqual(@as(u64, 0), (try start_resolve(stalled)).commit_stall_probability.numerator);
    // A ratio built by hand above 1 is refused as the parser refuses it.
    stalled.commit_stall_probability = .{ .numerator = 3, .denominator = 2 };
    try std.testing.expectError(error.CommitStallProbabilityInvalid, start_resolve(stalled));

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

test "--commit-stall-probability parses a ratio and refuses nonsense" {
    var diagnostic: ?[]const u8 = null;
    const parse = stdx.PRNG.Ratio.parse_flag_value;
    try std.testing.expectEqual(stdx.PRNG.ratio(1, 5), try parse("1/5", &diagnostic));
    try std.testing.expectEqual(stdx.PRNG.ratio(2, 5), try parse("2/5", &diagnostic));
    try std.testing.expectEqual(stdx.PRNG.Ratio.zero(), try parse("0", &diagnostic));
    try std.testing.expectEqual(@as(u64, 0), (try parse("0/10", &diagnostic)).numerator);
    for ([_][]const u8{ "3/2", "1/0", "1", "x/5", "1/y", "-1/5", "1/" }) |text| {
        try std.testing.expectError(error.InvalidFlagValue, parse(text, &diagnostic));
    }
}
