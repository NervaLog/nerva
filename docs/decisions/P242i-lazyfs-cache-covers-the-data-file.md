---
id: P242i
date: 2026-11-09
area: Releases
amends: P242h
---

# The LazyFS cache is larger than the data file, so it cannot fill; what the canary catches

The decision, in four parts.

1. `cache-size` is `1200MB` (was `128MB`), above the replica's data file: `nerva format
   --development` writes 1,141,374,976 bytes (1.06 GiB, measured on `zig-out/bin/nerva`). LazyFS's
   cache is keyed by file offset and eviction is off, so the cache can hold at most the files on
   the mount: the data file, the sentinel (4 KiB) and nothing else of size. A cache above that
   file cannot fill, whatever the run's length, so there is no rate to estimate and no run-time
   limit to enforce. Pages are allocated as they are written, so a node holds only what its replica
   touched (the bound is 1.2 GB per node, and 5 nodes together about 6 GB, reached only if the
   replica writes the whole file).
2. The bound is asserted. `check-cache-bound!` runs on each node after `nerva format` and before
   the mount: the file's size plus 16 MiB of slack must be at most `cache-bytes-min`
   (1,200,000,000, reading LazyFS's `MB` as 10^6, the smaller). If the format grows past that, setup
   throws with NRV-E0607 and the run ends before any fault, instead of the fault ending `:unknown`
   hours in. `:cache-full` stays as the check of the fact.
3. A `stat` that fails for any reason except ENOENT (a dead FUSE mount: "Transport endpoint is not
   connected") is `:error`, and the sentinel `:unchecked` (`:unknown`, NRV-E0607), never `:gone`,
   which proves the clear bit. No new code: it is the existing unchecked-sentinel path. The cache
   usage reads that LazyFS did not answer are counted (`:cache-usage-unread`), so `:cache-usage-max`
   is not read as a complete measurement.
4. What the canary catches is now explicit. The `lazyfs` checker judges the fault's own soundness
   (it bit, nothing was full, the recovery served); it does not judge Nerva's durability. A
   `lose!` that finds unsynced bytes after the kill reports `:lost-bytes` and `:warnings
   [:unsynced-bytes-lost]`, not a verdict: with the image's patch a correct Nerva leaves none
   (every hosted run: 0), and an unpatched LazyFS or a Nerva that stops syncing leaves some, so the
   warning shows in the result of any scope. The canary (`unpatched-lazyfs`, `--nemesis
   lose-unfsynced-writes --lazyfs-all-nodes`, P242h part 5) is expected to show that warning with
   `:lost-bytes` above 0, and the bank or protocol checker failing (the whole cluster restarting
   empty or short, #246). The teeth for the failure come from those checkers under
   `--lazyfs-all-nodes`; the default `:minority` scope on a Nerva that stopped syncing passes the
   `:lazyfs` checker with the warning only, which is what the warning is for.

Why (amends P242h): the review of 9a78be9 found that P242h's "about 5.5 MB per node in 5 minutes"
was wrong by more than 10x. Run 42692440134 shows a node at 0.27% and, 56 s after a restart, at
37.76% (about 48 MB); another at 66.35% (about 85 MB) four minutes into the run. The 128 MB cache
was full after about 6 minutes, so a host run of an hour would have ended `:unknown` at its first
fault after that. P242h's "a run of several hours ends `:unknown`" is superseded by this decision:
no run length does. The alternatives were a cache sized from `--time-limit` and the measured rate
(it reaches the file size within about 12 minutes anyway, so it is the file size with extra
arithmetic) and clearing the cache on a cadence (a clear while the replica runs is itself a fault,
and drops the unsynced data the fault is there to lose).

What it costs: up to about 1.2 GB of RAM per node container (6 GB for the cluster) on a long run,
where the file is fully touched; a hosted runner has 16 GB. A change to the format's size is a
setup failure until `cache-size` and `cache-bytes-min` follow it. The `:lost-bytes` warning is
not a verdict, so a Nerva that stopped syncing is failed only by the workload's checkers and
only under `--lazyfs-all-nodes`.
