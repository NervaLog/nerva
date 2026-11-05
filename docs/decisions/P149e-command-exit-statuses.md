---
id: P149e
date: 2026-11-05
area: Releases
amends: P147c\n---

# Commands exit 1, 2 or 70; `nerva start` keeps its runtime statuses

A command that fails exits 1 (the operator's input), 2 (usage) or 70 (internal), with one
`error[NRV-…]` line naming the cause and the fix. `nerva start`'s statuses 2 to 8 stay as they are,
because supervisors and P90 match them, and their messages gain codes.

**What it costs:** two numbering schemes, documented side by side in `docs/ERRORS.md`.
