---
id: P123e
date: 2026-10-16
area: "Milestone 3: positioned reads and the first views"
amends: N80
---

# An export with rows or views in the record range is refused by import, by name

**The decision.** Before P123b, rows could live in any table below `0xFFFF0000`. Since P123b,
tables `0x80000000` to `0xFFFEFFFF` hold records. `nerva import` now refuses an export that has
a row change in that range, or (in format version 1) a view over a table in it. It logs the table
and how to move it (#126). The upgrade steps say to move such rows below `0x80000000` with the
old release first.

**Why.** Restoring them as rows would put rows where every read, index and view now expects
records. Before this check, the import crashed on them. Converting them to records would guess at
ids and values that the export does not hold.

**What it costs.** A cluster that used tables from `2^31` up must copy those rows to lower
tables, and rename them in its clients, before upgrading. The adversarial review found the case;
no known cluster uses those tables.
