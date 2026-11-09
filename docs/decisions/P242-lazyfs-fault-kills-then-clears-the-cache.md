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

## P242c: the fault is sound whether or not LazyFS honours O_DSYNC

(Superseded in part by P242d: the image's LazyFS now honours `O_DSYNC`, so a clear is no longer
amnesia. The sections below describe the harness before the patch and are kept as the record.)

The Opus review of this pull request found that P242's claim "the slice's claim is the minority
fault" does not hold if LazyFS drops `O_DSYNC` writes (#246): a clear then wipes everything the
replica wrote since it last opened its file (`src/io/linux.zig:1653-1662` fsyncs only at open),
which is replica amnesia, on one node as on five, and VSR does not tolerate amnesia of a majority.
Back-to-back minority faults with no catch-up could leave a majority amnesic, and a failure would
be the harness's. So #246's "the default fault is unaffected" was wrong; the fault is now sound
either way. Changes:

- **At most a minority is ever behind.** A fault does not act while a node it hit is pending
  (killed, not restarted) or unsettled (restarted, not seen serving). It first waits for them
  (`catch-up!`, 30 s) and is recorded `:skipped :not-caught-up` if they have not. "Caught up" is
  approximate: the replica process alive and every gateway healthy for 5 s (`settle-recovery`).
  No probe reads the replica's commit_max; filed in the follow-up issue.
- **The clear is confirmed.** After the clear the op reads LazyFS's unsynced-data report again until
  it is 0 (`:remaining`), so a fast restart cannot make the "lost" bytes durable first. The report
  before the clear stays `:unsynced-bytes`.
  Found by hosted run 42202316064 (the first with this check): after a clear LazyFS prints "all data
  blocks are synced!" and no byte total, which the first version read as no report, so every clear
  looked unconfirmed. `parse-report` reads both endings. The same cause explains the one `nil` before
  the clear in run 42200510496 (a restarted node with nothing unsynced).
- **The replica is judged.** The recovery probes the replica process too (`db/node-health`), not
  only gateways, which answer through the other replicas. NRV-E0604.
- **Victims are queued before the kill**, so a fault that throws (the LazyFS pipe timeout) still has
  them restarted and judged by the final recovery.
- **Only the final recovery is judged for availability** (`:final? true`, run after the heal). A
  mid-run recovery starts through `db/start-node-bounded!` (the replica, then `start-gateways!`,
  whose wait is bounded) and settles for at most 30 s; its outcome is recorded, because a concurrent
  `kill` or `partition` can remove quorum. The final recovery waits up to 180 s. The settle works
  whether `db/start!` waits for gateways (today) or returns early (`claude/jepsen-238-followup`,
  #244): after #244 merges nothing here changes, the probe just sees `:pending` first. If #244's
  `final-start?` covers this fault, the final gateway start also judges the gateways; this
  recovery's replica check stays. `lazyfs/package` is listed before `db-package` so its final
  recovery runs before the final start. When #244 lands, `umount!` goes inside its teardown
  `finally`, before `rm`.
- **The verdict counts completions, not invocations** (they are paired by order on the one nemesis
  process) and is `:unknown`, without a code (the harness, not Nerva, is at fault), when the fault was
  asked for and: a fault op threw; no final recovery ran; no fault took; none lost a byte; or a
  clear was not seen to take.
- The cache comment (128 MiB), the README and the namespace docstring no longer say `O_DSYNC` counts.

Once #244 merges (it makes `nemesis/final-start?` true for this fault too, and registers a separate
harness-failure code with `:valid? :unknown`), the final gateway start runs after a LazyFS fault and
`final-start-checker` judges the gateways, so this checker's gateway judging can defer to it; the
replica check and the harness `:unknown` verdicts stay. NRV-E0604 is used here only for a real
gateway or replica left down.

What it costs: faults are skipped while a node is slow to return, so a run may apply fewer; a run
where every fault is skipped is invalid. Until #246 is settled a minority verdict means "Nerva
survives a replica forgetting its data, one or two at a time".
