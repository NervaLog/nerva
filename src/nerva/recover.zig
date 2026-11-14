//! `nerva recover`: formats the data file of a replica whose disk is gone, as a replica of the
//! running cluster (R5, P149, P149b).
//!
//! The work is upstream's, unchanged: `vsr/replica_reformat.zig` registers a client session,
//! commits `pipeline_prepare_queue_max` `noop` requests, and formats the data file with a view
//! two past the client's. This file gives it the real message bus and storage (so the code the
//! VOPR checks is the code that runs), the refusals an operator can cause, and the file name
//! discipline: the data file is written as `<path>.recovering` and takes its name only once it
//! is complete.
//!
//! It writes only what `format` writes, with a view and an origin. It never writes a data file
//! that holds state: that is `import`'s, and unsafe alone (P90).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.recover);

const stdx = @import("stdx");
const vsr = @import("../vsr.zig");
const constants = @import("../constants.zig");
const config = constants.config;
const IO = @import("../io.zig").IO;
const Tracer = @import("../trace.zig").Tracer;
const MessagePool = @import("../message_pool.zig").MessagePool;
const MessageBus = @import("../message_bus.zig").MessageBusType(IO);
const Storage = @import("../storage.zig").StorageType(IO);
const StateMachine = @import("state_machine.zig").StateMachineType(Storage);
const release_peers = @import("release_peers.zig");
const release_eviction = @import("release_eviction.zig");
const diag = @import("diagnostic.zig");

const VSRClient = vsr.ClientType(StateMachine.Operation, MessageBus);
const Reformat = vsr.ReplicaReformatType(StateMachine, MessageBus, Storage);
const Message = MessagePool.Message;

const data_file_size_min = @import("../vsr/superblock.zig").data_file_size_min;

/// Registration and every `noop`: a healthy cluster commits them in well under a second.
pub const recover_timeout: stdx.Duration = .{ .ns = 60 * std.time.ns_per_s };
/// One TCP connect to a replica's address: a loopback or 6PN connect answers in milliseconds.
pub const recover_probe_timeout_ms: i32 = 1000;
/// Upstream's count of requests (one registration and the `noop`s): never changed here.
pub const recover_requests = constants.pipeline_prepare_queue_max;
/// How far past the cluster's view the new data file starts: upstream's rationale
/// (`replica_reformat.zig:14-20`), asserted in a test against the vendored code.
pub const recover_view_skip = 2;

/// The smallest cluster upstream's reformat accepts (`replica_reformat.zig:62`).
pub const replica_count_min = 3;

pub const Options = struct {
    cluster: u128,
    replica: u8,
    replica_count: u8,
    /// Every replica's address, in replica index order.
    addresses: []const stdx.SocketAddress,
    /// The export the cluster was imported from; zeroes for one that was formatted (P90).
    origin: [32]u8,
    development: bool,
    path: []const u8,
};

pub const Summary = struct {
    /// The view of the new data file.
    view: u32,
};

/// Formats `options.path` as replica `options.replica` of the running cluster, or exits with a
/// coded diagnostic. Leaves nothing but `options.path` behind, and not even that on a failure.
pub fn run(gpa: std.mem.Allocator, options: Options) void {
    const summary = attempt(gpa, options) catch |err| switch (err) {
        error.Timeout => diag.fail(
            "NRV-E0712",
            "recover: the cluster did not commit recover's requests within {} seconds",
            .{@divFloor(recover_timeout.ns, std.time.ns_per_s)},
            "bring back enough of the other replicas, then run nerva recover again; " ++
                "with fewer, restore from a backup",
            .{},
        ),
        error.Evicted => {
            // Evicted for its release: NRV-E0731, not "too many sessions".
            diag.fail_release_eviction();
            diag.fail(
                "NRV-E0716",
                "recover: the cluster evicted this session before it finished",
                .{},
                "run nerva recover again; the cluster holds at most {} client sessions",
                .{constants.clients_max},
            );
        },
        else => diag.fail_file(options.path, err),
    };
    log.info("recover: replica {} of cluster {} formatted at view {} (the cluster was at " ++
        "view {}), export {}; start it with nerva start", .{
        options.replica,
        options.cluster,
        summary.view,
        summary.view - recover_view_skip,
        release_peers.origin_name(&options.origin),
    });
    log.warn("recover: the old data file of replica {} must never start again: two replicas " ++
        "with one index void the cluster's guarantees", .{options.replica});
}

