---
id: P239
date: 2026-11-06
area: Testing
---

# Keyed bank shares retry's attempts and final phase; a refusal by Nerva is definite

**Decision.** `retry`'s attempts, backoff, gateway choice, final phase and key checks move to
`jepsen.nerva.keyed`; `bank --keys` (the default) and `retry` both use them. `bank` adds two
differences, passed in as functions: an attempt refused by Nerva (a 409 with a status, such as
`out_of_bounds`) is as definite as a commit, because a transfer depends on state and a resend
after a real refusal is not Botpike's behaviour; a gateway's own refusal (no status) is not
definite and the key waits for the final phase. `bank` defaults to two gateways with keys.
A record may exist for a key with no `2xx` only if an attempt got no answer or its operation
ended `:info`; a key every attempt of which was refused or never sent must have none. `test-all`
runs `bank` keyed, `bank --no-keys` and `retry`.

**Reason.** Conservation cannot see a duplicate transfer; one op per key and one record per
committed key can. Sharing the code keeps `retry` and `bank` resending the same way.

**Cost.** A key left unanswered even by the final phase leaves the run `:unknown`. `test-all`
has one more variant. The checks' failures are the suite's own, not codes a client or operator
sees, so none is registered in docs/ERRORS.md.
