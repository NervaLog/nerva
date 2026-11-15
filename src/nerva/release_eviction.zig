//! A client evicted because of its release (NRV-E0609 and NRV-E0610, #356).
//!
//! A replica evicts a client whose release is above the cluster's (`client_release_too_high`) or
//! below the cluster's `release_client_min` (`client_release_too_low`). The vendored client hands
//! the reason to its eviction callback; the callbacks in `client.zig` and `recover.zig` pass it
//! here, so that the command that fails with `error.Evicted` can name both releases and the fix
//! instead of `bug[NRV-B0004]` or a wrong cause. The error itself keeps its name: callers match
//! on it.
//!
//! One record per process, written by the thread that drives the client. It is meaningful only to a
//! one-shot command, which `take`s it when its client failed with `error.Evicted`; a long-lived
//! gateway only logs the line, and its record goes stale, so it must not `take` one for a later
//! eviction of another reason.

const std = @import("std");
const assert = std.debug.assert;
const vsr = @import("../vsr.zig");

const log = std.log.scoped(.nerva_release_eviction);

pub const Reason = vsr.Header.Eviction.Reason;

pub const Eviction = struct {
    reason: Reason,
    /// The release of this process, the client.
    client: vsr.Release,
    /// The release of the replica that evicted it.
    cluster: vsr.Release,

    pub fn too_high(eviction: Eviction) bool {
        return eviction.reason == .client_release_too_high;
    }
};

var recorded: ?Eviction = null;

/// Whether `reason` is about the client's release.
pub fn is_release(reason: Reason) bool {
    return reason == .client_release_too_high or reason == .client_release_too_low;
}

/// Called by an eviction callback. Records the eviction, and logs its code, when the reason is
/// the client's release; any other reason is left to the caller.
pub fn record(reason: Reason, client: vsr.Release, cluster: vsr.Release) void {
    if (!is_release(reason)) return;
    const eviction: Eviction = .{ .reason = reason, .client = client, .cluster = cluster };
    recorded = eviction;
    log.warn("{s} the cluster (release {}) evicted this client of release {}: {s}", .{
        if (eviction.too_high()) "NRV-E0609" else "NRV-E0610",
        cluster,
        client,
        if (eviction.too_high()) "the client is newer" else "the client is below release_client_min",
    });
}

/// The recorded eviction, if any, cleared.
pub fn take() ?Eviction {
    const eviction = recorded;
    recorded = null;
    return eviction;
}

test "release_eviction: only a release reason is recorded" {
    defer _ = take();
    const client = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 200 });
    const cluster = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 6 });
    record(.no_session, client, cluster);
    try std.testing.expectEqual(@as(?Eviction, null), take());
    record(.client_release_too_high, client, cluster);
    const high = take().?;
    try std.testing.expect(high.too_high());
    try std.testing.expectEqual(client, high.client);
    try std.testing.expectEqual(cluster, high.cluster);
    try std.testing.expectEqual(@as(?Eviction, null), take());
    record(.client_release_too_low, cluster, client);
    try std.testing.expect(!take().?.too_high());
}
