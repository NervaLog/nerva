---
id: P175
date: 2026-11-05
area: Releases
amends: P168d
---

# The gateway reconnects and probes before every wait, not only when idle

**Decision.** `nerva api` runs its housekeeping (replace a broken client, else probe a silent
cluster) before every `receiver.next`. `nerva view` replaces a broken client before every wait. 

**Why.** Housekeeping used to run only after the receiver idled for 1 s. A load balancer polling
`/healthz` more often than that kept a broken gateway from ever reconnecting, and would have kept the
probe from ever running too (#174).

**Cost.** One check per loop turn. It does nothing unless a reconnect or probe is due. When the
cluster is gone, a probe or reconnect can hold the loop for up to one request timeout, and requests
that arrive meanwhile are answered when it ends, within the answer bound.
