---
id: P136
date: 2026-10-21
area: "Milestone 3: positioned reads and the first views"
---

# The primary's no-lag commit stall is `nerva start --commit-stall-probability`, default unchanged

The primary's commit path (`src/vsr/replica.zig`, vendored) has two stalls. They are different
things and only the first is configurable.

1. **The breathing-room stall.** When no backup is lagging (`commit_lag < commit_stall_lag_min`)
   and another prepare in the pipeline is already acked by all replicas, the primary delays the
   commit one tick (10 ms) with probability `commit_stall_probability`, so that backups catch up
   with the primary's commit. TigerBeetle's default is 2/5.
2. **The lag stall.** When a backup is lagging, the stall grows with the lag, 10 ms per quarter
   checkpoint, up to 40 ms. It is the safety valve that lets a lagged replica catch up. It is not
   touched here.

W2 of the throughput plan (#134) measured the first stall: with 8 clients about 94% of each op's
time is spent in it (about 4 ms an op; 250 ops/s at 8 clients, 580 at 4, 1,400 at 2) while one op
alone costs about 0.7 ms.

- **Decision.** `nerva start --commit-stall-probability=<numerator>/<denominator>` (a ratio from 0
  to 1; `0` never stalls) is passed to the replica's `commit_stall_probability`. The parser refuses
  a ratio above 1, a zero denominator and anything that is not `a/b` or `0`; `start_resolve`
  asserts the same. Nerva's own `cli.zig` now names the default, 2/5, so it is visible in Nerva's
  code and not only in the vendored fallback. No vendored file changes (the option already existed
  and `nerva_main.zig` passed null).
- **The default stays 2/5.** The flag changes no behaviour of an existing deployment. A different
  default needs measurements that backups keep up (no lag stalls, repair or view changes) and a
  VOPR run of the shipped value; the VOPR builds its replicas in `src/testing/cluster.zig`, which
  is vendored and passes no value, so exercising a value other than the default means patching
  that file (UPSTREAM.md, CLAUDE.md "Stop" 2). This decision does not do that.
- **Cost.** Another value is per replica: only the primary's value matters, and a replica of
  another setting speaks the same protocol. A lower value gives backups less breathing room, which
  the lag stall then has to absorb; 0 removes the first stall entirely.
