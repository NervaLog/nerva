---
id: P173
date: 2026-11-05
area: Releases
amends: P168c
---

# The Receiver's lingering table holds `refusals_per_wake_max` (128) entries

**Decision.** `linger_max` equals `refusals_per_wake_max` (128), not 16, so every connection refused
in one wake can linger. A full table still closes at once; that is now only the overflow case.
`Options.linger_entries_max` (default `linger_max`) exists so tests can use a smaller table.

**Why.** Under `tests/api/busy.py` (32 clients, 16 drippers), a table of 16 filled up. The gateway
then closed refused connections while their clients were still sending, and the close became a reset
(`BrokenPipeError`), not a `503 busy` the client could read (#172).

**Cost.** 128 × 24 bytes, and up to 128 more poll entries.