fn attempt(gpa: std.mem.Allocator, options: Options) !Summary {
    assert(options.replica_count >= replica_count_min);
    assert(options.replica < options.replica_count);
    assert(options.addresses.len == options.replica_count);

    // Both names are checked before any connection.
    var recovering_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const recovering = std.fmt.bufPrint(&recovering_buffer, "{s}.recovering", .{options.path}) catch
        return error.NameTooLong;
    if (exists(options.path)) {
        diag.fail(
            "NRV-E0005",
            "recover: {s} exists",
            .{options.path},
            "give a new path; if that file is the lost replica's, destroy it first",
            .{},
        );
    }
    if (exists(recovering)) {
        diag.fail(
            "NRV-E0715",
            "an earlier recover did not finish: {s} is left",
            .{recovering},
            "remove it, then run nerva recover again",
            .{},
        );
    }

    replicas_check(options);

    // Written under another name; `path` appears only when the data file is complete.
    var io = try IO.init(2048, 0);
    defer io.deinit();
    var time_os: stdx.TimeOS = .{};
    const time = time_os.interface();
    var tracer = try Tracer.init(gpa, time, .unknown, .{});
    defer tracer.deinit(gpa);

    var storage = Storage.init(&io, &tracer, .{
        .path = recovering,
        .size_min = data_file_size_min,
        .purpose = .format,
        .direct_io = if (!constants.direct_io)
            .direct_io_disabled
        else if (options.development)
            .direct_io_optional
        else
            .direct_io_required,
    }) catch |err| return err;
    var storage_open = true;
    defer if (storage_open) storage.deinit();
    // Any failure from here on removes the temporary file.
    errdefer std.fs.cwd().deleteFile(recovering) catch {};

    const view = try format_session(gpa, &io, time, &storage, options);

    storage.deinit();
    storage_open = false;

    // Every write is on disk: the data file is complete, and takes its name (as import does).
    const cwd = std.posix.AT.FDCWD;
    try std.posix.linkat(cwd, recovering, cwd, options.path, 0);
    try std.fs.cwd().deleteFile(recovering);
    try directory_sync(options.path);
    return .{ .view = view };
}

const Session = struct {
    vsr_client: VSRClient,
    reformat: Reformat,
    evicted: bool,

    fn on_eviction(vsr_client: *VSRClient, eviction: *const Message.Eviction) void {
        const session: *Session = @fieldParentPtr("vsr_client", vsr_client);
        log.warn("evicted: {s}", .{@tagName(eviction.header.reason)});
        release_eviction.record(
            eviction.header.reason,
            config.process.release,
            eviction.header.release,
        );
        // The callback runs inside the message bus's receive path: the client is only
        // deinitialized once the loop below stops (as `Client.on_eviction`, #52).
        session.evicted = true;
    }
};

/// Registers, commits the `noop`s and formats the storage; returns the data file's view.
fn format_session(
    gpa: std.mem.Allocator,
    io: *IO,
    time: stdx.Time,
    storage: *Storage,
    options: Options,
) !u32 {
    comptime assert(recover_requests == constants.pipeline_prepare_queue_max);

    var message_pool = try MessagePool.init(gpa, .client);
    defer message_pool.deinit(gpa);

    var state: Session = undefined;
    state.evicted = false;

    state.vsr_client = try VSRClient.init(gpa, time, &message_pool, .{
        .id = stdx.crypto_u128(),
        .cluster = options.cluster,
        .replica_count = options.replica_count,
        .aof_recovery = false,
        .message_bus_options = .{
            .configuration = options.addresses,
            .io = io,
            .trace = null,
            .time = time,
        },
        .eviction_callback = Session.on_eviction,
    });
    defer state.vsr_client.deinit(gpa);

    state.reformat = try Reformat.init(gpa, &state.vsr_client, storage, .{
        .cluster = options.cluster,
        .release = config.process.release,
        .replica = options.replica,
        .replica_count = options.replica_count,
        .view = null,
        .origin = options.origin,
    });
    defer state.reformat.deinit(gpa);

    // Never `Reformat.done()`: it names a field the struct does not have. `pending()` and
    // `format()` are the interface (docs/briefs/r5.md).
    state.reformat.start();
    const start = time.monotonic();
    var tick_next = start;
    while (state.reformat.pending()) {
        if (state.evicted) return error.Evicted;
        const now = time.monotonic();
        if (start.elapsed(now).ns > recover_timeout.ns) return error.Timeout;
        const tick: stdx.Duration = .{ .ns = constants.tick_ms * std.time.ns_per_ms };
        if (now.ns >= tick_next.ns) {
            state.vsr_client.tick();
            tick_next = now.add(tick);
        }
        const wait_ns: u63 = @intCast(@max(tick_next.ns -| now.ns, 1));
        try io.run_once(wait_ns);
    }

    const view = state.reformat.safe_view.?;
    assert(view == state.vsr_client.view + recover_view_skip);
    try state.reformat.format();

    // Close the connections gracefully, bounded: the session is done either way.
    state.vsr_client.shutdown();
    const shutdown_start = time.monotonic();
    while (!state.vsr_client.shutdown_complete()) {
        if (shutdown_start.elapsed(time.monotonic()).ns > recover_timeout.ns) break;
        io.run_once(constants.tick_ms * std.time.ns_per_ms) catch break;
    }
    return view;
}

