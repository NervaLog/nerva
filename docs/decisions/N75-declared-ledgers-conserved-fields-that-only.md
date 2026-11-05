---
id: N75
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Declared ledgers: conserved fields that only pairs of adds change.

The owner's spec (NV-1, design approved before implementation). Adds (N42) conserve value only
when the client pairs them correctly and picks the right bounds; a ledger of record must refuse
a bad move whoever sends it, as TigerBeetle refuses an unbalanced or overdrawing transfer. A
**ledger** is an immutable declaration of 2 to 16 conserved `i64` fields (`(table, offset)`),
each with an optional floor. Generic: a ledger could conserve seats or stock as well as money.
- **A core operation, not a catalog document.** `declare_ledger` (`reserved + 7`) and
  `get_ledger` (`reserved + 8`, which serves `GET /v1/ledgers/<id>`: the gateway keeps no state,
  so reading a ledger needs an operation of its own). The layout catalog is rows any client can
  put or delete, so a declaration kept there could be deleted and the balances overwritten after
  it; and the core does not read layouts (N34). Ledgers live in their own groove, `ledgers`,
  with tree ids 16 (`timestamp`) and 17 (`slot`), keyed by a dense `slot` (1..64, in declaration
  order) so that every op can prefetch them all, as views are (N52); the client's `id` is inside
  the definition. No table id reaches them. They are loaded at prefetch like views, and indexed
  in memory (`ledgers.Index`: the conserved fields sorted by `(table, offset)`, found by
  bisection); the index only grows, since ledgers are immutable, and is rebuilt after a reset.
  `Ledger` is 512 bytes: grooves need a power of two.
- **Declaration rules.** `DeclareLedgerStatus`: `created` 1, `exists` 2 (the same definition
  again; it names the op it was declared at), `ledger_immutable` 3, `ledger_field_taken` 4 (a
  field already in another ledger), `invalid` 5, `table_invalid` 6, `ledgers_full` 7, and
  `field_viewed` 8 (a view the state machine maintains filters or groups by a field). Fields
  must be strictly ascending by `(table, offset)` (assumed): one canonical form per set of
  fields, so that "identical" is byte equality and duplicates are refused; `nerva api` sorts
  them. Offsets are 8-aligned and at most 72; a floor's bytes are zero without its flag. At most
  64 ledgers, 16 fields each. A ledger may be declared over rows that already exist: its total is
  then whatever it was at that op (Nerva has no scans to check).
- **Pairs** (`AddFlags.pair`, from its padding). An add is conserved when its `(table, offset)`
  is a ledger's field. A first half (`pair`) at `i` needs its partner at `i + 1`: a conserved add
  of the same ledger whose `delta_from` is `i`, without `pair`, `clamp`, `min` or `max`, and not
  on the same field of the same row. Anything else is `unpaired` (`EntryStatus` 16): a conserved
  add outside a pair, another add naming a first half, and (assumed) `pair` on an add outside
  every ledger. The index is the first half's when its partner is missing, the partner's when it
  breaks a rule. Checked in `commit_failure` after the per-entry checks and before
  `write_duplicate`, from the entries and the ledgers alone.
- **Floors.** `nerva.ledger_bounds(add, floor)` raises a conserved add's `min` to its field's
  floor (pure, shared by the state machine, the VOPR model and the fuzzer; `add_amount` is
  unchanged). The first half may clamp there; the partner never does, so a partner its floor or
  the `i64` range stops fails the transaction `out_of_bounds`. A field below its floor moves back
  up freely.
- **Other writes** are `conserved_write` (`EntryStatus` 17): an add that overlaps a conserved
  field without matching it (an exact match that is not `i64` too, assumed), checked per entry
  in `commit_failure`; a put that changes a conserved field's bytes, or a delete of a row where
  one is not zero, checked in `adds_resolve` in entry order. An absent row is zeros. A put or
  delete is the only write to its row in its transaction (`write_duplicate`), so the stored row
  is what it changes. An add with `create` starts from zeros, and is allowed.
- **Views.** A maintained view may not filter or group by a conserved field (adds would move
  rows between groups and be refused `view_key_field`): `field_viewed` for a ledger declared
  after such a view, `DeclareStatus.ledger_field` (10) for a view declared after the ledger.
  `nerva api` now sends `declare_view` before writing the view's catalog document, after
  checking the catalog for a different declaration under the name as before, so a view refused
  over a ledger's field answers 409 and leaves no document (owner's choice; N78 refines which
  answers write one). Only views the state machine maintains are checked (assumed): one it
  refused lives only in `nerva view`, which recomputes it on read, so adds never touch it.
- **The invariant**: for every ledger, the sum of its fields over all rows equals the sum at its
  declaration's op, and no field moves down past its floor.
- **Numbers.** The spec named `unpaired = 15` and `conserved_write = 16`; `views_too_large`
  took 15 first (N72), and persisted values are never renumbered, so they are 16 and 17. The
  release string stays `0.0.4`: it has not shipped.
- **Tests.** `state_machine_tests.zig`: pairs, every `unpaired` case, floors with and without
  `clamp` and own bounds, partners stopped by a floor or the `i64` range, a field below its floor,
  puts, deletes and straddling adds, declarations (identical, different, taken, invalid, full,
  reloaded after what a reset forgets, untouched by writes to every table id), views in both
  orders, and a sum view following pairs. VOPR (`workload.zig`): a ledger over 2 to 5 accounts
  and a source; moves (fund, reserve, post, void, clamped or not) and transactions that must not
  change it, after the ledger is known declared; the model mirrors the checks in the state
  machine's order, with the pair rules written apart from its scan; `check_ledger` asserts the
  invariant after every commit from the adds' results alone. `adds_fuzz.zig`: floors and the
  partner's arithmetic against the reference, and conservation. `tests/api/ledgers.py` (in
  `test:api`): fifty threads of clamped reservations through two gateways, a sum view answering
  the funded total, every refusal. The format guards gain the new types, statuses, operations
  and tree ids, and the fixed script a ledger, a clamped pair and a refused put. Mutation-tested:
  floors not applied, puts and deletes not checked, straddling adds not checked, each fail the
  unit tests and the VOPR; `ledger_bounds` taking the lower bound fails the fuzzer.
