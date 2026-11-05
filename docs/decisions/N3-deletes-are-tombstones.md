---
id: N3
date: 2026-10-04
area: Foundations (recorded after the fact)
---

# Deletes are tombstones.

Upstream `Groove.remove` is untested and compiles only in verification builds. Tombstones also
keep versions exact: a row deleted and re-created never looks unchanged. Cost: rows are never
reclaimed.
