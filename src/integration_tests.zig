//! Integration tests: a three-replica Nerva cluster of real `nerva` processes on local ports,
//! driven through the client library.
//!
//! Run with `zig build test:integration`. Needs about 3.5 GiB of disk and 3 GiB of memory.
//!
//! An executable rather than a `zig test` binary: test binaries use the `test_min` configuration,
//! but the client must share the production configuration of the `nerva` binary it talks to.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const stdx = @import("stdx");
const vsr = @import("vsr.zig");
const constants = @import("constants.zig");
const nerva = @import("nerva.zig");
const Client = @import("nerva/client.zig").Client;
const workload = @import("nerva/workload.zig");
const peer_auth = @import("nerva/peer_auth.zig");
const Header = vsr.Header;

const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const RowValue = nerva.RowValue;
const Change = nerva.Change;
const Receipt = workload.Receipt;

const nerva_exe = @import("integration_tests_options").nerva_exe;

pub const tigerbeetle_config = @import("config.zig").configs.default_production;

var gpa: std.mem.Allocator = undefined;

pub fn main() !void {
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer switch (gpa_instance.deinit()) {
        .ok => {},
        .leak => @panic("memory leaked"),
    };
    gpa = gpa_instance.allocator();

    try scenario_cluster();
    try scenario_peer_auth();
    std.debug.print("integration: PASSED\n", .{});
}

const cluster_id: u128 = 0; // Test binaries refuse any other cluster id.
const replica_count = 3;
const timeout = stdx.Duration.seconds(60);

/// Replicas authenticate each other with a real cluster key, never the development key (P102).
const cluster_key = "integration-cluster-key-0123456789abcdef";
const cluster_key_new = "integration-cluster-key-rotated-0123456789";
const cluster_key_wrong = "integration-cluster-key-wrong-0123456789ab";

comptime {
    assert(cluster_key.len >= peer_auth.key_length_min);
    assert(cluster_key_new.len >= peer_auth.key_length_min);
    assert(cluster_key_wrong.len >= peer_auth.key_length_min);
}

