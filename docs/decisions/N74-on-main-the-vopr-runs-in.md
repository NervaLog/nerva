---
id: N74
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# On `main`, the VOPR runs in ReleaseSafe on about 300 seeds; pull requests keep Debug.

CI ran the VOPR on seeds 1, 2, 5 and one random seed in Debug on every push and pull request
(N32): 40 s to 2m01 a seed (N57). ReleaseSafe runs the same seed 10 to 40 times faster (measured
locally, one core: seed 1 in 8 s, 2 in 1 s, 5 in 3 s; `fuzz_loop.sh` searched 25 random seeds
in 2 minutes) with the same checks, since the simulator always builds with `config_verify`
(`vopr.zig`). Owner's decision: pull requests keep the Debug matrix as it was; everything else
(pushes to `main`, the run `release.yml` calls, a dispatch) runs `vopr_main` instead, five
jobs: seeds 1, 2 and 5 in ReleaseSafe, and four lanes of `fuzz_loop.sh vopr nerva 6`, each
searching fresh random seeds for 6 minutes, as the long fuzzing does (N59), about 300 seeds a
push in all. A lane stops at its first failing seed and prints the command that replays it
(`./zig/zig build -Drelease vopr -- <seed>`). The jobs fit inside the run's critical path, the
`demo` jobs, about 6 minutes after their build (N57), plus the ReleaseSafe build (about 2
minutes locally). A run on `main` takes 11 Machines instead of 10, of the org's 30. This is a
step towards TigerBeetle's continuous fuzzing on dedicated machines; the always-on fleet
(Hetzner, the owner's choice) is a later decision.
