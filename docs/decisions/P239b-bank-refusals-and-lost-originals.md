---
id: P239b
date: 2026-11-06
area: Releases
amends: P239
---

# A refusal is Nerva's only on a 409, and not after an attempt that got no answer

**Decision.**
- `bank`'s definite refusal is a `409` with a status. A `503 views_busy` or `413
  views_too_large` carries a status too, but says nothing was applied and a resend is safe
  (R4's contract), so it is a gateway-style refusal: retried, then the key waits for the final
  phase.
- A Nerva refusal after an `:unknown` attempt of the same key is not definite: the original may
  still commit (a paused gateway) and Nerva records no key for a refusal. The op ends `:info`
  and the key goes to the final phase (`keyed/invoke-keyed`, for any workload that has refusals;
  `retry` has none). This amends P239's "a refusal by Nerva is definite".
- `scan-from!` stops at 100 pages and throws if a cursor does not advance.
- `test-all`'s unkeyed bank run is named `nerva bank no-keys ...`, and the reporter files it as
  workload `bank-no-keys` (`--no-keys` on the command line), so its findings do not share a
  fingerprint with the keyed run's.
- The refactor of `retry` into `keyed.clj` adds fields without changing a verdict: every
  committed attempt carries `:applied` (the first add's applied amount) and `key-records` marks
  `:info? true`. `expected` and `applied-lies` ignore both.

**Reason.** The first two avoided a false invalid on a correct cluster and a transfer recorded
as failed that moved money. The rest bounds a loop and tells the two bank runs apart.

**Cost.** A refused key after a lost attempt is resent once more in the final phase. Records are
upserts, so keyed `bank` catches a duplicate only when both `2xx` replies arrived.
