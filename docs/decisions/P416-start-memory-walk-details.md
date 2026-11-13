---
id: P416
date: 2026-11-13
area: Errors
amends: P406d
---

# How `start_memory.zig` reads the limits: the details P406d left open

**Decision.** (1) The levels `cgroup_depth_max` (32) counts include the root: a cgroup 31
directories below the mount is read, 32 below it is a refusal. (2) On a host with both versions
(hybrid), a `memory` controller line of `/proc/self/cgroup` (v1) wins over `0::` (v2), because
that is where the memory limit then lives. (3) A `proc/self/cgroup` that is absent is no cgroup
limit; `proc/meminfo` absent or without a parsable `MemTotal` is a refusal, as is a cgroup path
over 512 bytes. (4) A file of exactly 4,096 bytes is read; 4,097 is a refusal. (5) The refusal
names the flags' values (`--cache-grid` in MiB, `--cache-rows` in rows) and the source of the
limit, and an unusable file is NRV-E0723 with its own headline (the file and `unparsable`,
`too_large` or `too_deep`), not a second code.

**Why.** P406d fixes the budget and the refusal; these are the cases its text left to the code.
One code keeps the operator's fix the same: make the machine or its files readable, or lower the
caches.

**Cost.** A host whose cgroup files are unreadable for some other reason (an odd container
runtime) cannot start a replica until it is fixed; there is no flag to skip the check (owner
answer 3, P406e).
