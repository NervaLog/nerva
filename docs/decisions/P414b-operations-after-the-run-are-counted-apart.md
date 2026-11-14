---
id: P414b
date: 2026-11-14
area: Testing
amends: P414
---

# `bench-load` counts an operation that ends after the run apart, instead of in the last second

**Decision.** An operation that began before the end of the run but ended after the timeline's last
second belongs to no second. It is in no histogram and no counter, not in the timeline and not in
the summary. It is counted as `late_operations` in the summary JSON (an additive member) and in
`Timeline.late`. An operation never ends before the start: the workers now wait for the start
instant, and `Timeline.second_of` asserts it.

**Reason.** The timeline says an operation belongs to the second in which it ended, and the R3
report tests whether a second held a checkpoint. Clamping a straggler (up to the 30 s client
timeout later) into the last line put its latency against a second it did not end in. Dropping it
loses nothing the summary counted before: it was only ever in the last line. Keeping a separate
count shows how many there were. The workers also began up to 100 ms before the start and had their
first operations clamped into second 0; that clamp is gone because they now wait.

**Cost.** The summary JSON gains `late_operations`. A run's last operations, which are the slowest
when a stall begins at the end, are not in the percentiles; `late_operations` is how a reader
learns of them.
