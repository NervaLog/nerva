//! A cluster that evicts a client for its release (#222, P354).
//!
//! A replica evicts a client whose release is above its own (`client_release_too_high`) or below
//! its `release_client_min` (`client_release_too_low`). The VSR client reports only that it was
//! evicted, which a command used to end as `bug[NRV-B0004]` and a gateway logged as a raw
//! `error.Evicted`. The eviction callbacks (`client.zig`, `recover.zig`) `record` the refusal
//! here, as NRV-E0609 and NRV-E0610 with both releases, and a command that ends on
//! `error.Evicted` asks `taken` for it (`diagnostic.zig`). Nothing here is read by a gateway's
//! requests: it is a diagnosis of why the last session was evicted, never a decision.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.nerva_client);

const vsr = @import("../vsr.zig");

pub const Kind = enum { too_high, too_low };

/// A release as text, such as `0.0.207`: three `u8`s and two dots are far below this.
const text_max = 32;

pub const Refusal = struct {
    kind: Kind,
    client_text: [text_max]u8,
    client_len: u8,
    cluster_text: [text_max]u8,
    cluster_len: u8,

    pub fn client(refusal: *const Refusal) []const u8 {
        return refusal.client_text[0..refusal.client_len];
    }

    pub fn cluster(refusal: *const Refusal) []const u8 {
        return refusal.cluster_text[0..refusal.cluster_len];
    }
};

/// The last refusal this process saw. Clients are driven by one thread (a command's, or the
/// gateway's), so no lock.
var last: ?Refusal = null;

/// What an eviction of `reason` means for releases: null for any other reason.
pub fn kind_of(reason: vsr.Header.Eviction.Reason) ?Kind {
    return switch (reason) {
        .client_release_too_high => .too_high,
        .client_release_too_low => .too_low,
        else => null,
    };
}

/// The refusal an eviction of `reason` is, or null for any other reason.
pub fn refusal_of(
    reason: vsr.Header.Eviction.Reason,
    client: vsr.Release,
    cluster: vsr.Release,
) ?Refusal {
    const kind = kind_of(reason) orelse return null;
    var refusal: Refusal = .{
        .kind = kind,
        .client_text = undefined,
        .client_len = 0,
        .cluster_text = undefined,
        .cluster_len = 0,
    };
    const client_text = std.fmt.bufPrint(&refusal.client_text, "{}", .{client}) catch unreachable;
    refusal.client_len = @intCast(client_text.len);
    const cluster_text = std.fmt.bufPrint(&refusal.cluster_text, "{}", .{cluster}) catch unreachable;
    refusal.cluster_len = @intCast(cluster_text.len);
    return refusal;
}

/// Called by an eviction callback: `client` is this process's release, `cluster` the evicting
/// replica's. Logs the coded line (one line, both releases, the fix) and keeps the refusal. Any
/// other eviction supersedes an earlier refusal: it is not the reason this one ended.
pub fn record(
    reason: vsr.Header.Eviction.Reason,
    client: vsr.Release,
    cluster: vsr.Release,
) void {
    last = refusal_of(reason, client, cluster);
    const refusal = last orelse return;
    switch (refusal.kind) {
        .too_high => log.err(
            "NRV-E0609: the cluster runs release {s} and this client runs {s}, a newer " ++
                "one, so it evicted this client; run the client at the cluster's release",
            .{ refusal.cluster(), refusal.client() },
        ),
        .too_low => log.err(
            "NRV-E0610: this client runs release {s}, below the {s} cluster's " ++
                "release_client_min; upgrade the client to at least that release",
            .{ refusal.client(), refusal.cluster() },
        ),
    }
}

/// The refusal behind the last `error.Evicted`, if it was a release's; forgets it.
pub fn taken() ?Refusal {
    const refusal = last;
    last = null;
    return refusal;
}

const testing = std.testing;

test "release_eviction: only the two release reasons are refusals" {
    for (std.enums.values(vsr.Header.Eviction.Reason)) |reason| {
        const expected: ?Kind = switch (reason) {
            .client_release_too_high => .too_high,
            .client_release_too_low => .too_low,
            else => null,
        };
        try testing.expectEqual(expected, kind_of(reason));
    }
}

test "release_eviction: a refusal names both releases and is taken once" {
    // `record` logs at error level, which a test may not: it is `refusal_of` and `taken`.
    last = null;
    try testing.expect(taken() == null);
    const low = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 6 });
    const high = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 207 });
    try testing.expect(refusal_of(.no_session, high, low) == null);

    last = refusal_of(.client_release_too_high, high, low);
    const refusal = taken().?;
    try testing.expectEqual(Kind.too_high, refusal.kind);
    try testing.expectEqualStrings("0.0.207", refusal.client());
    try testing.expectEqualStrings("0.0.6", refusal.cluster());
    try testing.expect(taken() == null);

    const below = refusal_of(.client_release_too_low, low, high).?;
    try testing.expectEqual(Kind.too_low, below.kind);
    try testing.expectEqualStrings("0.0.6", below.client());
    try testing.expectEqualStrings("0.0.207", below.cluster());
}
