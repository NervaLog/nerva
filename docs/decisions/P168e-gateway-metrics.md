---
id: P168e
date: 2026-11-05
area: Releases
amends: N50
---

# Gateway metrics over statsd, from Nerva's own emitter

**Decision.** This amends N50. `nerva api` sends statsd metrics named `nerva.api.*`:
- `requests`
- `refused` (tagged with `reason`)
- `unknown`
- `group_size`
- `cluster_request_us`
- `queue_wait_us`
- `reconnects`
- `session`
- `connections`

Tag values come from comptime enums, so cardinality is fixed. The emitter is Nerva's own and
changes no vendored file.

**Why.** It is the same format the replicas use, and Botpike already runs `statsd_exporter`.

**Cost.** A small UDP emitter to maintain, with its own bounded buffer.
