---
id: P416c
date: 2026-11-14
area: Errors
amends: P416
---

# The v1 memory controller is assumed at `/sys/fs/cgroup/memory`

**Decision.** `start_memory` reads cgroup v1 limits under `/sys/fs/cgroup/memory` and v2 limits
under `/sys/fs/cgroup`, and does not parse `/proc/self/mountinfo` for the mount point. File names
are built in a buffer that holds the longest possible name, never truncated; a cgroup path over 512
bytes is refused (NRV-E0723, naming `/proc/self/cgroup`).

**Reason.** Those are the paths every mainstream distribution, Docker and Kubernetes use; a v1
host that mounts the controller elsewhere has no `/sys/fs/cgroup/memory` directory, which is "no
limit at any level", so the check falls back to `MemTotal`, never to a wrong number. (An earlier
revision of this PR refused such a host, with no flag to get past it; that stranded a host to
catch a case this decision accepts.) Reading `mountinfo` would
add a parser and another file whose failure modes need refusals.

**Cost.** The same fallback covers cgroup v2 where `/sys/fs/cgroup` is not mounted (a sandbox or
rootless runtime that masks it): `/proc/self/cgroup` says `0::/...`, `memory.max` is absent, and
that is "no limit", with no warning (no new code is added for it; tested). On such a host, or the v1
one above, a cgroup limit is missed and an oversized cache can still be OOM-killed
with no message of Nerva's. If a report shows one, parse `mountinfo` then.