const Cluster = struct {
    gpa: std.mem.Allocator,
    tmp_path: []const u8,
    addresses_flag: []const u8,
    addresses: [replica_count]stdx.SocketAddress,
    processes: [replica_count]?std.process.Child,
    /// Every replica sends its metrics here (`--statsd`).
    statsd: StatsdListener,
    /// Each replica's environment: its cluster keys (P102).
    environments: [replica_count]std.process.EnvMap,
    trace_started: bool = false,

    fn init() !*Cluster {
        const cluster = try gpa.create(Cluster);
        errdefer gpa.destroy(cluster);

        var tmp_name_buffer: [128]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(
            &tmp_name_buffer,
            ".zig-cache/tmp/nerva-integration-{x}",
            .{stdx.crypto_u128()},
        );
        try std.fs.cwd().makePath(tmp_name);
        errdefer std.fs.cwd().deleteTree(tmp_name) catch {};
        const tmp_path = try std.fs.cwd().realpathAlloc(gpa, tmp_name);
        errdefer gpa.free(tmp_path);

        // Reserve ports by binding to port 0, then release them for the replicas.
        var ports: [replica_count]u16 = undefined;
        for (&ports) |*port| port.* = try port_free();
        const addresses_flag = try std.fmt.allocPrint(
            gpa,
            "127.0.0.1:{},127.0.0.1:{},127.0.0.1:{}",
            .{ ports[0], ports[1], ports[2] },
        );
        errdefer gpa.free(addresses_flag);

        var statsd = try StatsdListener.init();
        errdefer statsd.deinit();

        cluster.* = .{
            .gpa = gpa,
            .tmp_path = tmp_path,
            .addresses_flag = addresses_flag,
            .addresses = undefined,
            .processes = @splat(null),
            .statsd = statsd,
            .environments = undefined,
        };
        for (&cluster.environments, 0..) |*environment, index| {
            errdefer for (cluster.environments[0..index]) |*done| done.deinit();
            environment.* = try std.process.getEnvMap(gpa);
            environment.remove("NERVA_CLUSTER_KEY_NEXT");
            try environment.put("NERVA_CLUSTER_KEY", cluster_key);
        }
        errdefer for (&cluster.environments) |*environment| environment.deinit();
        const parsed = try vsr.parse_addresses(addresses_flag, &cluster.addresses);
        assert(parsed.len == replica_count);

        for (0..replica_count) |replica| try cluster.format(@intCast(replica));
        for (0..replica_count) |replica| try cluster.start(@intCast(replica));
        return cluster;
    }

    fn deinit(cluster: *Cluster) void {
        for (0..replica_count) |replica| cluster.stop(@intCast(replica));
        for (&cluster.environments) |*environment| environment.deinit();
        cluster.statsd.deinit();
        cluster.gpa.free(cluster.addresses_flag);
        std.fs.deleteTreeAbsolute(cluster.tmp_path) catch {};
        cluster.gpa.free(cluster.tmp_path);
        cluster.gpa.destroy(cluster);
    }

    fn data_file(cluster: *const Cluster, buffer: []u8, replica: u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}/0_{}.nerva", .{ cluster.tmp_path, replica }) catch
            unreachable;
    }

    fn log_file(cluster: *const Cluster, buffer: []u8, replica: u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}/replica_{}.log", .{ cluster.tmp_path, replica }) catch
            unreachable;
    }

    /// Prints the end of every replica's log.
    fn logs_print(cluster: *const Cluster) void {
        for (0..replica_count) |replica| {
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const log = std.fs.cwd().readFileAlloc(
                cluster.gpa,
                cluster.log_file(&path_buffer, @intCast(replica)),
                256 * stdx.MiB,
            ) catch continue;
            defer cluster.gpa.free(log);
            const tail_size = 16 * 1024;
            const tail = log[log.len -| tail_size..];
            std.debug.print("--- replica {} log (last {} bytes) ---\n{s}\n", .{
                replica,
                tail.len,
                tail,
            });
        }
    }

    /// Replica 1 writes its span trace here (`--trace`).
    fn trace_file(cluster: *const Cluster, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}/trace_1.json", .{cluster.tmp_path}) catch
            unreachable;
    }

    fn format(cluster: *Cluster, replica: u8) !void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var replica_buffer: [32]u8 = undefined;
        const result = try std.process.Child.run(.{
            .allocator = cluster.gpa,
            .argv = &.{
                nerva_exe,
                "format",
                "--cluster=0",
                try std.fmt.bufPrint(&replica_buffer, "--replica={}", .{replica}),
                std.fmt.comptimePrint("--replica-count={}", .{replica_count}),
                "--development",
                cluster.data_file(&path_buffer, replica),
            },
        });
        defer cluster.gpa.free(result.stdout);
        defer cluster.gpa.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("format failed: {s}\n", .{result.stderr});
            return error.FormatFailed;
        }
    }

    fn start(cluster: *Cluster, replica: u8) !void {
        assert(cluster.processes[replica] == null);
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var addresses_buffer: [256]u8 = undefined;
        var trace_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var observe_buffer: [std.fs.max_path_bytes + 16]u8 = undefined;
        var statsd_buffer: [64]u8 = undefined;
        var log_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var argv: stdx.BoundedArrayType([]const u8, 10) = .{};
        // Each replica's log is appended to `replica_<n>.log`, shown if a scenario fails.
        argv.push("/bin/sh");
        argv.push("-c");
        argv.push("exec \"$0\" \"$@\" 2>>\"$NERVA_TEST_LOG\"");
        try cluster.environments[replica].put(
            "NERVA_TEST_LOG",
            cluster.log_file(&log_buffer, replica),
        );
        argv.push(nerva_exe);
        argv.push("start");
        argv.push(try std.fmt.bufPrint(
            &addresses_buffer,
            "--addresses={s}",
            .{cluster.addresses_flag},
        ));
        argv.push("--development");
        // Every replica sends metrics (round trips are recorded by whichever is primary);
        // replica 1 also writes a trace, and replica 2 has a larger row cache.
        argv.push(try std.fmt.bufPrint(&statsd_buffer, "--statsd=127.0.0.1:{}", .{
            cluster.statsd.port,
        }));
        switch (replica) {
            0 => {},
            // Only on its first start: `--trace` refuses an existing file.
            1 => if (!cluster.trace_started) {
                cluster.trace_started = true;
                argv.push(try std.fmt.bufPrint(&observe_buffer, "--trace={s}", .{
                    cluster.trace_file(&trace_buffer),
                }));
            },
            2 => argv.push("--cache-rows=64MiB"),
            else => unreachable,
        }
        argv.push(cluster.data_file(&path_buffer, replica));
        var process = std.process.Child.init(argv.const_slice(), cluster.gpa);
        process.env_map = &cluster.environments[replica];
        process.stdin_behavior = .Ignore;
        process.stdout_behavior = .Ignore;
        process.stderr_behavior = .Ignore;
        try process.spawn();
        cluster.processes[replica] = process;
    }

    /// Restarts `replica` with these cluster keys.
    fn restart_with_keys(
        cluster: *Cluster,
        replica: u8,
        current: []const u8,
        next: ?[]const u8,
    ) !void {
        cluster.stop(replica);
        const environment = &cluster.environments[replica];
        try environment.put("NERVA_CLUSTER_KEY", current);
        if (next) |key_next| {
            try environment.put("NERVA_CLUSTER_KEY_NEXT", key_next);
        } else {
            environment.remove("NERVA_CLUSTER_KEY_NEXT");
        }
        try cluster.start(replica);
    }

    fn stop(cluster: *Cluster, replica: u8) void {
        if (cluster.processes[replica]) |*process| {
            _ = process.kill() catch {};
            cluster.processes[replica] = null;
        }
    }

    fn client(cluster: *Cluster) !*Client {
        return cluster.client_with_timeout(timeout);
    }

    fn client_with_timeout(cluster: *Cluster, client_timeout: stdx.Duration) !*Client {
        const result = try cluster.gpa.create(Client);
        errdefer cluster.gpa.destroy(result);
        try result.init(cluster.gpa, .{
            .cluster = cluster_id,
            .addresses = &cluster.addresses,
            .timeout = client_timeout,
        });
        return result;
    }

    fn client_deinit(cluster: *Cluster, client_: *Client) void {
        client_.deinit();
        cluster.gpa.destroy(client_);
    }
};

