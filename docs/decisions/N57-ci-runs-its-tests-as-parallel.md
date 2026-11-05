---
id: N57
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# CI runs its tests as parallel jobs, and keeps the Zig toolchain on the runner's volume.

Measured on run 37240753012, the single `test` job was the critical path at 7m05 (typecheck 48 s,
format 0 s, unit 3m06, integration 29 s, API 2m10, views 21 s), then `demo` at 6m03 (a release
build, the seat demo, then the canvas demo); the VOPR seeds take 40 s to 2m01. `ci.yml` now runs:
- `unit`: the unit tests alone, the longest step.
- `system` ("check, integration, API, views"): typecheck and format first, then the
  integration, API and view tests. The typecheck builds the `nerva` binary those tests run, so
  its 48 s is mostly work they would do anyway.
- `demo`, one job per demo (`seats_chaos.py`, `canvas_chaos.py`): a release build, then the demo
  with `--seconds=75`, exactly the command `zig build -Drelease test:demo -- --seconds=75` runs for
  it. A step fails the job if build.zig's demo list and the matrix differ, so a new demo cannot
  be left out of CI. Nothing a demo checks changed.
- `vopr`, as before.
- `fuzz`: every fuzzer's smoke pass (N53), a job of its own so it does not lengthen `unit`
  (about 1.5 minutes).
Every check that ran before still runs, on the same commands. There is no aggregate `test` job:
this private repository's plan has no branch protection or rulesets (the API answers 403), so
no check name is required, and `release.yml` depends on the called workflow as a whole. Should
a required check be configured later, add an aggregate job then.
Checkout cleans `./zig`, so each job spent 7 to 9 s downloading Zig. The toolchain is now kept on
the Machine's volume at `$XDG_CACHE_HOME/nerva-toolchain/zig-<hash of zig/download.sh>` and
linked into `./zig` (Zig finds its `lib` next to the real binary). Changing the pinned version
changes the script, so the key. A copy is written aside and renamed when complete, used only if
it runs and has its standard library, and otherwise replaced by a fresh download; download.sh
then checks the version as before. `release.yml` still downloads (one job per release).
A run now takes 10 Machines instead of 6, of the org's pool of 30.
