---
id: N42
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Adds: conditional, commutative changes to a field, applied inside the commit (G8).

Optimistic transactions serialize every client of a hot row through retries. An `add` entry
(`EntryKind.add = 4`) changes one 64-bit field of a row (`u64` or `i64`, little-endian, at a
byte offset ≤ 72) inside the commit, reading the current value there, with no version check:
two adds to one row never conflict.
- **Parameters** live in the entry's 80-byte value (`nerva.Add`): `delta`, optional `min` and
  `max` (as the field's type), flags `clamp`, `create`, `delta_from`. `Entry` stays 128 bytes.
- **Bounds bind in the direction of the move.** An add never moves the field past `min` (delta
  negative) or `max` (positive), nor out of the type's range: the transaction fails with
  `out_of_bounds` (the result carries the field's current value), or, with `clamp`, the add
  applies as much as fits, possibly nothing. A field already outside its bounds may move back
  towards them; that makes clamping and failing agree exactly (`nerva.add_amount`, shared by the
  state machine, the VOPR model and the API).
- **`delta_from: k`** makes the delta minus what earlier add `k` of the same transaction
  applied. "Reserve up to X" is `add(available, -X, min 0, clamp)` then `add(held, delta_from 0)`:
  it can never overdraw, and money is conserved by construction. A delta of `minInt(i64)` is
  invalid, so every applied amount can be negated.
- **Transactions.** Static checks, then duplicate writes, then read versions, then adds in
  entry order (resolved against the rows and the transaction's earlier adds, without writing),
  then everything applies. Several adds may change one row (`available` and `held` in one row);
  an add and a put or delete of one row is `write_duplicate`. A row that does not exist (or is
  deleted) is `row_absent`, unless `create` starts it from zeros.
- **Results.** `EntryResult` grows from 16 to 32 bytes: `applied` (signed) and `value` (the
  field after the add, or before it for `out_of_bounds`). New statuses are appended:
  `out_of_bounds` 9, `row_absent` 10, `field_invalid` 11, `delta_from_invalid` 12.
- **The feed.** Each add is a change of kind `put` carrying the whole new row, so history,
  as-of reads, views and every reader of the feed are unchanged.
- **Tests.** Unit tests of the arithmetic and validation; deterministic state machine cases;
  the VOPR model resolves adds independently and checks every `applied` and `value`, and plays
  hot budgets (fund, reserve, release by adds only) asserting, apart from the model, that each
  budget's available plus held equals what was funded and that adds alone never fail;
  `tests/api/adds.py` races fifty reservations through the JSON API.
- **Found on the way:** two writes in one op that leave a row's bytes unchanged (an add that
  applies nothing after another write in the same request, or two identical puts in two
  transactions of one request) tripped the LSM groove's assertion against no-op updates, which
  would have crashed every replica. The row update is now skipped when nothing changed; the
  change is still recorded.
- **The release string** moves to `0.0.2` for this protocol change: N43.
