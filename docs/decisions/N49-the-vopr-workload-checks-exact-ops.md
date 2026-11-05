---
id: N49
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# The VOPR workload checks exact ops, sends the inputs it never did, and reaches the limits.

An audit of the workload found what it generated and checked well, and what it never touched:
- **Exact ops.** Replies were checked only to be later than every op seen before. `vopr.zig` now
  passes the op each request committed at, and the workload asserts it exactly: each committed
  transaction's `op`, each lookup's `op_read`, and a complete feed or history reply's `end.op`.
  A reply reporting a later op than it executed at passed before.
- **Inputs never sent.** `op_seen` on a put, delete or add; kind zero; non-zero `reserved_a` or
  `reserved_c`; reads asserting a version no row has yet (they conflict); lookups with
  `RowKey.reserved` set (not found); and feed and history filters with reserved bytes set or a
  timestamp past `maxInt(u63)` (invalid: an empty reply).
- **Validation checked apart from itself.** The model took each entry's status from
  `nerva.entry_validate`, the state machine's own function, so a mistake there could not fail.
  `entry_status_check` now derives, from the rules `EntryStatus` documents, the set of rules an
  entry breaks, and requires `entry_validate` to accept exactly the entries breaking none and
  otherwise to name one it breaks. Which rule wins when several are broken stays
  `entry_validate`'s choice; an add's own parameters are `nerva_adds`'s (N46).
- **Limits.** Feed and history limits sometimes sit at `changes_limit_max`, just past it, or at
  `maxInt(u32)`, and must be clamped; lookups sometimes fill a batch to what the reply holds;
  about one commit request in a hundred is one transaction as large as the request allows,
  which runs prefetch and the state machine's scratch space at capacity. The model's scratch
  for a transaction's expected results is sized for that (`commit_entries_max`).
- **Cursors fed back.** The cursor an incomplete feed or history reply returns is kept and,
  sometimes, the next request continues from it, so the cursors the state machine hands out are
  themselves checked.
- In short-log mode the VOPR now prints the workload's end-of-run summary, with counters for
  each of the above, so a run shows what it exercised.
Signed adds were already generated (N42). Proven by planting bugs in the state machine, each
caught by a VOPR seed: see WORKLOG.
