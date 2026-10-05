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

- Added `docs/GOALS-1.0.md`: Nerva 1.0 design goals (G1–G8), each mapped to a gap of the
  motivating workload (agent budget services). Linked from README.md and CLAUDE.md.

## 2026-10-04 — 1.0 Milestone 1: the receipt race

- `src/nerva/workload.zig`: the receipt race. Clients race over 1–4 receipts (table 100);
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

## 2026-10-04 — 1.0 Milestone 2b: an application-specific gateway (since removed)

- Built an HTTP gateway for one application's existing ledger protocol, with differential tests
  against its reference implementation, and started `docs/DECISIONS.md` (N1–N20). Removed in
  N39; the chunked storage it introduced lives on in `documents.zig`.

## 2026-10-04 — 1.0 Milestone 3: positioned reads and the first views

- Core: `RowValue.op_read`, the op a lookup executed at (G2); the VOPR checker asserts it is
  shared by a request's results and increases with op order.
- Chunked values: tail chunk ids derive from chunk 0's id, so a reader holding only rows can
  reassemble values (N25).
- `src/nerva/view/`: a feed follower (pages `get_changes`, groups by op, applies complete ops,
  keeps a watermark) and `nerva view` (HTTP, `min_op=<n|latest>`, 504 if not reached in 10 s),
  first with two application-specific views (since replaced by declared views, N39).
- Decisions N21–N26 in docs/DECISIONS.md.
- Verified: `test:unit` 287/288 (sandbox perf test); `test:integration`; VOPR seeds 1, 2, 5
  replay with identical tick counts.

## 2026-10-04 — 1.0 Milestone 4 (part): as-of reads

- Core: `get_history` (operation 131), one row's changes newest first, with `op_max` (as of)
  and a counting-down cursor. Served from a derived index on the change feed (`Change.row_key`,
  tree id 4); `Client.get_history` and `Client.row_as_of` (N27).
- VOPR: random histories checked against the model's change list; mutation-tested (an
  off-by-one in the `op_max` filter is caught).
- The gateway of the time gained as-of reads of its keys and a key-value route for workflow
  state (N28, N29; both removed in N39).
- Integration test reads as of ops before and after a replica restart.
- Not built, waiting on a decision: approval attribution and a claim lease (N30).
- Verified: `test:unit` 289/290 (sandbox perf test); `test:fmt`; `test:integration`; VOPR seeds
  1, 2, 5, 11.

## 2026-10-04 — An integration guide (since moved out)

- Wrote a guide for integrating the dog-fooding application, and ran its runbook from scratch:
  release build, a one-replica `--development` cluster (1.1 GiB data file, ~850 MB resident),
  smoke requests, a restart of every process. The guide now lives outside Nerva (N39).
- Decision N31: dog-fooding, not a specification.

## 2026-10-04 — CI and releases

- `.github/workflows/ci.yml`: typecheck, format, unit, integration, gateway suites, and VOPR
  seeds 1, 2, 5 and one random seed, on every push and pull request to `main`.
- `.github/workflows/release.yml`: on a `v*` tag, CI on that commit, then binaries for four
  targets, `SHA256SUMS`, and a GitHub release (prerelease if the tag contains `-`).
- Decision N32. The integration guide now prefers a pinned release binary over building.
- Checked locally: both workflows parse and pass `actionlint`; all four targets cross-compile
  from Linux; the step commands are the ones run throughout this session. The first run on
  GitHub is the real test.

## 2026-10-04 — Phase 2, step 1: the JSON API

- `src/nerva/api/`: `nerva api` serves `lookup`, `commit`, `changes`, `history` and `row`
  (as of an op) as JSON over HTTP (N33). Unit tests use an in-memory fake client.
- `tests/api/api.py` (`zig build test:api`, and in CI): random transactions through two
  gateways checked against a model (statuses, conflict index and version, ops), lookups, the
  whole change feed, every row's history at random `op_max`, as-of reads, a refusal for a future
  op, eight writers racing on one counter with retries (no increment lost), 401/404/405.
- Found by the test and fixed: `row?as_of=` answered for an op not yet committed.
- Mutation-tested: an off-by-one in `op_max` parsing is caught. Seeds 1, 2 and 3 pass.

## 2026-10-04 — Phase 2, step 2a: table layouts

- `src/nerva/catalog.zig`: layouts (parse, validate, pack, render, extend-only check), fields
  to and from 80-byte values, field values as integers for views (N34).
- `nerva api`: `PUT`/`GET /v1/tables/<t>`; puts by `fields`; `fields` in lookups, the feed,
  history and `row`; reserved tables refused and left out of the feed.
  `src/nerva/api/catalog_store.zig` keeps layouts in the log as chunked documents.
- Tests: unit tests for layouts and for the API with an in-memory catalog; `tests/api/api.py`
  adds layouts end to end, including two gateways declaring at once.

## 2026-10-04 — Phase 2, step 2b: declared views

- `catalog.zig`: view declarations (parse, check against a layout, canonical form).
- `nerva api`: `PUT`/`GET /v1/views/<name>`, stored in the catalog, immutable.
- `src/nerva/view/declared.zig`: mirrors the catalog and application tables from the feed;
  computes views latest or as of any op, with a SHA-256 hash (N35).
- `nerva view`: `GET /v1/views` and `GET /v1/views/<name>?min_op=|as_of=`; NERVA_KEY.
- `tests/views/declared.py` (`zig build test:views`, in CI): two views (one declared halfway)
  against a model at sampled ops on two view processes, hashes recomputed and equal, a
  restarted view process, declaration errors, 504 past the op. Mutation-tested (replaying one
  op short is caught).

## 2026-10-04 — Phase 2, steps 3 and 4: the crash supervisor and the seat demo

