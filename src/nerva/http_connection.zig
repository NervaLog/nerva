//! What Nerva's HTTP gateways (`api`, `view`, `ledgerd`) do with each accepted connection
//! (docs/DECISIONS.md N37).
//!
//! The gateways serve one request at a time. A connection kept open between requests, or one
//! that never sends its request, would hold up every other client. So each connection carries
//! one request (replies say `Connection: close`) and must send it within `receive_timeout_s`.

const std = @import("std");
const log = std.log.scoped(.http);

pub const receive_timeout_s = 10;

/// Gives the connection a receive deadline. On failure the connection is still served, without
/// one, and the failure is logged.
pub fn deadline(stream: std.net.Stream) void {
    const timeout: std.posix.timeval = .{ .sec = receive_timeout_s, .usec = 0 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    ) catch |err| log.warn("receive timeout: {}", .{err});
}
