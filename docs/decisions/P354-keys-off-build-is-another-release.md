---
id: P354
date: 2026-11-12
area: Release
---

# The keys-off test build runs its own release, so it cannot join a release cluster

Issue #222. `-Dtest-commit-keys=off` commits a resent key again; a replica of that build in a
cluster with release replicas would diverge on the first resent key. Nothing stopped the mix.
- **Decision:** that build is compiled as release `0.0.201` (`release_keys_off` in `build.zig`),
  above every real release and apart from `test:release`'s `0.0.200`. Replicas already ignore
  peers of another release (N61), so a mixed cluster does not count the other side toward any
  quorum, and logs at error level `replica N runs release 0.0.6, this replica runs 0.0.201:
  ignoring it (a cluster must run one release)`. Each side's data file is refused by the other
  with NRV-E0701. Clients of releases from `release_client_min` up still reach it.
- **Why this way:** no wire or on-disk format changes, nothing in the state machine or the
  vendored replica changes, and no new failure path: it reuses N61 and NRV-E0701. Carrying the
  flag in the ping or the peer-auth proof would change the wire format.
- **What it costs:** one more constant in `build.zig` (recorded in UPSTREAM.md); `nerva version`
  of that build says `0.0.201+keys-off`. It narrows rather than closes the issue in one respect:
  the refusal is the generic release one, not a message naming keys-off; the replica's start
  warning (NRV-W0701) still names the build. A cluster of keys-off replicas only is unaffected.
- **Tests:** `tests/errors/commands.py` checks that the two builds report different releases and
  that each refuses the other's data file with NRV-E0701; `tests/release/mixed.py` already
  proves the N61 ignore for builds of different releases.
