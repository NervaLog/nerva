//! The `botpike` workload of `bench:load` (P132): submits like the ones Botpike's app sends, through
//! one `nerva api` gateway over HTTP, instead of direct clients of the cluster.
//!
//! Botpike reaches Nerva only through one gateway, which serves one request at a time over one
//! cluster session, with up to 12 requests in flight. The other workloads measure direct clients,
//! which Botpike never has; this one measures what Botpike gets.
//!
//! One operation is one submit: a `POST /v1/lookup` of the rows the batch names, then a
//! `POST /v1/commit` under a fresh `key`. Submits alternate per caller:
//!
//! - reserve: `read` (`op_seen` 0) and `put` of a new transfer row, and a clamped add pair that
//!   moves an amount from an account's `available` to its `held`;
//! - settle: `read` of the pending transfer at the version the lookup returned, `read` (`op_seen`
//!   0) and `put` of a new transfer row, and an add pair that moves the amount from that
//!   account's `held` to another account's `available`.
//!
//! `--clients` is the number of concurrent callers, each a thread that opens one connection per
//! request (the gateway answers `Connection: close`). Closed loop only. The number of accounts is
//! `--keys`. Everything is bounded: bodies and replies have fixed buffers that are asserted.

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;

const stdx = @import("stdx");
const LatencyHistogram = @import("nerva/latency_histogram.zig").LatencyHistogram;

const accounts_table: u32 = 7;
const sources_table: u32 = 8;
const transfers_table: u32 = 9;
const ledger_id: u32 = 1;
const source_id: u64 = 1;
/// Microdollars a reserve asks for, and what each account is funded with (enough for a run).
const amount: u64 = 30_000;
const funding: u64 = 1_000_000_000;
/// Funding pairs in one commit: 2 entries each, within the 1024 of a commit with room to spare.
const funding_pairs_max = 255;
const accounts_max = 1_000_000;
pub const callers_max = 64;
const body_size_max = 16 * 1024;
const reply_size_max = 16 * 1024;
const funding_body_size_max = 128 * 1024;
const io_timeout_s = 30;
const key_header = "bench-botpike-key-0123456789abcdef";

pub const Params = struct {
    /// The gateway to send to.
    address: std.net.Address,
    callers: u32,
    /// Accounts, funded in setup.
    accounts: u64,
    seconds: u32,
    seed: u64,
    cluster: u128,
};

pub const Outcome = struct {
    /// Latency of a submit: its lookup and its commit.
    histogram: LatencyHistogram = .{},
    submits: u64 = 0,
    requests: u64 = 0,
    /// Entries committed (the key's entry not counted).
    entries: u64 = 0,
    conflicts: u64 = 0,
    /// A commit refused for a reason other than a conflict, or an HTTP request that failed.
    errors: u64 = 0,
    /// Callers that stopped with an error.
    failures: u64 = 0,

    fn merge(outcome: *Outcome, other: *const Outcome) void {
        outcome.histogram.merge(&other.histogram);
        outcome.submits += other.submits;
        outcome.requests += other.requests;
        outcome.entries += other.entries;
        outcome.conflicts += other.conflicts;
        outcome.errors += other.errors;
        outcome.failures += other.failures;
    }
};

