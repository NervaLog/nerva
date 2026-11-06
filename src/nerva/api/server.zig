//! The HTTP side of `nerva api` (docs/DECISIONS.md N33): keyed by `X-Nerva-Key`, every route one
//! Nerva request (`api.zig`), one cluster request at a time over one session. The commits and
//! lookups that are waiting together when the gateway turns to them are one cluster request, one
//! batch each (docs/decisions/P143-nerva-api-combines-waiting-requests.md). Run several gateways
//! for more throughput: each is a separate client of the cluster, and commits from all of them
//! are serialized there.

const std = @import("std");
const stdx = @import("stdx");
const assert = std.debug.assert;
const log = std.log.scoped(.api);

const Client = @import("../client.zig").Client;
const client_batches_max = @import("../client.zig").batches_max;
const api = @import("api.zig");
const http_connection = @import("../http_connection.zig");
const CatalogStore = @import("catalog_store.zig").CatalogStore;
const MemoryBudget = @import("memory_budget.zig");
const ClientHealth = @import("../client_health.zig").ClientHealth;
const wire = @import("../wire_code.zig");
const metrics = @import("metrics.zig");
const timings = @import("../timings.zig");
const diagnostic = @import("../diagnostic.zig");

/// The largest request body: a full commit request in JSON is well under this.
const body_size_max = 4 * 1024 * 1024;
/// Connections whose requests are read at once (N45): each holds a buffer of `body_size_max`.
const connections_max = 16;

comptime {
    // A group is read from the connections, and is one request of the cluster client.
    assert(api.group_max <= connections_max);
    assert(api.group_max <= client_batches_max);
}

pub const Options = struct {
    listen: std.net.Address,
    /// `X-Nerva-Key` must be one of these (`http_connection.key_accepted`).
    keys: http_connection.Keys,
    on_listening: ?*const fn (address: std.net.Address) void = null,
    /// Where metrics go as statsd (`--statsd`); none without it. Opened by the caller before the
    /// client registers a session (P176d); the caller closes it.
    emitter: ?*metrics.Emitter = null,
    /// What `client` counts; the gateway reports it. It is `client.options.tally`, so that it
    /// survives the client being replaced.
    tally: *timings.Tally,
};

pub fn serve(gpa: std.mem.Allocator, client: *Client, options: Options) !noreturn {
    assert(http_connection.Keys.invalid(options.keys.current, options.keys.next) == null);
    assert(client.options.tally == options.tally);
    var counters: metrics.Counters = .{};
    var receiver = try http_connection.Receiver.init(gpa, options.listen, .{
        .connections_max = connections_max,
        .body_size_max = body_size_max,
        .counters = &counters,
    });
    defer receiver.deinit(gpa);

    if (options.emitter) |emitter| emitter.set_listen(receiver.listen_address());
    log.info("listening on {}", .{receiver.listen_address()});
    if (options.on_listening) |on_listening| on_listening(receiver.listen_address());
    var layouts = CatalogStore.init(client);
    var health = try ClientHealth.init(client);
    // Each request's memory is bounded, and the arena gives back what one large request took
    // (#31).
    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    var budget = MemoryBudget.init(arena_instance.allocator(), MemoryBudget.limit_default);

    while (true) {
        // Before every wait, not only when idle: a load balancer polling `/healthz` every second
        // must not keep a broken client from being replaced (#44), or a quiet cluster from being
        // probed, so that `/healthz` notices a cluster that went away (P168d).
        if (health.state == .ready) {
            if (!health.probe(client)) layouts.cache_clear();
        } else {
            _ = health.ready(client);
        }
        var wake_ms = health.idle_timeout_ms(-1);
        if (options.emitter) |sender| {
            sender.tick(&counters, &options.tally.operations, .{
                .session = health.state == .ready,
                .reconnects_ok = health.reconnects_ok,
                .reconnects_failed = health.reconnects_failed,
                .lingering_dropped = receiver.lingering_dropped,
                .connections = receiver.slots_in_use(),
            });
            wake_ms = sender.wait_ms(wake_ms);
        }
        const received = try receiver.next(wake_ms) orelse continue;
        const requests_before = options.tally.requests;
        // One deadline for everything this request does (#186). Groups are served by one cluster
        // request each, so they share it.
        health.window_open(client);
        budget.request_start();
        const arena = budget.allocator();
        // Requests are read from many connections at once (N45). Those already waiting for the
        // cluster, for the same route, are answered with one cluster request, never waiting for
        // more (P143).
        var group: [api.group_max]http_connection.Received = undefined;
        group[0] = received;
        var group_count: usize = 1;
        const filter: GroupFilter = .{ .keys = options.keys, .target = received.request.target };
        if (filter.accepts(&received.request)) {
            group_count += receiver.take(filter, GroupFilter.accepts, group[1..]);
        }
        if (group_count > 1) {
            serve_group(
                arena,
                client,
                &health,
                &layouts,
                &receiver,
                &counters,
                &budget,
                group[0..group_count],
            );
        } else {
            const writes_before = client.writes_sent;
            const reply = serve_request(
                arena,
                client,
                &health,
                &layouts,
                options,
                &received.request,
            ) catch |err| reply_of_error(
                err,
                &budget,
                api.applied_since(writes_before, client.writes_sent),
            );
            answer(&receiver, &counters, received, reply);
        }
        const asked = options.tally.requests != requests_before;
        if (asked) counters.group(group_count);
        if (health.state == .ready and asked) health.replied();
        health.window_close(client);
        // `respond` has written the reply: give back what the request took at once, rather than
        // when the next request arrives (#60).
        _ = arena_instance.reset(.{ .retain_with_limit = MemoryBudget.retain_max });
    }
}

