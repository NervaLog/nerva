---
id: P415b
date: 2026-11-13
area: Releases
amends: N61
---

# A grid block is admitted when the release that wrote it is at or below the newest this process runs

N61 admitted a block only when its `release` was the running release, true while a new release was
an export and import that rewrote every block. P259 made releases rolling, and a block's `release`
(`compaction.zig`, `manifest_log.zig`: the checkpoint's release when it was written) now names the
release that wrote it, which stays in the grid for as long as compaction leaves it.

**Decision.** `release_peers.admits` admits a `.block` whose release is nonzero and at or below the
newest release this process runs. Messages that drive the state machine (prepares, ping, pong and
the commands of a peer) keep the strict rule: the release announced must be one this process runs.

**Reason.** A binary bundles at most one past release (P259). After vR to vR+1 to vR+2, a vR+2
replica that lags, repairs, state-syncs or is recovered asks for blocks written at vR; under the
strict rule every reply is dropped and grid repair never completes. A block is content-addressed
and checksummed, and its release says only which code wrote it; the strict format digest (P259c)
makes every release at or below the newest readable. A newer one is not.

**Cost.** A single-release binary now accepts blocks of older releases, which N61 refused. They can
only come from a data file that already passed the format digest.
