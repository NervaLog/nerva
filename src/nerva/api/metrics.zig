//! What `nerva api` counts, and sends as statsd over UDP (R4, P168e).
//!
//! The replicas' format (DogStatsD tags, so the same `statsd_exporter` reads it) with the prefix
//! `nerva.api.`. The gateway's loop holds one `Counters` and, with `--statsd`, one `Emitter`;
//! every `statsd_interval` the emitter writes the window's counters as lines of at most
//! `packet_size_max` bytes per packet, and starts a new window.
//!
//! Everything is bounded and allocates nothing after startup:
//! - the aggregates are fixed arrays sized by comptime enums (`Route`, `RefusalReason`,
//!   `nerva.Operation`) and the statuses the gateway answers, so cardinality is fixed;
//! - a packet is one buffer of `packet_size_max` bytes, sent when full;
//! - the socket never blocks: a packet the kernel does not take is dropped and counted in
//!   `nerva.api.statsd_dropped`, in the next window's lines.
//!
//! Series with no events in a window are not sent, except the two gauges.

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const log = std.log.scoped(.metrics);

const stdx = @import("stdx");
const nerva = @import("../../nerva.zig");
const api = @import("api.zig");

/// How often the emitter sends a window: as the replicas (N50).
pub const statsd_interval_ns = 10 * std.time.ns_per_s;
/// One MTU's worth, as `src/trace/statsd.zig`.
pub const packet_size_max = 1400;
/// The longest line: the metric, the shared tags and two more.
const line_size_max = 320;
/// The shared tags: `cluster:<32 hex>,listen:<address>`.
const tags_size_max = 128;

/// The routes a request is counted under: `api.Route`, the health check, and everything else (a
/// path that is not a route, or a request refused before it was read).
pub const Route = enum {
    lookup,
    commit,
    changes,
    history,
    row,
    tables,
    views,
    documents_get,
    documents_commit,
    documents_changes,
    view_groups,
    view_definition,
    view_list,
    ledgers,
    index_list,
    indexes,
    index_scan,
    healthz,
    other,
};

comptime {
    // A route added to the API must be counted under its own name.
    for (@typeInfo(api.Route).@"enum".fields) |field| assert(@hasField(Route, field.name));
}

/// The route of a request: by its path, whatever its method, as `api.handle` finds it.
pub fn route_of(get: bool, target: []const u8) Route {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..question];
    if (get and std.mem.eql(u8, path, "/healthz")) return .healthz;
    if (std.mem.eql(u8, path, "/v1/indexes")) return .index_list;
    if (std.mem.startsWith(u8, path, api.indexes_prefix)) {
        const scan = std.mem.endsWith(u8, path, api.index_scan_suffix) and
            path.len > api.indexes_prefix.len + api.index_scan_suffix.len;
        return if (scan) .index_scan else .indexes;
    }
    if (std.mem.startsWith(u8, path, api.ledgers_prefix)) return .ledgers;
    if (std.mem.eql(u8, path, "/v1/views")) return .view_list;
    if (std.mem.startsWith(u8, path, api.tables_prefix)) return .tables;
    if (std.mem.startsWith(u8, path, api.views_prefix)) {
        const view_suffix = struct {
            fn is(path_: []const u8, suffix: []const u8) bool {
                return std.mem.endsWith(u8, path_, suffix) and
                    path_.len > api.views_prefix.len + suffix.len;
            }
        }.is;
        if (view_suffix(path, api.views_groups_suffix)) return .view_groups;
        if (view_suffix(path, api.views_definition_suffix)) return .view_definition;
        return .views;
    }
    for (api.routes) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return std.meta.stringToEnum(Route, @tagName(entry.route)).?;
    }
    return .other;
}

/// The statuses the gateway answers, as the `status` tag; any other is counted as `other`.
pub const statuses = [_]u16{ 200, 400, 401, 404, 405, 408, 409, 413, 500, 503, 504 };
const status_slots = statuses.len + 1;

const status_names = names: {
    var names: [status_slots][]const u8 = undefined;
    for (statuses, 0..) |status, index| names[index] = std.fmt.comptimePrint("{d}", .{status});
    names[statuses.len] = "other";
    break :names names;
};

