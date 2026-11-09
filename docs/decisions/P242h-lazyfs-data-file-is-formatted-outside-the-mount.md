---
id: P242h
date: 2026-11-09
area: Releases
amends: P242f
---

# The data file is formatted on the backing path, and the sentinel comes before the first clear

The decision, in five parts.

1. `nerva format` writes the replica's data file on LazyFS's backing path
   (`<dir>/data.lazyfs/data/replica.nerva`), before the mount. LazyFS is mounted afterwards, and
   the replica opens the same file through it. Without the fault nothing changes.
2. `lose!` writes the unsynced sentinel before the first (and only) clear, as P242e first did. The
   second sentinel and the extra clear of P242f are gone. The sentinel is read back after the
   clear and judged as before.
3. `lose!` records LazyFS's `lazyfs::display-cache-usage` before each clear (`:cache-usage`, in
   percent). A fault that finds the cache full (100) is reported: the checker is `:unknown` with
   `:cache-full` (NRV-E0607), and `:cache-usage-max` is in the `:lazyfs` result.
4. Every command `lose!` runs on the mount (`dd`, `stat`, `rm`) is bounded by `timeout -k 2 10`; a
   timed-out `stat` is `:unchecked`, a timed-out `dd` leaves the sentinel `:unwritten`, both
   `:unknown`. A run that never asked for the fault (no `:lazyfs` in the test map, no fault or
   recover op in the history) is valid and unjudged by this checker.
5. A teeth canary: `jepsen.yml`'s `unpatched-lazyfs` input (`JEPSEN_LAZYFS_PATCH=no` for `run.sh`,
   the Dockerfile's `LAZYFS_PATCH` argument) builds stock LazyFS. With `--nemesis
   lose-unfsynced-writes --lazyfs-all-nodes` the run must fail; what it reports is quoted in the pull
   request.

Why (amends P242f): the review of 13316b2 found that P242f's reasoning, not its repro, was wrong
about what it fixed. Nerva's format wrote the whole data file through the mount, and those clean
pages filled the 128 MB cache; LazyFS writes through when the cache is full (`cache_full`,
`lazyfs.cpp:887-1018`; reads never populate the cache). P242f moved the sentinel after a clear so
that it would be cached, which made the sentinel pass. But it also hid the fact that each node's
first fault was only a kill: the clear dropped clean pages, and `:remaining 0` and `:sentinel
:truncated` looked the same as a fault that bit. Up to five of the 17 faults of run 42686336702
were of that kind. P242f's "the first-fault behaviour is not hidden" was false. The failure the
fault guards against (a change that drops `O_DSYNC`, or a new file written unsynced) would also have
survived the first fault on each node. Formatting before the mount keeps the cache empty at no
cost in memory: the alternative, a 1 GB cache (29% used by the format), costs about 1 GB of RAM on
each node container. The pre-clear sentinel restores the signal P242f removed: a full cache shows
as `:survived`, and `:cache-usage` says why.

What it costs: a run long enough to fill the cache (about 5.5 MB per node in 5 minutes against
128 MB: several hours) now ends `:unknown` at its first fault after that, instead of passing on a
fault that lost nothing. The mount's `dd` and `stat` now run through `sh -c` and `timeout`.
Formatting is done on ext4, not through FUSE, so the format no longer exercises LazyFS. The
reasoning of P242c's section in P242 about a replica that left unsynced bytes is superseded by
P242d: with the patch, `:before` is 0 and only the sentinel shows the clear bit. P242g's remark that P242c
lists `lazyfs/package` before `db-package` stays as it was.