/// Before any session: the replica to replace is gone, and enough of the others answer.
fn replicas_check(options: Options) void {
    const own = options.addresses[options.replica];
    if (accepts(own)) {
        diag.fail(
            "NRV-E0713",
            "replica {} still answers at {}",
            .{ options.replica, own.to_std() },
            "stop replica {} and destroy its data file, then run nerva recover again",
            .{options.replica},
        );
    }
    var answering: u8 = 0;
    for (options.addresses, 0..) |address, index| {
        if (index == options.replica) continue;
        if (accepts(address)) answering += 1;
    }
    const quorum = vsr.quorums(options.replica_count).replication;
    if (answering < quorum) {
        diag.fail(
            "NRV-E0712",
            "recover: only {} of the other {} replicas answer; the cluster needs {}",
            .{ answering, options.replica_count - 1, quorum },
            "bring back enough of the other replicas first; with fewer, restore from a backup",
            .{},
        );
    }
}

/// Whether a TCP connect to `address` succeeds within `recover_probe_timeout_ms`.
fn accepts(address: stdx.SocketAddress) bool {
    const std_address = address.to_std();
    const fd = std.posix.socket(
        std_address.any.family,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
        0,
    ) catch return false;
    defer std.posix.close(fd);
    std.posix.connect(fd, &std_address.any, std_address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {},
        else => return false,
    };
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
    const ready = std.posix.poll(&fds, recover_probe_timeout_ms) catch return false;
    if (ready == 0) return false;
    std.posix.getsockoptError(fd) catch return false;
    return true;
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch |err| return err != error.FileNotFound;
    return true;
}

/// Makes a new directory entry durable: the directory holding `path` is synced.
fn directory_sync(path: []const u8) !void {
    // Read-only, not `openDir`'s default `O_PATH`, which `fsync` refuses.
    const fd = try std.posix.open(std.fs.path.dirname(path) orelse ".", .{ .DIRECTORY = true }, 0);
    defer std.posix.close(fd);
    try std.posix.fsync(fd);
}

/// What `nerva recover` takes from its flags, before anything else happens.
pub const Flags = struct {
    replica: u8,
    replica_count: u8,
    /// How many addresses `--addresses` gave, and whether it was the test-only `0`.
    address_count: u8,
    addresses_zero: bool,
    origin: []const u8,
};

/// Why `recover`'s flags are refused, in the order they are checked; `cli.zig` prints each with
/// its code (NRV-E0714, NRV-E0002, NRV-E0710, NRV-E0001).
pub const FlagsError = error{
    ReplicaCountTooSmall,
    ReplicaCountTooLarge,
    ReplicaOutOfRange,
    AddressesZero,
    AddressCount,
    OriginInvalid,
};

/// Checks the flags; returns the parsed origin.
pub fn flags_check(flags: Flags) FlagsError![32]u8 {
    if (flags.replica_count < replica_count_min) return error.ReplicaCountTooSmall;
    if (flags.replica_count > constants.replicas_max) return error.ReplicaCountTooLarge;
    if (flags.replica >= flags.replica_count) return error.ReplicaOutOfRange;
    if (flags.addresses_zero) return error.AddressesZero;
    if (flags.address_count != flags.replica_count) return error.AddressCount;
    return origin_parse(flags.origin) catch error.OriginInvalid;
}

