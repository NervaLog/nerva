//! Replicas authenticate each other (P102, NV-3): before any replica message flows on a
//! replica-to-replica connection, each side proves it holds the cluster key, `NERVA_CLUSTER_KEY`.
//!
//! The replica that dials (the lower index; replicas dial only those after them) sends
//! `peer_hello` with a fresh nonce and its origin. The accepting replica answers
//! `peer_challenge` with its own nonce, its origin and its proof; the dialing replica checks
//! that proof and answers `peer_proof` with its own. A proof is an HMAC-SHA256, under the key, of
//! the whole transcript: the cluster, both replicas, both nonces and both origins, with the
//! prover's role. Fresh nonces on both sides make a recorded handshake useless, the role keeps a
//! proof from being reflected back, and the origins bind what each side said it was imported
//! from (P90) to the key, so a ping or pong on the connection must later announce the same.
//!
//! A replica proves with its current key and accepts a proof under either the current or the
//! next key (`NERVA_CLUSTER_KEY_NEXT`), so the key is rotated by restarting replicas one at a
//! time. Keys are never logged: `Keys` formats as a placeholder.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// A cluster key is at least this long: 32 random bytes, or a passphrase longer still.
pub const key_length_min = 32;

/// How long a handshake may take, in replica ticks (10 ms): 5 seconds. A connection still
/// handshaking after it is closed.
pub const handshake_ticks_max = 500;

/// The key `nerva start --development` uses when `NERVA_CLUSTER_KEY` is unset, and only when
/// every address is a loopback address: it is public, so it authenticates nothing.
pub const development_key = "nerva-development-cluster-key-public-do-not-use";

/// The value `packaging/linux/replica.env.example` ships for `NERVA_CLUSTER_KEY`. It is long
/// enough and published in this repository, so it is refused (#306): a copied example that was
/// never edited must not run a cluster.
pub const placeholder_key = "replace-with-at-least-32-bytes-from-openssl-rand-hex-32";

comptime {
    assert(development_key.len >= key_length_min);
    assert(placeholder_key.len >= key_length_min);
}

pub const Keys = struct {
    current: []const u8,
    next: ?[]const u8 = null,

    /// Why these keys cannot be used, naming the variable and never a key; null if they can.
    pub fn invalid(current: []const u8, next: ?[]const u8) ?[]const u8 {
        if (current.len == 0) return "set NERVA_CLUSTER_KEY (at least 32 bytes)";
        if (current.len < key_length_min) return "NERVA_CLUSTER_KEY is shorter than 32 bytes";
        if (std.mem.eql(u8, current, placeholder_key)) {
            return "NERVA_CLUSTER_KEY is the example's placeholder: " ++
                "make a key with openssl rand -hex 32";
        }
        if (next) |key_next| {
            if (key_next.len == 0) return "NERVA_CLUSTER_KEY_NEXT is set but empty";
            if (key_next.len < key_length_min) {
                return "NERVA_CLUSTER_KEY_NEXT is shorter than 32 bytes";
            }
            if (std.mem.eql(u8, key_next, placeholder_key)) {
                return "NERVA_CLUSTER_KEY_NEXT is the example's placeholder: " ++
                    "make a key with openssl rand -hex 32";
            }
            if (std.mem.eql(u8, key_next, current)) {
                return "NERVA_CLUSTER_KEY_NEXT equals NERVA_CLUSTER_KEY";
            }
        }
        return null;
    }

    /// Keys are never printed, even by accident.
    pub fn format(
        _: Keys,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.writeAll("Keys(redacted)");
    }
};

/// The keys `nerva start` uses, from `NERVA_CLUSTER_KEY` and `NERVA_CLUSTER_KEY_NEXT` (null when
/// unset), or why it must not start. The public development key stands in for an unset key only
/// with `--development`, and only when every address is a loopback address, so that it never
/// guards a replica another machine can reach.
pub fn keys_resolve(
    current: ?[]const u8,
    next: ?[]const u8,
    development: bool,
    addresses: []const stdx.SocketAddress,
) union(enum) { keys: Keys, development, refused: []const u8 } {
    assert(addresses.len > 0);
    if (current == null or current.?.len == 0) {
        if (!development) return .{ .refused = "set NERVA_CLUSTER_KEY (at least 32 bytes)" };
        if (next != null) {
            return .{ .refused = "NERVA_CLUSTER_KEY_NEXT is set without NERVA_CLUSTER_KEY" };
        }
        for (addresses) |address| {
            if (!loopback(address)) {
                return .{ .refused = "set NERVA_CLUSTER_KEY: --development uses its public " ++
                    "key only when every address is a loopback address" };
            }
        }
        return .development;
    }
    if (Keys.invalid(current.?, next)) |reason| return .{ .refused = reason };
    return .{ .keys = .{ .current = current.?, .next = next } };
}

/// Whether `address` is a loopback address: 127.0.0.0/8 or ::1.
pub fn loopback(address: stdx.SocketAddress) bool {
    return switch (address.ip.family()) {
        .IPv4 => address.ip.big[12] == 127,
        .IPv6 => std.mem.eql(u8, &address.ip.big, &(@as([15]u8, @splat(0)) ++ [_]u8{1})),
    };
}

