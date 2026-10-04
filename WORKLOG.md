# Worklog

Chronological log of completed work items. The previous Kotlin/PostgreSQL implementation of Nerva
is preserved on branch `kotlin-archive` (commit `641a882`).

---

## 2026-10-04

- Reset the repository for the new Nerva: a log-centric database with declared derived state
  (design in README.md). Previous code archived on branch `kotlin-archive`.
- Vendored TigerBeetle at `6f8e6b5` (consensus, LSM storage, IO, tracing, VOPR simulator); dropped
  the accounting state machine, clients, CDC, REPL, Vortex and release tooling. All local patches
  are listed in UPSTREAM.md.
- Added `src/nerva.zig` (public `Operation` and `tree_ids`) and `src/nerva/state_machine.zig`, a
  placeholder echo state machine seeded from TigerBeetle's testing state machine.
- Rewrote `build.zig` (check, test, test:unit, test:fmt, vopr, fuzz).
- Added `zig/download.sh` for pinned Zig 0.14.1, with a PyPI fallback for sandboxes where
  ziglang.org is blocked.
- Added README.md, CLAUDE.md, UPSTREAM.md, NOTICE; adopted TIGER_STYLE.md as the coding style.
- Verified: `zig build check`, `zig build test:fmt` pass; `zig build test:unit` 262/263 pass (the
  one failure is the perf-counter test, denied by the sandbox and failing identically upstream);
  VOPR passes with the Nerva state machine (seeds listed in the commit message).

## 2026-10-04 — Commit core

- Defined the commit core's wire and storage types in `src/nerva.zig`: `Row` (128 bytes, 80-byte
  value, version = op of last write, tombstone flag), `Entry`/`EntryResult`, `RowKey`/`RowValue`,
  `ChangesFilter`/`Change`, and the operations `lookup_rows`, `commit`, `get_changes`. Replaced
  the placeholder `echo` operation and `Thing` tree ids (nothing was persisted yet).
- Implemented `src/nerva/state_machine.zig`: rows keyed by `(table, id)`; one batch = one
  transaction with per-entry results; optimistic validation of read versions; static entry
  validation; duplicate-write detection by sorting in preallocated scratch space; deletes as
  tombstones (upstream `Groove.remove` is untested and verify-only); an append-only change groove
  scanned by timestamp for `get_changes`.
- Added `src/nerva/state_machine_tests.zig` (8 deterministic tests) and
  `src/nerva/workload.zig`: a VOPR workload that checks every reply, in op order, against an
  in-memory model (statuses, versions, values, change feed).
- Bugs found by the simulator and fixed: a version assertion that was too strict when two
  transactions in one request write the same row (regression test added); two workload
  generator bugs (lookup replies exceeding the message size; a duplicate check on a deliberately
  invalid entry).
- Updated the `trace.zig` snapshot (tree id 1 is now `Row.timestamp`), README (commit core
  section, roadmap) and UPSTREAM.md.
- Verified: `check` and `test:fmt` pass; `test:unit` 272/273 (only the sandbox-denied perf
  test fails); VOPR passes seeds 1–9 and 42 (seed 8 ran 2.49M ticks; seed 1 checked 90
  committed and 56 failed transactions and 185 changes against the model).

## 2026-10-04 — 1.0 design goals

- Added `docs/GOALS-1.0.md`: Nerva 1.0 design goals (G1–G8), with Botpike as the first customer;
  each goal maps to a gap Botpike's own docs name. Linked from README.md and CLAUDE.md.

## 2026-10-04 — 1.0 Milestone 1: the receipt race

- `src/nerva/workload.zig`: Botpike's receipt race. Clients race over 1–4 receipts (table 100);
  a claim is `read` at the version seen + `put` of `{seq + 1, owner}`. Independently of the row
  model, the checker asserts each receipt's sequence advances by exactly one per winning claim,
  and that losing claims fail only with `conflict`. Logs claims won/lost.
- `src/nerva/state_machine_tests.zig`: two deterministic cases (simultaneous claims: exactly
  one wins; hand-off with the new version wins, stale retry loses).
- No state machine changes: G3 was already delivered by the commit core.
- Verified: `test:unit` 274/275 (only the sandbox-denied perf test fails); `test:fmt` passes;
  VOPR passes seeds 1–9 and 42 with 215 claims won and 474 lost in total (seed 5: 3.49M ticks).
- Marked G3 demonstrated and Milestone 1 done in `docs/GOALS-1.0.md`.

## 2026-10-04 — 1.0 Milestone 2a: server binary and Zig client

- `src/nerva_main.zig`: the `nerva` binary (`format`, `start`, `version`), trimmed from
  TigerBeetle's `main.zig`; single release, no AOF. `--addresses=0` prints an ephemeral port and
  exits when stdin closes.
- `src/nerva/cli.zig`: arguments via the vendored `stdx.Flags`; validation in pure functions
  (`format_validate`, `start_resolve`) with unit tests.
- `src/nerva/client.zig`: a blocking client over the vendored VSR client — `lookup_rows`,
  `commit`, `get_changes`; all memory allocated in `init`; `Evicted`/`Timeout`/`TooManyEvents`.
- `src/integration_tests.zig` + `zig build test:integration`: three real replicas on local ports;
  blind put and lookup, stale-read conflict, the receipt race between two clients, change-feed
  paging, a replica crash, and a restart that must catch up before reads succeed. It is an
  executable, not a `zig test`, because test binaries use the `test_min` config and the client
  must match the server's production config (found when the client rejected the server's batch
  size limit).
- Docs: README (running a cluster, roadmap), CLAUDE.md, UPSTREAM.md (derived files, build.zig),
  GOALS-1.0.md (2a done; 2b is the HTTP/JSON gateway).
