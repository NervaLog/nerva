---
id: P215
date: 2026-11-06
area: Releases
amends: N82
---

# R1's nightly Jepsen runs on the R2 host, in a window of its own with the fleet stopped

The decision: the nightly runs on the R2 Hetzner host (P147h), not on Fly as N82 assumed.
`ops/jepsen/nightly.sh`, started at 01:17 UTC by a systemd timer, stops `sim-fleet.service`,
builds the tip of `main` in ReleaseSafe, runs the nightly, archives `store/`, restarts the fleet
and calls the reporter, inside a whole-night deadline of 3 hours. The nightly is R1's demo steps 1
and 2: `retry` with the kill, partition and gateway faults, then keyed `bank`, 3,600 s each.

The reason: PRODUCTION.md's R1 (owner) names the R2 host, with Jepsen taking the fleet's place for
its hour. N82 named Fly only as an assumption. With the fleet stopped, Jepsen's 16 GB (five
replicas, ten gateways, a 4 GB JVM) never overlaps the fleet's `MemoryMax`, and P179's sizing
needs no change.

What it costs: the fleet loses about 2.5 hours a night (about 10% of its seeds), and a fleet
failure found in that window waits for the morning. The host is a single point: while it is down
there is no nightly, and the 7-night count restarts.
