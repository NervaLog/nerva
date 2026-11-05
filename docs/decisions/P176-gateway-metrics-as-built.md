---
id: P176
date: 2026-11-05
area: Releases
amends: P168e
---

# The gateway's metrics, as built

**Decision.** The details P168e left open:

- Counters are deltas per 10 s window. A series with no events in a window is not sent. The two
  gauges are always sent: `session` (1 if ready at the end of the window) and `connections` (the
  window's maximum number of slots in use, sampled at accept).
- `requests` counts every reply written. Refusals the Receiver writes itself count under
  `route:other`. `refused{reason:unavailable}` counts the E0605 reply to a request, never `/healthz`.
- `group_size` is recorded once per loop turn that reached the cluster: 1 for a single request,
  N for a P143 group.
- `queue_wait_us` runs from a request being complete to the Receiver handing it out.
  `cluster_request_us{operation}` runs from `send` to the reply, eviction or timeout, and includes
  the idle probe as `lookup_rows`.
- `status` takes one of 11 values (200, 400, 401, 404, 405, 408, 409, 413, 500, 503, 504) or
  `other`. A status the gateway starts to emit must be added to `statuses` in `metrics.zig`.
- A packet the kernel refuses is dropped and counted in `statsd_dropped`, which is reported one
  window late.

**Why.** Each choice keeps the emitter allocation-free and non-blocking, and keeps every series
bounded by a comptime enum.

**Cost.** Per-window deltas need the collector to sum them; a window with no traffic sends only
the gauges.
