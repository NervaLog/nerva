---
id: N80
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# A new release keeps the data: `nerva export` from the old release, `nerva import` into the new one, which recomputes everything derived.

The owner's spec (NV-2, design approved before implementation). Until now an upgrade meant
reformatting and loading the data again (N32, N61). Data files are the vendored LSM's and change
with every release that touches a tree; the log is the source of truth, but a replica keeps only
the last 1,024 prepares (the WAL is a ring), so a release cannot replay operations it no longer
has. What every release can read is what a client reads, so that is what crosses the upgrade.
- **What is exported** (`src/nerva/export.zig`, a client of the running cluster): every change
  with `op <= as_of` (`--as-of=<op>`, or `latest`: the op of the export's first read), in feed
  order, with its op, timestamp and value, the reserved tables' included (catalog documents,
  documents); each maintained view's name, id and declaration op (`get_view` headers: the name
  is in the header's `group_key`, as the view listing reads it); each ledger's definition and op
  (`get_ledger` by slot, below); and checks: each view's state, hash and group count as of
  `as_of`, each ledger's total, and per table the live rows' count and the SHA-256 of
  `table, id, op, value` for each, in key order. The last two are computed from the feed, with
  one entry per row ever written held in memory. No `ViewDefinition` crosses: the importer
  rebuilds each view from its catalog document (`view.<name>`, JSON, in the feed) and its
  table's layout with the new release's `catalog` code, at its original id. A view without a
  catalog document (declared through the Zig client alone) is refused, assumed acceptable: every
  view a gateway declares has one.
- **The export file** (`export_file.zig`), release-independent: `NERVAEXP`, format version 1,
  then records framed as size, kind, a fixed little-endian body and a CRC-32, in sections
  (changes by timestamp, views by id, ledgers by op, view, ledger and table checks, a summary
  with the counts and `as_of`), then an `end` record holding the SHA-256 of every byte before
  it. The reader checks every CRC, the sections' order and contents and the counts, and acts on
  nothing until the SHA-256 matched. A change is 121 bytes on disk. Guarded by a golden export
  in `format_test.zig`; its format changes only with its version.
- **The import** (`import.zig`, `nerva import`, once per replica): pass 1 reads and checks the
  whole export and rebuilds the views' definitions before any file exists; pass 2 formats the
  data file and drives the state machine in process on real storage, as the throwaway prototype
  (`nv2-proto`, never merged) established a cluster needs: every op from 1 to the trigger of
  C, the first checkpoint at or after `as_of`, at its number, with a compaction beat after each
  and a forest, grid and superblock checkpoint at each trigger; then the WAL a replica leaves at
  C (C's prepare and empty pulses up to `trigger(C) + pipeline_prepare_queue_max + 1`, chained
  by parent, in both WAL zones, whole header sectors, wrapping the ring when C's slots do), and
  a superblock whose `commit_max` is that head, with the head as the view headers, so that C is
  durable and replicas repair nothing before C + 1. C's prepare carries the checkpoint id
  replicas would have given it. No client sessions. The importer reads no clock: every
  replica's file is the same. Then the checks run against the restored forest (a scan of every
  row); on a mismatch, a damaged export or a refused declaration it exits non-zero and removes
  the data file it created. An existing data file is refused, before anything is written
  (N81 hardens this).
- **Restore in the state machine** (`restore_prefetch`, `restore_changes`, `restore_view`,
  `restore_ledger`): in process only, never an `Operation`, so unreachable by clients. One op's
  changes become one batch of entries (an add was recorded as the put of its row's new value)
  and take the commit's prefetch stages unchanged (ledgers, views, rows, admission of groups and
  members, extreme scans), then are written by `row_put`/`row_delete` with their recorded
  timestamps, and `views_finish` maintains every view as a commit does. Nothing a commit
  validates is validated (ledger pairs, conserved writes, reads): the history already passed.
  It does refuse a history no commit writes: changes of another op, timestamps closer than an
  entry's block (`entry_timestamps`: the groups and members a change creates take the
  timestamps after it), a delete of a row that is not live, and an op over the group or member
  budget (the original op fit it; a release with smaller budgets refuses the import). Views,
  ledgers and every version take timestamps from the importer's counter, which starts past the
  export's last timestamp + `entry_timestamps`; C's prepare takes the counter plus one second.
