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
//! - the socket never blocks: a packet the kernel does not take is dropped, its lines counted in
//!   `nerva.api.statsd_dropped`, in the next window's lines (P176c).
//!
//! Series with no events in a window are not sent, except the two gauges.

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const log = std.log.scoped(.metrics);

const stdx = @import("stdx");
const nerva = @import("../../nerva.zig");
const api = @import("api.zig");
const tallies = @import("../timings.zig");

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
        if (std.mem.eql(u8, entry.path, path)) {
            return std.meta.stringToEnum(Route, @tagName(entry.route)).?;
        }
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

pub const Aggregate = tallies.Aggregate;
pub const OperationTimings = tallies.OperationTimings;

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
    /// The most slots in use at once in the window: those in use as it began, and at each accept.
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
    /// Slots in use now: the next window starts from them.
    connections: u32,
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
    /// The packet holds the line that reports the dropped lines (`watched`).
    watched: bool = false,
    /// A packet that held the watched line did not leave: its count is reported again.
    watched_lost: bool = false,

    fn add(packet: *Packet, sink: anytype, line: []const u8) void {
        assert(line.len <= packet_size_max);
        const needed = line.len + @intFromBool(packet.len > 0);
        if (packet.len + needed > packet_size_max) packet.flush(sink);
        assert(packet.len + needed <= packet_size_max);
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
        const sent = sink.send(packet.buffer[0..packet.len]);
        if (!sent) packet.dropped += packet.lines;
        if (!sent and packet.watched) packet.watched_lost = true;
        packet.len = 0;
        packet.lines = 0;
        packet.watched = false;
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
    ) bool {
        var scratch: [line_size_max]u8 = undefined;
        var stream = std.io.fixedBufferStream(&scratch);
        const writer = stream.writer();
        const written = write: {
            writer.print("nerva.api.{s}{s}:{d}|{c}|#{s}", .{ name, suffix, value, kind, tags }) catch
                break :write false;
            for (extra) |pair| {
                writer.print(",{s}:{s}", .{ pair[0], pair[1] }) catch break :write false;
            }
            break :write true;
        };
        if (!written) {
            packet.dropped += 1;
            return false;
        }
        packet.add(sink, stream.getWritten());
        return true;
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
        assert(value.min <= value.max);
        const sum = value.sum / divisor;
        _ = packet.series(sink, name, ".count", value.count, 'c', tags, extra);
        _ = packet.series(sink, name, ".sum", sum, 'c', tags, extra);
        _ = packet.series(sink, name, ".min", value.min / divisor, 'g', tags, extra);
        _ = packet.series(sink, name, ".max", value.max / divisor, 'g', tags, extra);
        _ = packet.series(sink, name, ".avg", sum / value.count, 'g', tags, extra);
    }
};

/// What `render` did not send.
pub const Spent = struct {
    /// Lines that did not leave.
    dropped: u64,
    /// The line that reported the window's dropped lines did not leave.
    report_lost: bool,
};

/// Writes the window as packets to `sink` (`fn send(*Sink, []const u8) bool`, false when the
/// packet was not taken), then resets `counters` and `timings`. `window` carries what changed
/// elsewhere since the last window. Returns the lines that did not leave, and whether the line
/// that reported `window.statsd_dropped` was among them.
pub fn render(
    counters: *Counters,
    timings: *OperationTimings,
    window: Window,
    tags: []const u8,
    sink: anytype,
) Spent {
    assert(tags.len <= tags_size_max);
    var packet: Packet = .{};
    for (std.enums.values(Route)) |route| {
        for (counters.requests[@intFromEnum(route)], 0..) |count, slot| {
            if (count == 0) continue;
            _ = packet.series(sink, "requests", "", count, 'c', tags, &.{
                .{ "route", @tagName(route) },
                .{ "status", status_names[slot] },
            });
        }
    }
    for (std.enums.values(RefusalReason)) |reason| {
        const count = counters.refused[@intFromEnum(reason)];
        if (count == 0) continue;
        _ = packet.series(sink, "refused", "", count, 'c', tags, &.{.{ "reason", @tagName(reason) }});
    }
    for (std.enums.values(Route)) |route| {
        const count = counters.unknown[@intFromEnum(route)];
        if (count == 0) continue;
        _ = packet.series(sink, "unknown", "", count, 'c', tags, &.{
            .{ "route", @tagName(route) },
        });
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
        _ = packet.series(sink, "reconnects", "", window.reconnects_ok, 'c', tags, &.{
            .{ "result", "ok" },
        });
    }
    if (window.reconnects_failed > 0) {
        _ = packet.series(sink, "reconnects", "", window.reconnects_failed, 'c', tags, &.{
            .{ "result", "failed" },
        });
    }
    _ = packet.series(sink, "session", "", @intFromBool(window.session), 'g', tags, &.{});
    _ = packet.series(sink, "connections", "", counters.connections, 'g', tags, &.{});
    if (window.lingering_dropped > 0) {
        _ = packet.series(sink, "lingering_dropped", "", window.lingering_dropped, 'c', tags, &.{});
    }
    if (window.statsd_dropped > 0) {
        const written = packet.series(
            sink,
            "statsd_dropped",
            "",
            window.statsd_dropped,
            'c',
            tags,
            &.{},
        );
        packet.watched = written;
        packet.watched_lost = !written;
    }
    packet.flush(sink);

    counters.* = .{};
    timings.* = OperationTimings.initFill(.{});
    return .{ .dropped = packet.dropped, .report_lost = packet.watched_lost };
}

