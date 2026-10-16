---
id: P123
date: 2026-10-16
area: Foundations (recorded after the fact)
amends: N4
---

# A transaction may carry a commit key: sent again, it commits at most once

**The gap.** A client that loses a commit's reply (a gateway times out after 30 s, a connection
drops, a gateway displaces a request part-way through: #120) cannot tell whether the commit
applied. TigerBeetle's client resends within its session and gets the original reply; a Nerva
gateway is HTTP, one request per connection, and reconnects with a new session, so that
guarantee does not reach the caller. The first production application rebuilt it on top
(Botpike/app P99: read back, re-plan, resend with absence assertions, failure marks in a second
transaction), and still leaves money held when Nerva stays unreadable past its bound. The owner
agreed in session on 2026-10-16 that Nerva should close it, as a general capability.

**The decision.**
- A transaction may start with a `key` entry (`EntryKind.key = 5`): `table` and `id` zero, a
  non-zero 128-bit key in `value`'s first 16 bytes, the rest zero (else `key_invalid`). A `key`
  entry anywhere else is `key_misplaced`. Clients choose keys; a key names one logical
  operation, not one attempt.
- When the transaction commits, the state machine writes the key's row in the same op: table
  `0xFFFF0003` (`table_commit_keys`), id `commit_key_id(key)` (the first 8 bytes of
  SHA-256 of `"nerva.commit_key.v1"` and the key), value a `CommitKey`: the key, `vsr.checksum`
  of the entries after the key entry, and their count. Only `key` entries write the table: any
  other entry naming it is `table_invalid`. The row is written once and never changed, so its
  op is the op its transaction committed at.
- A transaction whose key's row exists commits nothing. Checked first, before the views budget
  and every other rule, because a resend must be recognized whatever changed since (its own
  reads are stale by then, and a view declared since may refuse its adds). Its key entry
  reports, with the row's op: `committed_before` when the row holds this key and these
  entries; `key_reused` when it holds this key and other entries; `key_collision` when it
  holds another key whose id is the same. The other entries report `aborted`. Admission to the
  op's views budget skips such a transaction, so a resend cannot crowd out new work.
- A transaction that does not commit writes no key. Its resend executes again, which is what a
  client wants: nothing applied the first time.
- `nerva api` takes `"key"` (32 hex digits) on `/v1/commit`, sends the key entry first, and
  answers with the request's own indices: a resend `200 {"status": "committed", "op",
  "replayed": true}`, a reuse or collision `409` with the op.
- The release string moves to `0.0.6`: a 0.0.5 replica would refuse `key` entries that a 0.0.6
  replica commits, so the two must not share a cluster (N61). `release_client_min` stays
  `0.0.4`: clients only gained an entry kind. Data moves by export and import (N80); key rows
  are ordinary rows of the feed and move with it.

**Why this shape.**
- A row of a reserved table, not a new LSM tree: prefetch, history, export, import, and the
  change feed already handle rows, and the catalog and documents already live in reserved
  tables. A tree keyed by the full 128 bits would need new `tree_ids` and grooves for no gain
  a collision check does not give.
- A checksum of the entries, not their results: a row is 80 bytes and a transaction may have
  thousands of adds. The client reads what a replayed transaction did as of its op (G6), and an
  application that needs an amount later already records it (as Botpike's balancing transfers
  do, with `delta_from` into a row of their own).
- One status per case, because each tells the client something different: `committed_before`
  (done, at this op), `key_reused` (some attempt of this operation committed; a client that
  re-plans its entries between attempts reads this as done too), `key_collision` (nothing
  committed under this key, ever: pick another).

**What it costs.**
- One 80-byte row and one change per keyed transaction, kept forever. No retention yet: a key
  must stay as long as a resend can arrive, and Nerva has no bound on that. Retention can come
  with the Phase B storage design (docs/design/phase-b-storage.md).
- A 64-bit row id: about 3 in 10,000 that two of 10⁸ keys collide. A collision refuses the
  second key and proves nothing applied under it; it never merges two operations.
- A resend's reply carries no adds' amounts, and `/v1/documents/commit` takes no key yet.
- The key's row is in the feed's reserved range: `nerva api` leaves it out of `/v1/changes`, as
  it does the catalog and documents; a Zig client following the raw feed sees it.
