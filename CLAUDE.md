# CLAUDE.md

Guidance for Claude Code when working in this repository.

**Read first, every session:** [README.md](./README.md) (design),
[docs/GOALS-1.0.md](./docs/GOALS-1.0.md) (1.0 goals),
`docs/decisions/` (the decision log; see "Decisions and
change notes" for how to add to it),
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
./zig/zig build -Drelease vopr -- <seed>  # Simulator; a seed reproduces a run exactly (1-8 s ReleaseSafe, N74)
./zig/zig build fuzz -- smoke
./zig/zig build test:integration  # Real 3-replica cluster + client (~20 s, ~3.5 GiB disk)
./zig/zig build test:api      # nerva api (JSON), documents and adds against models, races (~3 min)
./zig/zig build test:views    # declared views against a model; maintained views against nerva view (~2 min)
./zig/zig build test:release  # two releases: the odd replica is ignored; export, import (~2.5 min)
./zig/zig build test:demo     # seat and canvas demos (3 replicas each) under crashes (~3 min)
tests/jepsen/run.sh zig-out/bin/nerva test --nemesis kill,partition  # Jepsen (Docker, JDK, lein)
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
upgrade steps), then bump `VERSION` (and add a worklog note, `worklog/<number>.md`) in its own commit. The section
becomes the GitHub release notes; a version without one is refused.

**Before every release, the release gate** (P147b, amending P105). A release is cut only from a
`main` commit that is sim-clean (once R2's fleet runs: 24 hours of the fleet on that commit and no
open `sim-fleet` issue against it), Jepsen-clean (once R1's nightly runs: the suite passes on that
commit), and reviewed adversarially by **two** independent reviewers, as below. The release PR
quotes the fleet's tracker line, the Jepsen result and both verdicts. Within a day of the release,
a short retro goes in `docs/retros/<version>.md`: which assumptions were wrong, what each cost,
and what changes; a rule it changes lands here or in `docs/decisions/` in the same PR.

**Before every release, an adversarial review.** Before the `VERSION` commit, a separate bot that
did none of the release's work reviews the release candidate (the `main` commit to be released)
adversarially: its job is to break it, not to approve it. It reads every change since the last
tag, every vendored patch (UPSTREAM.md) and the upgrade and downgrade paths, hunts for invariant
violations (determinism, `commit` doing IO, unbounded queues, renumbered identifiers, lost
committed ops), and runs VOPR seeds, the fuzzers and the release, integration and Jepsen suites
against it. Two reviewers do this, each a fresh session given the diff since the last tag and the
briefs, never the other's findings nor the implementers' conclusions. Each finding is a GitHub
issue labelled `release-review`. The release waits until
every blocker is fixed or the owner waives it in writing, and the CHANGELOG section links the
review's issues.

## Vendored code

- Prefer adding code under `src/nerva/` over editing vendored files.
- When a vendored file must change, keep the patch minimal and **record it in UPSTREAM.md** in
  the same commit.
- Golden values (snapshots, checksums) may only be updated after explaining *why* they changed.
  Update snapshots with `SNAP_UPDATE=1 ./zig/zig build test:unit -- "<test name>"`.

## Decisions and change notes

A pull request never edits a shared log. When every pull request appended to the same file, they
collided with each other and took the same numbers. Each pull request now adds small files of its
own, named by its number.

**Open the pull request first**, as a draft, so that you have its number.

### Decisions

- A decision goes in `docs/decisions/P<number>-<short-slug>.md`, for example
  `docs/decisions/P62-cancel-kills-the-process-group.md`. Cite it as `P62`. A second decision in the same
  pull request is `P62b`, then `P62c`.
- The file starts with a header, then a one-line title, the decision, the reason and what it costs:

  ```
  ---
  id: P62
  date: 2026-10-06
  area: Money
  amends: D12
  ---
  ```

  `area` is one of the areas the existing decision files use. `amends` (or `supersedes`) is optional and
  names the earlier decision this one changes.
- N1 to N83 now live one per file in `docs/decisions/` (`N<n>-<slug>.md`) and keep their numbers;
  `docs/DECISIONS.md` is a pointer. Never edit a merged decision file: amend or supersede it instead.
- Never edit another pull request's decision file. To change any earlier decision, old or new,
  write a new one with `amends` or `supersedes`. The earlier text stays as it was.
- Nothing builds an index yet. To learn what has been decided, read every file
  in `docs/decisions/`.

### Change notes

- The worklog entry for a pull request goes in `worklog/<number>.md`: the date, the
  pull request, and a few lines on the work completed. Do not edit `WORKLOG.md`, which is frozen.
- If a pull request merged without one, the next pull request adds `worklog/<that number>.md`.

## Working rules

Most sessions in this repository run unattended: a task arrives as a spec or an issue, and nobody
answers questions while you work. Assume that is your situation unless a person is replying in the
session. These rules say what you decide yourself, what makes you stop, and what done means.

### Decide yourself

Inside the task you were given, you do not need permission for:

