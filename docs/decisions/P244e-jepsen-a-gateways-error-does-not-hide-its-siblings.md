---
id: P244e
date: 2026-11-06
area: Releases
amends: P244d
---

# One gateway's harness error never drops another's state; the reporter files NRV-E0607 as the host's

**Decision.** (1) `start-gateways-final!` handles each gateway in its own `try`. A gateway whose
probe or start threw (ssh, the harness) is left out of the states and named in `:error`
(`gateway N: message`); the node's other gateways keep `:up`, `:down` and `:pending`, so a gateway
left down still gives NRV-E0604 (`:valid? false`, which wins) however another threw. (2)
`http/healthy?` treats a `/healthz` reply it cannot read (a body that is not JSON) as not healthy,
so such a gateway ends `:pending` or `:down` (NRV-E0604, a Nerva finding); only transport and ssh
failures are the harness's. An interrupt still propagates. (3) The blame `harness` joins the
legend of `docs/ERRORS.md`: the test harness or its environment failed, not Nerva. (4)
`ops/jepsen/jepsen_report.py` reads a failing checker's `:code`. A verdict with `NRV-E0607` is the
host's (`kind` `host`, counted, status `error`, no issue), not an `unknown-result` finding. If
another checker found something in the same run, that finding is filed and the harness verdict is
dropped, so an invalid verdict elsewhere still outranks it. (5) Wording: `signal-script` only
narrows the pid-reuse window to between `stat` and `kill`; `heal-gateways!`'s docstring says that
only the final heal is judged.

**Why.** Third review of #244: a per-node `:error` replaced that node's earlier `:dead`, so a down
gateway could show only as NRV-E0607; and the reporter would have filed every ssh hiccup in the
final phase as a Nerva `jepsen` issue (fingerprint `jepsen|bank|gateways|unknown-result`).

**Costs.** A real harness failure that hides inside a night's only run turns that night's status
`error`, not `failure`: it is counted but nobody is paged by an issue. `healthy?` also swallows
any non-interrupt exception of its one HTTP call, so a bug in the harness's own request code reads
as an unhealthy gateway (NRV-E0604) instead of a harness failure.
