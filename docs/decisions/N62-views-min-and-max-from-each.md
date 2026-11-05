---
id: N62
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Views' `min` and `max` from each group's members in order; views read as of any op.

The second step of N52 (design approved by the owner before implementation). After it, every
aggregate `nerva view` offers is maintained by the state machine, and a view reads as of any
committed op since its declaration.
- **Members.** `count` and `sum` change by adding and subtracting; `min` and `max` cannot: when
  the row holding a group's minimum leaves, the new minimum is another row's. So every `min` or
  `max` slot keeps, for each row in the view, a `Member` (tree ids 9 to 11; 128 bytes): keyed by
  view, slot and row, and, while the row is in a group, indexed by `order`, the group's 64-bit
  prefix (SHA-256 of the view id, the slot and the group key) then the value, encoded so that it
  sorts as the field does (signed fields with the sign bit flipped; every comparable field is at
  most 64 bits). A group's slot is the first member of its range in `order` (`min`) or the last
  (`max`), and the group stores it, so reads cost nothing more. Members are never removed: a row
  that leaves the view keeps its member, out of the order. The member stores its group key: a
  prefix shared by two groups is found when the order is read, and fails the view at that op on
  every replica, as a group hash collision does (N52).
- **Exact at every op, with no IO in commit.** Commit prefetch gains two stages. Stage 3
  prefetches the member of every admitted write in every `min` or `max` slot of its table.
  Stage 4 counts, per group and slot, the writes that may take a member out (from the rows as
  they are before the op, a superset, as admission's count is), `r`; and where one of them may
  take away the member holding the group's value, reads the first `r + 1` members of the order,
  one scan each: at least one of them is untouched by the op, unless the slot has no more. At
  the end of the op each touched group's slot is the best of the members the op brought into it
  and either its stored value (if the op did not take away its holder) or the first untouched
  member read. The view's hash and group count are now kept there too, once per group per op,
  from the group as stored and as left.
- **Bounds.** At most 4 `min` and `max` slots per table, across its views (`declare_view`
  answers `table_extremes_full`, status 9). One op writes at most a request's entries' worth of
  distinct members (`members_per_op_max`, 8,190 in production), and admission counts them as it
  counts groups (N52): a write counts its member in each `min` or `max` slot of each view whose
  filter its old or new value passes, and a transaction that would take the op past the limit
  is refused whole (`views_busy`). With one such slot on a table any request fits; with k, a
  transaction of more than 8,190 / k writes to that table never does: 4,094 with two, 2,047 with
  four (measured; this said two slots fit any request, corrected after the 0.0.4 hardening pass,
  and such a transaction is refused `views_too_large` since N72). The owner chose
  this over sizing the members trees so that nothing is ever refused: measured on one replica
  (`--development`, RSS after start), `main` takes 1,014 MiB, this change 1,295 MiB, and with
  members sized for 4 × a request's entries 1,953 MiB. The 281 MiB are mostly the two version
  trees. A pulse adds at most as many rows as both limits allow (`backfill_rows_max`). The scans
  of stage 4 count each member once, so they read at most twice as many members as the op may
  touch. Each entry's block of timestamps grows from 5 to 9 (its change, a group in each of 4
  views, a member in each of 4 slots); a pulse's rows take the same blocks.
- **As of an op.** Two append-only trees, like the changes: `group_versions` (tree ids 12, 13;
  256 bytes), the group as each op that changed it left it, and `view_versions` (14, 15; 128
  bytes), the view's state, hash and group count likewise, written once per op at the end of
  the op. Each op reserves timestamps for them, below its writes' (`group_writes_limit` plus
  `views_max`), so entries keep the top of the op's range as before. A version key orders a
  group's versions by op (`view_id`, the group hash, then the op in 57 bits: ops below 2^57).
  `ViewQuery.as_of` (zero: the latest; the last 8 of v0.3.0's 12 reserved bytes, which its
  clients send as zeros, so their queries still read the latest) reads the view's last version at or before `as_of`, then walks the
  current groups in storage order (groups are never removed) and reads each one's last version,
  one scan per group: so an `as_of` page holds at most 128 groups (`view_as_of_limit_max`). A
  group with no version then did not exist yet; a view with none, `missing`. `as_of` past the
  read's op reads the latest. History is kept forever, as rows' is.
