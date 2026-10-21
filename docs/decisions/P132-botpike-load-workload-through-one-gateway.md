---
id: P132
date: 2026-10-21
area: "Milestone 3: positioned reads and the first views"
amends: N55
---

# `bench:load` has a `botpike` workload that goes through one `nerva api` gateway

The nightly (N55, N56) drove the cluster with direct Zig clients, 8 of them, and found about
250 requests per second at a 32 ms median whatever the entries per request. Botpike's app has no
direct clients: every submit goes through one `nerva api` gateway, which serves one request at a
time over one cluster session, with up to 12 requests in flight. The number that matters is the one
that path gives, so the generator gets a workload for it.

- **One submit is two requests**, as the app's `NervaLedger.submit` sends them: `POST /v1/lookup`
  of the rows the batch names, then `POST /v1/commit` under a fresh 16-byte `key`. Submits alternate
  per caller. A reserve reads (`op_seen` 0) and puts a new transfer row and moves an amount with a
  clamped add pair (`available` to `held`, `clamp`, `min` 0, the partner with `delta_from`). A settle
  reads the pending transfer at the version the lookup returned, reads and puts a new transfer row,
  and moves the amount with a pair from `held` to another account's `available`. Layouts and the
  ledger are declared, and the accounts funded from an unfloored source, through the gateway's own
  routes, in setup (idempotent, so a cluster may be used again).
- **`--clients` is the number of concurrent callers of one gateway**, one thread each, one
  connection per request (the gateway answers `Connection: close`), closed loop. `--keys` is the
  number of accounts, `--local` starts the three-replica `--development` cluster and one gateway, and
  `--nerva=<path>` names the binary the gateway runs from (the nightly passes each build's own). The
  result has the same JSON shape as the others: `operations` are submits, `requests` are HTTP
  requests (2 per submit; `requests_per_s` is new in every result), latency is per submit.
- **Rows, not records, for the transfer**, so that a submit's lookup is one request: a lookup reads
  rows or records, not both. Transfer ids and keys are random per run, so a second run against the
  same cluster does not meet the first one's rows.
- **The nightly runs it at 1 and 12 callers** (`botpike/b1/c1`, `botpike/b1/c12`), with the other
  workloads' thresholds (ops/s 10%, p50 15%, p99 25%). A build that predates the workload (the
  baseline, the first nights) is not asked for it: no result, not an error, and a metric only the
  candidate has is not compared.

Cost: the workload measures the gateway and the cluster together, so a slow gateway hides a faster
cluster; the direct workloads remain for that. It sends two requests per submit and ignores
retries after a conflict or a displaced connection (counted as `errors`). Local numbers on a
4-CPU sandbox (indicative, release build, `--development` cluster): about 155 to 160 submits/s at
1, 4 and 12 callers, so the gateway, not the callers, is the limit; medians of 6, 24 and 74 ms.
