---
id: P176c
date: 2026-11-05
area: Releases
amends: P176
---

# `statsd_dropped` counts lines, and a lost report is made again

**Decision.** `nerva.api.statsd_dropped` counts lines, not packets: when the kernel refuses a
packet, every line in it is added. P176 said "a packet"; the code and the README already counted
lines, and a line is the unit a collector's counters are in. A window's count is marked reported
only when the packet carrying the `statsd_dropped` line was sent; if that packet is itself refused,
the count stays and is reported again in the next window, with what dropped since.

**Why.** Advancing the reported mark before rendering lost the count for good whenever the report's
own packet was refused, which is the case when the socket is already refusing.

**Cost.** While the socket refuses everything the count keeps growing and no report reaches the
collector; it arrives, whole, with the first packet that leaves.
