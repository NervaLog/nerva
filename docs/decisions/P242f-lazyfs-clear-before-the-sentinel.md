---
id: P242f
date: 2026-11-09
area: Releases
amends: P242e
---

# `lose!` clears LazyFS's cache before it writes the sentinel, because a full cache writes through

The decision: `lose!` reads the replica's unsynced bytes (`:before`), clears the cache, and only
then writes the unsynced sentinel, reads its report and clears again. Each clear is confirmed by
reading the unsynced bytes until 0 (`clear!`). The verdict's rules (P242e) are unchanged. The
extra clear loses nothing the fault should keep: the replica is dead, and with the O_DSYNC patch
(P242d) everything it wrote is already durable. `:before` no longer includes the sentinel's 4 KiB.

Why: in the smoke run 42665923216 the sentinel survived the first clear on every node (`{:survived
3, :truncated 1}`), LazyFS's report said "all data blocks are synced!" and listed no inode, yet
`stat` showed 4096 bytes. Cause: LazyFS's `lfs_write` checks `get_cache_usage() == 100 &&
!APPLY_LRU_EVICTION` and, when the cache is full, `pwrite`s straight to the backing file instead of
caching the block (`lazyfs/src/lazyfs.cpp`, `cache_full`). Eviction is off (P242), and Nerva's
format writes its whole data file through the mount (the log shows one "sparse write", LazyFS's
zero-fill, at the format); those clean pages fill the 128 MB cache. The unsynced sentinel is then
durable at once and unreported. A clear empties the cache, so the sentinel of the second fault of a
node was cached and truncated: the one truncation in the run was on a node's second fault.
Candidates (a), (c) and (d) were not the cause; (b) is this one (the cache's state, not a flag).

Proof: run 42668765950 (`repro/sentinel-fullcache`) mounts the image's LazyFS with the Jepsen
config and writes one sparse 4 KiB block at the end of a 300 MB file with `O_DSYNC`. Cache usage
reads 100%, and an unsynced 4 KiB `dd` then survives a clear (report "all data blocks are
synced!"); the next round, on the emptied cache, loses it. With a 60 MB file (cache 46.9%) or a 1 GB
cache (29.3%) the sentinel is lost on the first clear. Without a replica file it is always lost,
which is what the earlier standalone runs showed.

The first-fault behaviour is not hidden: the fault is still the kill, then a clear on the replica's
real cache, then a sentinel proved lost by a second clear. If the cache is somehow full again the
sentinel still `:survived` and the verdict is `:unknown` with NRV-E0607.

What it costs: one more clear per fault. The same LazyFS behaviour means that on a full cache any
unsynced write is durable; Nerva writes `O_DSYNC` only, so it is unaffected, but a future file that
Nerva writes unsynced would not be lost by this fault until the cache is cleared. It should be
reported upstream to `dsrhaslab/lazyfs` with the O_DSYNC patch (owner).