pub const Role = enum(u8) {
    /// The replica that accepted the connection (the higher index).
    accepting = 1,
    /// The replica that dialed it (the lower index).
    dialing = 2,
};

/// Everything a proof covers.
pub const Transcript = struct {
    cluster: u128,
    dialing: u8,
    accepting: u8,
    nonce_dialing: u128,
    nonce_accepting: u128,
    origin_dialing: [32]u8,
    origin_accepting: [32]u8,
};

pub const Mac = [16]u8;

const label = "nerva peer handshake v1";

/// The proof that `role` holds `key`, for this handshake.
pub fn proof(key: []const u8, role: Role, transcript: *const Transcript) Mac {
    assert(key.len >= key_length_min);
    assert(transcript.dialing < transcript.accepting);
    assert(transcript.nonce_dialing != 0);
    assert(transcript.nonce_accepting != 0);

    var hmac = HmacSha256.init(key);
    hmac.update(label);
    hmac.update(&.{@intFromEnum(role)});
    hmac.update(std.mem.asBytes(&std.mem.nativeToLittle(u128, transcript.cluster)));
    hmac.update(&.{ transcript.dialing, transcript.accepting });
    hmac.update(std.mem.asBytes(&std.mem.nativeToLittle(u128, transcript.nonce_dialing)));
    hmac.update(std.mem.asBytes(&std.mem.nativeToLittle(u128, transcript.nonce_accepting)));
    hmac.update(&transcript.origin_dialing);
    hmac.update(&transcript.origin_accepting);
    var digest: [HmacSha256.mac_length]u8 = undefined;
    hmac.final(&digest);
    return digest[0..@sizeOf(Mac)].*;
}

/// Whether `mac` proves that `role` holds either key. Always computes and compares both, in
/// constant time, so the time taken tells neither which key matched nor whether a rotation is
/// under way.
pub fn verify(keys: *const Keys, role: Role, transcript: *const Transcript, mac: *const Mac) bool {
    const current = proof(keys.current, role, transcript);
    const next = proof(keys.next orelse keys.current, role, transcript);
    const current_ok = std.crypto.timing_safe.eql(Mac, current, mac.*);
    const next_ok = std.crypto.timing_safe.eql(Mac, next, mac.*);
    return @intFromBool(current_ok) | @intFromBool(next_ok) == 1;
}

/// A nonce for a handshake: random, never zero.
pub fn nonce() u128 {
    while (true) {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        const value = std.mem.readInt(u128, &bytes, .little);
        if (value != 0) return value;
    }
}

const testing = std.testing;

const key_a = "a" ** key_length_min;
const key_b = "b" ** key_length_min;
const key_c = "c" ** key_length_min;

fn transcript_example() Transcript {
    return .{
        .cluster = 7,
        .dialing = 0,
        .accepting = 2,
        .nonce_dialing = 0x1111,
        .nonce_accepting = 0x2222,
        .origin_dialing = @splat(3),
        .origin_accepting = @splat(3),
    };
}

test "peer_auth: proof and verify" {
    const transcript = transcript_example();
    const keys: Keys = .{ .current = key_a };
    const dialing = proof(key_a, .dialing, &transcript);
    try testing.expect(verify(&keys, .dialing, &transcript, &dialing));

    // The roles differ: a proof cannot be reflected back.
    try testing.expect(!verify(&keys, .accepting, &transcript, &dialing));

    // A wrong key.
    const wrong = proof(key_b, .dialing, &transcript);
    try testing.expect(!verify(&keys, .dialing, &transcript, &wrong));

    // Every field of the transcript is covered: a replayed proof fails on fresh nonces, and
    // either origin or either replica changed fails.
    const Mutation = *const fn (*Transcript) void;
    const mutations = [_]Mutation{
        struct {
            fn f(t: *Transcript) void {
                t.cluster += 1;
            }
        }.f,
        struct {
            fn f(t: *Transcript) void {
                t.dialing = 1;
            }
        }.f,
        struct {
            fn f(t: *Transcript) void {
                t.accepting = 3;
            }
        }.f,
        struct {
            fn f(t: *Transcript) void {
                t.nonce_dialing += 1;
            }
        }.f,
        struct {
            fn f(t: *Transcript) void {
                t.nonce_accepting += 1;
            }
        }.f,
        struct {
            fn f(t: *Transcript) void {
                t.origin_dialing[31] ^= 1;
            }
        }.f,
        struct {
            fn f(t: *Transcript) void {
                t.origin_accepting[0] ^= 1;
            }
        }.f,
    };
    for (mutations) |mutate| {
        var changed = transcript;
        mutate(&changed);
        try testing.expect(!verify(&keys, .dialing, &changed, &dialing));
    }
}