/// A UDP socket that collects statsd packets from a replica.
const StatsdListener = struct {
    socket: std.posix.socket_t,
    port: u16,

    /// Replicas emit metrics every 10 s; allow for one full interval plus slack.
    const wait_max = stdx.Duration.seconds(15);

    fn init() !StatsdListener {
        const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        errdefer std.posix.close(socket);

        var address = try std.net.Address.parseIp4("127.0.0.1", 0);
        try std.posix.bind(socket, &address.any, address.getOsSockLen());
        var address_length = address.getOsSockLen();
        try std.posix.getsockname(socket, &address.any, &address_length);

        // A receive wakes at least once a second, so the deadline below is checked.
        const receive_timeout: std.posix.timeval = .{ .sec = 1, .usec = 0 };
        try std.posix.setsockopt(
            socket,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&receive_timeout),
        );
        return .{ .socket = socket, .port = address.getPort() };
    }

    fn deinit(listener: *StatsdListener) void {
        std.posix.close(listener.socket);
        listener.* = undefined;
    }

    /// Waits until every needle has appeared in some received packet.
    fn expect_metrics(listener: *StatsdListener, needles: []const []const u8) !void {
        assert(needles.len > 0);
        assert(needles.len <= 8);
        var found: [8]bool = @splat(false);
        var timer = try std.time.Timer.start();
        var packet: [2048]u8 = undefined;
        while (timer.read() < wait_max.ns) {
            const size = std.posix.recv(listener.socket, &packet, 0) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            for (needles, found[0..needles.len]) |needle, *seen| {
                if (std.mem.indexOf(u8, packet[0..size], needle) != null) seen.* = true;
            }
            if (std.mem.allEqual(bool, found[0..needles.len], true)) return;
        }
        for (needles, found[0..needles.len]) |needle, seen| {
            if (!seen) std.debug.print("statsd: never received {s}\n", .{needle});
        }
        return error.StatsdMetricsMissing;
    }
};

