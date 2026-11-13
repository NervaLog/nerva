---
id: P394
date: 2026-11-13
area: Releases
---

# R7's brief is a proposal: retention declared in the log, trimmed by pulses, keep-last by predecessor

This pull request decides only that `docs/briefs/r7.md` is R7's proposed design, to be
implemented once the owner answers its nine questions. It amends no decision. Until the
answers, N27 and N62 (history and view versions kept forever) and P123 (commit keys kept
forever; clients choose keys) stand as written.

The proposal, in short: a horizon per kind (commit keys, row and record history, view and group
versions) is declared in the log, and the default is forever. The primary's pulses trim, a
number of objects per pulse, within each tree's per-op limit: one scan per tree in
`prefetch`, tombstones in `commit`, and ordinary compaction reclaims them. A forward cursor
removes each change's predecessor, found by a link written with the change, once the change is
below the horizon (keep-last). A kind's `horizon_op` is the op of the newest object its cursor
examined: as-of reads at or above it are exact, reads below it answer `before_horizon`, and the
feed is refused from at or below its trimmed timestamp. Keys are UUIDv7 once a key horizon is
declared; a key's resend with no row is refused as `key_expired` unless its time is strictly
above everything trimmed, plus `skew_max` and the op's timestamp span. That check holds for as
long as any key has been trimmed. Retention of facts is cut from R7.

**Why:** pulses are how Nerva already does bounded, deterministic background work in the log
(N52's backfill). Compaction-time filters cannot work, because append-only, timestamp-keyed
tables at the last level are never rewritten. Recording the brief as a proposal, not as
amendments, keeps merged decisions from saying more than the owner has agreed to.

**Cost:** nothing yet; the brief names its own costs (formats, a vendored patch, export and
import into R7's release).

**Open, for the owner** (the brief's questions; the pull request that records the answers files
its own decisions under its own number):
- whether to amend N27, N62 and P123 ("kept forever") for clusters that declare a horizon
  (question 5);
- how a key's age is known: UUIDv7 (recommended, no wire change) or `sent_at` (a wire change).
  Either amends P123's "clients choose keys" in substance (question 2);
- whether pulses replace PRODUCTION.md's "Compaction drops what is older" (question 7);
- whether facts' retention is cut from R7, amending GOALS-1.0 goal 7's line and PRODUCTION.md's
  goal (question 8);
- whether trimming's lag is bounded as stated, by backpressure, or by a vendored patch to
  `replica.zig` (question 9);
- the feed below the horizon, the demo's time scale, the bounds, and when R7 starts (questions 3,
  4, 6 and 1).
