---
id: P259
date: 2026-11-10
area: Releases
amends: N61
---

# R6's rolling upgrade uses upstream's multiversion switch; a peer is admitted when this process can run its release

The R6 brief (`docs/briefs/r6.md`) chooses how a cluster moves from release N to N+1 while
open: each replica is restarted on a binary that bundles N and N+1 and keeps running N; once
every replica offers N+1, the primary proposes upstream's `upgrade` ops and the cluster switches
at a durable checkpoint, as TigerBeetle's multiversion replica does, unchanged. N61's rule (a
replica ignores a peer that runs another release) is amended: a peer is admitted when it
announces a release this process bundles, so a restarted replica is not cut off from the ones
still on N. Rollback is a restart on N's binary before the switch, and a revert release after it.
A binary bundles at most one past release, of the same format digest; a format change stays an
export and import.

**Why.** The switch, the quorum and the checkpoint bar are upstream's, already exercised by its
VOPR; writing our own would put a new consensus path under the log. Strict format equality keeps
the proof small: N+1 opens N's checkpoint because nothing persisted changed.

**Cost.** The first rolling upgrade is vR to vR+1 (an older release must already be multiversion
aware); v0.7.0 to vR is an export and import. The release string must move every release (owner
question 1 in the brief), and a binary is about twice as large. The owner questions in the brief
(release string, strict formats, packer, revert releases, the demo's releases, v0.7.0 to vR) are
open; each answer is filed as its own decision.