fn port_free() !u16 {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    return server.listen_address.getPort();
}

fn value(byte: u8) [nerva.value_size]u8 {
    return @splat(byte);
}

fn put(id: u64, byte: u8) Entry {
    return .{ .id = id, .table = 1, .kind = .put, .op_seen = 0, .value = value(byte) };
}

fn read(id: u64, op_seen: u64) Entry {
    return .{ .id = id, .table = 1, .kind = .read, .op_seen = op_seen, .value = @splat(0) };
}

fn lookup(client: *Client, table: u32, id: u64) !RowValue {
    var result: [1]RowValue = undefined;
    try client.lookup_rows(&.{.{ .id = id, .table = table }}, &result);
    return result[0];
}

fn expect_as_of(client: *Client, op: u64, byte: u8) !void {
    const change = (try client.row_as_of(1, 1, op)).?;
    try testing.expect(change.op <= op);
    try testing.expectEqual(value(byte), change.value);
}

fn commit(client: *Client, entries: []const Entry) ![]const EntryResult {
    const results = try gpa.alloc(EntryResult, entries.len);
    errdefer gpa.free(results);
    try client.commit(entries, results);
    return results;
}

fn expect_statuses(results: []const EntryResult, statuses: []const nerva.EntryStatus) !void {
    try testing.expectEqual(statuses.len, results.len);
    for (results, statuses) |result, status| try testing.expectEqual(status, result.status);
}

