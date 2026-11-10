---
id: P242d
date: 2026-11-09
area: Releases
amends: P242
---

# The Jepsen node image builds LazyFS at 9c5685e8 plus a patch that syncs O_DSYNC writes

The decision: the pin of P242 is LazyFS `9c5685e8` (tag 0.3.0) plus `tests/jepsen/node/lazyfs-osync.patch`,
applied in `node/Dockerfile`'s `lazyfs` stage right after the `git rev-parse` pin check
(`git apply --check`, then `git apply`; the build fails if it does not apply). The patch makes
`lfs_write` sync the file (as `lfs_fsync` does, without taking the cache lock twice) when the file
was opened with `O_DSYNC` or `O_SYNC`. Nerva needs no change. The patch should be filed upstream
with `dsrhaslab/lazyfs` by the owner; nothing is filed from here.

Why: #246 (comment 6684729824). Nerva opens its pre-sized data file `O_DIRECT|O_DSYNC`, and a
non-extending direct write reaches LazyFS's `lfs_write` with no FUSE fsync after it, so LazyFS
kept it in its cache as unsynced and lost an acknowledged write on a clear. That made earlier runs
of this fault fail falsely (an empty cluster, a `commit_min` regression) and made every clear
replica amnesia (P242c). With the patch a write that was promised durable is durable, so the fault
loses only what a power cut loses. P242's reasons stand; its "most likely cause, not established"
is now established.

Also, from the second review: a recovery with no nodes (after a skipped fault) no longer clears
the set of nodes still behind, so the catch-up gate of P242c holds; the final recovery settles and
judges every node the fault has hit, not only the nodes still pending, and the verdict is
`:unknown` if it judged none; and the verdict's harness `:unknown` carries NRV-E0607
(`docs/ERRORS.md`). The final-recovery order in `core.clj` (it runs before the `kill` and
partition packages' final starts) waits for #239 to merge first (P250).

What it costs: the image carries a local patch to a third party's code, which must be re-checked
when the pin moves. The patch was proven on tmpfs; the hosted run over the node's own filesystem
is the first on ext4 (Nerva's `O_DIRECT` reads over a FUSE mount are not otherwise measured).