- new types, function signatures and modules under `src/nerva/` that follow existing patterns;
- new tests, VOPR workload checks and fuzzers;
- doc comments, README or CHANGELOG text the change makes wrong, and the worklog note;
- a design choice the task leaves open. Take the option closest to existing code and record it as
  a decision (see "Decisions"), in the same pull request.

When the task is larger than one file or its requirements are fuzzy, write the design first at the
top of the pull request description (types, wire and on-disk formats, signatures, test strategy),
then implement it in small steps, running `./zig/zig build check` and the relevant tests between
each.

- **Jepsen harness changes** run [tests/jepsen/CHECKLIST.md](./tests/jepsen/CHECKLIST.md) before
  their first review (P250).
- **Prove a surprising fault-injector result** against a minimal standalone reproduction before
  you review or fix code built on it (P250).
- **Cut slices so concurrent pull requests touch different files.** When they must share one, the
  shared part merges first (P250).
- **Leave draft as soon as the pull request is coherent,** so CI runs (P250).
- **Iterate on a Jepsen change with a short smoke:** dispatch `jepsen.yml` with `args` such as
  `--time-limit 60`. The full default run is for the head that will merge (P250).

### Stop

Each of these stops the work. Do not go round it, and do not merge.

1. **A persisted format changes**: an on-disk layout, a wire format, or a persisted identifier
   (`tree_ids`, `Operation` values). A data file written by the last release must still open.
2. **A vendored file changes** (anything `UPSTREAM.md` lists), unless the task names that patch.
3. **A golden value changes** (a snapshot or checksum) and you cannot say exactly why.
4. **An invariant above needs an exception**, however small or temporary.
5. **The toolchain changes**: the Zig version `zig/download.sh` pins, or a new dependency.
6. **The task contradicts** `README.md`, `docs/GOALS-1.0.md` or a decision (`docs/DECISIONS.md`,
   `docs/decisions/`).
7. **You cannot reach the exit criteria** below.

When you stop:

- Push what passes `./zig/zig build check` and open the pull request as a **draft**.
- Put `**Question:**` as the first line of its description: one question, yes/no or a short list
  of options, with the one you would choose and why.
- Finish the parts of the task the question does not touch. Leave the rest undone.
- The session that wrote a stopped pull request never merges it. The owner answers first.

If a person is replying in the session, ask them the same question there instead and wait.

### Pull request description

Every description states these, and they must be true of the final diff, not of the plan:

- **Formats:** `none`, or each on-disk layout, wire format or persisted identifier the diff changes.
- **Vendored:** `none`, or each vendored file the diff touches, with its `UPSTREAM.md` entry.
- **Not verified:** anything you did not run or could not test, or `nothing`.

Check them against `git diff --name-only origin/main...` before you write them.

### Pre-existing bugs

Whenever you find a bug that existed before your change (in Nerva's code or a vendored file),
file a GitHub issue on `NervaLog/nerva`, even if you fix it in the same pull request: what
fails, how to reproduce it, since when (the commit or release, if known), its impact, and the
fix or the pull request that carries it. Fixing it in the PR does not replace the issue; link
them (`Fixes #N`), and close the issue as completed if the fix has already merged.

### Exit criteria

You are not done until:

1. `./zig/zig build check` passes and relevant tests pass (`test:unit`; a VOPR seed when touching
   consensus, storage or the state machine).
2. `./zig/zig build test:fmt` passes.
3. Cleanup pass: no dead code, no stray `TODO` without a reason, assertions on new invariants.
4. README.md / UPSTREAM.md updated if behaviour, design or vendored code changed, and README's
   Production table and the site's data (`index.html` in `NervaLog/nervalog.github.io`: `SITE`,
   `GOALS`, `PRODUCTION`) if a status changed.
5. `worklog/<number>.md` exists for the change, and any decision you took is in `docs/decisions/`.
6. The pull request description carries the three statements above.
7. You ran [REVIEW.md](./REVIEW.md) on your own diff, and the description says which of its items
   the change touched and what you checked.
8. Every failure the change adds or touches is a registered code in [docs/ERRORS.md](./docs/ERRORS.md).

A failing VOPR seed, integration run or Jepsen run is a finding, never noise: do not re-run it until
it passes. Reproduce it from its seed, then fix it or file it (see "Pre-existing bugs").

## Milestones and demos (adopted from Zigbox, P147)

- The production work is milestones R1 to R7 in [docs/PRODUCTION.md](./docs/PRODUCTION.md). Work
  one milestone at a time, from its brief in `docs/briefs/rN.md` once one is written; do not start
  a later one, or build what a brief lists as a non-goal.
- **A milestone is delivered only when its demo runs for real and is green in CI.** Unit tests
  passing, or code that compiles, is never reported as a passed demo. Say exactly what was and was
  not run.
- Each demo script becomes an automated test, `zig build demo-rN` or a CI job. Never break an
  earlier demo.
