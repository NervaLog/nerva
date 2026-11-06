---
id: P242
date: 2026-11-06
area: Releases
---

# The lose-unfsynced-writes fault kills the replica, then clears LazyFS's cache

The decision: R1 slice 9's fault is a crash with lost writes, never a cache clear under a live
replica. `--nemesis lose-unfsynced-writes` mounts each node's `/opt/nerva/data` as LazyFS (pinned
to commit `9c5685e8...`, tag 0.3.0, built in the node image and checked with `git rev-parse`);
the fault is `:minority` (1 or 2 of 5 nodes) or `:all`, which kills a majority first (the quorum
crash), then the rest, and clears every node's cache. The undo starts the nodes it killed. The
op records LazyFS's own report of the unsynced bytes it dropped, so a run shows the fault took
something.

Why: clearing the cache under a running replica is not a failure a disk makes (the process would
read data that never was); a power cut kills the process and loses what was not durable. "All
nodes after a quorum crash" is read as the whole cluster losing power, with the majority dying
first, since that is the case where every ack a client saw must already be durable on a quorum.
Nerva writes with `O_DSYNC` and no explicit fsync; the kernel turns that into a FUSE fsync, which
LazyFS honours, and `nerva_main.zig` runs a `--development` replica without direct IO, which FUSE
needs. The data file moves into the mount only when the fault is asked for, so other runs are
unchanged.

What it costs: the node image builds LazyFS (a few minutes per run on a runner). LazyFS's own
build downloads toml11 v3.7.1 and spdlog 1.10.0 by tag and URL, not hash. The fault does not
gate R1 (P215e).
