# Test plan for v0.6.0: what this pull request could not test

Pull request #123 (commit keys, records, declared indexes, views over records) was tested in its
own session and by CI: unit tests, `test:api` (with `tests/api/records.py`), `test:views`,
`test:release` (an upgrade with records, export version 2), `test:integration`, `test:demo`,
the fuzz smoke run, and VOPR seeds with a workload that models records, facts committed with
ledger pairs, and indexes. Everything below needs something that session did not have: the
application, production scale, Docker, a published v0.5.0 cluster, or time.

Each item says what to run, what passes, and who runs it. Items 1 to 3 should pass before
Botpike's staging moves to v0.6.0; the rest before production holds facts in Nerva.

## 1. A real upgrade from v0.5.0 (owner, on `botpike-nerva-staging`)

`test:release` exports and imports between two builds of the same commit. A published v0.5.0
binary exporting a cluster that has run for days was not tested.

1. Snapshot staging's volumes. With v0.5.0's `nerva export`, export staging.
2. Stop the replicas; `nerva import` with v0.6.0 on each; start; then the gateways.
3. **Pass:** `nerva import` prints "checks passed" on every replica; `/status` on the app says
   conserved; the app's ledger ITs against staging (`LEDGER=nerva`) pass; every account's
   balance equals its balance before the export (compare `/v1/lookup` of every account row, as
   of the export's op).
4. Restart one replica with v0.5.0 against the v0.6.0 cluster. **Pass:** it is ignored (N61) and
   the cluster keeps committing.
5. Memory: **pass** if each replica's RSS stays under its Fly Machine's memory with 25 % to spare
   after an hour of traffic. Measured here at startup, default settings: 2.5 GB with v0.5.0, 3.0
   GB with v0.6.0, 2.5 GB with v0.6.0 and `--cache-grid=512MiB` (#127). On a 4 GB Machine that
   also runs the gateway and the metrics exporter, 3.0 GB leaves no such headroom: either
   resize the Machines or lower `--cache-grid` first, and compare read latency both ways.
6. Before exporting, list tables from `2147483648` up on v0.5.0 (`/v1/changes`): there must be
   none (#126).

## 2. The application's money with its facts (Botpike/app, after the app adopts records)

Nothing in Botpike/app uses commit keys, records or indexes yet. When `NervaLedger` does:

1. Replace app P99's read-back-and-resend with a commit key per logical operation.
   **Pass:** the app's lost-reply ITs (gateway killed after send) move each amount exactly once
   and never mark an execution failed that committed.
2. Write one fact (execution, attempt, receipt) per money transaction, in the same `/v1/commit`.
   **Pass:** an IT that fails the money half (out_of_bounds, unpaired) finds no fact; one that
   commits finds the fact at the same op as the transfer.
3. The reaper's scan (`status == reserved`, by `created`) through an index, against Postgres's
   answer for the same data. **Pass:** identical sets, every tick, for a day of staging traffic.

## 3. Jepsen with keys and records (Docker, JDK, lein: `tests/jepsen/`)

The Jepsen suite exercises rows only. Extend its workload so each operation is a keyed
`/v1/commit` of a ledger pair plus a fact record, resent on timeouts with the same key.

- **Run:** `tests/jepsen/run.sh zig-out/bin/nerva test --nemesis kill,partition` for an hour.
- **Pass:** the checker finds no lost or doubled operation (each key's fact exists at most once,
  and exists exactly when the money moved), the ledger total stays zero, and every index scan
  taken during the run equals the records as of its op.

## 4. Scale and performance (the nightly A/B run, N56; owner to schedule)

Not measured: throughput and latency with 512-byte records, the cost of four indexes per table
in every commit, compaction with the new trees, and disk growth.

- `bench-load` with 10⁸ records over 30 days' equivalent of writes, four indexes on the table.
- **Pass:** commit p99 within 2× of rows-only at the same entry count; an index scan of 100
  records under 10 ms; no compaction stall over 1 s; disk per record within 3× of
  (512 bytes + 128 bytes per index) after compaction.

## 5. Longer VOPR runs (CI's `vopr_main`, N74, after merge)

This session ran seeds by hand and a 30-minute loop. The ReleaseSafe run of about 300 seeds on
`main` after the merge is the real coverage. **Pass:** no failing seed. Coverage to read in the
summaries: `records committed`, `facts committed`/`failed`, `scans ready`, `records checked`,
`counts checked` all above zero across the run.

## 6. Retention (a later decision)

Keys, facts and index entries are kept forever. Before production holds facts in Nerva, measure
how fast staging's data file grows per day and decide retention (README "Object storage
tiering"). Nothing to pass yet: a number to decide with.
