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
//! Most replica messages carry release 0, so the check is by peer, not by message. Prepares and
//! blocks do not name their sender (a prepare may be relayed or repaired by any replica), but
//! carry the release they were made in, which in Nerva is always the cluster's one release.

const std = @import("std");
const assert = std.debug.assert;

const vsr = @import("../vsr.zig");
const constants = @import("../constants.zig");
const Header = vsr.Header;

/// Whether a replica running `release`, as replica `replica`, should handle a message with
/// `header`, given each peer's announced release (`peer_releases`, null if not yet announced).
/// A ping or pong is checked after its own announcement has been recorded.
pub fn admits(
    release: vsr.Release,
    replica: u8,
    peer_releases: []const ?vsr.Release,
    header: *const Header,
) bool {
    assert(release.value != 0);
    assert(peer_releases.len == constants.members_max);

    switch (header.into_any()) {
        // Created by clients: `release_client_min` governs them, and a reply carries its
        // request's release.
        .request, .ping_client, .reply => return true,
        // Root and reserved prepares carry release 0.
        .prepare => |prepare| return prepare.release.value == 0 or
            prepare.release.value == release.value,
        .block => |block| return block.release.value == release.value,
        else => {},
    }
    switch (header.peer_type()) {
        .replica => |peer| {
            if (peer == replica) return true;
            if (peer >= peer_releases.len) return false;
            const peer_release = peer_releases[peer] orelse return false;
            return peer_release.value == release.value;
        },
        .unknown, .client, .client_likely => return true,
    }
}

/// The release a ping or pong announces for its sender, or null for any other message.
pub fn announced(header: *const Header) ?struct { replica: u8, release: vsr.Release } {
    return switch (header.into_any()) {
        .ping => |ping| .{ .replica = ping.replica, .release = ping.release },
        .pong => |pong| .{ .replica = pong.replica, .release = pong.release },
        else => null,
    };
}

const testing = std.testing;

const release_this = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 3 });
const release_other = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 2 });

fn test_peers() [constants.members_max]?vsr.Release {
    var peers: [constants.members_max]?vsr.Release = @splat(null);
    peers[1] = release_this;
    peers[2] = release_other;
    return peers;
}

test "release_peers: a peer counts only once it has announced this replica's release" {
    const peers = test_peers();
    inline for (.{ .commit, .prepare_ok, .view, .headers }) |command| {
        const Command = Header.Type(command);
        var header: Command = std.mem.zeroInit(Command, .{ .command = command });
        header.replica = 1; // Announced this release.
        try testing.expect(admits(release_this, 0, &peers, header.frame_const()));
        header.replica = 2; // Announced another release.
        try testing.expect(!admits(release_this, 0, &peers, header.frame_const()));
        header.replica = 3; // Not announced yet.
        try testing.expect(!admits(release_this, 0, &peers, header.frame_const()));
        header.replica = 0; // This replica, to itself.
        try testing.expect(admits(release_this, 0, &peers, header.frame_const()));
    }
}

test "release_peers: a ping is admitted by the release it announces" {
    var peers = test_peers();
    var ping: Header.Ping = std.mem.zeroInit(Header.Ping, .{ .command = .ping, .replica = 3 });
    ping.release = release_other;
    const announcement = announced(ping.frame_const()).?;
    try testing.expectEqual(3, announcement.replica);
    peers[announcement.replica] = announcement.release;
    try testing.expect(!admits(release_this, 0, &peers, ping.frame_const()));

    ping.release = release_this;
    peers[3] = announced(ping.frame_const()).?.release;
    try testing.expect(admits(release_this, 0, &peers, ping.frame_const()));

    const commit: Header.Commit = std.mem.zeroInit(Header.Commit, .{ .command = .commit });
    try testing.expectEqual(null, announced(commit.frame_const()));
}

test "release_peers: prepares and blocks are admitted by the release they were made in" {
    const peers = test_peers();
    var prepare: Header.Prepare =
        std.mem.zeroInit(Header.Prepare, .{ .command = .prepare, .replica = 2 });
    prepare.release = release_this; // Relayed by a replica of another release: still ours.
    try testing.expect(admits(release_this, 0, &peers, prepare.frame_const()));
    prepare.release = release_other;
    prepare.replica = 1;
    try testing.expect(!admits(release_this, 0, &peers, prepare.frame_const()));
    prepare.release = vsr.Release.zero; // Root and reserved prepares.
    try testing.expect(admits(release_this, 0, &peers, prepare.frame_const()));

    var block: Header.Block = std.mem.zeroInit(Header.Block, .{ .command = .block });
    block.release = release_this;
    try testing.expect(admits(release_this, 0, &peers, block.frame_const()));
    block.release = release_other;
    try testing.expect(!admits(release_this, 0, &peers, block.frame_const()));
}

test "release_peers: client messages pass whatever their release" {
    const peers = test_peers();
    var request: Header.Request =
        std.mem.zeroInit(Header.Request, .{ .command = .request, .client = 7 });
    request.release = release_other;
    try testing.expect(admits(release_this, 0, &peers, request.frame_const()));
    var ping: Header.PingClient =
        std.mem.zeroInit(Header.PingClient, .{ .command = .ping_client, .client = 7 });
    ping.release = release_other;
    try testing.expect(admits(release_this, 0, &peers, ping.frame_const()));
    var reply: Header.Reply = std.mem.zeroInit(Header.Reply, .{ .command = .reply, .replica = 2 });
    reply.release = release_other;
    try testing.expect(admits(release_this, 0, &peers, reply.frame_const()));
}
