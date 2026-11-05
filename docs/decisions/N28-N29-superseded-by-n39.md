---
id: N28-N29
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Superseded by N39.

As-of reads of the gateway's keys, and a key-value route for an
application's workflow state. `row?as_of=` (N33) and declared views `as_of` (N35) cover the
first; applications chunk large values themselves, as `documents.zig` does for the catalog.