test "peer_auth: rotation" {
    const transcript = transcript_example();
    const old = proof(key_a, .accepting, &transcript);
    const new = proof(key_b, .accepting, &transcript);
    const other = proof(key_c, .accepting, &transcript);

    // Step 1: the new key is next everywhere; proofs under either are accepted.
    const step_1: Keys = .{ .current = key_a, .next = key_b };
    try testing.expect(verify(&step_1, .accepting, &transcript, &old));
    try testing.expect(verify(&step_1, .accepting, &transcript, &new));
    try testing.expect(!verify(&step_1, .accepting, &transcript, &other));

    // Step 2: the new key is current, the old one next.
    const step_2: Keys = .{ .current = key_b, .next = key_a };
    try testing.expect(verify(&step_2, .accepting, &transcript, &old));
    try testing.expect(verify(&step_2, .accepting, &transcript, &new));

    // Step 3: the old key is gone.
    const step_3: Keys = .{ .current = key_b };
    try testing.expect(!verify(&step_3, .accepting, &transcript, &old));
    try testing.expect(verify(&step_3, .accepting, &transcript, &new));
}

test "peer_auth: Keys.invalid" {
    try testing.expectEqual(null, Keys.invalid(key_a, null));
    try testing.expectEqual(null, Keys.invalid(key_a, key_b));
    try testing.expect(Keys.invalid("", null) != null);
    try testing.expect(Keys.invalid(key_a[1..], null) != null);
    try testing.expect(Keys.invalid(key_a, "") != null);
    try testing.expect(Keys.invalid(key_a, key_b[1..]) != null);
    try testing.expect(Keys.invalid(key_a, key_a) != null);

    // #306: the example's published placeholder is refused, as current or as next, and a
    // refusal is not a fallback to the development key.
    try testing.expectEqualStrings(
        "NERVA_CLUSTER_KEY is the example's placeholder: make a key with openssl rand -hex 32",
        Keys.invalid(placeholder_key, null).?,
    );
    try testing.expectEqualStrings(
        "NERVA_CLUSTER_KEY_NEXT is the example's placeholder: make a key with openssl rand -hex 32",
        Keys.invalid(key_a, placeholder_key).?,
    );

    // No message names a key.
    const messages = [_]?[]const u8{
        Keys.invalid(key_a[1..], null),
        Keys.invalid(key_a, key_b[1..]),
        Keys.invalid(key_a, key_a),
        Keys.invalid(placeholder_key, null),
        Keys.invalid(key_a, placeholder_key),
    };
    for (messages) |message| {
        try testing.expect(std.mem.indexOf(u8, message.?, "aaaa") == null);
        try testing.expect(std.mem.indexOf(u8, message.?, "bbbb") == null);
    }

    var buffer: [64]u8 = undefined;
    const printed = try std.fmt.bufPrint(&buffer, "{}", .{Keys{ .current = key_a }});
    try testing.expectEqualStrings("Keys(redacted)", printed);
}

test "peer_auth: keys_resolve" {
    @setEvalBranchQuota(20_000); // The addresses are parsed at comptime.
    const local = [_]stdx.SocketAddress{
        .{ .ip = .ip("127.0.0.1"), .port = 3001 },
        .{ .ip = .ip("127.0.0.2"), .port = 3002 },
        .{ .ip = .ip("::1"), .port = 3003 },
    };
    const mixed = [_]stdx.SocketAddress{
        .{ .ip = .ip("127.0.0.1"), .port = 3001 },
        .{ .ip = .ip("10.0.0.2"), .port = 3002 },
    };
    const wildcard = [_]stdx.SocketAddress{.{ .ip = .ip("0.0.0.0"), .port = 3001 }};

    try testing.expectEqualStrings(key_a, keys_resolve(key_a, null, false, &mixed).keys.current);
    try testing.expectEqualStrings(key_b, keys_resolve(key_a, key_b, true, &local).keys.next.?);
    // An explicit key wins over the development key.
    try testing.expect(keys_resolve(key_a, null, true, &local) == .keys);

    try testing.expect(keys_resolve(placeholder_key, null, false, &mixed) == .refused);
    try testing.expect(keys_resolve(placeholder_key, null, true, &local) == .refused);
    try testing.expect(keys_resolve(null, null, true, &local) == .development);
    try testing.expect(keys_resolve("", null, true, &local) == .development);
    try testing.expect(keys_resolve(null, null, false, &local) == .refused);
    try testing.expect(keys_resolve(null, null, true, &mixed) == .refused);
    try testing.expect(keys_resolve(null, null, true, &wildcard) == .refused);
    try testing.expect(keys_resolve(null, key_b, true, &local) == .refused);
    try testing.expect(keys_resolve(key_a[1..], null, true, &local) == .refused);
    try testing.expect(keys_resolve(key_a, key_a, false, &mixed) == .refused);

    try testing.expect(loopback(.{ .ip = .ip("127.255.0.1"), .port = 1 }));
    try testing.expect(!loopback(.{ .ip = .ip("128.0.0.1"), .port = 1 }));
    try testing.expect(!loopback(.{ .ip = .ip("::2"), .port = 1 }));
    try testing.expect(!loopback(.{ .ip = .ip("::"), .port = 1 }));
}

test "peer_auth: nonce" {
    try testing.expect(nonce() != 0);
    try testing.expect(nonce() != nonce());
}