fn status_slot(status: u16) usize {
    for (statuses, 0..) |known, index| {
        if (known == status) return index;
    }
    return statuses.len;
}

/// Why the gateway itself answered a request `applied: false` (`nerva.api.refused`).
pub const RefusalReason = enum {
    /// Every slot held a connection that had sent bytes, and another one waited (NRV-E0602).
    busy,
    /// A silent connection gave its slot to one that waited (NRV-E0602).
    displaced,
    /// A complete request was not taken within `queue_wait_max` (NRV-E0602).
    queue_wait,
    /// The request was not whole in time (NRV-E0116).
    deadline,
    /// A malformed head (NRV-E0101).
    malformed,
    /// A body past the limit (NRV-E0102).
    too_large,
    /// The gateway had no session, so the request was not sent (NRV-E0605).
    unavailable,
};

/// The count, sum, least and greatest of what a window saw.
pub const Aggregate = struct {
    count: u64 = 0,
    sum: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,

    pub fn record(aggregate: *Aggregate, value: u64) void {
        aggregate.count += 1;
        aggregate.sum +|= value;
        aggregate.min = @min(aggregate.min, value);
        aggregate.max = @max(aggregate.max, value);
    }
};

/// Round trips to the cluster by operation, in nanoseconds: `Client` records, the emitter reads
/// and resets.
pub const OperationTimings = std.enums.EnumArray(nerva.Operation, Aggregate);

/// What a gateway counts between two windows. The receiver and the loop record into it; only
/// the emitter resets it.
pub const Counters = struct {
    requests: [route_count][status_slots]u64 = std.mem.zeroes([route_count][status_slots]u64),
    refused: [refusal_count]u64 = std.mem.zeroes([refusal_count]u64),
    unknown: [route_count]u64 = std.mem.zeroes([route_count]u64),
    /// Requests answered together by one cluster request (P143).
    group_size: Aggregate = .{},
    /// From a request being complete to the loop taking it, in nanoseconds.
    queue_wait: Aggregate = .{},
    /// The most slots in use at once in the window.
    connections: u32 = 0,

    const route_count = std.meta.fields(Route).len;
    const refusal_count = std.meta.fields(RefusalReason).len;

    /// A reply written for a request on `route`.
    pub fn replied(counters: *Counters, route: Route, status: u16, unknown: bool) void {
        counters.requests[@intFromEnum(route)][status_slot(status)] += 1;
        if (unknown) counters.unknown[@intFromEnum(route)] += 1;
    }

    /// The gateway refused a request, applying nothing, without its reply being counted
    /// elsewhere.
    pub fn refused_with(counters: *Counters, reason: RefusalReason) void {
        counters.refused[@intFromEnum(reason)] += 1;
    }

    /// A refusal the receiver wrote itself: the reason, and the reply as a request on no route.
    pub fn refusal_written(counters: *Counters, reason: RefusalReason, status: u16) void {
        counters.refused_with(reason);
        counters.replied(.other, status, false);
    }

    pub fn group(counters: *Counters, size: usize) void {
        counters.group_size.record(size);
    }

    pub fn waited(counters: *Counters, ns: u64) void {
        counters.queue_wait.record(ns);
    }

    pub fn connections_seen(counters: *Counters, in_use: u32) void {
        counters.connections = @max(counters.connections, in_use);
    }
};

/// What the emitter reads beside `Counters`: state that lives elsewhere, as totals since the
/// start (the emitter sends the difference from the last window).
pub const Observed = struct {
    /// The session is ready now.
    session: bool,
    reconnects_ok: u64,
    reconnects_failed: u64,
    lingering_dropped: u64,
};

/// Whether a reply says `applied: "unknown"` (a write went out and nothing came back).
pub fn reply_unknown(status: u16, body: []const u8) bool {
    return status >= 400 and std.mem.indexOf(u8, body, "\"applied\":\"unknown\"") != null;
}