/// A `nerva api` process on a free local port, in front of a cluster.
pub const Gateway = struct {
    process: std.process.Child,
    address: std.net.Address,

    pub fn start(
        gpa: std.mem.Allocator,
        nerva_exe: []const u8,
        cluster: u128,
        addresses: []const u8,
    ) !Gateway {
        const port = try port_free();
        var cluster_buffer: [48]u8 = undefined;
        var addresses_buffer: [512]u8 = undefined;
        var listen_buffer: [32]u8 = undefined;
        var environment = try std.process.getEnvMap(gpa);
        defer environment.deinit();
        try environment.put("NERVA_KEY", key_header);
        var gateway: Gateway = .{
            .process = std.process.Child.init(&.{
                nerva_exe,
                "api",
                try std.fmt.bufPrint(&cluster_buffer, "--cluster={}", .{cluster}),
                try std.fmt.bufPrint(&addresses_buffer, "--addresses={s}", .{addresses}),
                try std.fmt.bufPrint(&listen_buffer, "--listen=127.0.0.1:{}", .{port}),
            }, gpa),
            .address = try std.net.Address.parseIp4("127.0.0.1", port),
        };
        gateway.process.env_map = &environment;
        gateway.process.stdin_behavior = .Ignore;
        gateway.process.stdout_behavior = .Ignore;
        gateway.process.stderr_behavior = .Ignore;
        try gateway.process.spawn();
        errdefer _ = gateway.process.kill() catch {};

        // The replicas may still be starting: wait until the gateway has a session.
        var reply: [reply_size_max]u8 = undefined;
        for (0..300) |_| {
            if (request(gateway.address, "GET", "/healthz", "", &reply)) |response| {
                if (response.status == 200) return gateway;
            } else |_| {}
            std.time.sleep(100 * std.time.ns_per_ms);
        }
        return error.GatewayNotReady;
    }

    pub fn stop(gateway: *Gateway) void {
        _ = gateway.process.kill() catch {};
    }
};

fn port_free() !u16 {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    return server.listen_address.getPort();
}

const Response = struct {
    status: u16,
    body: []const u8,
};

/// One request on its own connection, answered into `reply` (which it must fit).
fn request(
    address: std.net.Address,
    method: []const u8,
    target: []const u8,
    body: []const u8,
    reply: []u8,
) !Response {
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();
    const timeout: posix.timeval = .{ .sec = io_timeout_s, .usec = 0 };
    try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));

    var head_buffer: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &head_buffer,
        "{s} {s} HTTP/1.1\r\nHost: bench\r\nX-Nerva-Key: {s}\r\nContent-Type: application/json\r\n" ++
            "Content-Length: {}\r\nConnection: close\r\n\r\n",
        .{ method, target, key_header, body.len },
    );
    try stream.writeAll(head);
    try stream.writeAll(body);

    var size: usize = 0;
    while (true) {
        if (size == reply.len) return error.ReplyTooLarge;
        const count = try stream.read(reply[size..]);
        if (count == 0) break;
        size += count;
    }
    const text = reply[0..size];
    if (text.len < 12 or !std.mem.startsWith(u8, text, "HTTP/1.")) return error.BadReply;
    const status = std.fmt.parseInt(u16, text[9..12], 10) catch return error.BadReply;
    const separator = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return error.BadReply;
    return .{ .status = status, .body = text[separator + 4 ..] };
}

