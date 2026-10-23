---
id: P143b
date: 2026-10-23
area: "Milestone 3: positioned reads and the first views"
amends: P136
---

# The VOPR draws the primary's commit stall from the seed

P136 made the primary's no-lag commit stall (`commit_stall_probability`) a start flag and left the
default at 2/5, because the simulator only ever ran the default: exercising another value meant
patching the vendored `src/testing/cluster.zig`. The owner approved that patch on 2026-10-21 (PR
#136), together with the gateway's batching and before any other default ships.

- **Decision.** `Cluster.Options.commit_stall_probability` (null by default) is passed to every
  replica. When it is null and the state machine is Nerva's, `Cluster.init` draws 2/5, 1/5 or 0
  from a PRNG seeded with the cluster's seed and a fixed salt, and logs
  `commit_stall_probability=<n>/<d>` at the start of the run (the seed's parameters). A cluster of
  another state machine, and the replica tests, keep the replica's default. UPSTREAM.md records the
  patch. Nerva's default stays 2/5.
- **Reason.** A gateway that keeps more than one prepare in flight meets the stall; so would an
  operator who runs `--commit-stall-probability=0`. A value nobody simulates is a value nobody has
  tried against a slow or killed backup.
- **Cost.** The draw uses its own PRNG, so every other choice a seed makes is unchanged: a seed
  reproduces its earlier run apart from the stall. One third of the seeds run with no stall at all,
  where backups have less breathing room and the lag stall (10 ms per quarter checkpoint, P136)
  must absorb it; a finding there is a finding about that value.