/// A three-replica cluster commits, conflicts, races and survives a crash.
fn scenario_cluster() !void {
    const cluster = try Cluster.init();
    defer cluster.deinit();
    errdefer cluster.logs_print();

    const daemon_a = try cluster.client();
    defer cluster.client_deinit(daemon_a);
    const daemon_b = try cluster.client();
    defer cluster.client_deinit(daemon_b);

    // Blind put, then lookup.
    const put_results = try commit(daemon_a, &.{put(1, 0xaa)});
    defer gpa.free(put_results);
    try expect_statuses(put_results, &.{.ok});
    const op_put = put_results[0].op;
    const row = try lookup(daemon_b, 1, 1);
    try testing.expect(row.flags.exists);
    try testing.expectEqual(op_put, row.op);
    try testing.expectEqual(value(0xaa), row.value);

    // Read at the current version commits; the same read is then stale.
    const fresh = try commit(daemon_a, &.{ read(1, op_put), put(1, 0xbb) });
    defer gpa.free(fresh);
    try expect_statuses(fresh, &.{ .ok, .ok });
    const stale = try commit(daemon_b, &.{ read(1, op_put), put(1, 0xcc) });
    defer gpa.free(stale);
    try expect_statuses(stale, &.{ .conflict, .aborted });
    try testing.expectEqual(fresh[0].op, stale[0].op);

    // The receipt race: both daemons see the same receipt, both claim it, one wins.
    const receipt_before = try lookup(daemon_a, workload.receipts_table, 7);
    try testing.expectEqual(@as(u64, 0), receipt_before.op);
    const claim_a = workload.receipt_claim(7, receipt_before.op, 0, 1);
    const claim_b = workload.receipt_claim(7, receipt_before.op, 0, 2);
    const won = try commit(daemon_a, &claim_a);
    defer gpa.free(won);
    const lost = try commit(daemon_b, &claim_b);
    defer gpa.free(lost);
    try expect_statuses(won, &.{ .ok, .ok });
    try expect_statuses(lost, &.{ .conflict, .aborted });
    const receipt_after = try lookup(daemon_b, workload.receipts_table, 7);
    try testing.expectEqual(@as(u64, 1), Receipt.from_value(&receipt_after.value).owner);

    // The change feed, paged two at a time, reassembles every committed write.
    var changes_all = std.ArrayList(Change).init(gpa);
    defer changes_all.deinit();
    var cursor: u64 = 0;
    var buffer: [3]Change = undefined;
    while (true) {
        const count = try daemon_a.get_changes(.{ .timestamp_min = cursor, .limit = 2 }, &buffer);
        try testing.expect(count >= 1);
        const end = buffer[count - 1];
        try testing.expectEqual(nerva.ChangeKind.end, end.kind);
        try changes_all.appendSlice(buffer[0 .. count - 1]);
        cursor = end.timestamp;
        if (!end.flags.more) break;
    }
    try testing.expectEqual(@as(usize, 3), changes_all.items.len); // Two puts and one claim.
    try testing.expectEqual(op_put, changes_all.items[0].op);
    try testing.expectEqual(workload.receipts_table, changes_all.items[2].table);

    // As-of reads (G6): row 1 as it was at each op, from either client.
    try expect_as_of(daemon_b, op_put, 0xaa);
    try expect_as_of(daemon_a, fresh[0].op, 0xbb);
    try expect_as_of(daemon_a, std.math.maxInt(u64), 0xbb);
    try testing.expect(op_put > 1); // Client registration commits first.
    try testing.expectEqual(null, try daemon_b.row_as_of(1, 1, op_put - 1));

    // Latency: a reply ends the client's wait at once, not at the end of its 10 ms tick, so the
    // median lookup is well under one tick (it was always at least one, N51).
    {
        var durations_ns: [50]u64 = undefined;
        for (&durations_ns) |*duration_ns| {
            var timer = try std.time.Timer.start();
            _ = try lookup(daemon_a, 1, 1);
            duration_ns.* = timer.read();
        }
        std.mem.sortUnstable(u64, &durations_ns, {}, std.sort.asc(u64));
        const median_ns = durations_ns[durations_ns.len / 2];
        std.debug.print("integration: lookup median {} us\n", .{median_ns / std.time.ns_per_us});
        try testing.expect(median_ns < constants.tick_ms * std.time.ns_per_ms);
    }

    // Observability: the replicas send request timings and gauges over statsd, and
    // replica 1 has written commit spans to its trace file.
    try cluster.statsd.expect_metrics(&.{
        "tb.replica_request_us.count:",
        "operation:Operation.commit",
        "tb.replica_commit_us.avg:",
        "tb.grid_cache_hits:",
        // Clients send each request's previous round trip; the primary records it.
        "tb.client_request_round_trip_us.count:",
    });
    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const trace = try std.fs.cwd().readFileAlloc(
            gpa,
            cluster.trace_file(&path_buffer),
            64 * stdx.MiB,
        );
        defer gpa.free(trace);
        try testing.expect(std.mem.startsWith(u8, trace, "[\n"));
        try testing.expect(std.mem.indexOf(u8, trace, "\"replica_commit\"") != null);
    }

    // Crash replica 2: the other two still form a quorum.
    cluster.stop(2);
    var expected: [16]u8 = undefined;
    for (&expected, 0..) |*byte, id| {
        byte.* = @intCast(id + 1);
        const results = try commit(daemon_a, &.{put(100 + id, byte.*)});
        defer gpa.free(results);
        try expect_statuses(results, &.{.ok});
    }

    // Restart replica 2, then crash replica 0: every commit now needs replica 2, so it must
    // have caught up on the writes it missed.
    try cluster.start(2);
    cluster.stop(0);
    for (expected, 0..) |byte, id| {
        const row_back = try lookup(daemon_b, 1, 100 + id);
        try testing.expect(row_back.flags.exists);
        try testing.expectEqual(value(byte), row_back.value);
    }
    // Replica 2's history index caught up too.
    try expect_as_of(daemon_b, op_put, 0xaa);
    const after_failover = try commit(daemon_b, &.{put(200, 0xdd)});
    defer gpa.free(after_failover);
    try expect_statuses(after_failover, &.{.ok});

    // Eviction: a client whose session the replicas dropped is evicted on its next request,
    // and gets `error.Evicted` (it used to abort the process, #52). Sessions outlive their
    // clients, so registering `clients_max` more pushes the oldest one out. Last: it pushes out
    // every earlier session too. Replica 0 is restarted first: with it down, each new client
    // first waits on it, and registering 64 takes minutes.
    try cluster.start(0);
    {
        const evictee = try cluster.client();
        defer cluster.client_deinit(evictee);
        for (0..constants.clients_max) |_| cluster.client_deinit(try cluster.client());
        try testing.expectError(error.Evicted, lookup(evictee, 1, 1));
        try testing.expectError(error.Evicted, lookup(evictee, 1, 1));
    }
}

