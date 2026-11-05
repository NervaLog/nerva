---
id: N61
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Replicas ignore peers that run another release.

N60 measured that a release string only guards data files: a replica of another release joins
the cluster, counts toward quorums while it executes the log with other code, and is caught only
at the first checkpoint (#34). TigerBeetle lets releases mix because a newer binary bundles the
older releases and runs their prepares with the older code; Nerva bundles one (N43). Owner's
decision: fix it in v0.3.0.
- **By peer, not by message.** Only pings and pongs carry their sender's running release; most
  replica messages carry release 0. A replica records each peer's release from its pings and
  pongs and handles a peer's messages only once that peer has announced the release it runs
  itself (`nerva/release_peers.zig`, `admits`). A peer that has not announced yet counts for
  nothing, about a second at startup. Prepares and blocks do not name their sender (any replica
  relays or repairs them) but carry the release they were made in, so they are checked by that:
  root and reserved prepares carry 0. Requests, client pings and replies pass:
  `release_client_min` governs clients.
- **Restarts.** A restart always drops the restarting replica's connections, so a replica
  forgets a peer's release when the message bus no longer holds a connection to it, and pings a
  peer as soon as a connection appears, so each side learns the other's release within a tick
  rather than at the next ping timeout. (Pinging first on open, the first design, does not
  work: the bus drops messages to replicas it is not yet connected to.)
- **Opt-in, for Nerva.** `Replica.Options.release_peers_strict`, set by `nerva start`. Vendored
  `replica_test.zig` and the VOPR's `testing` lane simulate TigerBeetle's in-place upgrades, in
  which replicas of different releases cooperate, and keep upstream behaviour. The VOPR's `nerva`
  lane simulated them too, a path Nerva never runs (N43: a new release is a reformat). It now runs
  one release with the option on, as production does.
- **With a v0.2.0 peer**, which ignores no one (measured with the v0.2.0 binary). One v0.3.0
  replica and two v0.2.0: the v0.3.0 replica logs that it ignores both, drops their prepares,
  and never counts; the v0.2.0 pair cannot commit without each other. Two v0.3.0 and one v0.2.0:
  the v0.3.0 pair ignores the v0.2.0 replica and commits past a checkpoint; the v0.2.0 replica
  takes the v0.3.0 primary's view, commits its prepares, and panics on the first operation it
  does not know (`Operation.cast`, a views operation). Either way only one release's replicas
  count toward quorums. Between v0.3.0 and later releases neither side executes the other's
  prepares.
Tests: unit tests of `admits`; `zig build test:release` (`tests/release/mixed.py`) builds a
second `nerva` with release `0.0.200` and runs replicas 0 and 1 on one release and replica 2 on
the other: both sides log the mismatch, nothing commits without replica 1, and with it back
1,000 commits pass the first checkpoint with no panic (before: `checkpoint diverged`). VOPR
seeds 1, 2, 5 and two random seeds on the `nerva` lane, 1 and 2 on `testing`. Mutation-tested:
without the gate a commit succeeds with replica 1 stopped (`test:release`); admitting unannounced
peers or prepares of another release fails the unit tests. Forgetting a release on disconnect is
not covered by a failing test: a restart onto another release would need two binaries swapped on
one replica index within a ping interval.
