---
id: P259g
date: 2026-11-10
area: Releases
---

# Moving from v0.7.0 to the first rolling-capable release is export and import

Owner, 2026-11-10: the move from v0.7.0 to vR, the first release that ships R6, is an export and import, said in vR's notes. vR does not stay on release 0.0.6 so that v0.7.0 could restart into it.

**Why.** v0.7.0's binary runs one release and cannot offer a newer one, and keeping 0.0.6 would bring the same-string hazard back.

**Cost.** One more export and import for operators on v0.7.0. The first rolling upgrade is vR to vR+1.
