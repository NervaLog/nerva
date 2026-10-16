---
id: P123b
date: 2026-10-16
area: "Milestone 3: positioned reads and the first views"
amends: N2
---

# Records: 128-bit ids and 448-byte values, written with rows in one transaction

**The gap.** Rows are 80 bytes under a 64-bit id (N2). The first application's facts
(executions, receipts, runs, leases, acts, obligations, deposits) are 100 to 260 bytes, keyed by
128-bit ids (docs/design/phase-b-storage.md), and must commit in the same transaction as the
money they record (G1). The owner chose records as proposed on 2026-10-16, over facts split
across several rows.

**The decision.**
- Tables `0x80000000` to `0xFFFEFFFF` hold records; tables below hold rows, as before; from
  `0xFFFF0000` up are Nerva's own (N34, P123). A record is `(table, id: u128)` → 448 bytes. It
  lives in trees of its own (`Record`, tree ids 18 and 19; `RecordChange`, 20 and 21), keyed by
  `record_key`: the table in the top 32 bits, then the first 96 bits of SHA-256 of
  `("nerva.record.v1", table, id)`. Two ids of one table with the same key: the second is
  refused with `id_collision` (about 10⁻¹³ for 10⁸ records of a table) and a lookup of it says
  `collision`; they are never merged.
- `commit_wide` (operation 9) takes 512-byte `WideEntry`s: rows' entries (their id in 64 bits,
  their value in the first 80 bytes) and records' reads, puts and deletes, in one transaction
  under the same rules, in the same order (keys, views budget, static checks, pairs, duplicate
  writes, stale reads). Records take no adds (`field_invalid`): a record is written whole.
  `commit` keeps its number and its 128-byte entries, writes rows only, and runs on the same
  code: its entries are widened.
- Reads: `lookup_records` (10), `get_record_changes` (11) and `get_record_history` (12), as
  `lookup_rows`, `get_changes` and `get_history`. Records' changes are a feed of their own, by
  timestamp; timestamps are shared with rows', so the two merge into one order.
- `nerva api`: a record table's `id` is 32 hex digits (16 bytes, as sent); a layout packs up to
  448 bytes, a bytes field up to 255; `/v1/commit` sends `commit_wide` when any entry is a
  record's, else `commit`; a lookup reads rows or records, not both; `/v1/changes` merges both
  feeds under one cursor; `/v1/history` and `/v1/row?as_of` take either.
- Export format version 2 carries records' changes; a cluster without records or indexes is
  still written as version 1, which every reader since 0.4.0 reads. Import restores the ops
  that wrote records through `commit_wide`, and checks each record table as it checks a row
  table.
- A vendored one-line patch: `ScanTree` counts a value block's values with
  `value_block_values_used`, as the rest of the LSM does; the old division required the block
  to be an exact multiple of the value size, which 512-byte values are not (UPSTREAM.md).

**Why.** Exact 128-bit ids and whole facts in one record keep clients simple: no reassembly,
no client-side collision handling, and indexes and views read one value. A second kind of row
in trees of its own leaves rows, adds, ledgers and their views exactly as they were.

**What it costs.**
- New tree ids and operations, the export format version 2, and the scan tree patch.
- A record is 512 bytes stored, and each write keeps a 512-byte change, six times a row's.
- No adds on records: a counter or a balance stays a row, written in the same transaction.
- A record's key keeps 96 bits of hash: a collision refuses an id for good.