/// `--origin`: the export's SHA-256 as 64 hex digits, or `none` for a formatted cluster.
pub fn origin_parse(text: []const u8) error{Invalid}![32]u8 {
    if (std.mem.eql(u8, text, "none")) return [_]u8{0} ** 32;
    if (text.len != 64) return error.Invalid;
    var origin: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&origin, text) catch return error.Invalid;
    // A hash of zeroes would be indistinguishable from `none`.
    if (stdx.zeroed(&origin)) return error.Invalid;
    return origin;
}

test origin_parse {
    try std.testing.expectEqual(@as([32]u8, @splat(0)), try origin_parse("none"));
    const hex = "0123456789abcdef" ** 4;
    const origin = try origin_parse(hex);
    try std.testing.expectEqual(@as(u8, 0x01), origin[0]);
    try std.testing.expectEqual(@as(u8, 0xef), origin[31]);
    try std.testing.expectEqual(origin, try origin_parse("0123456789ABCDEF" ** 4));
    for ([_][]const u8{
        "",
        "None",
        "0123456789abcdef" ** 3 ++ "0123456789abcde", // 63 digits.
        "0123456789abcdef" ** 4 ++ "0", // 65 digits.
        "g123456789abcdef" ** 4,
        "0" ** 64, // The zero hash is `none`'s, and must be spelled so.
    }) |text| {
        try std.testing.expectError(error.Invalid, origin_parse(text));
    }
}

fn flags_test(replica: u8, replica_count: u8, address_count: u8, origin: []const u8) Flags {
    return .{
        .replica = replica,
        .replica_count = replica_count,
        .address_count = address_count,
        .addresses_zero = false,
        .origin = origin,
    };
}

test flags_check {
    const valid = flags_test(2, 3, 3, "none");
    try std.testing.expectEqual(@as([32]u8, @splat(0)), try flags_check(valid));

    const cases = [_]struct { flags: Flags, err: FlagsError }{
        .{ .flags = flags_test(0, 1, 1, "none"), .err = error.ReplicaCountTooSmall },
        .{ .flags = flags_test(1, 2, 2, "none"), .err = error.ReplicaCountTooSmall },
        .{
            .flags = flags_test(0, constants.replicas_max + 1, 3, "none"),
            .err = error.ReplicaCountTooLarge,
        },
        .{ .flags = flags_test(3, 3, 3, "none"), .err = error.ReplicaOutOfRange },
        .{ .flags = flags_test(2, 3, 2, "none"), .err = error.AddressCount },
        .{ .flags = flags_test(2, 3, 4, "none"), .err = error.AddressCount },
        .{ .flags = flags_test(2, 3, 3, ""), .err = error.OriginInvalid },
        .{ .flags = flags_test(2, 3, 3, "abc"), .err = error.OriginInvalid },
    };
    for (cases) |case| try std.testing.expectError(case.err, flags_check(case.flags));
    var zero = valid;
    zero.addresses_zero = true;
    try std.testing.expectError(error.AddressesZero, flags_check(zero));
    // The smallest accepted cluster, and the largest.
    _ = try flags_check(flags_test(2, replica_count_min, replica_count_min, "none"));
    _ = try flags_check(flags_test(2, constants.replicas_max, constants.replicas_max, "none"));
}

test "recover_view_skip is upstream's (replica_reformat.zig: client.view + 2)" {
    const source = @embedFile("../vsr/replica_reformat.zig");
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        std.fmt.comptimePrint("reformat.safe_view = reformat.client.view + {};", .{
            recover_view_skip,
        }),
    ) != null);
    try std.testing.expectEqual(constants.pipeline_prepare_queue_max, recover_requests);
}

test "accepts: a listening address, a closed one" {
    const listen = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try listen.listen(.{});
    defer server.deinit();
    const open = try stdx.SocketAddress.from_std(server.listen_address);
    try std.testing.expect(accepts(open));

    const port = open.port;
    server.deinit();
    server = try listen.listen(.{}); // Another port; the first is closed now.
    try std.testing.expect(!accepts(.{ .ip = open.ip, .port = port }));
}