- **API.** `GET /v1/views/<name>/groups?as_of=<op>` (refused for an op not yet committed, as
  `GET /v1/row` is; `404` before the declaration), and every group renders each aggregate as
  `<fn>_<field>`, as `nerva view` does. The reply now carries `declared_op`. `PUT /v1/views`
  says `"maintained": true` for `min` and `max`; `unsupported` (status 8) is no longer returned.
- **Tests.** Unit tests for the ordered encoding, member keys and order prefixes and version
  keys; golden values for all four (computed in Python) in the derivations guard. The state
  machine tests' harness now compacts and checkpoints as the replica does, so a test may run
  for hundreds of ops: a randomized test (ids few and prices fewer, so that ties are common;
  puts, deletes and adds; several transactions per op) compares two views, with four `min` and
  `max` slots over unsigned and signed fields, to a brute-force model after each of 300 ops,
  after a backfill with commits between the pulses; then reads every one of those ops back as of
  it, and as of before and at the declaration. The VOPR declares views with random `min`, `max`
  and `sum` slots, predicts `table_extremes_full`, checks ready views' slots against the model
  (computed apart from the members), reads as of random past and future ops against the rows
  replayed from the model's change feed, and checks that a view read ready as of an op is never
  building as of a later one. `tests/views/maintained.py` adds a view with `min` and `max`, and
  compares both views with `nerva view` latest and then as of every op compared before.
- **The canvas demo** declares a view with a group per pixel and `max`, maintained since this
  change: its reset, one transaction of 4,096 pixels, needed one group more than an op takes and
  was refused forever, and `commit_retrying` retried it forever (found by `test:demo`). The
  owner chose to reset in two transactions of 2,048 pixels; an epoch starts at the second.
- **Mutation-tested.** In the state machine: reading one member instead of `r + 1`, ignoring that
  an op took away a group's holder, and reading versions as of `as_of - 1` each fail the
  randomized unit test. The VOPR's comparison is live (every `min` and `max` set to zero fails
  seeds 1 and 13), but the two subtler of those bugs pass seeds 1, 2, 3 and 13: its few reads of
  ready views rarely meet a group whose holder left, or a group changed at exactly `as_of`.
  The unit test is what guards them.
- **Release `0.0.4`, clients from `0.0.4`** (owner's decisions, on N32 and N60). What a commit
  does on every replica changed (9 timestamps per entry, a reserve per op, trees 9 to 15), so a
  `0.0.3` and a `0.0.4` replica would diverge: the release string moves, data files must be
  reformatted, and N61 keeps replicas of the two releases apart. Clients of v0.3.0 are refused:
  a v0.3.0 `nerva api` asserts that a maintained view's aggregates are sums, and does not know
  status 9, so against this cluster it would crash on a `min` or `max` view. Measured: a `0.0.2`
  `nerva api` is evicted at registration with `client_release_too_low`, and then segfaults, an
  older bug in the client's eviction (#48). `ViewQuery` keeps v0.3.0's layout regardless:
  `as_of` takes the last 8 of its 12 reserved bytes, so had old clients been kept, their
  queries would still read the latest. The formatted data file's golden checksum is unchanged,
  as for `0.0.3` (N60).
- **Format guards** (N54) updated, as they should fail on all of this: the layouts snapshot
  gains the three new types, tree ids 9 to 15, `table_extremes_full` and `ViewQuery.as_of` in
  its reserved bytes; the script snapshot's change timestamps step by 9 per entry, plus each op's reserve
  for versions.
