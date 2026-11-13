---
id: P388
date: 2026-11-13
area: Releases
amends: P374
---

**The v0.7.1 candidate moves from `5d7d806` to `c886c9f`, which contains #382.**

The owner chose this in session on 2026-11-13. The fleet runs the `run.sh` and `sim_fleet.py` of
the commit it soaks, so a soak of `5d7d806` would run the loop that loses failing seeds (#370,
#387). `c886c9f` is `5d7d806`'s descendant and the pinned paths of P374 (`src/`, `build.zig`,
`build.zig.zon`, `zig/`, `.gitmodules`, `.gitattributes`) are identical in both, so the release
reviews of the candidate still read the code that ships.

Jepsen is not run again: the owner accepts `5d7d806`'s Jepsen run for `c886c9f`, whose pinned
code is the same (in session, 2026-11-13), and the release PR quotes that run and this acceptance.

What it costs: the 24-hour soak starts over on `c886c9f`. The Jepsen result the release PR
quotes is of `5d7d806`, not of the candidate commit itself.
