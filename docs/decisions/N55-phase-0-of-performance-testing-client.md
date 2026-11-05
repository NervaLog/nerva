---
id: N55
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Phase 0 of performance testing: client round trips, a row cache flag, `zig build bench` and a load generator.

The rest of what the nightly performance job needs before it can measure anything:
- **Client round trips.** A primary records `client_request_round_trip` from each request's
  `previous_request_latency`, which the vendored `vsr.Client.request` always sent as 0.
  `src/nerva/client.zig` now builds its request messages itself (`send`, with the public
  `get_message` and `raw_request`), carrying the previous call's round trip in nanoseconds: a
  replica reads the field as nanoseconds before release 0.17.0, as microseconds after, and a
  comptime assertion fails if Nerva's release string ever crosses that line. No vendored change.
  Found on the way: only the primary records round trips (at prepare), while every replica
  records request timings (at commit); `test:integration` now has every replica send statsd.
- **`--cache-rows=<size>`** sizes the row object cache, which was fixed at its minimum (one set,
  a few hundred rows). Bytes are divided by the row size (128) and rounded down to whole sets;
  less than one set is refused. The default is unchanged: changing it is a measured decision for
  later.
- **`zig build bench`** runs every `benchmark:` test in benchmark mode, ReleaseSafe, from a
  separate test binary (the existing route, `-Drelease test -- "benchmark: …"`, still works).
  `Bench.metric` (a vendored addition) prints `bench-json:` lines for machines. Nerva's first
  benchmarks: `documents` (chunk encode with ids, and decode) and `declared views` (latest and
  as of a middle op). First numbers (ReleaseSafe, this sandbox): a 64 KiB document takes about
  0.69 ms to encode, nearly all of it the SHA-256 of each of its ~820 chunk ids.
- **`zig build bench:load`** (`src/bench_load.zig`): one thread and one blocking client per
  `--clients`, closed or open loop, workloads c1–c5, c3_adds and c7 of the plan, a log-linear
  `LatencyHistogram` (`src/nerva/latency_histogram.zig`, at most 1/16 relative error), one JSON
  object out. `--local` starts a three-replica `--development` cluster (at most 6 clients there).
  Built by `zig build check`, so it cannot rot. Not done: C6 (history of deep rows) and C8 (a
  replica crash), which belong to the harness that owns the processes.
- First local readings (4-CPU sandbox, `--development`, 5 s each): adds on four hot rows commit
  691 a second against 223 for read-modify-write with retries (541 conflicts). Lookups: one or
  two clients reach about 1,550 a second with p99 1.4–10 ms; four clients fall to 710 a second
  with p90 20 ms and p99 32 ms, in steps of the replicas' 10 ms tick. Either CPU contention (3
  replicas and 4 clients on 4 CPUs) or requests waiting on a replica tick: the first thing for
  the nightly job, on dedicated machines, to settle.
