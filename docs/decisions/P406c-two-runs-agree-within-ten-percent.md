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

The reason: 10% is PRODUCTION's bound. At about 150 submits a second for 300 s, p99.9 rests on
about 45 samples, so checking it would fail on noise; memory is fixed at start and should repeat
almost exactly.

What it costs: the tail beyond p99 is reported but not held to a bound.
