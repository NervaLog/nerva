//! Replicas ignore peers that run another release (N61, #34).
//!
//! TigerBeetle expects a newer binary to bundle its older releases, and to run an older peer's
//! prepares with that older code. Nerva bundles only its own release (N43), so a replica of
//! another release in the same cluster executes the log with different code: it diverges, and
//! is only caught at the first checkpoint ("checkpoint diverged"), after it has acknowledged
//! prepares and could have become primary. With `release_peers_strict`, a replica handles a
//! peer's messages only once that peer has announced (in a ping or pong) the release this
//! replica runs.
//!
//! Most replica messages carry release 0, so the check is by peer, not by message. Blocks do not
//! name their sender, but carry the release they were made in. A prepare carries the release of
//! the client whose request it holds (`replica.zig` copies the request's), any from
//! `release_client_min` up, and names the primary that made it (`replica`), though any replica
//! may relay or repair it: it is admitted with a client release this replica accepts, unless its
//! maker last announced another release.
//!
//! The same gate keeps apart replicas imported from different exports (N84, #81): a ping or pong
//! also announces its sender's origin (`VSRState.origin`, the export's SHA-256, or zero for a
//! formatted data file), and a peer counts only once it has announced this replica's origin. A
//! prepare is refused when its maker announced another origin. What a peer last announced is
//! remembered across connections for prepares, so that prepares a primary made before it crashed
//! are still repaired; its messages need an announcement on its current connection. A replica
//! whose peers
//! are so many of other exports that it can never reach a quorum with its own stops
//! (`origin_refused`): it would never be of use, and the operator must import it again.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");

const vsr = @import("../vsr.zig");
const constants = @import("../constants.zig");
const Header = vsr.Header;

/// Whether a replica running `release` (accepting clients from `release_client_min`), as replica
/// `replica`, imported from `origin`, should handle a message with `header`, given each peer's
/// announced release on its current connection (`peer_releases`, null if none yet), and the
/// release and origin it last announced on any (`peer_releases_last`, `peer_origins`, null if
/// never). A ping or pong is checked after its own announcement has been recorded.
pub fn admits(
    release: vsr.Release,
    release_client_min: vsr.Release,
    origin: *const [32]u8,
    replica: u8,
    peer_releases: []const ?vsr.Release,
    peer_releases_last: []const ?vsr.Release,
    peer_origins: []const ?[32]u8,
    header: *const Header,
) bool {
    assert(release.value != 0);
    assert(release_client_min.value != 0);
    assert(release_client_min.value <= release.value);
    assert(peer_releases.len == constants.members_max);
    assert(peer_releases_last.len == constants.members_max);
    assert(peer_origins.len == constants.members_max);

    switch (header.into_any()) {
        // Created by clients: `release_client_min` governs them, and a reply carries its
        // request's release.
        .request, .ping_client, .reply => return true,
        // Root and reserved prepares carry release 0.
        .prepare => |prepare| {
            if (prepare.release.value == 0) return true;
            if (prepare.release.value < release_client_min.value or
                prepare.release.value > release.value) return false;
            // Relayed or repaired by any replica: refused only once its maker is known to run
            // another release, or to be of another export.
            if (prepare.replica == replica or prepare.replica >= peer_origins.len) return true;
            if (peer_releases_last[prepare.replica]) |maker_release| {
                if (maker_release.value != release.value) return false;
            }
            if (peer_origins[prepare.replica]) |maker_origin| {
                if (!std.mem.eql(u8, &maker_origin, origin)) return false;
            }
            return true;
        },
        .block => |block| return block.release.value == release.value,
        else => {},
    }
    switch (header.peer_type()) {
        .replica => |peer| {
            if (peer == replica) return true;
            if (peer >= peer_releases.len) return false;
            const peer_release = peer_releases[peer] orelse return false;
            const peer_origin = peer_origins[peer] orelse return false;
            return peer_release.value == release.value and std.mem.eql(u8, &peer_origin, origin);
        },
        .unknown, .client, .client_likely => return true,
    }
}

/// What a ping or pong announces of its sender, or null for any other message.
pub fn announced(header: *const Header) ?struct {
    replica: u8,
    release: vsr.Release,
    origin: [32]u8,
} {
    return switch (header.into_any()) {
        inline .ping, .pong => |announcement| .{
            .replica = announcement.replica,
            .release = announcement.release,
            .origin = announcement.origin,
        },
        else => null,
    };
}

/// How an origin is named in messages: the export's SHA-256 in hex, or "none (formatted)".
pub fn origin_name(origin: *const [32]u8) OriginName {
    return .{ .origin = origin.* };
}

pub const OriginName = struct {
    origin: [32]u8,

    pub fn format(
        name: OriginName,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (stdx.zeroed(&name.origin)) return writer.writeAll("none (formatted)");
        try writer.print("{s}", .{std.fmt.fmtSliceHexLower(&name.origin)});
    }
};

