---
id: P168
date: 2026-11-05
area: Releases
---

# R4's brief is approved, with the owner's answers to its seven questions

The owner approved `docs/briefs/r4.md` on 2026-11-05 and took the brief's recommendation on every question:

1. Two status changes, named here so they are not a stop: a body that is too large is `413`
   (was `400`), and "not yet committed" is `504` (was `400`) on every route. Everything else on
   the wire is additive.
2. `nerva api` refuses to listen on anything but loopback unless it is given `--listen-remote`
   (NRV-E0009). Jepsen passes the flag. The CHANGELOG carries the upgrade step for anyone who
   binds `0.0.0.0`.
3. `--request-timeout` is a flag, with a default of 30 s as today. The bound on how long a reply
   can take is documented as the minimum timeout a client should set.
4. `/v1/documents/commit` accepts a commit key. This is additive and needs no change to the state
   machine.
5. "Conservation as a metric" is cut from R4. Replicas hold no ledger totals, and a running total
   built from the applied changes would always read zero. PRODUCTION.md is corrected, and the item
   is filed for later replica work.
6. Gateway metrics go out over statsd, from an emitter of Nerva's own, with no vendored change.
7. R4 is delivered when `demo_r4` is green in CI. PRODUCTION's "Jepsen with two gateways per node"
   stays unchecked until R1's nightly runs it, and Botpike's gate waits for that box.

**Why:** each is the brief's recommendation. The only non-additive wire changes are the two
statuses named in answer 1, and no persisted format changes.
