---
id: P102
date: 2026-10-06
area: "Milestone 3: positioned reads and the first views"
---

# Replicas authenticate each other with a cluster key before any replica message flows

NV-3. A replica handled whatever arrived on its port: any process that could reach it could pose
as a replica (a ping naming an index was enough), vote in view changes and send prepares.
Chosen by the owner over a private network alone (still required, below) and over TLS between
replicas (certificates to issue and rotate, and a TLS stack in the vendored bus).
- **The key:** `NERVA_CLUSTER_KEY`, at least 32 bytes, the same on every replica, read by
  `nerva start` and never logged (`peer_auth.Keys` prints as `Keys(redacted)`). `nerva start`
  refuses to run without it, naming the variable. `--development` falls back to a public
  development key only when every address is a loopback address, with a warning, so the public
  key never guards a replica another machine can reach; the integration tests, the Python
  harnesses and Jepsen set a real key.
- **Rotation:** `NERVA_CLUSTER_KEY_NEXT`. A replica proves with its current key and accepts a
  proof under either, always computing and comparing both in constant time, so a rotation is
  three rounds of restarts with no downtime (README). The key rules are those of gateway keys
  (P96), plus the length.
- **The handshake** (`src/nerva/peer_auth.zig`; three header-only commands, `peer_hello`,
  `peer_challenge`, `peer_proof`, new ordinals 25 to 27, since a retired ordinal may still be
  in old logs). The dialing replica (the lower index: replicas dial only those after them) sends
  a fresh 128-bit nonce and its origin; the accepting one answers with its nonce, its origin and
  its proof; the dialing one checks it and sends its own. A proof is HMAC-SHA256 under the key,
  truncated to 128 bits, of a label, the prover's role, the cluster, both indexes, both nonces
  and both origins. Fresh nonces on both sides make a recorded handshake useless; the role keeps
  a proof from being reflected; the accepting replica proves first, but only over a nonce it
  chose too.
- **Binding the origins** (P90): both data files' origins are in both proofs, and the bus closes
  an authenticated connection whose ping or pong announces another origin than its proof covered,
  so P90's gate decides on origins the key vouched for. The handshake does not refuse a peer of
  another origin itself: P90's gate needs to hear it, to count it and exit with status 8.
- **A zero origin is not adopted.** A formatted replica (origin zero) never joins an imported
  cluster (P90 refuses it before any sync), so it never syncs and never takes the cluster's
  origin; its origin stays what its data file holds for the file's life (`monotonic` asserts it).
  The handshake binds whatever the data file holds.
- **What the bus refuses** (it closes the connection, naming the reason, never a key): before
  the handshake, any message but a hello, a request or a `ping_client`; on a client's
  connection, anything but a request or a `ping_client` (a prepare, block or reply has no peer
  type, and was handled from anyone); a hello from an index at or above the replica's own; a
  challenge or proof from another replica than the one the handshake is with, or under neither
  key; after it, a message claiming another replica, or a handshake message again. A
  connection's peer becomes a replica only by the handshake. Clients are unchanged: they never
  see the new commands, and `release_client_min` stays 0.0.4.
- **Bounds:** a handshake has `peer_auth.handshake_ticks_max` (500 ticks, 5 s) to finish, or the
  connection is closed. Messages a replica sends meanwhile wait in the connection's send queue
  (`connection_send_queue_max_replica`, asserted), which drops the rest as it did while
  connecting. Connect attempts reset only once authenticated, so a replica with another key is
  redialed with backoff rather than in a loop.
- **Releases:** 0.0.5 (P90) has not shipped, so the release string stays. A 0.0.4 replica and a
  0.0.5 replica cannot talk at all: 0.0.4 closes on an unknown command, and 0.0.5 on a replica
  message before the handshake. The README says never to mix them; upgrades go through export and
  import (N80).
- **Not covered:** the key authenticates who opened a connection, not what follows: a party on
  the network path could still read or alter traffic, or hijack a connection after its
  handshake. Replicas need a private network that encrypts (WireGuard; Fly.io's 6PN is
  WireGuard). The simulator's bus has no connections, so the VOPR does not run the handshake;
  `message_bus_fuzz` and `test:integration` do.
- **Golden values:** none changed. The handshake adds wire commands and nothing on disk; the
  formatted data file's checksum (`replica_format.zig`) and the header format snapshot hold.
- **Tests.** Unit (`peer_auth.zig`): proofs and checks with the right key, a wrong one, swapped
  roles, and each field of the transcript changed (a replayed proof fails on fresh nonces); the
  three steps of a rotation; key rules, none of whose messages names a key; `keys_resolve` (the
  development key only with `--development` and loopback addresses); loopback detection. Fuzz:
  `message_bus_fuzz` with keys, and with replica 2 on another key, asserting that no replica
  message passes between it and the others and that it is never authenticated. Integration
  (`scenario_peer_auth`, real processes): a well-formed ping claiming replica 1 is closed
  unread; a hello from an index that must not dial is closed; a challenge proves the key, a
  proof under another key is closed, a proof under the key is answered as a replica; a replica
  with another key gives no quorum; a rolling rotation commits at every step, each restarted
  replica needed for the next quorum.
