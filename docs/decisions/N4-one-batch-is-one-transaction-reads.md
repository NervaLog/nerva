---
id: N4
date: 2026-10-04
area: Foundations (recorded after the fact)
---

# One batch is one transaction; reads assert the version (`op`) they saw.

Optimistic validation at commit, serial execution, so point reads are serializable. Fits
TigerBeetle's multi-batch framing with no framework change. Cost: hot rows conflict (G8).
