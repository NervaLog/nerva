# Worklog

Chronological log of completed work items. The previous Kotlin/PostgreSQL implementation of Nerva
is preserved at git tag `kotlin-archive`.

---

## 2026-10-04

- Reset the repository for the new Nerva: a log-centric database with declared derived state
  (design in README.md). Previous code archived at tag `kotlin-archive`.
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