/// How many of the cluster's `replica_count` replicas, other than `replica`, announced another
/// origin than `origin`.
pub fn origin_others(
    replica_count: u8,
    replica: u8,
    origin: *const [32]u8,
    peer_origins: []const ?[32]u8,
) u8 {
    assert(replica_count > 0);
    assert(replica_count <= constants.replicas_max);
    assert(peer_origins.len == constants.members_max);

    var others: u8 = 0;
    for (peer_origins[0..replica_count], 0..) |peer_origin, peer| {
        if (peer == replica) continue;
        const announced_origin = peer_origin orelse continue;
        if (!std.mem.eql(u8, &announced_origin, origin)) others += 1;
    }
    assert(others <= replica_count);
    return others;
}

/// Whether so many of the cluster's `replica_count` replicas (other than `replica`) announced
/// another origin than `origin` that the rest, with this replica, can never reach the replication
/// or the view-change quorum: this replica can never be of use, and should stop.
pub fn origin_refused(
    replica_count: u8,
    replica: u8,
    origin: *const [32]u8,
    peer_origins: []const ?[32]u8,
) bool {
    const others = origin_others(replica_count, replica, origin, peer_origins);
    const quorums = vsr.quorums(replica_count);
    const quorum = @max(quorums.replication, quorums.view_change);
    return replica_count - others < quorum;
}

const testing = std.testing;

const release_this = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 3 });
const release_other = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 2 });
/// This replica accepts clients from `release_other` on.
const release_client_min_this = release_other;
const release_newer = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 4 });
const origin_this: [32]u8 = @splat(0xaa);
const origin_other: [32]u8 = @splat(0xbb);

const TestPeers = struct {
    releases: [constants.members_max]?vsr.Release,
    releases_last: [constants.members_max]?vsr.Release,
    origins: [constants.members_max]?[32]u8,

    /// Replica 1 is of this release and origin, 2 of another release, 3 has announced nothing,
    /// 4 is of this release and another origin.
    fn init() TestPeers {
        var peers: TestPeers = .{
            .releases = @splat(null),
            .releases_last = @splat(null),
            .origins = @splat(null),
        };
        peers.releases[1] = release_this;
        peers.origins[1] = origin_this;
        peers.releases[2] = release_other;
        peers.origins[2] = origin_this;
        peers.releases[4] = release_this;
        peers.origins[4] = origin_other;
        peers.releases_last = peers.releases;
        return peers;
    }

    fn admits(peers: *const TestPeers, header: *const Header) bool {
        return release_peers_admits(
            release_this,
            release_client_min_this,
            &origin_this,
            0,
            &peers.releases,
            &peers.releases_last,
            &peers.origins,
            header,
        );
    }
};

const release_peers_admits = admits;

test "release_peers: a peer counts only once it has announced this replica's release and origin" {
    const peers: TestPeers = .init();
    inline for (.{ .commit, .prepare_ok, .view, .headers, .exit_view }) |command| {
        const Command = Header.Type(command);
        var header: Command = std.mem.zeroInit(Command, .{ .command = command });
        header.replica = 1; // Announced this release and origin.
        try testing.expect(peers.admits(header.frame_const()));
        header.replica = 2; // Announced another release.
        try testing.expect(!peers.admits(header.frame_const()));
        header.replica = 3; // Not announced yet.
        try testing.expect(!peers.admits(header.frame_const()));
        header.replica = 4; // Imported from another export.
        try testing.expect(!peers.admits(header.frame_const()));
        header.replica = 0; // This replica, to itself.
        try testing.expect(peers.admits(header.frame_const()));
    }
    // A release announced on this connection, with an origin remembered from before, counts.
    var peers_known = peers;
    peers_known.releases[3] = release_this;
    var commit: Header.Commit = std.mem.zeroInit(Header.Commit, .{ .command = .commit });
    commit.replica = 3;
    try testing.expect(!peers_known.admits(commit.frame_const()));
    peers_known.origins[3] = origin_this;
    try testing.expect(peers_known.admits(commit.frame_const()));
}

test "release_peers: a ping or pong is admitted by what it announces" {
    var peers: TestPeers = .init();
    var ping: Header.Ping = std.mem.zeroInit(Header.Ping, .{ .command = .ping, .replica = 3 });
    ping.release = release_other;
    ping.origin = origin_this;
    const announcement = announced(ping.frame_const()).?;
    try testing.expectEqual(3, announcement.replica);
    peers.releases[announcement.replica] = announcement.release;
    peers.origins[announcement.replica] = announcement.origin;
    try testing.expect(!peers.admits(ping.frame_const()));

    ping.release = release_this;
    peers.releases[3] = announced(ping.frame_const()).?.release;
    try testing.expect(peers.admits(ping.frame_const()));

    var pong: Header.Pong = std.mem.zeroInit(Header.Pong, .{ .command = .pong, .replica = 3 });
    pong.release = release_this;
    pong.origin = origin_other;
    try testing.expectEqualSlices(u8, &origin_other, &announced(pong.frame_const()).?.origin);
    peers.origins[3] = announced(pong.frame_const()).?.origin;
    try testing.expect(!peers.admits(pong.frame_const()));

    const commit: Header.Commit = std.mem.zeroInit(Header.Commit, .{ .command = .commit });
    try testing.expectEqual(null, announced(commit.frame_const()));
}

