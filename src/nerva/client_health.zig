//! A gateway's cluster client, and replacing it when it breaks (#27, #42, #44).
//!
//! `nerva api` and `nerva view` each hold one `Client`. A request that times out, or a session
//! evicted, breaks it; it is replaced at most every `reconnect_interval_ns`, both on the next
//! request for the cluster and while the gateway is idle, so that a gateway recovers after the
//! cluster does even when nothing sends it requests (a load balancer that routes by `/healthz`).

const std = @import("std");
const log = std.log.scoped(.client_health);

const Client = @import("client.zig").Client;

/// Between attempts to replace a broken client: in between, requests for the cluster answer 503
/// at once rather than each waiting out a registration.
pub const reconnect_interval_ns = 5 * std.time.ns_per_s;
/// How often an idle gateway with a broken client wakes to try replacing it.
pub const idle_poll_ms = 1000;

pub const ClientHealth = struct {
    state: enum {
        ready,
        /// Timed out or evicted: `deinit` it, then `init` a new one (`Client.reconnect`).
        broken,
        /// A replacement failed partway: the memory is uninitialized; only `init` it.
        gone,
    } = .ready,
    /// When it broke, or the last attempt to replace it failed (a `timer` reading).
    since_ns: u64 = 0,
    timer: std.time.Timer,
    allocator: std.mem.Allocator,
    options: Client.Options,

    pub fn init(client: *const Client) !ClientHealth {
        return .{
            .timer = try std.time.Timer.start(),
            .allocator = client.allocator,
            .options = client.options,
        };
    }

    pub fn broke(health: *ClientHealth) void {
        std.debug.assert(health.state == .ready);
        health.state = .broken;
        health.since_ns = health.timer.read();
    }

    /// Ready, or replaced now if it has been long enough since the last attempt. Replacing it
    /// blocks until the new session registers, or the client's timeout.
    pub fn ready(health: *ClientHealth, client: *Client) bool {
        if (health.state == .ready) return true;
        if (health.timer.read() - health.since_ns < reconnect_interval_ns) return false;
        const result = switch (health.state) {
            .ready => unreachable,
            .broken => client.reconnect(),
            .gone => client.init(health.allocator, health.options),
        };
        result catch |err| {
            log.err("reconnecting to the cluster: {}", .{err});
            health.state = .gone;
            health.since_ns = health.timer.read();
            return false;
        };
        log.info("reconnected to the cluster", .{});
        health.state = .ready;
        return true;
    }

    /// The `receiver.next` timeout for an idle gateway: wake to retry while broken.
    pub fn idle_timeout_ms(health: *const ClientHealth, idle_ms: i32) i32 {
        if (health.state == .ready) return idle_ms;
        return if (idle_ms < 0) idle_poll_ms else @min(idle_ms, idle_poll_ms);
    }
};
