---
id: N21
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# `lookup_rows` results carry the op they were read at (`RowValue.op_read`).

G2: every read names its position. The field replaces `reserved_a` (same size and offset), so
the wire format grows no larger. `get_changes` already carries its op in the `end` record.
