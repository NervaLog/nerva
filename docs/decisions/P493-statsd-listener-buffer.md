---
id: P493
date: 2026-11-18
area: Testing
---

# The integration test's statsd listener has a drain thread and a larger receive buffer

**Decision.** `StatsdListener` in `src/integration_tests.zig` raises `SO_RCVBUF` to 212992
(Linux doubles it to 425984) and fails at once if the buffer is smaller than three replicas'
emits at once. A thread drains it from before the first replica starts. On Linux it reads
`SO_RXQ_OVFL` and prints the kernel's drop count when a needle is missing. `expect_metrics` does
not send requests while it waits, and still waits 15 s for all five needles.

**Reason.** In #482 two replicas started 2 ms apart, so their first emits (53 to 55 packets each)
coincided, and together they exceed the 93 packets the default buffer holds. A reader that was off
the CPU at that moment lost the tail of the primary's burst, where the round trips are. The
buffer is the cause; the thread keeps the buffer empty between bursts. Requests while waiting
would make a lost emit survivable, but they would also hide it, and a check that needs them to
pass is a weaker check than one that needs the metric in the first emit.

**Cost.** The drop count is as of the last packet received, so a loss at the very end of the
last burst shows only as the missing needle. A host whose `net.core.rmem_max` is below 212992
fails the test at start, with the numbers.