/// What happened in a window that the counters do not hold.
pub const Window = struct {
    session: bool,
    reconnects_ok: u64,
    reconnects_failed: u64,
    lingering_dropped: u64,
    statsd_dropped: u64,
};

/// Whether a window that began at `window_start` is over at `now` (`timer` readings): when it has
/// lasted `interval_ns`, not before.
fn window_due(now: u64, window_start: u64, interval_ns: u64) bool {
    return now -| window_start >= interval_ns;
}

/// Why `Emitter.init` failed, in words, for NRV-E0010.
pub fn init_reason(err: anyerror) []const u8 {
    return switch (err) {
        error.AddressFamilyNotSupported => "this host has no socket for that address family",
        error.NetworkUnreachable => "the network is unreachable",
        error.AddressNotAvailable => "the address is not available on this host",
        error.PermissionDenied, error.AccessDenied => "permission denied",
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => "the host is out of sockets",
        else => "the socket could not be set up",
    };
}

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
    previous: struct {
        reconnects_ok: u64 = 0,
        reconnects_failed: u64 = 0,
        lingering_dropped: u64 = 0,
    } = .{},
    /// Lines the socket did not take, in total, and as reported by a line that left.
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
        const tags = std.fmt.bufPrint(
            &emitter.tags,
            "cluster:{x:0>32},listen:{}",
            .{ cluster, listen },
        ) catch unreachable; // A 32-digit cluster and an address fit `tags_size_max`.
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
        const left_ms: u64 = @max(1, (left_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
        const left: i32 = @intCast(@min(left_ms, std.math.maxInt(i32)));
        return if (limit_ms < 0) left else @min(limit_ms, left);
    }

    /// Ends the window and sends it, if it has lasted `interval_ns`.
    pub fn tick(
        emitter: *Emitter,
        counters: *Counters,
        timings_now: *OperationTimings,
        observed: Observed,
    ) void {
        const now = emitter.timer.read();
        if (!window_due(now, emitter.window_start, emitter.interval_ns)) return;
        emitter.window_start = now;
        counters.connections_seen(observed.connections);
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
        var sink: UdpSink = .{ .socket = emitter.socket };
        const tags = emitter.tags[0..emitter.tags_len];
        const spent = render(counters, timings_now, window, tags, &sink);
        // The next window starts from the slots in use now, not from none.
        counters.connections_seen(observed.connections);
        // A report that did not leave is made again, with what dropped since.
        if (!spent.report_lost) emitter.dropped_reported += window.statsd_dropped;
        emitter.dropped += spent.dropped;
        assert(emitter.dropped_reported <= emitter.dropped);
    }

    const UdpSink = struct {
        socket: posix.socket_t,

        fn send(sink: *UdpSink, bytes: []const u8) bool {
            const flags = posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL;
            const sent = posix.send(sink.socket, bytes, flags) catch return false;
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

const test_observed: Observed = .{
    .session = true,
    .reconnects_ok = 0,
    .reconnects_failed = 0,
    .lingering_dropped = 0,
    .connections = 0,
};

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
    try testing.expectEqual(@as(u64, 0), render(&counters, &timings, window, test_tags, &sink).dropped);
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
    const spent = render(&counters, &timings, test_window(true), test_tags, &sink);
    try testing.expectEqual(@as(u64, 0), spent.dropped);
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
    const spent = render(&counters, &timings, test_window(true), test_tags, &sink);
    try testing.expect(sink.count > 1);
    try testing.expect(spent.dropped > 0);
    // No `statsd_dropped` line was due, so none was lost.
    try testing.expect(!spent.report_lost);
    try testing.expectEqual(@as(u64, 0), counters.requests[0][0]);
}

test "an emitter sends a window over UDP and the next window reports what was dropped" {
    const listener = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(listener);
    var bound = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var bound_size = bound.getOsSockLen();
    try posix.bind(listener, &bound.any, bound_size);
    try posix.getsockname(listener, &bound.any, &bound_size);
    const receive_timeout = posix.timeval{ .sec = 5, .usec = 0 };
    try posix.setsockopt(
        listener,
        posix.SOL.SOCKET,
        posix.SO.RCVTIMEO,
        &std.mem.toBytes(receive_timeout),
    );

    const target: stdx.SocketAddress = .{ .ip = .@"127.0.0.1", .port = bound.getPort() };
    const listen = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    var emitter = try Emitter.init(target, 42, listen);
    defer emitter.deinit();
    var counters: Counters = .{};
    var timings = OperationTimings.initFill(.{});
    counters.replied(.commit, 200, false);

    // Not due: nothing is sent.
    emitter.window_start = emitter.timer.read();
    emitter.tick(&counters, &timings, test_observed);
    try testing.expectEqual(@as(u64, 1), counters.requests[@intFromEnum(Route.commit)][0]);
    // Due: the window is sent and spent.
    emitter.interval_ns = 0;
    emitter.tick(&counters, &timings, test_observed);
    try testing.expectEqual(@as(u64, 0), counters.requests[@intFromEnum(Route.commit)][0]);
    var buffer: [packet_size_max]u8 = undefined;
    const received = try posix.recv(listener, &buffer, 0);
    try testing.expect(std.mem.startsWith(
        u8,
        buffer[0..received],
        "nerva.api.requests:1|c|#" ++ test_tags ++ ",route:commit,status:200\n",
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

test "a packet of exactly packet_size_max is one packet, one byte more is two" {
    const half = (packet_size_max - 1) / 2; // Two lines and their newline: 1,399 bytes.
    var line_a: [half]u8 = undefined;
    @memset(&line_a, 'a');
    var line_b: [half + 1]u8 = undefined;
    @memset(&line_b, 'b');

    var sink: TestSink = .{};
    var packet: Packet = .{};
    packet.add(&sink, &line_a);
    packet.add(&sink, &line_b);
    packet.flush(&sink);
    // 699 + 1 + 700 = 1,400: the limit itself fits.
    try testing.expectEqual(@as(usize, 1), sink.count);
    try testing.expectEqual(@as(usize, packet_size_max), sink.sizes[0]);

    var line_c: [half + 2]u8 = undefined;
    @memset(&line_c, 'c');
    var sink_over: TestSink = .{};
    var packet_over: Packet = .{};
    packet_over.add(&sink_over, &line_a);
    packet_over.add(&sink_over, &line_c); // 1,401 bytes together
    packet_over.flush(&sink_over);
    try testing.expectEqual(@as(usize, 2), sink_over.count);
    try testing.expectEqual(half, sink_over.sizes[0]);
    try testing.expectEqual(half + 2, sink_over.sizes[1]);
    try testing.expectEqual(@as(u64, 0), packet_over.dropped);
}

test "a window is due at its interval, and not one nanosecond before" {
    try testing.expect(window_due(statsd_interval_ns, 0, statsd_interval_ns));
    try testing.expect(!window_due(statsd_interval_ns - 1, 0, statsd_interval_ns));
    try testing.expect(window_due(statsd_interval_ns + 1, 0, statsd_interval_ns));
    try testing.expect(window_due(5 + statsd_interval_ns, 5, statsd_interval_ns));
    try testing.expect(!window_due(4 + statsd_interval_ns, 5, statsd_interval_ns));
    // A clock reading before the start never makes a window due, and never overflows.
    try testing.expect(!window_due(3, 5, statsd_interval_ns));
}

test "a statsd_dropped line that did not leave is reported again" {
    var counters: Counters = .{};
    var timings_now = OperationTimings.initFill(.{});
    var window = test_window(true);
    window.statsd_dropped = 3;
    // Every packet is refused, the one with the report too.
    var refused: TestSink = .{ .refuse_from = 0 };
    const lost = render(&counters, &timings_now, window, test_tags, &refused);
    try testing.expect(lost.report_lost);
    // The packets are taken: the report left.
    var taken: TestSink = .{};
    const kept = render(&counters, &timings_now, window, test_tags, &taken);
    try testing.expect(!kept.report_lost);
    try testing.expect(std.mem.indexOf(u8, taken.packet(0), "nerva.api.statsd_dropped:3|c") != null);
}

test "connections: a window starts from the slots in use, and a quiet one still reports them" {
    var counters: Counters = .{};
    var timings_now = OperationTimings.initFill(.{});
    counters.connections_seen(2);
    var observed = test_observed;
    observed.connections = 5;
    const listener = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(listener);
    var bound = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var bound_size = bound.getOsSockLen();
    try posix.bind(listener, &bound.any, bound_size);
    try posix.getsockname(listener, &bound.any, &bound_size);
    const target: stdx.SocketAddress = .{ .ip = .@"127.0.0.1", .port = bound.getPort() };
    var emitter = try Emitter.init(target, 42, std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080));
    emitter.interval_ns = 0;
    defer emitter.deinit();
    emitter.tick(&counters, &timings_now, observed);
    // Nothing accepted since: the held slots are the next window's least.
    try testing.expectEqual(@as(u32, 5), counters.connections);
}
