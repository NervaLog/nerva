---
id: P394
date: 2026-11-13
area: Releases
---

# R7's brief is a proposal: history and versions declared in the log, trimmed by pulses, keep-last by predecessor

This pull request decides only that `docs/briefs/r7.md` is R7's proposed design, to be
implemented once the owner answers its eight questions. It amends no decision. Until the
answers, N27 and N62 (history and view versions kept forever) stand as written, and P123
(commit keys kept forever) is not touched by the proposal at all.

The proposal, in short: a horizon for row and record history and one for view and group versions
are declared in the log, and the default is forever. The primary's pulses trim, at most a tree's
runtime per-op limit (`batch_value_count_limit`, from `batch_size_limit`, as backfill's pulse is
sized) per track per pulse: one scan per track in `prefetch`, tombstones in `commit`, and ordinary
compaction reclaims them. A forward cursor removes each change's predecessor, found by a link
written with the change (on disk only, in the groove's `.ignored` list, zeroed in replies). A
kind's `horizon_op` is the op of the newest object its cursor examined: as-of reads at or above
it are exact, reads below it answer `before_horizon`; history pages end at the cursor and the
next page is refused; the feed is refused from at or below its trimmed timestamp, the largest
removed. Retention of commit keys and of facts is proposed to be cut from R7, with the open
questions for keys listed in the brief.

**Why:** pulses are how Nerva already does bounded, deterministic background work in the log
(N52's backfill). Compaction-time filters cannot work, because append-only, timestamp-keyed
tables at the last level are never rewritten. Three review rounds found a double apply in every
design for trimming commit keys, so the brief cuts it rather than add mechanism. Recording the
brief as a proposal, not as amendments, keeps merged decisions from saying more than the owner
has agreed to.

**Cost:** nothing yet; the brief names its own costs (formats, a vendored patch, export and
import into R7's release, keyed loads still growing by their keys).

**Open, for the owner** (the brief's questions; the pull request that records the answers files
its own decisions under its own number):
- whether to cut keys' and facts' retention from R7, amending GOALS-1.0 goal 7's line,
  PRODUCTION.md's scope and goal and the README row (question 7);
- whether pulses replace PRODUCTION.md's "Compaction drops what is older" (question 6);
- whether trimming's lag is bounded as stated, by backpressure, or by a vendored patch to
  `replica.zig` (question 8);
- the feed below the horizon, the demo's time scale, the default horizon, `retention_min`, and
  when R7 starts (questions 2, 3, 4, 5 and 1). Amending N27 and N62 follows from the answers.
