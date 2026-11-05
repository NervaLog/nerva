---
id: P173c
date: 2026-11-05
area: Releases
amends: P168b
---

# `applied` on a failure is decided by whether a write went out

**Decision.** `Client.writes_sent` counts the write operations sent (`Operation.is_write()`, an
exhaustive switch), and a reconnect keeps the count. A request that fails after reaching the cluster
answers `applied: "unknown"` if the count moved after it began, and `false` if it did not. So a read
that timed out is E0601 with `applied: false`. Members of a group that fails take the group's count.

**Why.** It needs no per-request tracking in the client, and it errs only toward `unknown`: a write
by another request can make a read say `unknown`, but nothing that went out is ever reported `false`.

**Cost.** Some failures that were not applied say `unknown`, so clients sometimes reconcile when they
did not need to.
