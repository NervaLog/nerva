---
id: N2
date: 2026-10-04
area: Foundations (recorded after the fact)
---

# Rows are fixed-size: `(table: u32, id: u64)` → 80-byte value.

TigerBeetle's LSM stores fixed-size values only. Cost: anything longer must be chunked by the
caller (see N12).