- `demo/cluster.py`: three replicas, `nerva api`, two `nerva view`; crash (SIGKILL, keeping
  quorum) and restart. `demo/nerva_http.py`: a client that never retries a commit.
- `demo/seats/`: the seat race server (venue, views, simulated buyers, visitor endpoints,
  self-healing) and page (seat map, rewind slider, crash controls, hash agreement, declare a
  view). Checked in a browser with Playwright: live, after a crash, rewound, after declaring a
  view, dark mode, phone width (no horizontal scroll).
- Found and fixed: the gateways' keep-alive starvation (N37); the view's `/healthz` is text;
  SIGTERM orphaned the cluster; `buy()` asserted on a 503 during recovery.
- `tests/demo/seats_chaos.py` (`zig build test:demo`, CI job `demo`): a minute of random
  crashes; no double sale, confirmed sales in the map, views agree, nothing left running.
  Mutation-tested with blind writes.

## 2026-10-04 — Phase 2, step 5: the shared canvas

- `demo/common.py`: the shared demo base (setup, views, agreement, visitor views, rate limits,
  safe handler, `run`); the seat server now builds on it.
- `demo/canvas/`: the canvas server (typed pixels, three views, simulated painters, timelapse
  frames, hourly clear) and page (paint, play, rewind, crash, declare). Checked in a browser
  with Playwright: painting, the timelapse playing, dark mode, phone width.
- Found while profiling: `ArrayHashMap.sort` is insertion sort (O(n²)); declared views use
  `sortUnstable` (4,096 groups: 145 ms to 10 ms). Gateways set `TCP_NODELAY`.
- `tests/demo/canvas_chaos.py`, in `zig build test:demo` with the seat test: confirmed paints
  are on the canvas as of their ops, under crashes. Mutation-tested.
- Decision N38. Moderation defaults await the owner's policy (task 6).

## 2026-10-04 — No application-specific code (N39)

- Removed the application-specific gateway (routes, key-value routes, server), its two views,
  its differential and race tests (with the copy of the application's reference
  implementation), its build and CI steps, and the integration guide.
- `src/nerva/documents.zig`: chunked documents in optimistic transactions, now used by the
  catalog (`api/catalog_store.zig`) and decoded by declared views; new id vector pinned.
- `nerva view` serves declared views only, all replies JSON, key from `NERVA_KEY`.
- Docs: GOALS-1.0 describes the motivating workload without naming it; superseded decisions keep
  their numbers; README, CLAUDE.md, UPSTREAM.md updated.
- Verified: `test:unit` (all but the sandbox perf test), `test:api`, `test:views`, `test:demo`
  (both demos under crashes).

## 2026-10-04 — Releases by commit; v0.1.0

- `.github/workflows/release.yml`: a commit to `main` that changes `VERSION` releases
  `v<VERSION>` (semver check, refuses an existing tag, full CI, four targets, `SHA256SUMS`, tag
  created on that commit). Tag pushes no longer release (N40).
- `VERSION`: `0.1.0`, the first release.


## 2026-10-04 — Documents in the generic API (N41)

- `nerva api` serves documents (values up to 64 KiB under string keys, per namespace) in the
  reserved table `0xFFFF0002`: `POST /v1/documents/get` (latest or `as_of`),
  `POST /v1/documents/commit` (reads at a version, puts and deletes, `409` naming the key), and
  `GET /v1/documents/changes` (decoded document writes, pages ending at op boundaries).
  Code: `src/nerva/api/documents_routes.zig`.
- `documents.zig`: deletes are tombstones (a `deleted` flag in chunk 0's header, which was
  reserved), so the feed names deleted keys; headers are checked strictly.
- Fixed in `client.zig`: an oversized request left the client marked busy, so the next request
  panicked. The check now comes first.
- `tests/api/documents.py`, run by `zig build test:api` after `api.py`: random transactions in
  two namespaces against a model, reads latest and as of, feeds with small pages, limits, and
  an eight-thread counter race on one document. Mutation-tested: reading tail chunks without
  checking their version, and pages that split an op, both fail it.

## 2026-10-04 — Adds: conditional operations for hot rows (N42)

- `src/nerva.zig`: `EntryKind.add`, `Add` (parameters in the entry's value), `add_amount` and
  `add_apply` (the shared arithmetic), four new statuses, and a 32-byte `EntryResult` with
  `applied` and `value`.
- `src/nerva/state_machine.zig`: adds are resolved in entry order against the rows and the
  transaction's earlier adds (a preallocated scratch map, looked up only), then applied as puts
  of the whole row. Several adds may share a row; `delta_from` is checked statically.
- Fixed: a write that leaves a row's bytes unchanged within one op (two identical puts in one
  request, or an add of nothing) crashed the groove; it now skips the update. Regression test.
- `nerva api`: `"kind": "add"` by field name or offset and type; replies list each add's
  `applied` and `value`; `409` for `out_of_bounds` and `row_absent`.
- VOPR workload: random adds in the model, and hot budgets with an independent conservation
  check. `tests/api/adds.py` (in `test:api`): fifty threads reserving and releasing on one
  budget, never retried. Mutation-tested: a clamp that under-takes and a `delta_from` that
  does not negate both fail the tests.
