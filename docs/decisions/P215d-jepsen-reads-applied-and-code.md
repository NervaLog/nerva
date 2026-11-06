---
id: P215d
date: 2026-11-06
area: Releases
amends: N82
---

# The Jepsen suite reads R4's `applied` and `code`, not the status alone

The decision: `tests/jepsen/src/nerva/http.clj` decides an operation's outcome from the reply's
body as R4 defines it (P168b, P173c): `applied: false` on any status is a definite failure;
`"applied": "unknown"`, and a request with no reply, are indeterminate for a write; `200` with
`"replayed": true` (NRV-W0201) is a success that names the original operation. A non-2xx reply
without `code` or `applied` fails the test. This replaces N82's mapping by status (503 and 504
unknown, other errors definite).

The reason: R4 is delivered, and every non-2xx reply now says whether it was applied. Reading the
status alone would count a refused-but-unknown reply as definite, or a definite refusal as
unknown, and would never check that the gateway tells the truth about `applied`, which is what
Botpike's retries rely on.

What it costs: the suite depends on R4's answer contract; a change to it changes the suite in the
same pull request.
