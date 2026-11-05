---
id: P180
date: 2026-11-05
area: Releases
amends: P123
---

# A documents commit takes a commit key, with `/v1/commit`'s replies verbatim

**Decision.** `/v1/documents/commit` takes an optional `"key"`, sent as the transaction's first
entry exactly as `/v1/commit` sends it (P123). Both routes parse it with `api.key_parse` and answer
the key entry with `api.key_reply`: `replayed` (W0201), `key_reused` (E0207), `key_collision`
(E0208). A replayed documents commit answers the op it committed at; nothing is re-read for the
reply, and the documents' versions are that op, as a replayed `/v1/commit` answers its adds
without amounts.

**Why.** R4 owner question 4 (P168): without a key, an `"unknown"` documents commit has no safe
resend (a blind write applies again). One function per step means the two routes cannot drift.

**Cost.** Keys are opt-in: an unkeyed documents commit stays ambiguous after `"unknown"`, as an
unkeyed `/v1/commit` does. A key entry takes a few bytes of the request's entry budget.
