---
id: P190
date: 2026-11-05
area: Releases
---

# The R4 demo's clients are caller threads, and a waiting request is not "unknown"

**Decision.** In `tests/demo/r4.py`, clients A and B are two groups of caller threads in the
demo process, each group using its own `nerva api` process (GA, GB), not two Python
subprocesses. Step 9 asserts that every request in flight when the replicas stop is answered
`503` within 4 s, that at least one of them is `"applied":"unknown"` with NRV-E0601, and that any
other is `"applied":false` (NRV-E0605 or NRV-E0602): a request that was still waiting its turn
was never sent.

**Reason.** What the demo shows is the gateway's: the failure domain is the gateway process and
its sockets, which are separate processes either way. A caller subprocess would add a control
channel (start, stop, report) without changing any assertion. A gateway that answered `"unknown"`
for a request it never sent would be wrong, not safe; the brief's "in-flight requests get
unknown" is about requests the cluster may have seen.

**Cost.** Both clients share one Python interpreter, so the callers are limited by its lock rather
than by two processes (about 700 commits a second here). The refusals at 16 held connections do
not depend on speed, and the run still keeps 32 callers busy for 30 s.
