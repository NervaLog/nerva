---
id: N23
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# View reads wait for a position: `min_op=<n>` or `min_op=latest`.

A reader that knows the op of its write passes it and gets read-your-writes. A reader that does
not (a client that never sees ops) passes `latest`: the view first pages the feed to its end,
which reaches past every write committed before the read began. Every reply starts `op=<n>`,
the watermark it reflects (G2). A wait that does not reach the position within 10 s answers
504. (Replies were `key=value` lines at first; declared views answer in JSON, N35.)
