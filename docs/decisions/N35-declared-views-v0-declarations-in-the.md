---
id: N35
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Declared views v0: declarations in the catalog, computed on read in `nerva view`.

The demos' "Declare" moment, and Nerva's core claim, need views that are data rather than code.
- A view is `{table, where, group_by, aggregates}`: `where` ANDs up to four comparisons on
  numeric or bool fields; up to three `group_by` fields of any type; one to six aggregates
  (`count`, `sum`, `min`, `max`). It is declared with `PUT /v1/views/<name>` on `nerva api`,
  checked against the table's layout, stored in the catalog as `view.<name>`, and immutable:
  the same declaration again is "unchanged", a different one under the name is 409. Changing
  a view means declaring a new name. Deleting views is not supported yet.
- Semantics: over the table's rows as they are at op N (deletes remove rows), not over events.
  This fits the demos: seats sold and revenue per section, pixels per color.
- `nerva view` mirrors the catalog and every application table (not Nerva's own) from the feed, with every change, in memory, capped at two million changes;
  past that it stops rather than answer wrongly. A view is computed when read, over current
  rows for the latest answer or over rows replayed to op N for `as_of`. Consequences: a view
  answers for ops before it was declared, declaring needs no backfill, and reads cost
  O(rows) (latest) or O(changes up to N) (as of). Incremental maintenance and snapshots are
  later steps; this computation stays as their oracle.
- An answer at op N waits until the view process has seen op N (else 504), as for ledger
  `as_of` (N28).
- Each answer carries `hash`, SHA-256 of the `groups` JSON exactly as served (groups sorted by
  key, fields in declaration order, 64-bit numbers as decimal strings), so any two processes,
  or a reader recomputing it, can check agreement.
- `nerva view` takes its key from `NERVA_KEY` and checks `X-Nerva-Key`.
