---
id: P149c
date: 2026-11-05
area: Releases
---

# `nerva recover` requires `--origin`, with `none` spelled out

There is no default. An imported cluster's replica would otherwise be recovered as a formatted
one, the failure P90 found.

**What it costs:** one more flag the operator must type.
