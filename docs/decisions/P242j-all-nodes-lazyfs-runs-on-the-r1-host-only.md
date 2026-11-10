---
id: P242j
date: 2026-11-10
area: Releases
amends: P242i
---

# LazyFS on all five nodes runs only on the 64 GB host; a hosted run puts it on a minority

The decision, in four parts (the owner's, after the measurements below).

1. `--lazyfs-all-nodes` (LazyFS on all 5 nodes, and the `:all` scope that crashes a quorum and
   loses writes everywhere) runs only on the R1 host (`ops/jepsen`, 64 GB). The harness refuses it
   on a host with under 32 GiB of `MemTotal`, or whose `/proc/meminfo` cannot be read, before
   anything starts: `NRV-E0607` (`lazyfs/check-host-memory!`, called by `nerva-test`; registered
   in docs/ERRORS.md, a harness failure that says nothing about Nerva). `jepsen.yml` refuses the
   flag in its input check with the same code, before the build.
2. Without it, LazyFS is mounted on the first minority of the nodes (`lazyfs-nodes`: 2 of 5), not
   on all 5; the other nodes keep the data file on the container's disk. The `:minority` fault
   draws 1 or 2 of those nodes. `data-file`, `format-file`, `check-cache-bound!`, the mount, the
   unmount and `log-files` follow the node (`mounted?`). The `:all` scope needs every node
   mounted, which the flag gives.
3. Kept from this round: `-Xmx3g` for the Jepsen JVM, and `tests/jepsen/memsample.sh` (every 5 s,
   bounded: 40 lines a sample, 8 MiB). Dropped: one gateway per node under the fault (5e85f0c): it
   bought 25 MiB at the low point, and with 2 mounts the memory is there, so keyed workloads have
   their two gateways again (the test's first three nodes, as before). The reverted
   `--cache-grid=256MiB` stays out: `--development` already gives the replica the minimum grid cache
   (`cache_grid_size_min`), so the flag added 224 MiB to each replica.
4. The hosted canary (`unpatched-lazyfs`) changes its check, and it catches less. A minority loss
   is repaired by VSR from the nodes that kept their data, so with LazyFS on 2 nodes the workload's
   `:keys` checker cannot fail on stock LazyFS: the canary no longer tests that a Nerva that
   stops syncing loses acknowledged records. It tests that the fault has teeth: with
   `--lazyfs-strict-sync` the `:lazyfs` checker is `:valid? false` (NRV-E0608, registered in
   docs/ERRORS.md: a finding about the node, not the harness; a harness problem beside it does not
   turn it into NRV-E0607, and its reason is kept) when LazyFS held any unsynced byte after a kill, with `:reason`. The image's
   patched LazyFS leaves none (every hosted run: 0 over 14 to 17 faults), stock LazyFS keeps every
   O_DSYNC write unsynced, so the first fault, which never skips, loses bytes on a node that has
   written. It is a check that the LazyFS in the image is the patched one. Without the flag the
   verdict is unchanged (a warning, P242i). A Nerva that stops syncing is still failed only by
   `:keys` under `--lazyfs-all-nodes`, on the R1 host.

## What was measured

All hosted (`ubuntu-24.04`, 15,983 MB), bank, `lose-unfsynced-writes --lazyfs-all-nodes`, 300 s,
and all valid; the bar was a MemAvailable floor of 2,048 MiB:

| run | commit | change | MemAvailable floor |
| --- | --- | --- | --- |
| 42702458425 | 5fda8e0 | two gateways on three nodes, `-Xmx4g` | 414 MiB |
| 42727421914 | 5e85f0c | one gateway per node, `-Xmx3g` | 439 MiB |
| 42735546330 | 93fedec | same, with the memory sampler | 365 MiB |
| 42737270443 | 12f9bb1 | `--cache-grid=256MiB` | 380 MiB |

The breakdown at the lowest point of 42735546330 (anonymous memory, not page cache): the five
replicas 1,814 MiB RSS each (9,070 MiB; fixed at init, "allocated 1804MiB during replica init":
memtables and object-cache maps sized from the request size limit and vendored constants, no flag
reduces it), five LazyFS 865 to 942 MiB each (4,625 MiB; the 1,105 MB cache is pre-allocated at
mount but not all resident), the Jepsen JVM and lein 519 MiB, five gateways about 90 MiB each.
The floor is every replica up at once, so it does not move with the run's length. Cutting cache
flags did not help (the replicas already run the `--development` floor), so the memory the fault
needs on 5 nodes is about 13.5 GiB of 16.

The hosted run of the decision, 42813550862 (23c95f6, bank,
`lose-unfsynced-writes`, LazyFS on n1 and n2, 300 s): `:valid? true` throughout, `:lazyfs {:faults
15 :scopes {:minority 15} :lost-bytes 0 :cache-usage-max 3.38 :sentinel {:truncated 22}}`,
`:gateways` valid (final start 1 of 1), two gateways on three nodes, MemAvailable 14,918 MiB at
the start and a floor of **2,104 MiB** (bar 2,048 MiB; 56 MiB over it: the margin is thin, it is not
the 3 GiB the arithmetic predicted, because the replicas peak at 1,815 MiB each and `lazyfs` at
1,261 MiB RSS each, more than the 865 to 942 MiB seen before).

The hosted canary, run 42815030155 (23c95f6, `unpatched-lazyfs=true`, `--nemesis
lose-unfsynced-writes --lazyfs-strict-sync`, 300 s, floor 2,132 MiB): the job failed as it must.
`:lazyfs` `:valid? false`, `:faults 16`, `:scopes {:minority 16}`, `:lost-bytes 65740800`,
`:warnings [:unsynced-bytes-lost]`, with the `:reason`; bank, `:keys` (`:duplicate 0`), protocol,
gateways valid. As the decision says, `:keys` did not fail: the minority is repaired. The canary
fails on the first fault with probability 1 (stock LazyFS keeps every O_DSYNC write unsynced), so
it does not depend on a draw.

## What it costs

Hosted CI no longer covers the `:all` scope: a quorum crash followed by every node losing its
unsynced writes, the fault that gave the canary its teeth against Nerva's durability (P242i, run
42696580002), and the 5-node `:keys` verdict under it. The R1 host runs it (the nightly does not
yet name the flag; the host's first run of it is the first evidence for the scope). Hosted runs
cover the minority scope only: 1 or 2 nodes lose their unsynced writes while the rest keep them,
which exercises repair and catch-up, not the loss of a committed write by every replica. Because
only 2 nodes have LazyFS, only those 2 can be the fault's victims: replicas 3 to 5 are never the
node that loses its disk's writes in a hosted run (they are still killed and partitioned by the
other faults).

## LazyFS upstream

The owner filed both LazyFS defects upstream: the `O_DSYNC` write not counted as synced, which
`tests/jepsen/node/lazyfs-osync.patch` fixes (P242d), is
https://github.com/dsrhaslab/lazyfs/issues/25; the write-through of a full cache (P242f) is
https://github.com/dsrhaslab/lazyfs/issues/24.
