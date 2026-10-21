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
- **The default stays 2/5.** Measured on 3 `--development` replicas in one 4-CPU sandbox with 8
  direct clients (two interleaved passes), ops/s at stall 2/5, 1/5 and 0: one client class 246/243,
  473/465, 1199/1107; four 243/247, 511/510, 1756/959; adds 248/250, 471/469, 1455/1419; a 120 s
  run 248/244, 466/472, 1248/1296. p50 went from 31.7 ms to 14-17 ms to 5-6 ms, p99 from 70-74 to
  49-51 to 20-22 ms. Botpike through one gateway (1 and 12 callers) did not change beyond drift: a
  serial gateway never has two ops in flight, so the stall only matters once requests are batched
  (W5). At 0 no view change, sync or repair happened in 36 runs and replicas ended with equal
  `commit_max`, but "lagging behind" warnings rose from 0-13 a run (2/5) to 136-1,815, and one run
  reached a lag of 181 ops with 3,494 suspended prepares; the lag stall then fires 10-50 ms, up
  to about 40% of wall time. Lag at 1/5 was not measured. There is no gain for Botpike before W5
  and 0 lets backups fall behind, so the default is unchanged. Revisit it with W5, after a soak
  with a slow or killed backup and simulator coverage of the chosen value. The VOPR builds its
  replicas in `src/testing/cluster.zig`, which is vendored and passes no value, so it only ever
  runs the default; exercising another value means patching that file (UPSTREAM.md, CLAUDE.md
  "Stop" 2), which this decision does not do.
- **Cost.** Another value is per replica: only the primary's value matters, and a replica of
  another setting speaks the same protocol. A lower value gives backups less breathing room, which
  the lag stall then has to absorb; 0 removes the first stall entirely.
