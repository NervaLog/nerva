---
id: P406
date: 2026-11-13
area: Testing
amends: P147d, P359b
---

# R3 measures with `perf/topology/`, on generic Linux hosts over SSH, not with `perf/fly/`

R3's harness is `perf/topology/run.py --topology 3+1`: three replicas on three hosts, each on its
own data disk, and the load with its gateway and the statsd sink on a fourth, reached over SSH
through the load host (or, with `--hosts=local`, four directories on one machine). It uses no
Fly feature. PRODUCTION.md's R3 demo command, `perf/fly/run.sh --topology 3+1`, becomes this one.
Which hosts it runs on: four generic VMs the owner provisions, as the owner answered on
2026-11-13 (P406e).

This amends P359b's R3 line: P359b said R3 measures the topology production uses and names the
host once Botpike chooses it, with the Fly p99 numbers kept as one data point. R3 now measures
before Botpike chooses (on generic VMs, re-run on the chosen host by one dispatch) and takes no
Fly data point (P406e).

The reason: P359b makes Fly no longer a design target and asks for no new work that depends on a
Fly-only feature, and says R3 measures the topology production actually uses. A harness that only
needs SSH runs on whichever host Botpike chooses, and its local mode runs in CI.

What it costs: `perf/fly/`'s probe is not extended, and the owner provisions the hosts by hand.
Latencies measured before Botpike chooses its host may need a re-run there (one dispatch).
