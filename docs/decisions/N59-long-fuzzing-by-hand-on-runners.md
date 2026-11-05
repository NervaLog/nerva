---
id: N59
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Long fuzzing, by hand, on runners started for it.

Smoke (N53) runs each fuzzer once at a fixed seed: it keeps fuzzers working, but finds little.
Finding bugs takes many seeds. `.github/workflows/fuzz.yml` runs, on `workflow_dispatch` only,
one job per fuzzer (all sixteen but `canary` and `smoke`), six VOPR lanes on Nerva's state
machine and one on the testing state machine, each searching random seeds for a budget of
minutes (default 120, at most 300). The owner starts Fly runners (Botpike/ci-runners) for a run
and stops them afterwards, so it costs only while it runs. `.github/scripts/fuzz_loop.sh` builds
once (ReleaseSafe), then gives each run a fresh seed and a 30-minute cap. A failing seed replays
exactly, so the job prints the seed and the command that replays it, in its log and summary, and
stops: one failing seed is the finding. A run past the cap is a warning, not a failure (some
fuzzers' default sizes are long). Not scheduled: a schedule would need runners standing by.
