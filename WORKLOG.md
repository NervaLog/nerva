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
