---
id: P238
date: 2026-11-06
area: Testing
amends: P234
---

# A gateway start reports only the gateways that came up; a fault reports only those it reached

**Decision.** `gateway-start` starts the gateways that are not running, waits at most 10 s in all
(each `/healthz` probe at most 3 s) and records `:hit` as the gateways that answered. A gateway that
exited at start (NRV-E0604, still cut off from its replicas) or does not answer is reported in
the op's value as `:down`, and is not retried within the op: the next `gateway-start` starts every
gateway that is not running, and the final phase heals the cuts before it starts. `gateway-kill` and
`gateway-partition` act on, and report, only gateways that are running; a partition adds no rule
for a gateway that is down, so it is not cut off when it restarts. `:hit` is `[]` when the fault
reached nothing.

**Why.** #237: the history recorded a gateway as started while it was down for 125 s, and kills and
cuts counted gateways that were already dead. A checker or a reader of the history must be able to
trust `:hit`. Reporting `:down` rather than retrying keeps the nemesis bounded and honest: a retry
under a cut would only fail again.

**Costs.** `gateway-start` can take up to 10 s when a gateway is slow to come up. A gateway started
under a cut stays down until the next start op.
