---
id: P242
date: 2026-11-06
area: Releases
---

# The lose-unfsynced-writes fault kills the replica, then clears LazyFS's cache

The decision: R1 slice 9's fault is a crash with lost writes, never a cache clear under a live
replica. `--nemesis lose-unfsynced-writes` mounts each node's `/opt/nerva/data` as LazyFS (pinned
to commit `9c5685e8...`, tag 0.3.0, built in the node image and checked with `git rev-parse`);
the fault is `:minority` (1 or 2 of 5 nodes) and, only with `--lazyfs-all-nodes`, `:all`, which
kills a majority first (the quorum crash), then the rest, and clears every node's cache. The undo starts the nodes it killed. The
op records LazyFS's own report of the unsynced bytes it dropped, so a run shows the fault took
something.

Why: clearing the cache under a running replica is not a failure a disk makes (the process would
read data that never was); a power cut kills the process and loses what was not durable. "All
nodes after a quorum crash" is read as the whole cluster losing power, with the majority dying
first, since that is the case where every ack a client saw must already be durable on a quorum.
The first hosted run with `:all` (retry, 300 s, run 42191880007) showed a problem: after the
whole-cluster loss every replica restarted empty (NRV-E0114 from the gateways, 2489 protocol
violations). The replica sets `O_DSYNC` on every data-file open in every mode
(`src/io/linux.zig:1454-1458`); `--development` only makes `O_DIRECT` optional (FUSE has none),
and `src/storage.zig:473-480` skips fsync because writes are `O_DSYNC`. The most likely cause,
not established, is that LazyFS does not treat `O_DSYNC` writes as synced and drops them on
`lose-unfsynced-writes`. It is tracked in #246 (confirm with strace and LazyFS's log, then make
LazyFS honour `O_DSYNC` in the test image; no Nerva change). Until then `:all` is off by default
(`--lazyfs-all-nodes` opts in) and the slice's claim is the minority fault: a node that loses
its writes is repaired from its peers. Recorded in `docs/demos/r1.md`. The data file moves into the
mount only when the fault is asked for, so other runs are unchanged.

What it costs: the node image builds LazyFS (a few minutes per run on a runner). LazyFS's own
build downloads toml11 v3.7.1 and spdlog 1.10.0 by tag and URL, not hash. The fault does not
gate R1 (P215e).

## P242b: the recovery judges the gateways it restarts

The fault restarts nodes through `db/kill!` and `db/start!`, which report no `:up` or `:down`, so
`nemesis/final-start-checker` never saw them and a run with only this fault passed the gateway
check with `:final-starts 0`. Now `:lazyfs-recover` probes each restarted node's gateways
(`db/node-gateway-outcome`, passed in as `:gateway-probe` because `lazyfs` cannot require `db`),
its completion carries `:down` and `:pending` as `[node index]` pairs, and
`lazyfs/recover-checker` (key `:lazyfs`) fails the run with NRV-E0604 on any, or on an
`:exception`. The change is local to the LazyFS path; the generic "gateways left down by
`db/start!` are never judged" fix on `claude/jepsen-238-followup` may overlap and can replace it.