/// One packet being filled: lines, joined by newlines.
const Packet = struct {
    buffer: [packet_size_max]u8 = undefined,
    len: usize = 0,
    lines: u32 = 0,
    /// Lines that did not leave: formatted wrongly, or the sink did not take their packet.
    dropped: u64 = 0,

    fn add(packet: *Packet, sink: anytype, line: []const u8) void {
        assert(line.len <= packet_size_max);
        const needed = line.len + @intFromBool(packet.len > 0);
        if (packet.len + needed > packet_size_max) packet.flush(sink);
        if (packet.len > 0) {
            packet.buffer[packet.len] = '\n';
            packet.len += 1;
        }
        @memcpy(packet.buffer[packet.len..][0..line.len], line);
        packet.len += line.len;
        packet.lines += 1;
    }

    fn flush(packet: *Packet, sink: anytype) void {
        if (packet.len == 0) return;
        if (!sink.send(packet.buffer[0..packet.len])) packet.dropped += packet.lines;
        packet.len = 0;
        packet.lines = 0;
    }

    /// `nerva.api.<name>:<value>|<kind>|#<tags>[,<key>:<value>]...`
    fn series(
        packet: *Packet,
        sink: anytype,
        name: []const u8,
        suffix: []const u8,
        value: u64,
        kind: u8,
        tags: []const u8,
        extra: []const [2][]const u8,
    ) void {
        var scratch: [line_size_max]u8 = undefined;
        var stream = std.io.fixedBufferStream(&scratch);
        const writer = stream.writer();
        const written = write: {
            writer.print("nerva.api.{s}{s}:{d}|{c}|#{s}", .{ name, suffix, value, kind, tags }) catch
                break :write false;
            for (extra) |pair| writer.print(",{s}:{s}", .{ pair[0], pair[1] }) catch break :write false;
            break :write true;
        };
        if (!written) {
            packet.dropped += 1;
            return;
        }
        packet.add(sink, stream.getWritten());
    }

    /// The five lines of an aggregate, as the replicas' timings: `count` and `sum` are counters,
    /// `min`, `max` and `avg` gauges. Values are divided by `divisor` (ns to us).
    fn aggregate(
        packet: *Packet,
        sink: anytype,
        name: []const u8,
        value: Aggregate,
        divisor: u64,
        tags: []const u8,
        extra: []const [2][]const u8,
    ) void {
        if (value.count == 0) return;
        const sum = value.sum / divisor;
        packet.series(sink, name, ".count", value.count, 'c', tags, extra);
        packet.series(sink, name, ".sum", sum, 'c', tags, extra);
        packet.series(sink, name, ".min", value.min / divisor, 'g', tags, extra);
        packet.series(sink, name, ".max", value.max / divisor, 'g', tags, extra);
        packet.series(sink, name, ".avg", sum / value.count, 'g', tags, extra);
    }
};

/// Writes the window as packets to `sink` (`fn send(*Sink, []const u8) bool`, false when the
/// packet was not taken), then resets `counters` and `timings`. `window` carries what changed
/// elsewhere since the last window. Returns the lines that did not leave.
pub fn render(
    counters: *Counters,
    timings: *OperationTimings,
    window: Window,
    tags: []const u8,
    sink: anytype,
) u64 {
    assert(tags.len <= tags_size_max);
    var packet: Packet = .{};
    for (std.enums.values(Route)) |route| {
        for (counters.requests[@intFromEnum(route)], 0..) |count, slot| {
            if (count == 0) continue;
            packet.series(sink, "requests", "", count, 'c', tags, &.{
                .{ "route", @tagName(route) },
                .{ "status", status_names[slot] },
            });
        }
    }
    for (std.enums.values(RefusalReason)) |reason| {
        const count = counters.refused[@intFromEnum(reason)];
        if (count == 0) continue;
        packet.series(sink, "refused", "", count, 'c', tags, &.{.{ "reason", @tagName(reason) }});
    }
    for (std.enums.values(Route)) |route| {
        const count = counters.unknown[@intFromEnum(route)];
        if (count == 0) continue;
        packet.series(sink, "unknown", "", count, 'c', tags, &.{.{ "route", @tagName(route) }});
    }
    packet.aggregate(sink, "group_size", counters.group_size, 1, tags, &.{});
    for (std.enums.values(nerva.Operation)) |operation| {
        packet.aggregate(
            sink,
            "cluster_request_us",
            timings.get(operation),
            std.time.ns_per_us,
            tags,
            &.{.{ "operation", @tagName(operation) }},
        );
    }
    packet.aggregate(sink, "queue_wait_us", counters.queue_wait, std.time.ns_per_us, tags, &.{});
    if (window.reconnects_ok > 0) {
        packet.series(sink, "reconnects", "", window.reconnects_ok, 'c', tags, &.{.{ "result", "ok" }});
    }
    if (window.reconnects_failed > 0) {
        packet.series(sink, "reconnects", "", window.reconnects_failed, 'c', tags, &.{.{ "result", "failed" }});
    }
    packet.series(sink, "session", "", @intFromBool(window.session), 'g', tags, &.{});
    packet.series(sink, "connections", "", counters.connections, 'g', tags, &.{});
    if (window.lingering_dropped > 0) {
        packet.series(sink, "lingering_dropped", "", window.lingering_dropped, 'c', tags, &.{});
    }
    if (window.statsd_dropped > 0) {
        packet.series(sink, "statsd_dropped", "", window.statsd_dropped, 'c', tags, &.{});
    }
    packet.flush(sink);

    counters.* = .{};
    timings.* = OperationTimings.initFill(.{});
    return packet.dropped;
}

