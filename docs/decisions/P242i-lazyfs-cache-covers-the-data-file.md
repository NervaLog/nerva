---
id: P242i
date: 2026-11-09
area: Releases
amends: P242h
---

# The LazyFS cache is larger than the data file, so it cannot fill; what the canary catches

The decision, in four parts.

1. `cache-size` is `1105MB` (was `128MB`): LazyFS's `MB` is 2^20 bytes (constants.hpp:23), so
   1,158,676,480 bytes (`cache-bytes`), just above the replica's data file: `nerva format
   --development` writes 1,141,374,976 bytes (1,088.5 MiB, measured on `zig-out/bin/nerva`) and
   the margin over it is 16.5 MiB. LazyFS's cache is keyed by file offset and eviction is off, so
   the cache can hold at most the files on the mount: the data file, the sentinel (4 KiB) and
   nothing else of size. A cache above that file cannot fill, whatever the run's length, so there
   is no rate to estimate and no run-time limit to enforce. The margin is the sentinel and room
   for a stray file (`sentinel-slack-bytes`, 16 MiB); it is as small as that because the memory
   is not allocated as it is used (the cost below).
2. The bound is asserted. `check-cache-bound!` runs on each node after `nerva format` and before
   the mount: the file's size plus 16 MiB of slack must be at most `cache-bytes`. If the format
   grows past that, setup throws with NRV-E0607 and the run ends before any fault, instead of the
   fault ending `:unknown` hours in. `:cache-full` stays as the check of the fact.
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
   `:lost-bytes` above 0, and the workload's `:keys` checker failing (acknowledged records lost
   when the whole cluster restarts short, #246). Run 42696580002 (9a78be9, 120 s) did exactly that:
   `:keys` invalid (`:committed 506`, `:records 425`, 81 committed keys with no record: `:missing`
   405 is those 81 counted over the 5 final reads, `:count-view` 5, and 506 - 425 = 81;
   `:duplicate` 1); bank, source, view and refusals valid; `:lazyfs` valid with `:faults 4` and
   `:lost-bytes 24715264`. The `:duplicate` is expected, not a second Nerva bug: the first
   transfer committed at op 1306 and its reply was dropped on purpose (`:info :unresolved`); the
   `:all` clear lost op 1306 and its commit-key row cluster-wide, so the final resend found no key
   and committed afresh at op 3297 instead of replaying. It follows from losing acknowledged
   commits. The teeth for the failure come from the `:keys` checker under `--lazyfs-all-nodes`
   (the bank and protocol checkers did not fail); the default `:minority` scope on a Nerva that
   stopped syncing passes the `:lazyfs` checker with the warning only, which is what the warning
   is for.
5. The canary always draws an `:all` fault. Only an `:all` fault gives it its teeth, and the scope
   was a fair draw per fault, so about 1 canary in 16 (4 faults in 120 s) drew none, VSR repaired
   the minority, `:keys` stayed valid and stock LazyFS passed. With `--lazyfs-all-nodes` the
   first fault (which never skips: nothing is pending) is `:all`; the rest are drawn. The
   `:lazyfs` result reports each fault's scope (`:scopes {:minority n, :all m}`), and a canary
   result counts only with `:all` at least 1 (CHECKLIST, teeth).

Why (amends P242h): the review of 9a78be9 found that P242h's "about 5.5 MB per node in 5 minutes"
was wrong by more than 10x. Run 42692440134 shows a node at 0.27% and, 56 s after a restart, at
37.76% (about 48 MB); another at 66.35% (about 85 MB) four minutes into the run. The 128 MB cache
was full after about 6 minutes, so a host run of an hour would have ended `:unknown` at its first
fault after that. P242h's "a run of several hours ends `:unknown`" is superseded by this decision:
no run length does. The alternatives were a cache sized from `--time-limit` and the measured rate
(it reaches the file size within about 12 minutes anyway, so it is the file size with extra
arithmetic) and clearing the cache on a cadence (a clear while the replica runs is itself a fault,
and drops the unsynced data the fault is there to lose).

What it costs: memory, all of it from the mount. LazyFS pre-allocates and zero-fills every cache
page when it mounts (`custom_cache.cpp:33-48`: `new Page` for each of `CACHE_NR_PAGES`;
`page.cpp:33-34`: `malloc` then `memset(0)`), so a node holds the whole cache, 1,105 MiB (about
1.08 GiB), from mount to unmount whether the replica touches it or not: 5.4 GiB for the 5 nodes
of every run with the fault, not only with `--lazyfs-all-nodes` (an earlier text of this decision
said pages are allocated as they are written; that was wrong). `1200MB` would have held 1.26 GB a
node, 6.3 GB for the cluster. The R1 brief's risk 2 puts the hosted runner's 15,983 MB (`free
-m`) at about 13 GB with two gateways per node, so the sizing is the tightest the bound allows
and the headroom is measured, not assumed: MEASURED. The workflow records `free -m` at the start
and end of the run and the lowest MemAvailable between, and the harness logs `free -m` after
each mount. A change to the format's size is a setup failure until `cache-size` and
`cache-bytes` follow it. The `:lost-bytes` warning is not a verdict, so a Nerva that stopped
syncing is failed only by the workload's `:keys` checker and only under `--lazyfs-all-nodes`.
