---
id: P90
date: 2026-10-06
area: "Milestone 3: positioned reads and the first views"
amends: N81
---

# Data files record their export; replicas of other exports are refused; release 0.0.5

Extends N80 and N81 (#81). Replicas imported from two exports that reach one checkpoint met
there with different logs, and the odd one panicked in the vendored journal
(`find_latest_headers_break_between`) after the view change: loud, but an assertion, not the
operator's mistake named. Import cannot see the other replicas' files, so the check is where
replicas meet. Chosen by the owner over comparing the checkpoint ids pings already carry (no
format change, but blind to exports that reach different checkpoints).
- **The export's identity** is the SHA-256 its `end` record holds (N80): `nerva export` prints
  it, `nerva import` logs it and writes it to the data file, `nerva start` logs it. Two exports
  of one cluster at different ops are different exports, even with no write between them.
- **On disk:** `VSRState.origin: [32]u8`, from the superblock's reserved bytes; zero for
  `nerva format`. Every superblock update copies the VSR state, so it lasts the file's life;
  `monotonic` asserts that nothing after the root state changes it. A formatted file's bytes are
  unchanged (the golden checksum holds).
- **On the wire:** pings and pongs carry `origin` in their reserved bytes. A 0.0.4 replica
  rejects them (`reserved != 0`); it ignores a peer of another release anyway (N61).
- **The gate** (`release_peers.zig`, N61's): a peer's messages are handled only once its ping or
  pong has announced this replica's release and origin. A prepare does not name its sender, but
  names the primary that made it: it is refused when that primary last announced (on any connection
  since this replica started) another release or another origin, and admitted otherwise, for any
  client release this replica accepts. A maker not heard from must be admitted: if the primary dies
  and the others restart, neither can hear from it again, and they repair its prepares from each
  other. (A first version admitted an older client's prepare only from a maker known to run this
  release, so that a real v0.4.0 replica's prepares, which carry 0.0.4 too, could not slip in before
  its first ping; the review of #90 found that it wedged that cluster, since what a peer announced
  lives in memory only. Persisting it would be another on-disk change for a narrow race; rejected.)
- **Left open, and why it is acceptable:** a prepare from a replica of another release or export
  that arrives before its maker's first ping is not refused by the gate. It still cannot do harm
  silently: its checkpoint id is another lineage's, and a backup in normal status stops on the
  vendored `checkpoint diverged` panic before it acknowledges it; peers ping on connecting, and no
  test has reached it.
- **A prepare carries its client's release**, not its primary's (the vendored primary copies the
  request's). N61 admitted only prepares of the replica's own release, so every backup dropped the
  prepares of an older accepted client's requests, its registration included, and a cluster of more
  than one replica could not serve it. This is as old as N61: v0.3.0 accepted clients from 0.0.2,
  which could not even register with a cluster of more than one replica; v0.4.0 hid it by accepting
  clients of its own release only (#93). With clients from 0.0.4 the test found it (a 0.0.4
  gateway's registration timed out with one replica down).
- **The refusal:** a replica exits with `origin_mismatch` (status 8) once so many of the cluster's
  replicas announced another origin that the rest, with it, can never reach the larger of the
  replication and view-change quorums (three replicas: two others; six: three). Its message names
  both exports and says to import it again. The others log once that they ignore it and run on. With
  three exports in a cluster of three, a replica stops once it has heard both others, before it
  answers the second; so the last may have heard neither before they stopped, and then stays up
  alone and commits nothing (the test allows either). Nothing from a peer of another export is
  handled, so nothing of it is written to the refused replica's file.
- **What it costs:** a replica of an imported cluster cannot be replaced by `nerva format` (its
  origin is none, and an imported cluster refuses it). Nor is it safe to replace it by importing it
  alone from the cluster's export, though that replacement joins and catches up: it has forgotten
  every prepare the lost replica acknowledged, so a view change after one more failure could leave
  out an op committed with that acknowledgement (upstream's `replica_reformat.zig` exists for this:
  a reformatted replica first commits a pipeline of requests and takes a view two past the
  cluster's, so that it makes no promise it cannot keep). Until a replacement takes the same
  precautions (`import --replace` or `nerva recover`, its own design), the only safe replacement is
  a new export and import of every replica. A replica imported from the export that has never
  started has acknowledged nothing, and may start late. Seen in CI on this change's first test:
  replica 0 lost and imported again joined a view change, and replica 2 then stopped on the vendored
  assertion that a new view's op is at least its commit_max (`set_op_and_commit_max`, from
  `on_view`): the view the amnesiac replica helped form ended below an op replica 2 knew committed.
  The test no longer does it.
- **Downgrade:** a v0.4.0 replica given a 0.0.5 data file stops and writes nothing (its SHA-256
  unchanged), but not with a message: a formatted file reaches the vendored `multiversion
  unsupported` panic, as any other release's file has since N61 (#95), and an imported one an
  assertion that the superblock's reserved bytes are zero, which `origin` now holds. v0.4.0 cannot
  change; going back means exporting with 0.0.5 and importing with v0.4.0, which reads the export
  (format version 1; checked on a small export).
- **Release 0.0.5**, clients from 0.0.4 (`release_client_min`): client messages did not change,
  so v0.4.0's clients and gateways (Botpike's APP-L2 and INF-1) keep working. Data files move to
  0.0.5 by export and import, as N80. `VERSION` is unchanged: the owner decides when it ships.
- **Tests.** Unit: the gate by release and origin, prepares by their client's release and their
  maker, the refusal at the quorum's edge for 1 to 6 replicas (`release_peers.zig`); the export
  file's digest from writer and reader, and another export's differing (`export_file.zig`); a
  formatted file's origin, all superblock copies (`import.zig`); the header offsets (comptime).
  `tests/release/origins.py`: three exports before the first checkpoint; replica 0 (the first view's
  primary) from B, replicas 1 and 2 from A: replica 0 exits 8 naming B, 1 and 2 commit on; one
  export each: two or three exit 8, and one left up commits nothing; replicas 0 and 1 from A commit
  past a checkpoint, replica 2, imported from A and never started before, then joins and carries the
  quorum with replica 1 stopped; a `nerva api` built as 0.0.4 commits and reads, and commits again
  after its primary dies with commits in flight and both others restart (a liveness check only: it
  passes on the earlier gate too, so it does not reach the repair the review described; the gate's
  decision for a maker not heard from is pinned by the unit test, which fails on the earlier gate).
  No log shows a panic. VOPR: the `nerva` lane's release is 0.0.2, accepting clients from 0.0.1; its
  clients run 0.0.1 or 0.0.2 by seed, so older clients' prepares cross the gate under faults, and
  every replica's origin, reformatted ones' too, is none or random by seed.
