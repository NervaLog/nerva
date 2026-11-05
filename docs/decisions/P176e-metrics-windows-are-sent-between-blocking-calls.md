---
id: P176e
date: 2026-11-05
area: Releases
amends: P176
---

# Metric windows are sent between blocking calls, and the gap is bounded in the README

**Decision.** The gateway sends a statsd window only at the top of its single-threaded loop. It
does not send during a reconnect or a cluster request. The gap between two windows is therefore
at most `statsd_interval` (10 s) plus the longest the loop blocks: `--request-timeout` per
blocking call, and a request makes up to two (`health.ready`, then the cluster request). With the
cluster down it is one blocked reconnect: 10 s + `--request-timeout`, 40 s by default and 70 s at
most. The README says so. A window that goes out late is not lost: counters are deltas over the
whole gap, gauges are read when it is sent.

**Why.** Sending from inside the blocking calls would thread the emitter and the gateway's
counters through `Client.init` and `ClientHealth`, and read `session` and the receiver's state in
the middle of a reconnect: more code in the path that must stay simple, to narrow a gap that it
could not close (a call still blocks for its timeout). A second thread is out of the design (one
thread, no locks). The bound is the same one every request already has.

**Cost.** An operator who alerts on a missing `session` series or on staleness must allow
10 s + `--request-timeout`, not 10 s, during an outage. `tests/api/metrics.py` waits 15 s with
`--request-timeout=1000`, where the bound is about 11 s.