- **A view at its declaration op**: `ready` if its table has no row (a tombstone counts) then,
  from a one-row scan in the restore's prefetch, and kept by every restored change after; else
  `building`, and the new cluster's pulses build it after start. Assumed, as approved: the as-of
  history of a view declared over existing rows does not survive (its versions start when the
  pulses build it), and its check is not compared at import (the import logs it); nor is a
  view's that was still building, or failed, in the export. A view declared before rows is
  `ready` from its declaration, while the old cluster built it at its first pulse a few ops
  later: as of an op in between, the old cluster answered `building` with fewer groups (writes
  wait for the pulse) and the restored one `ready` with all of them. From the old cluster's
  first pulse on, both answer alike (unit test).
- **What survives**: rows, versions (`op_seen` compare-and-set across the upgrade), history,
  `row?as_of`, the feed with its timestamps (a cursor taken before the upgrade continues),
  documents and layouts, ledgers at their ops, every view's answer and hash, and the as-of
  history of views declared before their table had rows. Not: client sessions (clients
  register again); the timestamps of views and ledgers (`get_ledger` returns one; nothing
  depends on it); the as-of history of views declared over existing rows. The new cluster's
  first op is past C.
- **`LedgerQuery.slot`** (from its reserved bytes, so that the exporter can list ledgers): a
  query by `slot` when `id` is zero, by `id` when `slot` is zero, all zeros otherwise. Safe
  because 0.0.4 has not shipped (the release string stays). The format guard's snapshot changed
  for this one struct; the VOPR queries by slot too.
- **Tests.** Unit (`state_machine_tests.zig`): a fixed history (a view with `min` and `max`
  declared before rows, a ledger moved by pairs, puts, deletes, adds, several transactions and a
  row written twice in one op, a view declared over existing rows) restored at its ops reads as
  committed: the feed byte for byte with its timestamps, rows, versions and histories, the
  ledger's total, the early view's hash latest and as of every op after the first pulse, the
  late view's after the restored side's pulses build it, and both then commit alike; restore
  writes a put of a conserved field that a commit refuses, and refuses a delete of an absent
  row. `export_file.zig`: a round trip; every byte flipped, every truncation, a byte appended,
  two records swapped, a record dropped, another version, each refused. `test:release`
  (`tests/release/upgrade.py`): a fixed script on this build (1,100 commits: layouts, puts,
  deletes, adds, reads, documents, a view before rows, a ledger with pairs, a view over existing
  rows), exported, imported by the `0.0.200` build into three replicas: both views, the view
  before rows as of past ops, the ledger and its total, every row's history and value, rows as
  of past ops, the feed page by page with its cursors, and documents read the same; a version
  read before commits, a cursor from before continues, the cluster commits on through a
  replica's loss and return; an export with one byte changed is refused and leaves no file.
  Both sides are builds of this commit: once a published release contains `nerva export`, the
  test fetches the previous release's binary, as CI fetches releases, to export with it.
- **Measured** (`perf/upgrade.py`: one `--development` replica loaded by `bench-load` c1, the
  harness's load generator (N55); ReleaseSafe, a 4-CPU sandbox; wall time and the process's
  peak RSS):

  | load | changes | rows | export | export RSS | file | import | import RSS |
  |---|---|---|---|---|---|---|---|
  | 1,024 puts a request (1,121 requests) | 1,147,904 | 670,720 | 4.6 s | 196 MiB | 139 MB | 8.2 s | 1,188 MiB |
  | 16 puts a request (63,227 requests) | 1,011,632 | 972,000 | 5.8 s | 365 MiB | 122 MB | 14.0 s | 1,188 MiB |

  The export's memory is its map of rows (about 380 bytes a row with the hash map's slack); the
  import's is the state machine and grid allocated up front, as a replica allocates them, the
  same at any size. Import time grows with ops (a compaction beat each) as well as with changes.
  Not measured: the nightly harness (N56) does not run it yet.
