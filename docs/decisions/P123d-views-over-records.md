---
id: P123d
date: 2026-10-16
area: "Milestone 3: positioned reads and the first views"
amends: N52
---

# Views over records: count and sum only, maintained by the state machine

**The decision.** A maintained view (N52) may be declared over a record table, with `where`
and `group_by` over the record's fields at any offset of its 448 bytes, and `count` and `sum`
aggregates. `min` and `max` over records are refused (`unsupported` from the state machine; 400
from `nerva api`, before declaring). The view's backfill cursor over a record table is 96 bits:
the low 64 in `backfill_cursor`, the high 32 in `backfill_cursor_high`, carved from reserved
bytes. `nerva view` (N22, N35) refuses views over records: `nerva api` serves them.

**Why.** The application's reports (spend by agent, status and window) are counts and sums.
`min` and `max` need a member per record (N62), whose key holds a 64-bit row id.

**What it costs.** No `min` or `max` over records until members take 128-bit ids. A view over
records is read only through `nerva api` (or the client), not `nerva view`.