/// Declares the layouts and the ledger, and funds every account from the source: the gateway's
/// own routes, as Botpike's app uses them. Idempotent, so a cluster may be used again by a later run (the nightly's): the source row is
/// created by its first add, never put over a balance that has moved.
fn setup(gpa: std.mem.Allocator, params: *const Params) !void {
    var reply: [reply_size_max]u8 = undefined;
    const address = params.address;
    try send_ok(address, "PUT", "/v1/tables/7",
        \\{"name":"accounts","fields":[{"name":"available","type":"i64"},{"name":"held","type":"i64"}]}
    , &reply);
    try send_ok(address, "PUT", "/v1/tables/8",
        \\{"name":"sources","fields":[{"name":"balance","type":"i64"}]}
    , &reply);
    try send_ok(address, "PUT", "/v1/tables/9",
        \\{"name":"transfers","fields":[{"name":"kind","type":"u8"},{"name":"state","type":"u8"},
        \\{"name":"account","type":"u64"},{"name":"amount","type":"i64"}]}
    , &reply);
    try send_ok(address, "PUT", "/v1/ledgers/1",
        \\{"fields":[{"table":7,"field":"available","floor":"0"},
        \\{"table":7,"field":"held","floor":"0"},{"table":8,"field":"balance","floor":null}]}
    , &reply);
    var body = try std.ArrayList(u8).initCapacity(gpa, funding_body_size_max);
    defer body.deinit();
    // The reply lists every add's applied amount and value.
    const funding_reply = try gpa.alloc(u8, funding_body_size_max);
    defer gpa.free(funding_reply);
    var next: u64 = 1;
    while (next <= params.accounts) {
        const pairs: u64 = @min(funding_pairs_max, params.accounts - next + 1);
        body.clearRetainingCapacity();
        const writer = body.writer();
        try writer.writeAll("{\"entries\":[");
        for (0..pairs) |pair| {
            if (pair > 0) try writer.writeAll(",");
            try writer.print(
                "{{\"kind\":\"add\",\"table\":{},\"id\":\"{}\",\"field\":\"balance\"," ++
                    "\"delta\":\"-{}\",\"pair\":true,\"create\":true}}," ++
                    "{{\"kind\":\"add\",\"table\":{},\"id\":\"{}\",\"field\":\"available\"," ++
                    "\"delta_from\":{},\"create\":true}}",
                .{ sources_table, source_id, funding, accounts_table, next + pair, pair * 2 },
            );
        }
        try writer.writeAll("]}");
        assert(body.items.len <= funding_body_size_max);
        const response = try request(address, "POST", "/v1/commit", body.items, funding_reply);
        if (response.status != 200) {
            std.debug.print("funding refused: {} {s}\n", .{ response.status, response.body });
            return error.SetupFailed;
        }
        next += pairs;
    }
}

fn send_ok(
    address: std.net.Address,
    method: []const u8,
    target: []const u8,
    body: []const u8,
    reply: []u8,
) !void {
    const response = try request(address, method, target, body, reply);
    if (response.status != 200) {
        std.debug.print("{s} {s}: {} {s}\n", .{ method, target, response.status, response.body });
        return error.SetupFailed;
    }
}

const Shared = struct {
    params: *const Params,
    /// Makes this run's transfer ids and keys differ from an earlier run's on the same cluster.
    nonce: u64,
    end_ns: u64,
};

