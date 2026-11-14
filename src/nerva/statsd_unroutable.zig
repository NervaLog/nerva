//! `nerva start --statsd` with an address it cannot send to (#198, P427).
//!
//! The vendored `StatsD.init_udp` connected its socket, so a host with no route to the collector
//! failed `Tracer.init` and stopped `start` (NRV-E0010). It now sends each packet to the address:
//! a failing destination warns once (NRV-W0733) and its packets are dropped. These tests use the
//! broadcast address, which every host refuses to send to without `SO_BROADCAST`, so they do not
//! depend on the host's routes. A loopback collector shows that sending still works.

const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");

const IO = @import("../io.zig").IO;
const Tracer = @import("../trace.zig");
const fixtures = @import("../testing/fixtures.zig");

fn tracer_udp(io: *IO, address: std.net.Address, time: stdx.Time) !Tracer {
    var tracer = try Tracer.init(std.testing.allocator, time, .unknown, .{
        .statsd_options = .{ .udp = .{ .io = io, .address = try stdx.SocketAddress.from_std(address) } },
    });
    tracer.set_replica(.{ .cluster = 1, .replica = 0 });
    return tracer;
}

test "statsd: an address that cannot be sent to starts, warns once and drops" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    var time_sim = fixtures.init_time(.{});
    var tracer = try tracer_udp(&io, std.net.Address.initIp4(.{ 255, 255, 255, 255 }, 8125), time_sim.interface());
    defer tracer.deinit(std.testing.allocator);

    for (0..3) |round| {
        tracer.gauge(.replica_commit_min, @intCast(round + 1));
        tracer.emit_metrics();
        const udp = &tracer.statsd.implementation.udp;
        // The send failed at once: nothing is left in flight, and the failure is counted.
        try std.testing.expectEqual(@as(u32, 0), tracer.statsd.send_in_flight_count);
        // Warned at the second emit (the first one's failures are reported by the next), once.
        try std.testing.expectEqual(round >= 1, udp.send_failure_warned);
        try std.testing.expect(udp.send_failure_errno != .SUCCESS);
    }
}

test "statsd: a reachable collector still receives the packets" {
    const collector = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(collector);
    var address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    try std.posix.bind(collector, &address.any, address.getOsSockLen());
    var length: std.posix.socklen_t = address.getOsSockLen();
    try std.posix.getsockname(collector, &address.any, &length);

    var io = try IO.init(8, 0);
    defer io.deinit();
    var time_sim = fixtures.init_time(.{});
    var tracer = try tracer_udp(&io, address, time_sim.interface());
    defer tracer.deinit(std.testing.allocator);

    tracer.gauge(.replica_commit_min, 7);
    tracer.emit_metrics();
    try std.testing.expectEqual(@as(u32, 0), tracer.statsd.send_in_flight_count);
    try std.testing.expect(!tracer.statsd.implementation.udp.send_failure_warned);
    try std.testing.expectEqual(@as(u64, 0), tracer.statsd.implementation.udp.send_callback_error_count);

    var packet: [1500]u8 = undefined;
    const received = try std.posix.recv(collector, &packet, std.posix.MSG.DONTWAIT);
    try std.testing.expect(std.mem.indexOf(u8, packet[0..received], "replica_commit_min") != null);
}
