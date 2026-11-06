---
id: P195b
date: 2026-11-06
area: Releases
amends: P195
---

# A call the request's window has passed is not sent: NRV-E0606

**Decision.** `Client` checks the request's window (`Options.window_end`) before it queues a call.
If it has passed, the call returns `error.Expired` and sends nothing: `writes_sent` and the state
are untouched, so the gateway keeps the session and answers `503 {"error":"request deadline
passed","applied":false,"code":"NRV-E0606"}` (`"unknown"` only if an earlier call of the same
request had sent a write). A call that is sent and then passes the window is still
`error.Timeout`, NRV-E0601. `nerva view` catching up with its feed (`catch_up`) is bounded by the
same check: each request pages until its window ends, answers NRV-E0606, and the next one resumes
from the cursor, without breaking the session.

**Why a new code.** NRV-E0601's cause is "the cluster did not answer after a write was sent"; a
request that never sent its call, to a healthy cluster, has a different cause, blame and fix (the
outcome is known, nothing to reconcile, and the cluster is merely slow). The review of #195 showed
that sending the call anyway and giving up at once turned a slow but healthy cluster into an
unknown outcome, a broken session and a run of NRV-E0605 for 5 s. The code is registered in
`docs/ERRORS.md`.

**Cost.** One more failure a client may see, which it handles as any 503 `applied: false`: resend.
A cluster slower than the window per call still fails every request; the flag is the remedy.
