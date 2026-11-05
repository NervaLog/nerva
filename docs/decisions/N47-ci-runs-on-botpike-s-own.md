---
id: N47
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# CI runs on Botpike's own runners.

`ci.yml` and `release.yml` run every job on `[self-hosted, fly]`: Botpike/ci-runners starts a Fly
Machine (performance-2x, 8 GB, its own 10 GB volume) for the job and stops it afterwards, so a
job waits seconds for a runner and the Zig cache survives between jobs. They behave as GitHub's
runners do where this repository depends on it: jobs run as a non-root user with
`perf_event_paranoid` 2, so the perf test still skips itself (N32); the workspace is on the
volume, which holds the integration test's 3.5 GiB; `xz` and `gh` are installed for Zig's
download and the release. Nothing else changed: the steps, seeds and release are as N32 and N40
set them.