test "release_peers: a prepare is refused for its client's release, or its maker's" {
    var peers: TestPeers = .init();
    var prepare: Header.Prepare =
        std.mem.zeroInit(Header.Prepare, .{ .command = .prepare, .replica = 1 });
    // A prepare carries its client's release: any this replica accepts.
    for ([_]vsr.Release{ release_this, release_other }) |release_client| {
        prepare.release = release_client;
        prepare.replica = 1; // Made by a replica of this release and export.
        try testing.expect(peers.admits(prepare.frame_const()));
        prepare.replica = 0;
        try testing.expect(peers.admits(prepare.frame_const()));
        prepare.replica = 3; // Made by a replica not heard from (it may have crashed since).
        try testing.expect(peers.admits(prepare.frame_const()));
        prepare.replica = 2; // Made by a replica of another release, with a client we accept.
        try testing.expect(!peers.admits(prepare.frame_const()));
        prepare.replica = 4; // Made by a replica of another export.
        try testing.expect(!peers.admits(prepare.frame_const()));
    }
    // A client release this replica does not accept, whoever made it.
    prepare.replica = 1;
    prepare.release = release_newer;
    try testing.expect(!peers.admits(prepare.frame_const()));
    prepare.release = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 1 });
    try testing.expect(!peers.admits(prepare.frame_const()));
    // Its maker's last release counts after its connection is gone.
    prepare.release = release_this;
    peers.releases[1] = null;
    try testing.expect(peers.admits(prepare.frame_const()));
    peers.releases_last[1] = release_newer;
    try testing.expect(!peers.admits(prepare.frame_const()));
    prepare.release = vsr.Release.zero; // Root and reserved prepares.
    prepare.replica = 4;
    try testing.expect(peers.admits(prepare.frame_const()));

    var block: Header.Block = std.mem.zeroInit(Header.Block, .{ .command = .block });
    block.release = release_this;
    try testing.expect(peers.admits(block.frame_const()));
    block.release = release_other;
    try testing.expect(!peers.admits(block.frame_const()));
}

test "release_peers: client messages pass whatever their release" {
    const peers: TestPeers = .init();
    var request: Header.Request =
        std.mem.zeroInit(Header.Request, .{ .command = .request, .client = 7 });
    request.release = release_other;
    try testing.expect(peers.admits(request.frame_const()));
    var ping: Header.PingClient =
        std.mem.zeroInit(Header.PingClient, .{ .command = .ping_client, .client = 7 });
    ping.release = release_other;
    try testing.expect(peers.admits(ping.frame_const()));
    var reply: Header.Reply = std.mem.zeroInit(Header.Reply, .{ .command = .reply, .replica = 4 });
    reply.release = release_other;
    try testing.expect(peers.admits(reply.frame_const()));
}

test "release_peers: a replica stops when peers of other exports leave it no quorum" {
    // Per replica count: the fewest peers of another export that stop a replica.
    const cases = [_]struct { replica_count: u8, others_min: u8 }{
        .{ .replica_count = 1, .others_min = 1 }, // Never: it has no peers.
        .{ .replica_count = 2, .others_min = 1 },
        .{ .replica_count = 3, .others_min = 2 },
        .{ .replica_count = 4, .others_min = 2 },
        .{ .replica_count = 5, .others_min = 3 },
        .{ .replica_count = 6, .others_min = 3 },
    };
    for (cases) |case| {
        for (0..case.replica_count) |others| {
            var origins: [constants.members_max]?[32]u8 = @splat(null);
            // Replica 0 is this one; peers 1.. announce another origin, then the rest this one.
            for (1..case.replica_count) |peer| {
                origins[peer] = if (peer <= others) origin_other else origin_this;
            }
            const refused = origin_refused(case.replica_count, 0, &origin_this, &origins);
            try testing.expectEqual(others >= case.others_min, refused);
        }
    }
    // Peers not heard from never count against it; nor does a standby's origin.
    var origins: [constants.members_max]?[32]u8 = @splat(null);
    origins[1] = origin_other;
    origins[3] = origin_other; // A standby of a three-replica cluster.
    try testing.expect(!origin_refused(3, 0, &origin_this, &origins));
    origins[2] = origin_other;
    try testing.expect(origin_refused(3, 0, &origin_this, &origins));
    // A formatted replica (origin zero) and an imported one disagree.
    const zero: [32]u8 = @splat(0);
    try testing.expect(origin_refused(3, 0, &zero, &origins));
}