pub fn run(gpa: std.mem.Allocator, params: *const Params) !Outcome {
    assert(params.callers >= 1 and params.callers <= callers_max);
    assert(params.accounts >= 2 and params.accounts <= accounts_max);
    assert(params.seconds >= 1);

    try setup(gpa, params);

    var time_os: stdx.TimeOS = .{};
    const time = time_os.interface();
    var shared: Shared = .{
        .params = params,
        .nonce = std.crypto.random.int(u64),
        .end_ns = time.monotonic().add(.{ .ns = @as(u64, params.seconds) * std.time.ns_per_s }).ns,
    };

    const callers = try gpa.alloc(Caller, params.callers);
    defer gpa.free(callers);
    const threads = try gpa.alloc(std.Thread, params.callers);
    defer gpa.free(threads);
    for (callers, threads, 0..) |*caller, *thread, index| {
        caller.* = .{
            .shared = &shared,
            .index = @intCast(index),
            .prng = stdx.PRNG.from_seed(params.seed ^ (shared.nonce +% index)),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        thread.* = try std.Thread.spawn(.{}, Caller.main, .{caller});
    }
    var total: Outcome = .{};
    for (callers, threads) |*caller, thread| {
        thread.join();
        caller.arena.deinit();
        total.merge(&caller.outcome);
    }
    return total;
}

const Pending = struct {
    transfer: u64,
    account: u64,
};

const Caller = struct {
    shared: *Shared,
    index: u32,
    prng: stdx.PRNG,
    arena: std.heap.ArenaAllocator,
    outcome: Outcome = .{},
    sequence: u64 = 0,
    /// The reserve this caller settles next, if its last submit was a reserve that committed.
    pending: ?Pending = null,
    body: [body_size_max]u8 = undefined,
    reply: [reply_size_max]u8 = undefined,
    /// The body of the last lookup's reply, in `reply`.
    last_body: []const u8 = "",

    fn main(caller: *Caller) void {
        caller.loop() catch |err| {
            std.log.err("caller {}: {}", .{ caller.index, err });
            caller.outcome.failures += 1;
        };
    }

    fn loop(caller: *Caller) !void {
        var time_os: stdx.TimeOS = .{};
        const time = time_os.interface();
        while (true) {
            const start = time.monotonic();
            if (start.ns >= caller.shared.end_ns) break;
            const pending = caller.pending;
            caller.pending = null;
            const done = if (pending) |reserved|
                try caller.settle(reserved)
            else
                try caller.reserve();
            // A submit that failed on the wire is not a latency sample of the cluster.
            if (done) {
                caller.outcome.histogram.record(start.elapsed(time.monotonic()).ns);
                caller.outcome.submits += 1;
            }
        }
    }

    fn account_random(caller: *Caller) u64 {
        return 1 + caller.prng.int_inclusive(u64, caller.shared.params.accounts - 1);
    }

    /// A transfer id, distinct across callers, submits and runs (the top bit is set: never zero).
    fn transfer_next(caller: *Caller) u64 {
        caller.sequence += 1;
        const base = caller.shared.nonce +% (@as(u64, caller.index) << 40);
        return (1 << 63) | ((base +% caller.sequence) & ((1 << 63) - 1));
    }

    fn key_next(caller: *Caller) [32]u8 {
        var key: [16]u8 = undefined;
        while (true) {
            caller.prng.fill(&key);
            if (!std.mem.allEqual(u8, &key, 0)) break;
        }
        return std.fmt.bytesToHex(key, .lower);
    }

    /// Returns whether the submit ran to an answer.
    fn reserve(caller: *Caller) !bool {
        const account = caller.account_random();
        const transfer = caller.transfer_next();
        const lookup = try std.fmt.bufPrint(
            &caller.body,
            "{{\"rows\":[{{\"table\":{},\"id\":\"{}\"}},{{\"table\":{},\"id\":\"{}\"}}]}}",
            .{ accounts_table, account, transfers_table, transfer },
        );
        if (!try caller.send("/v1/lookup", lookup)) return false;

        const key = caller.key_next();
        const body_commit = try std.fmt.bufPrint(
            &caller.body,
            "{{\"key\":\"{s}\",\"entries\":[" ++
                "{{\"kind\":\"read\",\"table\":{},\"id\":\"{}\",\"op_seen\":\"0\"}}," ++
                "{{\"kind\":\"put\",\"table\":{},\"id\":\"{}\"," ++
                "\"fields\":{{\"kind\":1,\"state\":1,\"account\":\"{}\",\"amount\":\"{}\"}}}}," ++
                "{{\"kind\":\"add\",\"table\":{},\"id\":\"{}\",\"field\":\"available\"," ++
                "\"delta\":\"-{}\",\"min\":\"0\",\"pair\":true,\"clamp\":true}}," ++
                "{{\"kind\":\"add\",\"table\":{},\"id\":\"{}\",\"field\":\"held\"," ++
                "\"delta_from\":2}}]}}",
            .{
                key,            transfers_table, transfer,       transfers_table, transfer,
                account,        amount,          accounts_table, account,         amount,
                accounts_table, account,
            },
        );
        const committed = try caller.commit(body_commit, 4);
        if (committed) caller.pending = .{ .transfer = transfer, .account = account };
        return true;
    }

    fn settle(caller: *Caller, reserved: Pending) !bool {
        const destination = caller.account_random();
        const transfer = caller.transfer_next();
        const lookup = try std.fmt.bufPrint(
            &caller.body,
            "{{\"rows\":[{{\"table\":{},\"id\":\"{}\"}},{{\"table\":{},\"id\":\"{}\"}}," ++
                "{{\"table\":{},\"id\":\"{}\"}},{{\"table\":{},\"id\":\"{}\"}}]}}",
            .{
                accounts_table,  reserved.account,  accounts_table,  destination,
                transfers_table, reserved.transfer, transfers_table, transfer,
            },
        );
        if (!try caller.send("/v1/lookup", lookup)) return false;
        const op = caller.pending_version() orelse {
            caller.outcome.errors += 1;
            return true;
        };

        const key = caller.key_next();
        const body_commit = try std.fmt.bufPrint(
            &caller.body,
            "{{\"key\":\"{s}\",\"entries\":[" ++
                "{{\"kind\":\"read\",\"table\":{},\"id\":\"{}\",\"op_seen\":\"{}\"}}," ++
                "{{\"kind\":\"read\",\"table\":{},\"id\":\"{}\",\"op_seen\":\"0\"}}," ++
                "{{\"kind\":\"put\",\"table\":{},\"id\":\"{}\"," ++
                "\"fields\":{{\"kind\":2,\"state\":2,\"account\":\"{}\",\"amount\":\"{}\"}}}}," ++
                "{{\"kind\":\"add\",\"table\":{},\"id\":\"{}\",\"field\":\"held\"," ++
                "\"delta\":\"-{}\",\"min\":\"0\",\"pair\":true,\"clamp\":true}}," ++
                "{{\"kind\":\"add\",\"table\":{},\"id\":\"{}\",\"field\":\"available\"," ++
                "\"delta_from\":3}}]}}",
            .{
                key,              transfers_table, reserved.transfer, op,
                transfers_table,  transfer,        transfers_table,   transfer,
                reserved.account, amount,          accounts_table,    reserved.account,
                amount,           accounts_table,  destination,
            },
        );
        _ = try caller.commit(body_commit, 5);
        return true;
    }

    /// The version of the pending transfer in the last lookup's reply (its third row).
    fn pending_version(caller: *Caller) ?u64 {
        const Reply = struct { rows: []const struct { exists: bool, op: []const u8 } };
        _ = caller.arena.reset(.retain_capacity);
        const parsed = std.json.parseFromSliceLeaky(
            Reply,
            caller.arena.allocator(),
            caller.last_body,
            .{ .ignore_unknown_fields = true },
        ) catch return null;
        if (parsed.rows.len != 4 or !parsed.rows[2].exists) return null;
        return std.fmt.parseInt(u64, parsed.rows[2].op, 10) catch null;
    }

    /// A lookup that answered 200. A failed request is an error of this generator or the
    /// gateway, counted, and the submit is dropped.
    fn send(caller: *Caller, target: []const u8, body: []const u8) !bool {
        caller.outcome.requests += 1;
        const response = request(
            caller.shared.params.address,
            "POST",
            target,
            body,
            &caller.reply,
        ) catch |err| {
            std.log.err("{s}: {}", .{ target, err });
            caller.outcome.errors += 1;
            return false;
        };
        if (response.status != 200) {
            std.log.err("{s}: {} {s}", .{ target, response.status, response.body });
            caller.outcome.errors += 1;
            return false;
        }
        caller.last_body = response.body;
        return true;
    }

    /// A commit: returns whether it committed.
    fn commit(caller: *Caller, body: []const u8, entries: u64) !bool {
        caller.outcome.requests += 1;
        const response = request(
            caller.shared.params.address,
            "POST",
            "/v1/commit",
            body,
            &caller.reply,
        ) catch |err| {
            std.log.err("/v1/commit: {}", .{err});
            caller.outcome.errors += 1;
            return false;
        };
        switch (response.status) {
            200 => {
                caller.outcome.entries += entries;
                return true;
            },
            409 => {
                if (std.mem.indexOf(u8, response.body, "\"conflict\"") != null) {
                    caller.outcome.conflicts += 1;
                } else {
                    std.log.err("/v1/commit: {s}", .{response.body});
                    caller.outcome.errors += 1;
                }
                return false;
            },
            else => {
                std.log.err("/v1/commit: {} {s}", .{ response.status, response.body });
                caller.outcome.errors += 1;
                return false;
            },
        }
    }
};
