---
id: P275
date: 2026-11-10
area: Releases
amends: P147b
---

# A release audit tests every new kind of op against the previous release's replicas

**Decision.** Two rules, both from the v0.7.0 retro (`docs/retros/v0.7.0.md`):

1. **Mixed versions, op by op.** A release audit lists every new kind of op the release can
   send since the last tag, such as combined requests (P143). It runs each one from a new
   gateway or client against the previous release's replicas, then states the upgrade order
   and the rollback condition that follow. The audit never claims a mixed cluster is safe in
   a direction nobody ran.
2. **One heavy build at a time.** In a cloud session, at most one of `test:release`,
   `test:integration` and the full `test:unit` runs at a time. A release reviewer that needs a
   release suite it cannot fit dispatches it on CI and cites the run. An agent never kills a
   process it did not start.

**Why.** v0.7.0's audit tested only a v0.6.1 gateway against v0.7.0 replicas. The other
direction panics a v0.6.1 replica (#272), and only a reviewer found it. In the same release, one
agent's memory use and its kills cut off a reviewer's `test:release`.

**Cost.** The audit takes longer, by one mixed-version run per new kind of op. Heavy suites wait
for each other, or for CI.
