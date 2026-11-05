---
id: P173d
date: 2026-11-05
area: Releases
---

# A commit result the gateway's checks rule out answers 500 B0002, not a panic

**Decision.** The three `std.debug.panic` sites on commit results that the gateway's own checks
make impossible now go through `api.unexpected_status`. It answers `500 internal error`, code
NRV-B0002, `applied: "unknown"`, and logs the result.

**Why.** P168b: every connection is answered. A panic dropped every connection in flight, and the
client could not learn the outcome of a request that had committed.

**Cost.** A real bug no longer stops the process. It shows as B0002 replies and log lines, which
the metrics in slice 4 count.
