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
over 512 bytes. (4) A file of exactly 4,096 bytes is read; 4,097 is a refusal; `/proc/self/cgroup` alone has a larger bound (16 lines of 512 bytes of path and 128 of prefix, 10,240 bytes; a 17th line is also `too_large`), because cgroup v1 repeats the path on a dozen lines. (5) The refusal
names the flags' values (`--cache-grid` in MiB, `--cache-rows` in rows) and the source of the
limit, and an unusable file is NRV-E0723 with its own headline (the file and `unparsable`,
`too_large`, `too_deep`, `absent` or `unreadable`), not a second code. (6) The reason names the cause, and the fix line follows it: no `/proc/meminfo` is `absent` (a v1 `memory` line whose `/sys/fs/cgroup/memory` is not there is no limit, P416c); a cgroup path over 512 bytes or deeper than 32 levels says to run in a shorter or shallower cgroup; every refusal names its file absolutely; a file that cannot be read is `unreadable`. (7) File names are built in a buffer sized for the longest path, so a path of 512 bytes is read in full and one of 513 is `too_large`; the walk never truncates a name into "no limit".

**Why.** P406d fixes the budget and the refusal; these are the cases its text left to the code.
One code keeps the operator's fix the same: make the machine or its files readable, or lower the
caches.

**Cost.** A host whose cgroup files are unreadable for some other reason (an odd container
runtime) cannot start a replica until it is fixed; there is no flag to skip the check (owner
answer 3, P406e).
