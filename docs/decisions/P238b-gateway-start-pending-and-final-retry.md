---
id: P238b
date: 2026-11-06
area: Releases
amends: P238
---

# A live gateway is never recorded down; the final start retries

**Decision.** (1) A `gateway-start` completion reports three sets: `:hit` (answered `/healthz`),
`:down` (the process exited, NRV-E0604) and `:pending` (alive but not answering at the deadline).
A pending gateway is not retried and not in `:hit`; the history never says a live process is down.
(2) The wait is `start-settle-s` (10 s) plus at most one round of probes, not "10 s in all": the
deadline is checked after a round, and each probe of each pending gateway can take its HTTP
timeouts plus an ssh `ps`. (3) The final phase's `gateway-start` (value `:final? true`) starts every
gateway that is not running with `start-gateway-until-up!` (bounded tries and backoff) and throws,
naming NRV-E0604, if one never comes up; no start op follows it, and a gateway also exits while the
replicas that just restarted have not formed a view, not only when cut off. This replaces P238's
claim that healing the cuts is enough. (4) `:hit` for a kill or a cut means running when checked: a
gateway that exits between the check and the action is still counted, and a rule added for it stays
until the next heal.

**Why.** Review of PR #238: a slow gateway recorded `:down` and later serving traffic is #237 the
other way round; a final start that tries once can leave the final reads with no gateway.

**Costs.** A start op can take longer than 10 s. A final start can take up to
`gateway-start-tries` times `gateway-start-wait-s` plus backoffs per gateway, and fails the run
rather than reading from fewer gateways. The check-then-act gap remains.
