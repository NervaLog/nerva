---
id: P170b
date: 2026-11-05
area: Releases
amends: P168c
---

# With every slot taken, a newcomer waits out the silent slots' grace

**Decision.** When every slot is taken and some are silent but still inside their 50 ms grace (`displace_grace_ns`), the newcomer waits for the grace to pass. It then takes the oldest silent slot, which is answered `503 busy`. A newcomer is refused at once only when no slot is silent.

**Why.** A connection that has just opened and not yet sent its request should not be displaced at once. Refusing the newcomer instead would turn every brief burst into busy replies.

**Cost.** A newcomer can wait up to 50 ms.
