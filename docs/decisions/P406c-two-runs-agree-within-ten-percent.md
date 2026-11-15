---
id: P406c
date: 2026-11-13
area: Testing
---

# Two R3 runs agree when ops/s, p50 and p99 are within 10% and memory within 1%

`perf/topology/same.py` compares two runs of one commit: every workload's ops/s, p50 and p99
within 10%, and each replica's allocation and RSS within 1%. p99.9 and max are printed beside them
and not checked. Runs that disagree are a finding (where the noise comes from), never re-run until
they pass.

- "Within" is `|a − b| / min(a, b)` at most 0.10 (0.01 for memory): strict and symmetric.
- p50 and p99 are `LatencyHistogram` bucket upper bounds, 3.1 to 6.25% apart (16 buckets per
  power of two): one bucket's difference always passes, two may fail. `same.py` prints each
  value's bucket width; the bound is not widened for it.
- The two runs are those of one `perf-r3.yml` dispatch with `runs=2`, back to back on the same
  VMs, so they measure minutes-apart noise on those VMs, not VM-to-VM or day-to-day variance; the
  README says so. The first such dispatch on the delivered commit counts; `docs/demos/r3.md` lists
  every dispatch on that commit, failures included, and a later one counts only if the owner
  waives the first in writing.

The reason: 10% is PRODUCTION's bound. At about 150 submits a second for 300 s, p99.9 rests on
about 45 samples, so checking it would fail on noise; memory is fixed at start and should repeat
almost exactly.

What it costs: the tail beyond p99 is reported but not held to a bound.