/// Replicas authenticate each other (P102): a peer without the cluster key is refused whatever it
/// sends, a replica with another key stays outside the cluster, and the key rotates while the
/// cluster commits.
fn scenario_peer_auth() !void {
    const cluster = try Cluster.init();
    defer cluster.deinit();
    errdefer cluster.logs_print();

    const daemon = try cluster.client();
    defer cluster.client_deinit(daemon);
    try commit_ok(daemon, 1);

    // A rogue peer sends replica 2 a well-formed ping claiming to be replica 1: closed unread.
    {
        const stream = try peer_connect(cluster.addresses[2]);
        defer stream.close();
        var ping = ping_from(1);
        try stream.writeAll(ping.bytes());
        try expect_closed(stream);
    }
    // A hello from replica 2 to itself, or from a replica after it: closed (replicas dial only
    // those after them).
    for ([_]u8{ 1, 2 }) |claimed| {
        const stream = try peer_connect(cluster.addresses[1]);
        defer stream.close();
        const hello = hello_from(claimed, 0x1234);
        try stream.writeAll(std.mem.asBytes(&hello));
        try expect_closed(stream);
    }
    // A hello claiming replica 0 is challenged; the challenge proves replica 2 holds the key,
    // and a proof under another key is refused.
    {
        const stream = try peer_connect(cluster.addresses[2]);
        defer stream.close();
        const transcript = try handshake_begin(stream, 2, 0x5678);
        var proof = proof_from(0, cluster_key_wrong, &transcript);
        try stream.writeAll(std.mem.asBytes(&proof));
        try expect_closed(stream);
    }
    // A proof under the key is accepted: replica 2 then talks to us as replica 0. Holding the
    // key is all it takes. Replica 0 is down meanwhile, or it would reconnect and displace us.
    cluster.stop(0);
    {
        const stream = try peer_connect(cluster.addresses[2]);
        defer stream.close();
        const transcript = try handshake_begin(stream, 2, 0x9abc);
        var proof = proof_from(0, cluster_key, &transcript);
        try stream.writeAll(std.mem.asBytes(&proof));
        const header = try read_header(stream);
        try testing.expectEqual(@as(u8, 2), header.replica);
        try testing.expect(header.peer_type() == .replica);
    }
    try cluster.start(0);
    try commit_ok(daemon, 2);

    // A replica with another key stays outside: with replica 0 down, replicas 1 and 2 (other
    // key) cannot form a quorum.
    try cluster.restart_with_keys(2, cluster_key_wrong, null);
    try commit_ok(daemon, 3);
    {
        const daemon_short = try cluster.client_with_timeout(stdx.Duration.seconds(10));
        defer cluster.client_deinit(daemon_short);
        cluster.stop(0);
        const results = commit(daemon_short, &.{put(4, 4)});
        if (results) |committed| {
            gpa.free(committed);
            return error.CommittedWithWrongKey;
        } else |err| try testing.expectEqual(error.Timeout, err);
    }
    try cluster.start(0);
    try cluster.restart_with_keys(2, cluster_key, null);
    try commit_ok(daemon, 5);

    // A rolling rotation, one replica at a time; after each restart the replica just restarted
    // is needed for the quorum, with the next one down, so it must have authenticated under the
    // keys of that step.
    const steps = [_]struct { current: []const u8, next: ?[]const u8 }{
        .{ .current = cluster_key, .next = cluster_key_new },
        .{ .current = cluster_key_new, .next = cluster_key },
        .{ .current = cluster_key_new, .next = null },
    };
    var row: u64 = 10;
    for (steps) |step| {
        for (0..replica_count) |replica_usize| {
            const replica: u8 = @intCast(replica_usize);
            try cluster.restart_with_keys(replica, step.current, step.next);
            const replica_next: u8 = @intCast((replica_usize + 1) % replica_count);
            cluster.stop(replica_next);
            try commit_ok(daemon, row);
            row += 1;
            try cluster.start(replica_next);
        }
    }
    try commit_ok(daemon, row);
}