/// Writes `reply` to the request `received`, and counts it (`metrics.zig`): by route and status,
/// as unknown if it says so, and as refused if the gateway had no session to send it to.
fn answer(
    receiver: *http_connection.Receiver,
    counters: *metrics.Counters,
    received: http_connection.Received,
    reply: api.Reply,
) void {
    const route = metrics.route_of(received.request.method == .get, received.request.target);
    // Counted only if written: a client that went away was not answered.
    if (!receiver.respond_written(received, reply.status, reply.body)) return;
    counters.replied(route, reply.status, metrics.reply_unknown(reply.status, reply.body));
    if (route != .healthz and reply.status == 503 and
        std.mem.eql(u8, reply.body, cluster_unavailable.body))
    {
        counters.refused_with(.unavailable);
    }
}

/// The requests that may be answered with others by one cluster request: a commit or a lookup,
/// with an accepted key and a body of a size that keeps the group inside a request's memory
/// budget (`api.group_body_max`), all for one route.
const GroupFilter = struct {
    keys: http_connection.Keys,
    target: []const u8,

    fn accepts(filter: GroupFilter, request: *const http_connection.Request) bool {
        return request.method == .post and
            api.group_route(.post, request.target) and
            std.mem.eql(u8, request.target, filter.target) and
            request.body.len <= api.group_body_max and
            http_connection.key_accepted(filter.keys, request.key);
    }
};

/// What a request that failed with `err` is answered, `applied` saying whether it sent a write
/// (`api.applied_since`, or the member's own in a group). The bodies are fixed: the arena may be
/// what ran out.
fn reply_of_error(
    err: anyerror,
    budget: *const MemoryBudget,
    applied: api.Applied,
) api.Reply {
    if (err == error.OutOfMemory and budget.exceeded) {
        log.warn("request: past its memory budget", .{});
        return .{ .status = 413, .body = switch (applied) {
            inline else => |known| wire.error_body(.E0113, "request too complex", known),
        } };
    }
    log.warn("request: {}", .{err});
    return .{ .status = 500, .body = switch (applied) {
        inline else => |known| wire.error_body(.B0001, "internal error", known),
    } };
}

/// The reply to a request that reached a cluster that did not answer (a timeout, an eviction):
/// unknown if a write was sent (NRV-E0601).
fn cluster_lost(applied: api.Applied) api.Reply {
    return .{ .status = 503, .body = switch (applied) {
        inline else => |known| wire.error_body(.E0601, "cluster unavailable", known),
    } };
}

/// The reply to a request whose window passed before a call could be sent (NRV-E0606): the
/// session is intact. Unknown if an earlier call of the same request sent a write.
fn request_expired(applied: api.Applied) api.Reply {
    return .{ .status = 503, .body = switch (applied) {
        inline else => |known| wire.error_body(.E0606, "request deadline passed", known),
    } };
}

/// The reply to a request while the gateway has no session: nothing was sent (NRV-E0605).
const cluster_unavailable = api.Reply{
    .status = 503,
    .body = wire.error_body(.E0605, "cluster unavailable", .no),
};

/// Answers requests that were waiting together (`api.handle_group`), each as it would have been
/// alone. If the cluster does not answer, every request that has no answer yet gets the 503 it
/// would have had alone.
fn serve_group(
    arena: std.mem.Allocator,
    client: *Client,
    health: *ClientHealth,
    layouts: *CatalogStore,
    receiver: *http_connection.Receiver,
    counters: *metrics.Counters,
    budget: *const MemoryBudget,
    received: []const http_connection.Received,
) void {
    assert(received.len >= 2 and received.len <= api.group_max);
    var members: [api.group_max]api.Member = undefined;
    for (members[0..received.len], received) |*member, one| {
        member.* = .{ .target = one.request.target, .body = one.request.body };
    }
    const members_used = members[0..received.len];
    const ready = health.ready(client);
    if (!ready) {
        for (members_used) |*member| member.result = cluster_unavailable;
    } else if (api.handle_group(arena, client, layouts, members_used)) {
        for (members_used) |*member| assert(member.result != null);
    } else |err| switch (err) {
        error.Expired => {
            for (members_used) |*member| {
                if (member.result == null) member.result = error.Expired;
            }
        },
        error.Evicted, error.Timeout => {
            log.err("{s}: {}", .{ members_used[0].target, err });
            health.broke();
            // The cluster may have changed under the new client: read layouts again (P135).
            layouts.cache_clear();
            for (members_used) |*member| {
                if (member.result == null) member.result = err;
            }
        },
        else => {
            for (members_used) |*member| {
                if (member.result == null) member.result = err;
            }
        },
    }
    for (members_used, received) |member, one| {
        answer(receiver, counters, one, member_reply(member, budget));
    }
}

