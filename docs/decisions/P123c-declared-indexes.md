---
id: P123c
date: 2026-10-16
area: "Milestone 3: positioned reads and the first views"
---

# Declared indexes over records: by `eq` fields, then an order, maintained in every commit

**The gap.** Nothing found a row or record except by its id, and the first application reads
its facts by foreign key, by status and age, and by agent (docs/design/phase-b-storage.md).
The owner chose indexes without reads as of a past op at first, on 2026-10-16.

**The decision.**
- `declare_index` (operation 13) declares an `IndexDefinition`: a name, a record table, up to
  three `eq` fields (64 bytes between them), an `order` field (a number or a bool; without one,
  the op of the record's last write), and up to four `where` clauses (as views', N52), which
  make it partial. Immutable: the same definition again is `exists`; another under the name is
  `different`. At most 64 indexes, and 4 per table.
- The state machine keeps every index exact in the commit that writes a record: an
  `IndexEntry` per index and record it has seen (tree ids 22 to 26), keyed by index and record,
  and positioned by a 64-bit hash of the `eq` bytes, then the order value, then a timestamp.
  An index declared over records already written is `building` until pulses have added them,
  as views build (N52), and answers no scan until then.
- **Ties order by the record:** an entry's timestamp is its record's own (fixed when the record
  is first written), plus its index's slot among the table's indexes. Records with equal `eq`
  and order values therefore list in the order they were first written, whether a commit or a
  pulse wrote their entries, and the same after an export and import, which rebuilds indexes by
  pulses.
- `scan_index` (14) reads one `eq` key's records from `order_min` to `order_max`, either way,
  a page at a time, with the records themselves, at the op it executed (G2). A page's header
  names the cursor of the next. Another key whose hash is the same is skipped when the page is
  read. `get_index` (15) reads a declaration, its state and its count of records.
- `nerva api`: `GET /v1/indexes`, `PUT` and `GET /v1/indexes/<name>` (fields by their layout's
  names), and `POST /v1/indexes/<name>/scan` (`eq` by field name, `min`, `max`, `descending`,
  `limit`, `after`); 503 while building.
- Export does not carry entries: import declares each index at its op, building, and pulses
  rebuild it.

**Why.** Equality then one order is every read the application makes (no query in it sorts
otherwise), and it is one range scan of one tree. Entries maintained in the commit keep an
index exact at every op, with no lag to wait for. Deriving the entry's timestamp from the
record makes the order a function of the records alone, which a cursor kept across an upgrade
needs.

**What it costs.**
- One 128-byte entry per record and index the record has entered, kept (absent) after it
  leaves.
- No reads as of a past op: a scan reads the latest state. Reads of the past go through
  history (G6) and views (N62).
- The order is within one `eq` key; there is no scan across keys.