fn commit_ok(client: *Client, key: u64) !void {
    const results = try commit(client, &.{put(key, @truncate(key))});
    defer gpa.free(results);
    try expect_statuses(results, &.{.ok});
}

fn peer_connect(address: stdx.SocketAddress) !std.net.Stream {
    const stream = try std.net.tcpConnectToAddress(address.to_std());
    errdefer stream.close();
    const receive_timeout: std.posix.timeval = .{ .sec = 10, .usec = 0 };
    try std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&receive_timeout),
    );
    return stream;
}

/// The replica closes the connection without sending anything.
fn expect_closed(stream: std.net.Stream) !void {
    var buffer: [@sizeOf(Header)]u8 = undefined;
    const size = stream.read(&buffer) catch |err| switch (err) {
        error.ConnectionResetByPeer => 0,
        else => return err, // WouldBlock: the replica kept the connection open.
    };
    try testing.expectEqual(@as(usize, 0), size);
}

fn read_header(stream: std.net.Stream) !Header {
    var header: Header = undefined;
    try stream.reader().readNoEof(std.mem.asBytes(&header));
    try testing.expect(header.valid_checksum());
    return header;
}

fn hello_from(replica: u8, nonce: u128) Header.PeerHello {
    var hello: Header.PeerHello = .{
        .cluster = cluster_id,
        .release = constants.config.process.release,
        .command = .peer_hello,
        .replica = replica,
        .nonce = nonce,
        .origin = @splat(0),
    };
    hello.set_checksum_body(&.{});
    hello.set_checksum();
    return hello;
}

fn proof_from(
    replica: u8,
    key: []const u8,
    transcript: *const peer_auth.Transcript,
) Header.PeerProof {
    var proof: Header.PeerProof = .{
        .cluster = cluster_id,
        .release = constants.config.process.release,
        .command = .peer_proof,
        .replica = replica,
        .mac = peer_auth.proof(key, .dialing, transcript),
    };
    proof.set_checksum_body(&.{});
    proof.set_checksum();
    return proof;
}

/// Sends a hello as replica 0 and checks the challenge: from `accepting`, proving the key.
fn handshake_begin(stream: std.net.Stream, accepting: u8, nonce: u128) !peer_auth.Transcript {
    const hello = hello_from(0, nonce);
    try stream.writeAll(std.mem.asBytes(&hello));
    const header = try read_header(stream);
    const challenge = header.into_const(.peer_challenge) orelse return error.NotAChallenge;
    try testing.expectEqual(accepting, challenge.replica);
    const transcript: peer_auth.Transcript = .{
        .cluster = cluster_id,
        .dialing = 0,
        .accepting = accepting,
        .nonce_dialing = nonce,
        .nonce_accepting = challenge.nonce,
        .origin_dialing = @splat(0),
        .origin_accepting = challenge.origin,
    };
    const keys: peer_auth.Keys = .{ .current = cluster_key };
    try testing.expect(peer_auth.verify(&keys, .accepting, &transcript, &challenge.mac));
    const keys_wrong: peer_auth.Keys = .{ .current = cluster_key_wrong };
    try testing.expect(!peer_auth.verify(&keys_wrong, .accepting, &transcript, &challenge.mac));
    return transcript;
}

/// A well-formed ping, as replica `replica` of this release would send.
const PingMessage = extern struct {
    header: Header.Ping,
    releases: [constants.vsr_releases_max]vsr.Release,

    fn bytes(message: *const PingMessage) []const u8 {
        return std.mem.asBytes(message);
    }
};

fn ping_from(replica: u8) PingMessage {
    var message: PingMessage = .{
        .header = .{
            .cluster = cluster_id,
            .size = @sizeOf(PingMessage),
            .view = 0,
            .release = constants.config.process.release,
            .command = .ping,
            .replica = replica,
            .checkpoint_id = 0,
            .checkpoint_op = 0,
            .ping_timestamp_monotonic = 1,
            .release_count = 1,
            .origin = @splat(0),
        },
        .releases = @splat(vsr.Release.zero),
    };
    message.releases[0] = constants.config.process.release;
    message.header.set_checksum_body(std.mem.sliceAsBytes(&message.releases));
    message.header.set_checksum();
    assert(message.header.invalid() == null);
    return message;
}