/// A group member's reply: its answer, or the 503 it would have had alone, with the `applied` of
/// its own writes (not the group's).
fn member_reply(member: api.Member, budget: *const MemoryBudget) api.Reply {
    return member.result.? catch |err| switch (err) {
        error.Expired => request_expired(member.applied),
        error.Evicted, error.Timeout => cluster_lost(member.applied),
        else => reply_of_error(err, budget, member.applied),
    };
}

fn serve_request(
    arena: std.mem.Allocator,
    client: *Client,
    health: *ClientHealth,
    layouts: *CatalogStore,
    options: Options,
    request: *const http_connection.Request,
) !api.Reply {
    const target = request.target;
    if (request.method == .get and std.mem.eql(u8, target, "/healthz")) {
        if (health.state != .ready) return unavailable_healthz;
        return .{ .status = 200, .body = "{\"ok\":true,\"session\":\"ready\"}" };
    }
    const method: api.Method = switch (request.method) {
        .get => .get,
        .post => .post,
        .put => .put,
        .other => return api.error_reply(arena, .E0104, 405, "method not allowed", .no),
    };
    if (!http_connection.key_accepted(options.keys, request.key)) {
        return api.error_reply(arena, .E0103, 401, "invalid key", .no);
    }

    if (!health.ready(client)) return cluster_unavailable;
    const writes_before = client.writes_sent;
    return api.handle(arena, client, layouts, method, target, request.body) catch |err|
        switch (err) {
            error.Expired => return request_expired(
                api.applied_since(writes_before, client.writes_sent),
            ),
            error.Evicted, error.Timeout => {
                log.err("{s}: {}", .{ target, err });
                health.broke();
                // The cluster may have changed under the new client: read layouts again (P135).
                layouts.cache_clear();
                return cluster_lost(api.applied_since(writes_before, client.writes_sent));
            },
            error.OutOfMemory => return err,
            else => {
                log.err("{s}: {}", .{ target, err });
                return api.error_reply(
                    arena,
                    .B0001,
                    500,
                    "internal error",
                    api.applied_since(writes_before, client.writes_sent),
                );
            },
        };
}

/// `/healthz` while the gateway has no session: 503 NRV-E0605, as a request for the cluster.
const unavailable_healthz = api.Reply{
    .status = 503,
    .body = "{\"ok\":false,\"error\":\"cluster unavailable\",\"applied\":false," ++
        "\"code\":\"NRV-E0605\",\"session\":\"reconnecting\"}",
};

test "a request whose window passed is answered NRV-E0606, applied false unless a write went out" {
    const none = request_expired(.no);
    try std.testing.expectEqual(@as(u16, 503), none.status);
    try std.testing.expectEqualStrings(
        "{\"error\":\"request deadline passed\",\"applied\":false,\"code\":\"NRV-E0606\"}",
        none.body,
    );
    // Not the 503 of a lost session, which the metrics count as refused (E0605).
    try std.testing.expect(!std.mem.eql(u8, none.body, cluster_unavailable.body));
    try std.testing.expect(!metrics.reply_unknown(none.status, none.body));
    const sent = request_expired(.unknown);
    try std.testing.expect(metrics.reply_unknown(sent.status, sent.body));
}

test "a group member's reply carries its own applied (P195b)" {
    var budget = MemoryBudget.init(std.testing.allocator, MemoryBudget.limit_default);
    const target = "/v1/commit";
    // A views_busy send again that expired: its batch went out.
    const sent: api.Member = .{
        .target = target,
        .body = "",
        .result = error.Expired,
        .applied = .unknown,
    };
    try std.testing.expectEqualStrings(
        request_expired(.unknown).body,
        member_reply(sent, &budget).body,
    );
    // Nothing of it went out, though another member's did.
    const unsent: api.Member = .{
        .target = target,
        .body = "",
        .result = error.Expired,
        .applied = .no,
    };
    const reply = member_reply(unsent, &budget);
    try std.testing.expectEqualStrings(request_expired(.no).body, reply.body);
    try std.testing.expect(!std.mem.eql(u8, reply.body, request_expired(.unknown).body));
    // A timeout is the other 503, with the same rule.
    const lost: api.Member = .{
        .target = target,
        .body = "",
        .result = error.Timeout,
        .applied = .unknown,
    };
    try std.testing.expectEqualStrings(cluster_lost(.unknown).body, member_reply(lost, &budget).body);
}
