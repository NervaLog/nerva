---
id: P179
date: 2026-11-05
area: "Milestone 3: positioned reads and the first views"
amends: P147h
---

# The simulation fleet sizes its workers and its memory cap from the host's memory

The decision: `run.sh` defaults the worker count to min(cores - 1, (memory - 1 GiB) / 4096 MB),
at least 1 (`SIM_FLEET_SEED_MEMORY_MB`); memory is MemTotal, or the cgroup's `memory.max` when
lower. With fewer than 3 workers the workers are "mixed": each rotates through vopr-nerva,
vopr-testing, vopr-nerva, fuzz seed by seed (Nerva's state machine gets half, as it gets most
workers in the default split). `setup.sh` installs a `MemoryMax` drop-in of
min(56G, MemTotal - 1G). Explicit `SIM_FLEET_WORKERS*` settings win, and setting any single kind
turns the automatic rotation off.

The reason: the first real host has 4 cores and 7 GiB. With 3 workers and a 56G cap, the kernel's
global OOM killer killed seeds of every kind at 3.2 to 3.9 GB anon-rss (exit 137, counted as the
host's), which is lost coverage, and it could as well have killed sshd. Rotation keeps all three
kinds covered on a host that holds one seed at a time. MemTotal rather than MemAvailable keeps a
restart from changing the count with the page cache.

What it costs: a 4-core, 8 GB host runs 1 worker, about a tenth of the suggested host's
throughput. The 4096 MB figure is an observed peak, not a bound; a seed past it on a tight host is
still killed and counted. A mixed worker's seeds are not split exactly as the larger-host default.
