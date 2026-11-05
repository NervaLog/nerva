---
id: N72
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# A transaction too large for any op gets `views_too_large` (413), not `views_busy`.

`views_busy` (N52) said "retry in a later op", but a transaction whose own distinct view groups
(or `min`/`max` members, N62) exceed the per-op budget fits in no op, and every retry got the
same answer (#32). Nerva's clients send one transaction per request, so for them every
`views_busy` was this case. Admission (`view_txn_admit`) now returns `views.Admission`: `fits`,
`busy`, or `too_large`, which is decided when the budget runs out: if every group (or member)
the op has counted is this transaction's own, it would fill any op alone. A transaction that
shares keys with earlier ones of the request and is also too large alone gets `busy` first, then
`too_large` when retried alone. New status `views_too_large = 15`, appended (persisted values
keep their numbers; the format snapshot gains that line). `nerva api` answers `413
{"status":"views_too_large","index":…}`; `views_busy` stays 503. The VOPR workload models the same
rule. Tests: the unit test's transaction of `limit + 1` new groups now expects `views_too_large`,
and the request whose third transaction overflows only with the first two expects `views_busy`
and then commits alone; `test:views` sends 4,200 new groups (413) and the same rows split in two
(200 each).
