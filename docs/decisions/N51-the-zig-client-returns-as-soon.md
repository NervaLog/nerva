---
id: N51
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# The Zig client returns as soon as its reply arrives, not at the end of a 10 ms tick.

Every call through `src/nerva/client.zig` (so every `nerva api` and `nerva view` request) took at
least 10 ms: the client waited with `IO.run_for_ns(tick_ms)`, which runs callbacks as completions
arrive but always waits out its deadline. Measured on a local three-replica `--development`
cluster through `nerva api`, 200 requests each:

| | before: min / p50 / p99 | after: min / p50 / p99 |
|---|---|---|
| lookup | 10.37 / 10.60 / 12.86 ms | 0.59 / 1.05 / 1.64 ms |
| commit | 10.38 / 10.53 / 11.37 ms | 0.62 / 0.92 / 1.55 ms |

This was most of N38's "about 11 ms per request".
- The vendored IO had no public call that waits for the next completion and returns: `run`
  never blocks, `run_for_ns` never returns early. `IO.run_once(nanoseconds)` (Linux) submits,
  waits up to `nanoseconds` for a completion, runs every ready callback and returns. A minimal
  patch, listed in UPSTREAM.md. On macOS and Windows it calls `run_for_ns`: correct, only as slow
  as before; a kqueue version would need a timeout completion that outlives the call.
- The client still ticks its VSR client every `tick_ms` by the monotonic clock (VSR's timeouts
  count ticks), and between ticks waits with `run_once` until the next tick or the call's
  deadline, checking its state after every callback.
- Rejected: polling `run_for_ns` in short slices. No vendored change, but it spins thousands of
  syscalls a second while waiting and still leaves a floor.
- Tests: an IO unit test (a 1 ms timeout ends a 10 s `run_once` within 1 s; an idle `run_once`
  waits its duration); `test:integration` asserts the median of 50 lookups is under one tick
  (1.4 ms locally). Mutation-tested: with `run_once` waiting out its duration, both fail (the
  median becomes 10.2 ms).
