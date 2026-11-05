---
id: P175b
date: 2026-11-05
area: Releases
amends: P168d
---

# The idle probe is due after 5 s of silence from the cluster

**Decision.** `ClientHealth.replied_ns` records when the cluster last replied: to a request, to a
probe, or with a new session. Once 5 s pass with no reply, the gateway sends a probe, a one-key
`lookup_rows` of the catalog row (`id 0`, `table_catalog`). Silence is not measured from client
traffic: `/healthz` polls and refused requests do not count. `nerva view` needs no separate probe,
because its feed poll, about once a second, marks `replied`.

**Why.** A gateway whose traffic never reaches the cluster (only health checks, only refusals)
must still notice that the cluster is gone, within the brief's 7.5 s with `--request-timeout=2000`.

**Cost.** An idle gateway sends one small read every 5 s.
