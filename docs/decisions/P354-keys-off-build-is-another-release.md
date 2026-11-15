---
id: P354
date: 2026-11-12
area: Releases
amends: P259b
---

# The keys-off test build runs its own release, so it cannot join a release cluster

Issue #222. `-Dtest-commit-keys=off` commits a resent key again; a replica of that build in a
cluster with release replicas would diverge on the first resent key. Nothing stopped the mix.
- **Decision:** that build is compiled as this release with its patch plus 201
  (`release_keys_off` in `build.zig`; `0.0.207` for release `0.0.6`). It is derived from `release`,
  not a fixed number, so it follows `release` when P259b makes it `VERSION` (R6, `docs/briefs/r6.md`:
  vR is 0.8.0), and it stays one above R6's `release_test_next` (patch plus 200). `test:release`'s
  `0.0.200` is unchanged. The comptime checks are that it is above `release`, differs from
  `release_test_other`, and that the patch plus 201 fits the release's `u8` patch (a release with a
  patch above 54 fails the build, as `release_test_next` will). P259b's invariant "the release
  string is `VERSION`" is unchanged for release builds; this amends it only for the test build.
  A fixed `0.0.201` was rejected: it fails the "real release < test release" check at 0.8.0. Upstream's
  reserved test major 65535 was rejected: `replica.zig` and `nerva_main.zig` panic with it on any
  cluster other than 0, and Jepsen's teeth run and `tests/packaging` use other clusters.
- **Replicas:** they already ignore peers of another release (N61), so a mixed cluster does not
  count the other side toward any quorum, and logs at error level `replica N runs release 0.0.6,
  this replica runs 0.0.207: ignoring it (a cluster must run one release)`. Each side's data file
  is refused by the other: a keys-off build's file by a release build with NRV-E0718 (its release is above the binary's), a release file by the keys-off build with NRV-E0701.
- **Clients:** a client's release is its build's, so the keys-off build's own clients (`nerva api`,
  `view`, `export`, `backup`, `recover`) are evicted by a release cluster with
  `client_release_too_high`. The coded refusal for that (NRV-E0609, and NRV-E0610 for
  `client_release_too_low`) is #430's (`src/nerva/release_eviction.zig`, `worklog/430.md`; #356), which merged
  while this pull request was held. This pull request first carried its own version of it and
  dropped it for #430's; it adds no eviction code. Release clients reach a keys-off cluster, since
  their release is lower; a release gateway on a mixed cluster therefore gets keys-off semantics
  from the keys-off majority, which does not diverge.
- **Not guarded:** `nerva import` does not compare releases, so a keys-off export can be imported
  into a release cluster. NRV-E0701's row in `docs/ERRORS.md` says never to (it names the keys-off exception); making
  `import` refuse it needs the export to say it came from a keys-off cluster, which is a format
  question (#357).
- **Why this way:** no wire or on-disk format changes, nothing in the state machine or the
  vendored replica changes. Carrying the flag in the ping or the peer-auth proof would change the
  wire format.
- **What it costs:** one derived constant and a helper in `build.zig` (recorded in UPSTREAM.md);
  `nerva version` of that build says `0.0.207+keys-off`. The refusal of a data file is the generic
  release one; the replica's start warning (NRV-W0701) names the build. A cluster of keys-off
  replicas only is unaffected. The ignore of peers is N61's, covered by `tests/release/mixed.py`
  (two real releases) and `release_peers.zig`'s unit tests; no test here runs a keys-off replica
  beside a release replica, and `release_peers.admits` admits a prepare whose maker has not yet
  announced since this replica started (#358).
- **Tests:** `tests/errors/commands.py` checks the two builds' releases differ, that each refuses
  the other's data file (NRV-E0718, NRV-E0701) and leaves it unchanged, and that the keys-off build's
  `export`, `api` and `view` against a release cluster end NRV-E0609, as #430 words it. NRV-E0610 is
  #430's unit tests only.