/// What happened in a window that the counters do not hold.
pub const Window = struct {
    session: bool,
    reconnects_ok: u64,
    reconnects_failed: u64,
    lingering_dropped: u64,
    statsd_dropped: u64,
};

/// Sends windows over UDP. The socket is non-blocking: a window never waits for the network.
pub const Emitter = struct {
    socket: posix.socket_t,
    tags: [tags_size_max]u8,
    tags_len: usize,
    timer: std.time.Timer,
    /// A `timer` reading: when the current window began.
    window_start: u64 = 0,
    /// How long a window lasts (`statsd_interval_ns`; tests shorten it).
    interval_ns: u64 = statsd_interval_ns,
    /// Totals as of the last window.
    previous: struct { reconnects_ok: u64 = 0, reconnects_failed: u64 = 0, lingering_dropped: u64 = 0 } = .{},
    /// Lines the socket did not take, in total, and as reported by the last window.
    dropped: u64 = 0,
    dropped_reported: u64 = 0,

    pub fn init(address: stdx.SocketAddress, cluster: u128, listen: std.net.Address) !Emitter {
        const address_std = address.to_std();
        const socket = try posix.socket(
            address_std.any.family,
            posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            posix.IPPROTO.UDP,
        );
        errdefer posix.close(socket);
        // Connected, so that `send` is a plain write.
        try posix.connect(socket, &address_std.any, address_std.getOsSockLen());

        var emitter: Emitter = .{
            .socket = socket,
            .tags = undefined,
            .tags_len = 0,
            .timer = try std.time.Timer.start(),
        };
        const tags = std.fmt.bufPrint(&emitter.tags, "cluster:{x:0>32},listen:{}", .{ cluster, listen }) catch
            unreachable; // A 32-digit cluster and an address fit `tags_size_max`.
        emitter.tags_len = tags.len;
        log.info("sending statsd metrics to {}", .{address});
        return emitter;
    }

    pub fn deinit(emitter: *Emitter) void {
        posix.close(emitter.socket);
    }

    /// Milliseconds until the window ends, at least 1 and at most `limit_ms` (-1: no limit).
    pub fn wait_ms(emitter: *Emitter, limit_ms: i32) i32 {
        const elapsed = emitter.timer.read() -| emitter.window_start;
        const left_ns = emitter.interval_ns -| elapsed;
        const left: i32 = @intCast(@max(1, (left_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms));
        return if (limit_ms < 0) left else @min(limit_ms, left);
    }

    /// Ends the window and sends it, if it has lasted `statsd_interval_ns`.
    pub fn tick(
        emitter: *Emitter,
        counters: *Counters,
        timings: *OperationTimings,
        observed: Observed,
    ) void {
        const now = emitter.timer.read();
        if (now -| emitter.window_start < emitter.interval_ns) return;
        emitter.window_start = now;
        const window: Window = .{
            .session = observed.session,
            .reconnects_ok = observed.reconnects_ok - emitter.previous.reconnects_ok,
            .reconnects_failed = observed.reconnects_failed - emitter.previous.reconnects_failed,
            .lingering_dropped = observed.lingering_dropped - emitter.previous.lingering_dropped,
            .statsd_dropped = emitter.dropped - emitter.dropped_reported,
        };
        emitter.previous = .{
            .reconnects_ok = observed.reconnects_ok,
            .reconnects_failed = observed.reconnects_failed,
            .lingering_dropped = observed.lingering_dropped,
        };
        emitter.dropped_reported = emitter.dropped;
        var sink: UdpSink = .{ .socket = emitter.socket };
        emitter.dropped += render(counters, timings, window, emitter.tags[0..emitter.tags_len], &sink);
    }

    const UdpSink = struct {
        socket: posix.socket_t,

        fn send(sink: *UdpSink, bytes: []const u8) bool {
            const sent = posix.send(sink.socket, bytes, posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL) catch
                return false;
            return sent == bytes.len;
        }
    };
};

const testing = std.testing;

/// A sink that keeps its packets, up to `packets_max`, and refuses packets from `refuse_from`.
const TestSink = struct {
    const packets_max = 64;
    packets: [packets_max][packet_size_max]u8 = undefined,
    sizes: [packets_max]usize = undefined,
    count: usize = 0,
    refuse_from: usize = std.math.maxInt(usize),

    fn send(sink: *TestSink, bytes: []const u8) bool {
        if (sink.count >= sink.refuse_from) {
            sink.count += 1;
            return false;
        }
        @memcpy(sink.packets[sink.count][0..bytes.len], bytes);
        sink.sizes[sink.count] = bytes.len;
        sink.count += 1;
        return true;
    }

    fn packet(sink: *const TestSink, index: usize) []const u8 {
        return sink.packets[index][0..sink.sizes[index]];
    }
};

const test_tags = "cluster:0000000000000000000000000000002a,listen:127.0.0.1:8080";

fn test_window(session: bool) Window {
    return .{
        .session = session,
        .reconnects_ok = 0,
        .reconnects_failed = 0,
        .lingering_dropped = 0,
        .statsd_dropped = 0,
    };
}

test "route_of names a request's route as the API does" {
    try testing.expectEqual(Route.healthz, route_of(true, "/healthz"));
    try testing.expectEqual(Route.other, route_of(false, "/healthz"));
    try testing.expectEqual(Route.commit, route_of(false, "/v1/commit"));
    try testing.expectEqual(Route.changes, route_of(true, "/v1/changes?limit=2"));
    try testing.expectEqual(Route.tables, route_of(false, "/v1/tables/7"));
    try testing.expectEqual(Route.views, route_of(true, "/v1/views/total"));
    try testing.expectEqual(Route.view_groups, route_of(true, "/v1/views/total/groups?limit=1"));
    try testing.expectEqual(Route.view_definition, route_of(true, "/v1/views/total/definition"));
    // A view named `groups`.
    try testing.expectEqual(Route.views, route_of(true, "/v1/views/groups"));
    try testing.expectEqual(Route.view_list, route_of(true, "/v1/views"));
    try testing.expectEqual(Route.ledgers, route_of(true, "/v1/ledgers/1"));
    try testing.expectEqual(Route.index_list, route_of(true, "/v1/indexes"));
    try testing.expectEqual(Route.indexes, route_of(true, "/v1/indexes/open"));
    try testing.expectEqual(Route.index_scan, route_of(false, "/v1/indexes/open/scan"));
    try testing.expectEqual(Route.documents_commit, route_of(false, "/v1/documents/commit"));
    try testing.expectEqual(Route.other, route_of(false, "/v1/nope"));
    try testing.expectEqual(Route.other, route_of(false, ""));
    // Every route of the API's table is found by its own path.
    for (api.routes) |entry| {
        try testing.expectEqualStrings(@tagName(entry.route), @tagName(route_of(false, entry.path)));
    }
}

test "reply_unknown reads an error reply's applied member" {
    try testing.expect(reply_unknown(503, "{\"error\":\"cluster unavailable\",\"applied\":\"unknown\"," ++
        "\"code\":\"NRV-E0601\"}"));
    try testing.expect(!reply_unknown(503, "{\"error\":\"busy\",\"applied\":false,\"code\":\"NRV-E0602\"}"));
    // A success never says it, whatever its body holds.
    try testing.expect(!reply_unknown(200, "{\"applied\":\"unknown\"}"));
}

test "render: the golden lines of one window" {
    var counters: Counters = .{};
    var timings = OperationTimings.initFill(.{});
    counters.replied(.commit, 200, false);
    counters.replied(.commit, 200, false);
    counters.replied(.commit, 409, false);
    counters.replied(.lookup, 503, true);
    counters.replied(.other, 418, false);
    counters.refusal_written(.busy, 503);
    counters.refused_with(.unavailable);
    counters.group(1);
    counters.group(8);
    counters.waited(1_500_000);
    counters.waited(500_000);
    counters.connections_seen(3);
    counters.connections_seen(2);
    timings.getPtr(.commit).record(2_000_000);
    timings.getPtr(.commit).record(4_000_000);
    var window = test_window(true);
    window.reconnects_ok = 1;
    window.lingering_dropped = 2;

    var sink: TestSink = .{};
    try testing.expectEqual(@as(u64, 0), render(&counters, &timings, window, test_tags, &sink));
    const lines = [_][]const u8{
        "nerva.api.requests:1|c|#" ++ test_tags ++ ",route:lookup,status:503",
        "nerva.api.requests:2|c|#" ++ test_tags ++ ",route:commit,status:200",
        "nerva.api.requests:1|c|#" ++ test_tags ++ ",route:commit,status:409",
        "nerva.api.requests:1|c|#" ++ test_tags ++ ",route:other,status:503",
        "nerva.api.requests:1|c|#" ++ test_tags ++ ",route:other,status:other",
        "nerva.api.refused:1|c|#" ++ test_tags ++ ",reason:busy",
        "nerva.api.refused:1|c|#" ++ test_tags ++ ",reason:unavailable",
        "nerva.api.unknown:1|c|#" ++ test_tags ++ ",route:lookup",
        "nerva.api.group_size.count:2|c|#" ++ test_tags,
        "nerva.api.group_size.sum:9|c|#" ++ test_tags,
        "nerva.api.group_size.min:1|g|#" ++ test_tags,
        "nerva.api.group_size.max:8|g|#" ++ test_tags,
        "nerva.api.group_size.avg:4|g|#" ++ test_tags,
        "nerva.api.cluster_request_us.count:2|c|#" ++ test_tags ++ ",operation:commit",
        "nerva.api.cluster_request_us.sum:6000|c|#" ++ test_tags ++ ",operation:commit",
        "nerva.api.cluster_request_us.min:2000|g|#" ++ test_tags ++ ",operation:commit",
        "nerva.api.cluster_request_us.max:4000|g|#" ++ test_tags ++ ",operation:commit",
        "nerva.api.cluster_request_us.avg:3000|g|#" ++ test_tags ++ ",operation:commit",
        "nerva.api.queue_wait_us.count:2|c|#" ++ test_tags,
        "nerva.api.queue_wait_us.sum:2000|c|#" ++ test_tags,
        "nerva.api.queue_wait_us.min:500|g|#" ++ test_tags,
        "nerva.api.queue_wait_us.max:1500|g|#" ++ test_tags,
        "nerva.api.queue_wait_us.avg:1000|g|#" ++ test_tags,
        "nerva.api.reconnects:1|c|#" ++ test_tags ++ ",result:ok",
        "nerva.api.session:1|g|#" ++ test_tags,
        "nerva.api.connections:3|g|#" ++ test_tags,
        "nerva.api.lingering_dropped:2|c|#" ++ test_tags,
    };
    // The lines in order, split into packets of whole lines within the limit.
    try testing.expect(sink.count > 1);
    var index: usize = 0;
    for (0..sink.count) |packet_index| {
        const packet = sink.packet(packet_index);
        try testing.expect(packet.len <= packet_size_max);
        var split = std.mem.splitScalar(u8, packet, '\n');
        while (split.next()) |line| : (index += 1) {
            try testing.expectEqualStrings(lines[index], line);
        }
    }
    try testing.expectEqual(lines.len, index);

    // The window is spent: the next one holds only the gauges.
    var next: TestSink = .{};
    _ = render(&counters, &timings, test_window(false), test_tags, &next);
    try testing.expectEqualStrings(
        "nerva.api.session:0|g|#" ++ test_tags ++ "\nnerva.api.connections:0|g|#" ++ test_tags,
        next.packet(0),
    );
}

test "render: a window of many series is several packets, each within packet_size_max" {
    var counters: Counters = .{};
    var timings = OperationTimings.initFill(.{});
    var series: u64 = 0;
    for (std.enums.values(Route)) |route| {
        for (statuses) |status| {
            counters.replied(route, status, true);
            series += 1;
        }
        counters.replied(route, 999, false);
        series += 1;
    }
    for (std.enums.values(nerva.Operation)) |operation| {
        timings.getPtr(operation).record(1_234_567);
    }

    var sink: TestSink = .{};
    try testing.expectEqual(@as(u64, 0), render(&counters, &timings, test_window(true), test_tags, &sink));
    try testing.expect(sink.count > 1);
    var lines: u64 = 0;
    for (0..sink.count) |index| {
        const packet = sink.packet(index);
        try testing.expect(packet.len <= packet_size_max);
        // A packet is whole lines.
        try testing.expect(std.mem.startsWith(u8, packet, "nerva.api."));
        try testing.expect(packet[packet.len - 1] != '\n');
        lines += std.mem.count(u8, packet, "\n") + 1;
    }
    // Every request series, every unknown series, five lines for each operation, the gauges.
    const unknown_series = std.enums.values(Route).len;
    const operations = std.enums.values(nerva.Operation).len;
    try testing.expectEqual(series + unknown_series + operations * 5 + 2, lines);
}

test "render: a refused packet is counted, not retried, and the window is spent" {
    var counters: Counters = .{};
    var timings = OperationTimings.initFill(.{});
    for (std.enums.values(Route)) |route| {
        for (statuses) |status| counters.replied(route, status, false);
    }
    var sink: TestSink = .{ .refuse_from = 1 };
    const dropped = render(&counters, &timings, test_window(true), test_tags, &sink);
    try testing.expect(sink.count > 1);
    try testing.expect(dropped > 0);
    try testing.expectEqual(@as(u64, 0), counters.requests[0][0]);
}

test "an emitter sends a window over UDP and the next window reports what was dropped" {
    const listener = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(listener);
    var bound = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var bound_size = bound.getOsSockLen();
    try posix.bind(listener, &bound.any, bound_size);
    try posix.getsockname(listener, &bound.any, &bound_size);
    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(posix.timeval{ .sec = 5, .usec = 0 }));

    const target: stdx.SocketAddress = .{ .ip = .@"127.0.0.1", .port = bound.getPort() };
    var emitter = try Emitter.init(target, 42, std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080));
    defer emitter.deinit();
    var counters: Counters = .{};
    var timings = OperationTimings.initFill(.{});
    counters.replied(.commit, 200, false);

    // Not due: nothing is sent.
    emitter.window_start = emitter.timer.read();
    emitter.tick(&counters, &timings, .{ .session = true, .reconnects_ok = 0, .reconnects_failed = 0, .lingering_dropped = 0 });
    try testing.expectEqual(@as(u64, 1), counters.requests[@intFromEnum(Route.commit)][0]);
    // Due: the window is sent and spent.
    emitter.interval_ns = 0;
    emitter.tick(&counters, &timings, .{ .session = true, .reconnects_ok = 0, .reconnects_failed = 0, .lingering_dropped = 0 });
    try testing.expectEqual(@as(u64, 0), counters.requests[@intFromEnum(Route.commit)][0]);
    var buffer: [packet_size_max]u8 = undefined;
    const received = try posix.recv(listener, &buffer, 0);
    try testing.expect(std.mem.startsWith(
        u8,
        buffer[0..received],
        "nerva.api.requests:1|c|#cluster:0000000000000000000000000000002a,listen:127.0.0.1:8080,route:commit,status:200\n",
    ));
}

test "wait_ms is at least 1 and at most the limit" {
    var emitter: Emitter = undefined;
    emitter.timer = try std.time.Timer.start();
    emitter.window_start = 0;
    emitter.interval_ns = statsd_interval_ns;
    const wait = emitter.wait_ms(-1);
    try testing.expect(wait >= 1 and wait <= statsd_interval_ns / std.time.ns_per_ms);
    try testing.expectEqual(@as(i32, 5), emitter.wait_ms(5));
    // A window long over: wake at once, never spin at 0.
    emitter.interval_ns = 0;
    try testing.expectEqual(@as(i32, 1), emitter.wait_ms(-1));
}