- When scope is in doubt, cut scope and keep the demo. Record the cut in `docs/demos/rN.md`.
- **Error messages are part of the demo:** one line saying what was refused and why, with its code
  (`docs/ERRORS.md`), never a raw Zig error name or a stack trace for something the operator or
  client caused.

## Errors (P147c)

- Every failure a client, an operator or a script can see has a stable code `NRV-<kind><4 digits>`
  (`E` error, `W` warning, `B` bug), registered once in [docs/ERRORS.md](./docs/ERRORS.md) with
  its surface, blame, cause and fix. Codes are never reused or renumbered.
- A new failure path gets its code, its entry and a test that triggers it, in the same PR. A
  message that blames the wrong layer, or ends in an errno or `error.Something`, is a bug.
- The wire identifiers clients already match on (`conflict`, `out_of_bounds`, `unpaired`,
  `key_reused` and the rest) keep their spelling: a code is added beside them, never in their
  place.

## Agent context discipline (adopted from Zigbox, P147)

An agent re-reads its whole context on every turn, so cost grows with context size, not with the
work done.

- **One agent per slice.** A supervisor starts a fresh implementer for each slice of a milestone,
  and does not resume a finished one for the next slice or for fixes.
- **Hand off through the repository.** Before stopping, an implementer commits and ends its report
  with a handoff note: decisions made, traps found, what is next. Lasting decisions go in
  `docs/decisions/`.
- **Context ceiling.** Stop at about 250K tokens of context or 60 turns, whichever comes first:
  reach the next safe stopping place, commit, write the handoff note and report.
- **Small fixes get new agents,** given the symptom and the commit, never the agent that wrote
  the code.
- **Keep noisy output out of context.** Redirect `zig build`, VOPR and test output to a file and
  read only the failing lines.
- **Check a brief's premises** (what is merged, with `git log`) before handing it to an agent
  (P250).
- **Scratch outside the tree.** Downloads, builds of third-party code and scratch files go in the
  session scratchpad, never in the repository (P250).
- **One worktree per agent.** Agents that run at once never share a checkout: each works in its
  own `git worktree` with its own `ZIG_GLOBAL_CACHE_DIR`, and adds files by path, never
  `git add -A` (P250).
- **Delegate lookups** (searching the vendored TigerBeetle code, the Zig std) to a read-only agent
  and keep only the answer.
- **The cheapest model suited to the task** (owner, P148b). Name the model whenever you start an
  agent or session; never let it inherit one by default.
  - **Haiku:** mechanical work fully specified by a pattern (threading an argument through call
    sites, a rename, a status update, a CI tweak), watching CI and auto-merge and other polling
    (P250), and read-only lookups.
  - **Sonnet:** implementing a slice, its tests, and fixing a review finding.
  - **Opus:** design, briefs, adversarial and release review, and a judgment the cheaper model got
    wrong.

  Whoever delegated checks the diff.
- **One agent per new task.** Every slice, fix, lookup or review gets a fresh agent; a finished
  one is never resumed for the next task.
- **A review is recorded on the pull request** (owner). When an Opus reviewer reviews a pull
  request (a slice, a fix, a second review), its findings go on GitHub as one pull request
  review, not only in the reviewer's report: a pending review with each finding as an inline
  comment on its `file:line` (severity MUST, SHOULD or NIT first, then the failure scenario and
  the evidence), and the verdict and any finding with no line in the review body, submitted as
  `COMMENT` (the bot cannot approve or request changes on its own pull request). It ends with the
  attribution footer. The reviewer posts it itself; if it cannot, the supervisor posts its report
  unchanged. The fixer replies to each comment with the commit that fixes it, or why it does not.
  A release review keeps its `release-review` issues as well.

## README and site status (adopted from Zigbox, P147)

- The site is its own repository, `NervaLog/nervalog.github.io` (P148): `index.html`, served by
  GitHub Pages from that repository's `main` at <https://nervalog.github.io/>. README's
  Production table and the site (the `SITE`, `GOALS`, `PRODUCTION`, `NEXT` and `RELEASES` data
  at the top of its script) show the same status: change the site in the same session that
  changes a status here. Never mark anything delivered before its demo is green in CI; never show
  output that was not recorded as recorded.
- A commit here that only records status (README after a CI result) carries `[skip ci]`; never use
  it on a commit that changes code, tests or CI.

## Disk (adopted from Zigbox, P147)

- A session's disk is a fixed allowance. `test:integration` needs about 3.5 GiB. Give each
  parallel worktree its own `ZIG_GLOBAL_CACHE_DIR`, and never delete another worktree's cache.
- A killed build can leave `.zig-cache` half written, which then fails with `FileNotFound`;
  `rm -rf .zig-cache` fixes it.

## Environment facts (Claude Code cloud container, 2026-11-04)

- `perf_event_open` is denied, so `benchmark.perf: usage example` fails (see above).
- There is no Docker, so Jepsen does not run here; it runs on the R1 host.
- The repository moved from `Botpike/nerva-ledger` to `NervaLog/nerva`; GitHub redirects the old
  name for reads only. File issues on `NervaLog/nerva`.
