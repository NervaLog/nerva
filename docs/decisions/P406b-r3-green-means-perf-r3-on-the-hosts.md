---
id: P406b
date: 2026-11-13
area: Testing
amends: P147d
---

# R3 is green when `perf-r3.yml` passes on the owner's hosts; `demo-r3` checks the harness on every push

`zig build -Drelease demo-r3` (CI job `demo_r3`) runs the harness locally on every push: the
report's shape, two runs' memory within 1%, the README's memory table, and the NRV-E0723 refusal.
It never checks latency. R3 is delivered only when `.github/workflows/perf-r3.yml`, dispatched by
hand on a `main` commit, is green on the owner's four hosts: two runs that agree (P406c) and the
sizing sweep, linked from `docs/demos/r3.md`.

The reason: PRODUCTION's demo needs separate machines with their own disks, which GitHub's
runners are not, and the repository is public, so a self-hosted runner is out (P147e). A local
demo on every push keeps the harness from rotting between hand-dispatched runs.

What it costs: delivery waits on the owner's hosts and a manual dispatch; a regression in latency
is caught by the nightly (N56), not by R3's CI job.
