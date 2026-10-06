# CLAUDE.md

Guidance for Claude Code when working in this repository.

**Read first, every session:** [README.md](./README.md) (design),
[docs/GOALS-1.0.md](./docs/GOALS-1.0.md) (1.0 goals),
[docs/DECISIONS.md](./docs/DECISIONS.md) (decision log: add to it when you decide something),
[UPSTREAM.md](./UPSTREAM.md) (what is vendored), and [docs/TIGER_STYLE.md](./docs/TIGER_STYLE.md)
(coding style, mandatory).

## Project

**Nerva** is a research database where derived state (indexes, aggregates, sync feeds, embeddings,
history) is declared and maintained from one ordered, replicated log. Consensus, storage, IO and
the VOPR simulator are vendored from TigerBeetle; Nerva's own code is `src/nerva.zig` and
`src/nerva/`.

### Invariants (never violate)

- **The log is the source of truth.** All state is a deterministic function of the committed log.
- **State machine code is deterministic.** No wall clock, randomness, threads, hash-map iteration
  order or allocation after startup inside `prefetch`/`commit`. Time comes from the prepare
  timestamp.
- **`commit` does no IO.** All reads happen in `prefetch`.
- **Persisted identifiers are stable.** Never renumber `tree_ids` or `Operation` values.
- **Everything is bounded.** Every queue, batch and buffer has an explicit, asserted limit.

## Commands

```bash
./zig/download.sh             # Install the pinned toolchain into ./zig
./zig/zig build check         # Typecheck (fast; run often)
./zig/zig build test:unit     # Unit tests (filter: -- "test name")
./zig/zig build test          # Unit tests + format check
./zig/zig build vopr -- <seed>  # Simulator; a seed reproduces a run exactly (~5 min ReleaseSafe)
./zig/zig build fuzz -- smoke
./zig/zig build test:integration  # Real 3-replica cluster + client (~20 s, ~3.5 GiB disk)
./zig/zig build test:api      # nerva api (JSON), documents and adds against models, races (~3 min)
./zig/zig build test:views    # declared views against a model; maintained views against nerva view (~2 min)
./zig/zig build test:release  # two releases: the odd replica is ignored; export, import (~2.5 min)
./zig/zig build test:demo     # seat and canvas demos (3 replicas each) under crashes (~3 min)
./zig/zig build               # zig-out/bin/nerva
./zig/zig fmt src build.zig
```

`benchmark.perf: usage example` fails where `perf_event_open` is denied (cloud sandboxes); this is
environmental, see UPSTREAM.md. Every other test must pass.

CI (`.github/workflows/ci.yml`) runs the same steps on every push and pull request to `main`
that changes more than Markdown (N68). A
commit that changes `VERSION` publishes release `v<VERSION>` (`release.yml`) after CI passes: to
release, add the version's "what's new" section to `CHANGELOG.md` (`## v<VERSION> — <date>`,
written for people running Nerva: new capabilities with examples, fixes with their issues, and
upgrade steps), then bump `VERSION` (and add a WORKLOG entry) in its own commit. The section
becomes the GitHub release notes; a version without one is refused.

## Vendored code

- Prefer adding code under `src/nerva/` over editing vendored files.
- When a vendored file must change, keep the patch minimal and **record it in UPSTREAM.md** in
  the same commit.
- Golden values (snapshots, checksums) may only be updated after explaining *why* they changed.
  Update snapshots with `SNAP_UPDATE=1 ./zig/zig build test:unit -- "<test name>"`.

## Working protocol

### Modes

Announce the mode in one line when entering it, followed by a brief plan:

- `🔍 Switching to DISCOVERY mode.` — finding existing code (here or upstream TigerBeetle).
- `🧑‍🎓 Switching to LEARN mode.` — understanding a module before changing it. Pause and
  summarize after ~15–20 files.
- `🐣 Switching to BASIC mode.` — small, well-defined changes.
- `🧠 Switching to DEEP WORK mode.` — larger or fuzzy changes.
- `📝 Switching to DOCUMENTING mode.` — doc comments and docs, only with consent.
- `🧪 Switching to TESTING mode.` — adding tests, VOPR workloads, fuzzers.

### Confirm before building

1. Confirm new **types** (structs, enums, unions, wire formats, on-disk layouts) and **function
   signatures** before implementing them.
2. Propose a few **test cases** (unit, fuzz, or VOPR workload checks) and confirm them.
3. Ask focused questions at the **bottom** of a message, prefixed `**Question:**`; prefer yes/no or
   explicit options; one or a few at a time.

### DEEP WORK

Step 1 (design) is mandatory: types, on-disk/wire formats, function signatures, test strategy.
End it with `DEEP WORK Step 1 complete`, a design summary, and
`Do you approve this design? Should I proceed to Step 2: Implementation?` — then wait.

Step 2 (implementation): types first, then signatures with `@panic("TODO")` bodies, then fill one
function at a time, running `check` and relevant tests after each.

### Pre-existing bugs

Whenever you find a bug that existed before your change (in Nerva's code or a vendored file),
file a GitHub issue on `Botpike/nerva-ledger`, even if you fix it in the same pull request: what
fails, how to reproduce it, since when (the commit or release, if known), its impact, and the
fix or the pull request that carries it. Fixing it in the PR does not replace the issue; link
them (`Fixes #N`), and close the issue as completed if the fix has already merged.

### Exit criteria

You are not done until:

1. `./zig/zig build check` passes and relevant tests pass (`test:unit`; a VOPR seed when touching
   consensus, storage or the state machine).
2. `./zig/zig build test:fmt` passes.
3. Cleanup pass: no dead code, no stray `TODO` without a reason, assertions on new invariants.
4. README.md / UPSTREAM.md updated if behaviour, design or vendored code changed.
5. **WORKLOG.md** has an entry for the change.
6. You have summarized what changed and where.

If stuck, show the last compiling version, the exact error, and ask a focused `**Question:**`.
