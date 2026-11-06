---
id: P228
date: 2026-11-06
area: Errors
---

# A catalog write that loses 16 attempts is `503 catalog busy`, NRV-E0313, and keeps the session

The decision: `CatalogStore.layout_put` and `view_put` return `error.CatalogBusy`, not
`error.Timeout`, when all 16 attempts conflict. The gateway answers `503
{"error":"catalog busy","applied":…,"code":"NRV-E0313"}`, class retry, and does not mark the
client broken, clear the layout cache or reconnect (`breaks_session` is true for `Evicted` and
`Timeout` only). `applied` is always `"unknown"`: the 16 attempts are commits that went out, so the write counter always moves (`api.applied_since`).

Reason: `Timeout` means a call went out and got no answer. Here the cluster answered every call;
reporting NRV-E0601 "cluster unavailable" blamed the cluster and tore down a healthy session (one of
64) for what is contention between clients (#216). Status 503 follows `views_busy` (E0211) and
`busy` (E0602), the existing retry-later replies. A 409 was rejected: the 409s are refusals the
client fixes by reading again (`conflict`, E0202), and Jepsen's `http/refused` would read a 409
as a definite refusal of the request, which a retry-exhausted declaration is not. With 503 the
Jepsen mapping needs no change: `applied: false` is `:refused`, `"unknown"` is `:unknown`.

What it costs: the counter counts each refused attempt as a write that went out, so `applied` is
always `"unknown"` though a conflicted commit changed nothing. On the view route the view may
already be declared in the state machine (`client.declare_view` commits first), so `unknown` is
accurate there too; a resend writes the catalog document. A precise `false` would need a counter
that excludes answered conflicts. `CatalogStore` becomes `CatalogStoreType(ClientType)` so the
retry loop can be tested with a stub client. No wire identifier changes; E0313 is a new code.