- Open for the owner: whether to bump the release string for the protocol change (N42).
- Release string `0.0.2` (N43, owner's decision): replicas refuse older clients; v0.1.0 data
  files (superblock version 0, TigerBeetle's development format for `0.0.1`) must be
  reformatted. Golden format checksum updated for that reason only. Release notes take the
  binary's version from the binary.
- CLAUDE.md: every pre-existing bug found gets a GitHub issue (#4, #5 filed).

## 2026-10-04 — Release notes from CHANGELOG.md (N44)

- `CHANGELOG.md`: a "what's new" section per release (v0.2.0, and v0.1.0 after the fact).
- `release.yml` publishes the version's section as the release notes and refuses a version
  without one (`.github/scripts/release_notes.sh`); CLAUDE.md and README describe the step.

## 2026-10-04 — Release v0.2.0

- `VERSION`: `0.2.0`. Documents (N41), adds (N42), the protocol release `0.0.2` (N43, data
  files from v0.1.0 must be reformatted), fixes #4 and #5. Notes: CHANGELOG.md.

## 2026-10-04 — Gateway hardening (N45; #8, #9, #10)

- `src/nerva/http_connection.zig`: a strict request-head parser (`head_parse`), a constant-time
  key check (`key_matches`), and a `Receiver` that reads up to 16 connections at once with a
  total 10 s deadline per request and hands out complete requests one at a time. Replaces
  `std.http.Server` in both gateways.
- `nerva api` and `nerva view` serve from the `Receiver`; their handlers return replies as
  values. `nerva view` answers 504 at once for an op not yet committed, after one `catch_up`,
  instead of waiting up to 10 s on its only thread.
- Fixed #8 (a bare-LF head crashed both gateways before auth), #9 (a slow client stalled a
  gateway; the deadline was per read) and #10 (key compared in variable time).
- Tests: unit tests for `head_parse`, `key_matches` and the `Receiver` on loopback;
  `tests/api/api.py` sends malformed heads and a dripping client alongside normal ones;
  `tests/views/declared.py` checks the immediate 504, a dripping and a malformed client.

## 2026-10-04 — Fuzzing runs again; Nerva's first fuzzers (N46; #6)

- `src/trace/event.zig`: the tree enum names placeholders for unused ids up to 15, so the
  vendored `lsm_scan` fuzzer no longer panics and `fuzz -- smoke` runs all its fuzzers (#6).
- `src/nerva/adds_fuzz.zig`, `http_head_fuzz.zig`, `documents_fuzz.zig`, registered in
  `src/fuzz_tests.zig` with smoke sizes: adds' arithmetic against an independent reference,
  the gateways' head parser and key check, and document chunking.
- Verified: `fuzz -- smoke` passes; each new fuzzer passes 20 random seeds; deliberate bugs
  (an off-by-one clamp, a dropped last byte, control bytes or a repeated key accepted in a
  head) each fail their fuzzer, then were reverted. A bare CR accepted is not caught, and is
  harmless: the other checks refuse it (N46).
- Smoke reports the vendored `lsm_segmented_array` as slow in Debug (about 20 s against its
  10 s budget); it is a warning, not a failure, and smoke never reached it before this fix.

## 2026-10-04 — Repository renamed to `Botpike/nerva-ledger`

- The repository moved from `topwombat/nerva` to `Botpike/nerva-ledger`; CLAUDE.md's issue rule
  names the new home. (GitHub redirects the old name for now.)

## 2026-10-04 — CI on Botpike's own runners (N47)

- `.github/workflows/ci.yml`, `release.yml`: every job `runs-on: [self-hosted, fly]`, the Fly
  Machines of Botpike/ci-runners, instead of `ubuntu-latest`. Steps unchanged.
- Verified on the pull request's own CI run: unit tests (the perf test skips), integration,
  API, views, demos and the four VOPR seeds pass on the new runners.

## 2026-10-04 — Consistent document reads in `documents.Transaction` (N48; #7)

- `src/nerva/documents.zig`: `Transaction.get` reads every tail chunk at chunk 0's version,
  from history when a rewrite landed between its two lookups, and records every chunk as read
  at that version. `Transaction` is `TransactionType(Client)`, so tests can use a stub client.
- Tests: a rewrite between the lookups (fails with the previous code: a value stitched from
  two versions), a read with no race, and a tail older than chunk 0.

## 2026-10-04 — VOPR workload: exact ops, unsent inputs, limits, cursors (N49)

- `src/vopr.zig` passes the op each request committed at; `src/nerva/workload.zig` checks
  replies against it exactly. The testing workload takes the argument, unused.
- The workload generates `op_seen` on writes, kind zero, `reserved_a`/`reserved_c`, future
  reads, `RowKey.reserved`, and invalid feed and history filters (reserved bytes, timestamps
  past `maxInt(u63)`); checks `entry_validate` against the documented rules
  (`entry_status_check`); reaches `changes_limit_max` and past it, full lookup batches and
  full commit batches; and continues from cursors that incomplete replies returned.
- Short-log VOPR runs print the workload's summary, with coverage counters.
- Verified: seeds 1, 2, 5 and 20 random seeds pass; across them 38 full batches, 171 invalid
  entries, 117 future reads, 26 invalid filters, 115 clamped limits, 48 cursors continued.
- Planted bugs, each caught on seeds chosen for exercising it (then reverted): `op_read`
  reported one op late (4/4 seeds; only the exact-op check catches it), `RowKey.reserved`
  ignored (4/4), `ChangesFilter.reserved` unchecked (2/4), the limit clamp removed (4/4) or
  off by one (4/4; the simulator's small messages make `changes_limit_max` a few dozen, within
  any run's feed), and a put carrying `op_seen` accepted (3/4; only `entry_status_check`
  catches it, as the model shares `entry_validate`).

## 2026-10-04 — Fly.io feasibility probe for nightly performance tests

- `perf/fly/`: `run-probe.sh` creates one Machine and a volume in the `nerva-perf` Fly app,
  builds `Dockerfile` (the `nerva` binary, `fio`, `perf`) with Fly's remote builder, runs
  `probe.sh` at boot, prints its report, and destroys the Machine and volume on exit, failure
  included. It answers the performance plan's Phase 0 questions about the hardware.
- Probe results (performance-4x, 10 GB volume, `iad`, binary `0.0.1+3a01765`): production
  config (Direct IO) formats and starts on the volume; three replicas and `nerva api` work on
  Fly's private IPv6 addresses; `perf_event_open` works with hardware counters; the volume
  delivers about 16,500 IOPS and 65 MiB/s, exactly Fly's documented cap for that size. Nightly
  throughput runs will be IO-capped on Fly and are judged on write amplification instead.
- Not part of the build or CI; it needs `flyctl` and `FLY_API_TOKEN`.

## 2026-10-04 — Metrics and traces from replicas (N50)

- `nerva start --statsd=<host:port>` sends the replica's metrics (statsd over UDP, every 10 s)
  and `--trace=<path>` writes its JSON span trace. `src/nerva/cli.zig` parses and validates
  both (`statsd_parse`, `error.StatsdAddressInvalid`, `error.TracePathEmpty`);
  `src/nerva_main.zig` hands them to the vendored tracer. No vendored file changed.
- README: "Metrics and traces", with the metrics the performance plan reads.
- Tests: `statsd_parse` and `start_resolve` unit tests; `test:integration` checks that replica 0's
  statsd packets carry request, commit and cache metrics and that replica 1's trace holds commit
  spans. Mutation-tested: without the statsd or the trace wiring, the integration test fails.
- Verified: `check`, `test:fmt`, `test:integration`; `test:unit -Drelease` 305/306 (the
  sandbox-denied perf test).

## 2026-10-05 — The client no longer waits out a 10 ms tick per request (N51)

- `src/io/linux.zig`: `IO.run_once(nanoseconds)`, which returns once callbacks have run;
  `darwin.zig` and `windows.zig` alias it to `run_for_ns`. Vendored patch, listed in UPSTREAM.md.
- `src/nerva/client.zig`: `run_io_once` ticks the VSR client every `tick_ms` and otherwise waits
  with `run_once`, so `run_until_reply` and `deinit` return as soon as the reply (or shutdown)
  arrives.
- Through `nerva api` on a local three-replica cluster: lookup p50 10.60 ms to 1.05 ms, commit
  p50 10.53 ms to 0.92 ms (N51 has the table).
- Tests: IO unit test for `run_once`; `test:integration` checks the median lookup is under one
  tick. Mutation-tested.

## 2026-10-05 — Views maintained by the state machine (N52)

- `src/nerva.zig`: `declare_view`, `get_view` and `pulse` operations; `ViewDefinition`, `View`,
  `Group`, `ViewQuery`, `ViewRecord`; statuses `view_key_field` and `views_busy`; tree ids 5–8.
- `src/nerva/views.zig`: validation, row membership, group keys and hashes, the consensus hash.
- `src/nerva/state_machine.zig`: `views` and `groups` grooves; three-stage commit prefetch;
  groups and hash kept in every commit, coalesced per op; admission by distinct groups per op
  (the canvas demo livelocked under a per-write budget); declare; paged reads by id or
  name; backfill by pulse. Commit entries reserve 5 timestamps each.
- `src/lsm/scan_builder.zig`: `scan_unique_key_range` (UPSTREAM.md).
- `nerva api`: `PUT /v1/views/<name>` also declares into the state machine;
  `GET /v1/views/<name>/groups`; `409 view_key_field`, `503 views_busy`. Client:
  `declare_view`, `get_view`.
- Tests: unit and state machine tests, the VOPR model of views, `tests/views/maintained.py` in
  `test:views`. Mutation-tested (groups that never lose rows, the backfill cursor, admission off
  by one).

## 2026-10-04 — CI runs the fuzzers' smoke pass (N53)

- `.github/workflows/ci.yml`: the `test` job runs `zig build fuzz -- smoke` after the unit tests.
  README lists it among CI's steps.
- Verified locally: the smoke pass passes on `main`.

## 2026-10-04 — Format guards (N54)

- `src/nerva/format_test.zig`: a snapshot of every wire and storage type's layout, enum values
  and tree ids, by reflection; golden values for `row_key`, `tail_id` and the catalog's stored
  JSON and field packing.
- `src/nerva/state_machine_tests.zig`: "format: what a fixed script commits", a summary and
  checksum of every result, row, change and history record a fixed script produces.
- Verified: each of six planted changes (field order, an enum value, a tree id, `row_key`, the
  layout JSON, change timestamps) fails exactly its guard; then reverted.
- Merged after views (N52): the layouts guard covers views' types, operations and tree ids; the
  script guard caught N52's 5 timestamps per entry, and its snapshot was updated for it.

## 2026-10-05 — Performance Phase 0: round trips, --cache-rows, bench, bench:load (N55)

- `src/nerva/client.zig`: `send` builds request messages and carries the previous round trip, so
  primaries record `client_request_round_trip`.
- `nerva start --cache-rows=<size>` (`cli.zig` `cache_rows_resolve`, `state_machine.zig`
  `cache_entries_rows_multiple`).
- `zig build bench` (`build.zig`), `Bench.metric` (vendored, UPSTREAM.md),
  `src/nerva/documents_benchmark.zig`, `src/nerva/view/declared_benchmark.zig`.
- `zig build bench:load` (`src/bench_load.zig`) and `src/nerva/latency_histogram.zig`.
- Tests: `cache_rows_resolve` and `LatencyHistogram` unit tests; `test:integration` checks round
  trips arrive over statsd (every replica now sends) and starts replica 2 with `--cache-rows`.
  Mutation-tested: sending 0 as the round trip fails it. Every bench:load workload ran locally.

## 2026-10-05 — Nightly performance run (N56)

- `.github/workflows/perf-nightly.yml`: nightly at 06:47 UTC and by hand; builds candidate and
  baseline, runs them on a Fly Machine, compares, records on `perf-results`, files
  `perf-regression` issues.
- `perf/nightly/`: `run.sh` (on the Machine), `Dockerfile`, `fly-run.sh` (create, poll, collect,
  destroy, sweep), `compare.py` and `test_compare.py` (7 tests).
- `build.zig`: `bench:build` installs `bench`, `bench-stdx` and `bench-load` without running them.
- Verified: `test_compare.py`; a local dry run of `run.sh` (two rounds, `--development`); a full
  trial on Fly (one performance-8x Machine, created and destroyed), which passed and found the
  Fly volume dominating production-config latency (N56).

## 2026-10-05 — Faster CI: parallel test jobs, demos split, Zig kept on the volume (N57)

- `.github/workflows/ci.yml`: `test` split into `unit` (unit tests) and `system` (typecheck,
  format, integration, API, views); `demo` split into one job per demo, each building with
  `-Drelease` and running its script as `test:demo` does, with a step that fails if build.zig's
  demo list and the matrix differ; every job installs Zig from a copy kept on the runner's
  volume, keyed by `zig/download.sh`'s hash, downloading only when it is missing or broken.
  The fuzzers' smoke pass (N53) runs as a job of its own, `fuzz`.
- Before (run 37240753012): critical path `test` 7m05, `demo` 6m03. After: the pull request's
  own CI run (see the pull request).
- Verified locally: the install snippet downloads once, then links the copy (0.03 s instead of
  9 s), and recovers from a damaged copy; `zig build check` passes through the links;
  actionlint is clean apart from the custom `fly` label.

## 2026-10-05 — Gateway fixes: routes, recovery, slots, trace files (N58; #26–#29, #36)

- `api.zig`: `/v1/views/groups` is the view named `groups`, not a groups route with no name
  (#26).
- `client.zig`, `api/server.zig`: `Client.reconnect`; the gateway replaces a client that timed
  out or was evicted, at most every 5 s, answering 503 meanwhile, and `/healthz` reports it (#27).
- `http_connection.zig`: with every slot busy, a new connection displaces the oldest one still
  sending its request (#28).
- `nerva_main.zig`: `--trace` creates its file exclusively (#29).
- `http_connection.zig`: the early bare-LF refusal scans only the head, so a body may hold
  newlines when it arrives with its head (#36, found writing the tutorial).
- Tests in `tests/api/api.py`, `tests/views/maintained.py` and a `Receiver` unit test, each
  failing on the binary before the fix.

## 2026-10-05 — Long fuzzing workflow (N59)

- `.github/workflows/fuzz.yml` (dispatch only) and `.github/scripts/fuzz_loop.sh`: every fuzzer
  and seven VOPR lanes on random seeds for a time budget, on Fly runners started for the run.
- Verified locally: `nerva_adds` for a minute (319 runs, passing); the `canary` fuzzer's planted
  failure is reported with its seed and replay command, and fails the job; the VOPR path (testing
  state machine, 9 runs); the workflow parses, 16 fuzz and 7 VOPR jobs.

## 2026-10-05 — Release v0.3.0 (N60)

- `build.zig`: release `0.0.3`, clients from `0.0.2`. `CHANGELOG.md`: the v0.3.0 section
  (maintained views, metrics and traces, the faster client; #7–#10, #26–#29, #34 and #36
  fixed; #30–#33 known; upgrade steps). `VERSION` 0.3.0.
- Measured, with the v0.2.0 binary and a `0.0.3` build: a v0.2.0 `nerva api` commits and reads
  against a `0.0.3` cluster; a `0.0.3` replica refuses a `0.0.2` data file
  (`multiversion unsupported`); a mixed cluster runs until the `0.0.3` replica panics with
  `checkpoint diverged` at op 960 (#34, commented). The replica_format golden checksum is
  unchanged.
- Verified: `check`, `test:fmt`, `test:unit` 328/329 (the sandbox-denied perf test).

## 2026-10-05 — Replicas ignore peers that run another release (N61; #34)

- `src/nerva/release_peers.zig`: `admits` (whether to handle a message, by its sender's announced
  release, or a prepare's or block's own) and `announced` (the release a ping or pong carries).
- `src/vsr/replica.zig`: option `release_peers_strict`; `on_message` records announcements and
  drops what `admits` refuses, logging a peer of another release once; `tick_peer_connections`
  forgets a disconnected peer's release and pings a newly connected peer; `send_ping(peer)`.
  `src/message_bus.zig` and the simulated bus: `replica_connected`. `src/testing/cluster.zig`:
  the option. `nerva start` sets it. UPSTREAM.md lists the patches.
- `src/vopr.zig`: the `nerva` lane runs one release with the option on (no simulated upgrades,
  which Nerva never performs); the `testing` lane is unchanged.
- `zig build test:release` (`tests/release/mixed.py`, a second `nerva` with release `0.0.200`),
  in CI's `system` job, CLAUDE.md and README.
- Verified: unit tests (`release_peers`, 332/333 overall, the sandbox-denied perf test);
  `test:release`; `test:integration`; VOPR `nerva` seeds 1, 2, 5, 16638486064026786667,
  3787786164975552336 and `testing` seeds 1, 2; `check`, `test:fmt`. With the v0.2.0 binary: one
  v0.3.0 replica among two v0.2.0 ones is ignored and ignores them; two v0.3.0 replicas commit
  past a checkpoint while the v0.2.0 one panics at the first operation it does not know.
- Mutation-tested: the gate off (a commit succeeds without replica 1), unannounced peers
  admitted, and prepares of another release admitted each fail a test.

## 2026-10-05 — Tutorial

- `docs/TUTORIAL.md`: a step-by-step tutorial for people new to Nerva. It covers a
  one-replica cluster and `nerva api`, rows and versions, transactions (compare-and-set,
  claims, atomicity, deletes), the change feed, history and as-of reads, layouts, adds,
  maintained views and `nerva view`, documents, crashes and safe retries, operating a replica,
  the Zig client, a contributor's tour of the code, and a cheat sheet. Linked from README.md.
- Written at `eaa7520`, then updated for v0.3.0: releases and upgrades (N60, N61), multi-line
  bodies (#36 fixed), the gateway's reconnect and `/healthz` (#27), `views_busy` that a retry
  cannot fix (#32), `--statsd`, `--trace` and `--cache-rows`, `Client.reconnect`,
  `test:release`.
- Verified: every command and reply in it comes from one scripted run against a fresh
  one-replica `--development` cluster at v0.3.0. The crash, outage and reconnect, retry,
  layout and declaration claims were each checked separately.
- Found while writing it: #36 (fixed in N58) and #37 (a duplicate of #27, fixed in N58).

## 2026-10-05 — Views: min, max and as_of in the state machine (N62)

- `src/nerva.zig`: `Member`, `GroupVersion`, `ViewVersion`; `member_key`, `member_order`,
  `group_version_key`, `view_version_key`; tree ids 9–15; `ViewQuery.as_of`;
  `view_extremes_per_table_max`; status `table_extremes_full`.
- `src/nerva/views.zig`: `min` and `max` accepted; ordered values, the members' order prefix,
  `extreme_count`.
- `src/nerva/state_machine.zig`: `members`, `group_versions` and `view_versions` grooves; commit
  prefetch stages 3 (members) and 4 (scans of the order where a group's holder may leave);
  `views_finish` settles `min` and `max`, keeps hashes and group counts, writes groups, members,
  views and their versions once each; a timestamp reserve per op for versions; entry blocks of 9;
  `get_view` as of an op (view version, then one scan per listed group).
- `src/lsm/scan_builder.zig`: `scan_prefix_range` (UPSTREAM.md).
- `nerva api`: `GET /v1/views/<name>/groups?as_of=`, `declared_op`, every aggregate rendered as
  `<fn>_<field>`; `min` and `max` maintained.
- Admission counts members as well as groups (`member_writes_limit`, a request's entries);
  pulses add at most what both limits allow. Replica RSS: 1,014 MiB on `main`, 1,295 MiB here.
- `build.zig`: release `0.0.4`, clients from `0.0.4` (owner's decisions; README, UPSTREAM.md).
  `ViewQuery.as_of` in v0.3.0's reserved bytes, so its layout is otherwise unchanged. Found and
  filed while checking: #42 (`nerva view` exits on a timeout; the canvas test flakes under
  load) and #48 (an evicted client segfaults).
- `docs/TUTORIAL.md` matches v0.3.0 and is left so: its maintained views (`count` and `sum`,
  latest only) and its release notes (`0.0.3`, clients from `0.0.2`) change with the release
  that ships this.
- `demo/canvas/server.py`: the reset is two transactions (its per-pixel `canvas` view, now
  maintained, needs 4,096 groups for one).
- Tests: the state machine tests' harness compacts and checkpoints; a randomized `min`, `max`
  and `as_of` test against a model (with member refusals); the VOPR model of both, reading
  declared views more often; `tests/views/maintained.py` with a `min` and `max` view and
  `as_of`; format guards updated. Mutation-tested: three planted bugs fail the unit test; the
  VOPR catches a blunt one but not those three (N62 says why).

## 2026-10-05 — A software bill of materials with every release (N63)

- `.github/scripts/sbom.py`: CycloneDX 1.5 JSON for a tag and commit, from `build.zig`,
  UPSTREAM.md and `zig/download.sh`; refuses disagreeing or missing pins.
- `.github/workflows/release.yml`: the `version` job checks it can be written; the release adds
  `nerva-v<VERSION>.cdx.json` to the assets and to `SHA256SUMS`, and the notes name it.
- `.github/scripts/test_sbom.py`, run in CI's `system` job. README: the release paragraph.
- Verified: the tests (6), mutation-tested; strict validation of v0.3.0's SBOM against the
  CycloneDX 1.5 schema; a dry run of the release step's `dist/` and `SHA256SUMS`.

## 2026-10-05 — Gateways recover on their own; late replies dropped (N64; #42, #44)

- `src/nerva/client.zig`: `on_reply` drops a reply that arrives after the timeout (#42), with a
  unit test.
- `src/nerva/client_health.zig` (moved from `api/server.zig`): `ClientHealth`, plus
  `idle_timeout_ms` so an idle gateway with a broken client wakes to replace it (#44).
- `src/nerva/api/server.zig`: retries while idle. `src/nerva/view/server.zig`: a timeout or
  eviction breaks the client instead of exiting; requests and `/healthz` answer 503 until it
  is replaced (#42).
- `tests/api/api.py`: recovery with only `/healthz` polled. `tests/views/declared.py`: a view
  process survives a stall and recovers on its own. README and TUTORIAL updated.
- Verified: `check`, `test:fmt`, `test:unit` 334/335 (the sandbox-denied perf test),
  `test:views` and `test:api`. Against `main`'s binary the new checks fail: a stalled view
  process answers 500 instead of 503, and `/healthz` stays 503 for 120 s after the cluster
  recovers. Without the `on_reply` change the new unit test panics.

## 2026-10-05 — CI frees a nearly full runner volume (N65; #50)

- `.github/scripts/free_disk.sh`: logs free space; below 6 GiB empties the Zig build cache and
  older toolchains. Run by `INSTALL_ZIG` in `ci.yml` and before the release build.
- Verified locally: with room it changes nothing; with the threshold forced above the free space
  it removes the build cache and the older toolchain, keeps the pinned one, and warns.

## 2026-10-05 — Nightly: build the image on the host network

- The first nightly run failed building its image: `fly machine run .` used the runner's local
  Docker, whose build containers cannot resolve DNS. `perf/nightly/fly-run.sh` now builds with
  `docker build --network host`, pushes to `registry.fly.io/nerva-perf`, and runs that image;
  without a local Docker it still uses Fly's remote builder.

## 2026-10-05 — `nerva api` serves views whole (N66)

- `src/nerva/api/api.zig`: `GET /v1/views/<name>` (the whole view, `nerva view`'s answer byte for
  byte, with `view_hash` and `declared_op`; `as_of`, `min_op`), `GET /v1/views` (listing),
  `GET /v1/views/<name>/definition` (the declaration, moved).
- `src/nerva/view/declared.zig`: `render`, shared by both gateways.
- `src/nerva.zig`, `state_machine.zig`: `Group.op`; reads as of an op scan only the groups
  changed since, and a page ends after 128 scans; the `get_view` header names its view.
- Demos read views from `nerva api` and compare its hash with a `nerva view` process's.
- Tests: `tests/views/maintained.py` (byte-for-byte equality, the new routes and refusals), the
  randomized test with pages ending early, format guard for `Group.op`. Mutation-tested.

## 2026-10-05 — A client may not send `pulse` (N67; #33)

- `src/nerva/internal_operations.zig`: `pulse_from_client`, unit-tested for every operation.
- `src/vsr/replica.zig`: `on_request` evicts such a client (`invalid_request_operation`);
  UPSTREAM.md.
- Measured at `825355c`: one raw `pulse` from a client crashes the replicas
  (`trace/event.zig`, invalid enum value), and again after a restart. With the guard (and #53's
  client fix), the client is evicted and the integration scenario passes after it.
- Verified: `check`, `test:fmt`, `test:unit` 337/338 (the sandbox-denied perf test); VOPR
  `nerva` seeds 1, 2 and `testing` seed 1.

## 2026-10-05 — No CI for Markdown-only changes (N68)

- `.github/workflows/ci.yml`: `paths-ignore: ['**.md']` on push and pull request; release.yml's
  call to it is unaffected.
- README's CI paragraph and DECISIONS N68 say so.

## 2026-10-05 — `nerva api` bounds a request's memory (N69; #31)

- `src/nerva/api/memory_budget.zig`: an allocator that refuses past a limit and says so; unit
  tests. `src/nerva/api/server.zig`: the request arena allocates through it (64 MiB), resets
  keeping at most 8 MiB, and answers 413 when a request exceeds it.
- `tests/api/api.py`: 4 MiB bodies of nested and of long arrays answer 413, RSS stays near its
  baseline. README, TUTORIAL.
- Verified: `check`, `test:fmt`, `test:unit` 338/339 (the sandbox-denied perf test),
  `test:api` (RSS 92 MiB, 100 MiB after both bodies); measured on `main`'s binary:
  91 → 788 MiB, then 527 MiB, both bodies answered 400; fixed: 92 → 133, 130 MiB, 413.

## 2026-10-05 — An eviction no longer aborts a client (N70; #52)

- `src/nerva/client.zig`: `on_eviction` records the eviction; `deinit` deinits the evicted
  VSR client.
- `src/integration_tests.zig`: the scenario ends with an eviction (`clients_max` newer
  sessions), expecting `error.Evicted` twice.
- Verified: `test:integration` passes (2.4 min); with `main`'s client it aborts in
  `MessageBuffer.invalidate` after `evicted: no_session`. `check`, `test:fmt`, `test:unit`
  336/337 (the sandbox-denied perf test).

## 2026-10-05 — `--trace` cannot stop the replica (N71; #30)

- `src/nerva/trace_file.zig`: `TraceFile`, a buffered writer that stops (with a warning) on a
  write error or at its size limit, and never fails; unit tests. `src/nerva_main.zig`: the
  tracer writes through it. `src/nerva/cli.zig`: `--trace-size-max` (default 1 GiB).
- `tests/api/api.py`: a traced replica with `--trace-size-max=64KiB` under load stops tracing at
  the cap and keeps serving. README, TUTORIAL.
- Verified: `check`, `test:fmt`, `test:unit` 341/342 (the sandbox-denied perf test), `test:api`
  (stopped at 65,503 bytes).
- With it, #60 (N69 amended): the largest valid `documents/get` (256 × 64 KiB) got 413. The
  budget sat below the arena, which sizes each block from the last, so it counted 330 MiB for a
  request asking for about 100 MB. It now sits above the arena (counting what a request asks
  for), at 128 MiB, and the arena is reset as soon as the reply is written; the `get` reply is
  sized up front. `tests/api/api.py` checks that `get` answers 200 and that RSS comes back. On a 1 MiB
  tmpfs: `main`'s replica panics (`Tracer.start: error.NoSpaceLeft`, 283 lookups in); the fix
  logs `tracing stopped: writing it failed: error.NoSpaceLeft` and serves 54,915 lookups.

## 2026-10-05 — `views_too_large` for a transaction no op can hold (N72; #32)

- `src/nerva.zig`: `EntryStatus.views_too_large = 15`. `src/nerva/views.zig`: `Admission`.
- `src/nerva/state_machine.zig`: `view_txn_admit` tells `busy` from `too_large`; commit reports
  each. `src/nerva/workload.zig`: the VOPR model follows, and counts both.
- `src/nerva/api/api.zig`: `413 {"status":"views_too_large"}`. README and TUTORIAL: split, do
  not retry; `views_busy` is retryable and only for multi-transaction requests.
- Tests: unit (too large; busy, then the same transaction alone commits); `test:views` (4,200
  new groups answer 413; split in two, they commit). Format snapshot: the new status line.
- Verified: `check`, `test:fmt`, `test:unit` (the sandbox-denied perf test aside), `test:views`;
  VOPR seeds 1, 2, 5 (one `views_busy`, one `views_too_large`) and 2467272726192300042.

## 2026-10-05 — `extremes_scratch` holds two keys per member (N73; #62)

- `src/nerva/state_machine.zig`: `extremes_scratch` sized for `2 * members_limit`.
- `src/nerva/state_machine_tests.zig`: one op moving every `min`/`max` holder it admits to new
  groups (panicked with `integer overflow` before; now commits, groups checked).
- N62 corrected: with two `min`/`max` slots a transaction holds at most 4,094 writes to the
  table, not any number; README gives the per-slot bounds.
- Verified: `check`, `test:fmt`, `test:unit` 341/342 (the sandbox-denied perf test),
  `test:views`; VOPR seeds 1, 2, 5, 2588955253890934414. At production limits (the pass's
  probe): 2,047 rows moved in one transaction commit and the view holds each; on `8c206f2` it
  panicked every replica, and again after a restart.
- Found by the 0.0.4 hardening pass (a background agent), which otherwise held up: `min`/`max`
  against a model with ties, deletes, moves and refills; about 8,100 `as_of` comparisons across
  checkpoints and restarts, in agreement with `nerva view`; backfill under load; 13 VOPR seeds;
  fuzzers at smoke size; v0.3.0 clients refused by 0.0.4, as N62 intends.

## 2026-10-05 — The VOPR on `main` runs in ReleaseSafe on about 300 seeds (N74)

- `.github/workflows/ci.yml`: `vopr` (seeds 1, 2, 5 and one random, Debug) runs on pull requests
  only; `vopr_main` runs everywhere else: seeds 1, 2 and 5 in ReleaseSafe, and four lanes of
  `fuzz_loop.sh vopr nerva 6`.
- README's CI paragraph and DECISIONS N74.
- Verified locally: the ReleaseSafe VOPR build (2m03), seeds 1, 2 and 5 pass (8 s, 1 s, 3 s),
  `fuzz_loop.sh vopr nerva 2` ran 25 seeds without a failure; the workflow parses as YAML.

## 2026-10-05 — Declared ledgers: conserved fields, floors, paired adds (N75)

- `src/nerva.zig`: `LedgerField`, `LedgerDefinition`, `DeclareLedgerStatus`,
  `DeclareLedgerResult`, `LedgerQuery`, `Ledger`; operations `declare_ledger` and `get_ledger`;
  `AddFlags.pair`; `EntryStatus.unpaired = 16`, `conserved_write = 17`;
  `DeclareStatus.ledger_field`; tree ids 16 and 17; `ledger_bounds`.
- `src/nerva/ledgers.zig`: `definition_validate`, and `Index`, the conserved fields sorted for
  bisection.
- `src/nerva/state_machine.zig`: the `ledgers` groove, prefetched and loaded every op that needs
  it; `declare_ledger` and `get_ledger`; in `commit_failure`, overlapping adds and the pair
  rules; in `adds_resolve`, floors and conserved puts and deletes; views refused over conserved
  fields.
- `src/nerva/client.zig`: `declare_ledger`, `get_ledger`. `src/nerva/api/api.zig`:
  `PUT`/`GET /v1/ledgers/<id>`, `"pair"` on adds, 409 `unpaired` and `conserved_write`;
  `PUT /v1/views` declares into the state machine before writing the catalog.
- Tests: `state_machine_tests.zig` (pairs, refusals, floors, declarations, views, reload);
  `workload.zig` (ledger traffic, the model's rules, `check_ledger`); `adds_fuzz.zig` (floors,
  partners, conservation); `tests/api/ledgers.py`, in `test:api`; format guards.
- Docs: README "Ledgers" and routes; DECISIONS N75; GOALS G8 decided and the non-goal's note;
  CHANGELOG v0.4.0.
- Verified: `check`, `test:fmt`, `test:unit` (the sandbox-denied perf test aside), `test:api`,
  `test:views`, `test:integration`, `test:release`, `fuzz -- smoke`, VOPR seeds; four planted
  bugs, each caught.

## 2026-10-05 — Documents of up to 512 KiB (N76; #25)

- `src/nerva/documents.zig`: `value_size_max` 512 KiB. `src/nerva/api/documents_routes.zig`: a
  compile-time check that the largest document fits one production commit with room; a `get`
  reads at most as many chunks as 256 documents of 64 KiB (413 past that).
- `tests/api/documents.py`: a 512 KiB value under a 1024-byte key, written and read back; one
  byte more refused; the `get` cap at its edge (33 × 512 KiB: 413; 32: 200). `src/nerva/api/api.zig`:
  the unit test's oversized value follows the limit. `src/fuzz_tests.zig`: the documents
  fuzzer's smoke count is 25 (values are up to 8 times larger).
- README and TUTORIAL: the limits, and content-addressed blobs with their hash in a document for
  larger values.
- Verified: `check`, `test:fmt`, `test:unit` 344/345 (the sandbox-denied perf test), `test:api`
  (api, documents, adds), `fuzz -- smoke` (exit 0; the vendored `lsm_segmented_array` reports
  17 s here, slower than smoke wants, unrelated).

## 2026-10-05 — `min`/`max` slots bounded by the member budget (N77; #68)

- `src/nerva/state_machine.zig`: `table_extremes_max`, `min(4, member_writes_limit)`, at
  declaration. `src/nerva/workload.zig`: the VOPR model follows.
- Verified: the seed that failed `main`'s lanes (17320319949900435868) and the other one
  (11511081922386736357) pass; seeds 1, 2, 5 and 30 random in ReleaseSafe pass; `check`,
  `test:fmt`, `test:unit` (the sandbox-denied perf test aside).

## 2026-10-05 — `/groups` names its replicated hash `view_hash` (#66)

- `src/nerva/api/api.zig`: `GET /v1/views/<name>/groups` sends `view_hash`, not `hash`, as the
  whole view and the README already say. `tests/views/maintained.py` follows; CHANGELOG v0.4.0
  (an incompatible change from v0.3.0) says so; DECISIONS N66 notes it. The tutorial is left
  to #67, which rewrites the views part.
- Verified: `check`, `test:fmt`, `test:views`.

