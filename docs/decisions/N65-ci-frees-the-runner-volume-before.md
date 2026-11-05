---
id: N65
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# CI frees the runner volume before a job when it is nearly full.

Each runner Machine's 10 GB volume keeps the Zig toolchain and Zig's global build cache between
jobs (N57). Nothing pruned the build cache, so as branches built it filled the volume, and jobs
on a well-used volume failed at the integration test's first data file with `NoSpaceLeft`
(#50). `.github/scripts/free_disk.sh` runs first in every CI job (`INSTALL_ZIG`) and in
`release.yml`'s build job. It logs free space on the workspace's and the cache's filesystems,
and below 6 GiB free (`FREE_MIN_GIB`) on either it empties the build cache and every toolchain
but the pinned one. A job then rebuilds from scratch, about a minute more. A threshold rather than
always emptying keeps the cache's speed-up on most jobs. If space is still short afterwards, it
warns and lists what is large, so the next full disk names its cause.
