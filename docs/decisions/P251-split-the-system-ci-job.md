---
id: P251
date: 2026-11-06
area: "Milestone 3: positioned reads and the first views"
---

# The `system` CI job is split into parallel jobs behind the same required check.

**Decision.** `check, integration, API, views` ran typecheck, format, the script tests, integration,
API, view and mixed-release tests in one job, about 26 minutes on a recent `main` run (typecheck
and scripts 1.5, integration 9, API 7, views 1, releases 7.6), twice any other job. It is now four
jobs that run in parallel: `check, fmt, scripts, views` (typecheck, format, the script tests, the
view tests, which use the binary the typecheck builds), `integration`, `API` and `releases`. A job
named exactly `check, integration, API, views` (`system`) needs the four and passes only if every
one finished `success`. Every step that ran before still runs, with the same gate
(`needs.changes.outputs.code != 'false'`), in a split job. The critical path is integration, about
10 minutes.

**Gating.** The split jobs use `if: !cancelled()` and skip each step on a docs-only change, as every
other job does, so they report `success` there, and so does `system`. `system` uses `if: always()`
and fails unless every result is `success`, so a failed, cancelled or skipped split job fails it
and never leaves it skipped. It does not need `changes`: as before, a failed `changes` makes the
steps run, not the check fail.

**Why.** The required check name cannot change (branch protection), and merge time was set by this
job.

**Cost.** Each job checks out and restores the toolchain, and the typecheck's build is repeated in
the jobs that build the binary (a minute or two of runner time each); four runners instead of one.
A new test step must be put in a split job, not only in `system`.
