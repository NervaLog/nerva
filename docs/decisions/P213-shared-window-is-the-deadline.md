---
id: P213
date: 2026-11-06
area: Releases
amends: P168d
---

# The request's absolute window is the deadline of every call in it

**Decision.** This amends P168d. `--request-timeout` is one deadline per HTTP request, an
absolute instant (`Client.Options.window_end`, opened when the gateway takes the request up),
not a timer each cluster call restarts. P195, P195b and P209 built it; this records it as the
answer to #186 and pins it with route tests. Every call of a request shares it: a table-layout
read before a commit, the read before a `layout_put` or a view declare, the `get_ledger` loop
and a `views_busy` send again. When it runs out:
- before a call is sent, the call is refused (`Expired`, NRV-E0606), nothing is sent and
  `applied` is `false` (`"unknown"` only if an earlier call of the request wrote);
- after a write was sent, the call is `Timeout` (NRV-E0601) and `applied` is `"unknown"`, never
  `false`.

**Why.** The alternative, documenting "per cluster call", leaves a client with a timeout set
from the documented bound giving up before the gateway answers, with an unknown outcome the
docs promised it would not have. The window needs no new flag, code or wire member.

**Cost.** None beyond P195b and P209. No new failure path: both outcomes reuse NRV-E0606 and
NRV-E0601, and the tests of this change trigger them through `handle` on a commit that reads
its layout first.
