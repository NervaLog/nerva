---
id: N52
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Views maintained by the state machine: groups and their hash are replicated state.

`nerva view` (N35) keeps every row and change in memory and computes a view when it is read,
so memory, restarts and `as_of` all grow with history, and its hash shows two processes agree,
not that they are right. Owner's decision (option B over an incremental view process): views
are maintained inside the commit, like rows. This first step covers `count` and `sum`; `min`,
`max` and `as_of` come next, and `nerva view` stays for those until then.
- **Declaring.** `declare_view` (operation 133) takes a binary `ViewDefinition`: the view with
  its fields resolved to offsets by `nerva api` from the table's layout, so the state machine
  reads no JSON and no layouts. Views are immutable (`exists`, `different`), at most 64 in the
  cluster and 4 per table, with ids 1..64 in declaration order. `PUT /v1/views/<name>` declares
  into the catalog as before (for `nerva view`) and then into the state machine, and says
  whether the view is maintained.
- **Storage.** Two new grooves: `views` (tree ids 5, 6; 512-byte objects) and `groups` (tree ids
  7, 8; 256 bytes), keyed by `view_id << 64 | group_hash`, the group hash being the first 8
  bytes of SHA-256 of the view id and the group key. The group key (the group_by fields'
  bytes) is stored and compared on every update: a collision fails the view, on every replica
  at the same op, rather than merging two groups. Empty groups are kept, so that their history
  can be read later.
- **The hash** of a view is the sum, modulo 2^256, of its non-empty groups' digests; each change
  subtracts the old digest and adds the new, so it costs the same whatever the view's size, and
  every replica holds the same value at every op.
- **Maintenance in the commit.** Commit prefetch runs in three stages: the views, then the rows,
  then every group the request may touch (the old row's group and the put's new one, per view
  of the table; an all-zero row's for a creating add). Adds may not change a field a view
  filters or groups by (`view_key_field`), so an add never moves a row between groups and the
  prefetch needs no simulation of the commit.
- **Bounded per op.** Each LSM tree's tables are sized from its writes per op. Budgeting for the
  worst case (every entry of a commit, two groups in each of four views) would have needed
  about 1 GB of table memory per replica. Instead one op writes at most
  `StateMachine.groups_per_op_max` distinct groups (half a commit's entries, 4,095 in
  production, so the groups tree is the rows tree's size). A commit's group changes are
  coalesced in memory and each group is written once, at the end of the op.
- **Admission by distinct groups.** The first budget charged 2 per write per view, and made
  any transaction of more than about 2,000 writes to a viewed table permanently `views_busy`:
  the canvas demo's large strokes livelocked. What costs memory is distinct groups, so that is
  what is counted. In prefetch, from the rows as they are before the op, each transaction in
  request order adds the groups it may touch (for every write, in every view of its table, the
  old row's group and the put's, or a creating add's empty row's, where they pass the filter):
  a superset of what the commit touches, since an earlier transaction's put is counted by that
  transaction and adds never move rows. A transaction whose groups do not fit is refused whole
  with `views_busy` (status 14), at its first write to a viewed table, before any other check,
  and can be retried in a later op; later transactions of the op may still fit. Commit only
  reads the decision, so prefetch and commit agree by construction. A transaction is refused
  only if the op's distinct groups exceed about 4,000, whatever its number of writes.
- **Timestamps.** Objects need unique timestamps, and one entry may create a group in each view
  of its table, so a commit reserves a block of 5 timestamps per entry (its change takes the
  first). Change timestamps are now sparse; feed cursors are unaffected.
- **Backfill by pulse.** A view starts `building`. While one is, `pulse_needed` is true and the
  replica sends itself `pulse` (mapped from `vsr.Operation.pulse` to operation 134, as
  TigerBeetle maps it to its own): the pulse scans the table's rows from the view's cursor (a
  range scan over the rows' key index, `scan_unique_key_range`, a small vendored addition) and
  adds up to `groups_per_op_max` rows, then the view is `ready`. Commits skip a building view's
  rows at or past its cursor; the pulse reads them later as they are then. After a restart the
  state machine does not know whether a view is building, so one pulse finds out.
- **Reading.** `get_view` (operation 132) returns a header (state, declared op, the read's op,
  hash, group count) and a page of groups in storage order, by view id or by name;
  `GET /v1/views/<name>/groups` renders them through the layout as `nerva view` does.
- Tests: `views.zig` unit tests (validation, membership, the hash's order independence, a
  pinned group-key vector); deterministic state machine tests (maintenance across transactions,
  moves, deletes and stale reads; backfill in several pulses with writes on both sides of the
  cursor; refusals; paging); the VOPR declares random views and checks every ready view's
  groups, hash and group count against groups computed from the model's rows, reproduces
  `view_key_field` and admission (`views_busy`) exactly, and checks a ready view never builds
  again; `tests/views/maintained.py` backfills 5,000 seats and compares each answer with `nerva view`
  at the same op, recomputing the hash in Python. Mutation-tested: groups that never lose rows
  fail the unit tests and the VOPR (seeds 1, 3 and 7); rows past the cursor counted twice fail
  the backfill test; admission refusing one group early fails the VOPR (seed 7).
