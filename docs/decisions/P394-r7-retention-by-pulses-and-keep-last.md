---
id: P394
date: 2026-11-13
area: Releases
amends: N27, N62, P123
---

# R7's brief: retention is declared in the log and trimmed by pulses under a keep-last rule

The R7 brief (`docs/briefs/r7.md`) proposes how Nerva stops keeping the past forever. A horizon
per kind (commit keys, row and record history, view and group versions) is declared in the log;
the default is forever. The primary's pulses trim a bounded number of objects per pulse: reads in
`prefetch`, tombstones written in `commit`, reclaimed by ordinary compaction. Trimming is not
done at compaction time. A change or version is trimmed only if a newer one of the same row,
group or view is itself below the horizon (keep-last), so as-of reads at or above `horizon_op`
stay exact and reads below it answer `before_horizon`. A commit key is trimmed with its row;
once a key horizon is declared keys must be UUIDv7, and a key older than the horizon less
`skew_max`, or than what was trimmed plus `skew_max`, is refused as `key_expired`, never applied.

**Why:** pulses are how Nerva already does bounded, deterministic background work in the log
(N52's backfill). Compaction-time filters cannot work, because append-only, timestamp-keyed
tables at the last level are never rewritten. The keep-last rule keeps every current answer and
every as-of answer above the horizon exact. The key check needs only prepare timestamps, so it is
deterministic, and it proves a passing resend finds its row.

**Cost:** a vendored patch to `groove.zig` (removal from cacheless grooves) and a fuzzer for it.
Formats move (new trees, operations, statuses, flags, export v3, `format_epoch` 2), so the
release that ships R7 is reached by export and import (P259c). Clients must send UUIDv7 keys
once a key horizon is declared. This amends N27, N62 and P123 ("kept forever") only for clusters
that declare a horizon; the owner's answers to the brief's questions will be filed as P394b and
onward.
