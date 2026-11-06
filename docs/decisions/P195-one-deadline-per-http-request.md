---
id: P195
date: 2026-11-06
area: Releases
amends: P168d
---

# `--request-timeout` is one deadline per HTTP request

**Decision.** A gateway opens a window of `--request-timeout` when it takes up a request, and
every cluster call and reconnection the request makes ends at it. A call that passes it is a
timeout (503, NRV-E0601). This amends P168d, whose flag bounded each call.

**Why.** The brief (`docs/briefs/r4.md`), README and `--help` promise an answer bound that a client
sets its own timeout from. With a deadline per call, a first commit after a reconnect (a layout
read, then the commit) or a `layout_put` took twice the bound, and a client that gave up at the
bound was left with an unknown outcome the docs said it would not have. Fixing the docs instead
would have made the flag useless for that purpose.

**Cost.** A reconnect that uses most of the window leaves the request little time, and it may
time out and break the fresh session. Idle probes and feed polls keep a deadline per call.
