---
id: P244
date: 2026-11-06
area: Releases
amends: P234
---

# The gateway heal is confirmed, and P234 is a Releases decision

**Decision.** (1) P234's `area: Testing` is not an area the other Jepsen decisions use; they use
`Releases`. P234 stays as merged; this decision carries the corrected area for it and for the
choices below. (2) `heal-gateways!` deletes each gateway rule (`iptables -D`, at most
`heal-deletes-max` = 8 copies per gateway and replica) and then confirms with `iptables -C` that
none is left; a rule that is left fails the heal with NRV-E0604 naming it. `-D` fails both when no
rule is left and when iptables itself fails, so its failure alone cannot be read as "healed". The
node's teardown still kills the replica and gateways and removes the data directory when the heal
throws. (3) `signal-gateways!` (`gateway-pause`, `gateway-resume`) signals only gateways that are
running when checked, as kill and partition do, so a stale pidfile after an NRV-E0604 exit does
not signal a reused pid and count it in `:hit`.

**Why.** Issue #236: the heal treated every `-D` failure as "no rule left" and never confirmed;
the pause NIT from #238's first review.

**Costs.** One more `iptables -C` per gateway and replica at each heal. A heal that cannot delete
a rule now fails the op instead of leaving the gateway cut for the rest of the run unnoticed.
"Running" is as of the check: a pid reused by an unrelated process still passes it.
