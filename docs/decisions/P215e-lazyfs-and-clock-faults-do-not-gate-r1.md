---
id: P215e
date: 2026-11-06
area: Releases
---

# LazyFS and clock faults are R1's last slices and do not gate its delivery

The decision: LazyFS (lost unfsynced writes) and clock faults on separate machines (the five
nodes as KVM guests) are R1's slices 9 and 10, built after the nightly is green. R1 is delivered
on the demo (`retry` and keyed `bank` valid, the teeth build invalid, a failure filed as an
issue) and on 7 green nights, without them. Once they are built they join the nightly, and a
failure they find is filed like any other.

The reason: PRODUCTION.md lists them as "Later in R1", outside the demo script and the acceptance
list. Clock faults need KVM guests, since containers share the host's clock, which is a host
capability the owner has not yet confirmed; R1's delivery, and Botpike's gate behind it, should
not wait on it.

What it costs: R1 can be delivered without having tested lost fsyncs or skewed clocks against
real processes; until slices 9 and 10 land, those faults are covered only by the VOPR's simulated
storage and time.
