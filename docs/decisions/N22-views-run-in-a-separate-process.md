---
id: N22
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Views run in a separate process, `nerva view`, that follows the change feed.

As in the white paper: the core only commits; a view process pages through `get_changes`,
groups changes by op, applies complete ops, and keeps a watermark (the op through which it is
complete). v0.1 state is in memory and rebuilt from the start of the feed on restart. Cost:
restart time grows with history until views snapshot (later).