- Verified: `check`, `test:fmt` pass; `test:unit` 276/277 (only the sandbox-denied perf test
  fails); `test:integration` passes three times in a row with no leftover processes; VOPR
  seed 1 replays identically (91,649 ticks).

## 2026-10-04 — 1.0 Milestone 2b: `nerva ledgerd`

- Read Botpike/runtime and Botpike/app: the runtime already speaks a small ledger protocol to a
  pluggable backend (`ledger/ledgerd.py`, Botpike's `/runtime-ledger`). Chose to serve that
  protocol from Nerva instead of inventing a JSON API. Started `docs/DECISIONS.md` (N1–N20).
- `src/nerva/ledgerd/routes.zig`: a port of `ledgerd.py`'s sixteen routes over a store interface,
  including Python-compatible UTF-8 replacement and its write-before-error behaviour (N18).
- `src/nerva/ledgerd/store.zig`: one Nerva transaction per route; values chunked over 80-byte
  rows with SHA-256-derived ids (collision-checked); generations for `admin/init`; read set with
  versions; conflict → retry.
- `src/nerva/ledgerd/server.zig` + `nerva ledgerd`: sequential HTTP server (std.http), key from
  `LEDGER_KEY`, jittered backoff on conflict (N20).
- `tests/ledgerd/`: oracle copy of `ledgerd.py` (runtime commit 23010ba), `conformance.py`
  (differential, byte-identical, scripted + seeded fuzz, ledger isolation) and `race.py` (two
  gateways, money conservation, single claims, retries exercised). `zig build test:ledgerd`.
- Found by the race test and fixed: a hot `journal.count` row (N19) and retry storms (N20).
- Verified: conformance 5 seeds × 2,000 fuzzed requests byte-identical; race passes repeatedly
  (8 and 16 threads); harness mutation-tested (a one-space journal change is caught);
  `test:unit` 284/285 (sandbox perf test); `test:integration` passes.

## 2026-10-04 — 1.0 Milestone 3: positioned reads and the first views

- Core: `RowValue.op_read`, the op a lookup executed at (G2); the VOPR checker asserts it is
  shared by a request's results and increases with op order.
- ledgerd rows: chunk 0 records ledger and generation; tail chunk ids derive from chunk 0's id,
  so a view holding only rows can reassemble values (N25).
- `src/nerva/view/`: a feed follower (pages `get_changes`, groups by op, applies complete ops,
  keeps a watermark), the ledgerd views (`journal` in commit order; `spend`, Botpike's agent
  spend rollup over runtime request ids), and `nerva view` (HTTP, `min_op=<n|latest>`, 504 if
  not reached in 10 s).
- `tests/ledgerd/views.py`: journal equal to the oracle's `journal.log`, spend equal to a rollup
  recomputed from the oracle's `ledger.txt`, same answers after a view restart, 504 past the
  watermark. Mutation-tested (dropping denied counts is caught).
- Decisions N21–N26 in docs/DECISIONS.md.
- Verified: `test:unit` 287/288 (sandbox perf test); `test:integration`; `test:ledgerd`
  (conformance, race, views); views over seeds 1–4; VOPR seeds 1, 2, 5 replay with identical
  tick counts.

## 2026-10-04 — 1.0 Milestone 4 (part): as-of reads and agent state

- Core: `get_history` (operation 131), one row's changes newest first, with `op_max` (as of)
  and a counting-down cursor. Served from a derived index on the change feed (`Change.row_key`,
  tree id 4); `Client.get_history` and `Client.row_as_of` (N27).
- VOPR: random histories checked against the model's change list; mutation-tested (an
  off-by-one in the `op_max` filter is caught).
- ledgerd: `store.get_as_of` reads a key as of an op (generation, chunk 0 and tails, each as of
  that op). `nerva view` serves `GET /v1/ledgers/<ledger>/as_of?op=&key_hex=`, and journal
  lines are now `line=<op>:<hex>` (N28).
- ledgerd: `/v1/store/get` and `/v1/store/put` for the runtime's `Store` ability, in
  `table_store` (1002), outside generations (N29).
- Tests: `views.py` re-reads 65 snapshots of `ledgerd.py`'s files as of their ops (about 2,600
  reads; mutation-tested: ignoring the op is caught). The new `store.py` covers a model,
  `admin/init`, concurrent writers and a staged suspend (mutation-tested: storing in the ledger
  table is caught). Integration test reads as of ops before and after a replica restart.
- Not built, waiting on a decision: approval attribution and a claim lease (N30).
- Verified: `test:unit` 289/290 (sandbox perf test); `test:fmt`; `test:integration`;
  `test:ledgerd` (conformance, race, views, store); VOPR seeds 1, 2, 5, 11.

## 2026-10-04 — Botpike integration guide

- `docs/BOTPIKE-INTEGRATION.md`: instructions for a coding bot working in Botpike's repositories.
  Ground rules (dog-fooding, no real money, Nerva as a pinned dependency); building and running
  Nerva; phase 1 (`nerva ledgerd` as the runtime's HTTP ledger, accepted by an identical demo
  transcript); phase 2 (a `Store.http` handler, with `daemon.key`/`daemon.pub` kept local and
  `$STATE/.lock` kept); phase 3 (read-only views and `as_of`); how to report findings.
- The runbook was run from scratch: release build, a one-replica `--development` cluster (1.1 GiB
  data file, ~850 MB resident), the gateway, the view, smoke requests, `as_of` at three ops, a
  restart of every process.
- Found while writing it: the runtime reads its Ed25519 signing key through `Store`, so a
  Nerva-backed `Store` must keep `daemon.key` in local files.
- Decision N31: Botpike is dog-fooding, not a specification.

