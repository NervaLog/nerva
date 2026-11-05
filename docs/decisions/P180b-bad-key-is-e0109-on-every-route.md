---
id: P180b
date: 2026-11-05
area: Releases
---

# A malformed commit key is NRV-E0109 on every route

**Decision.** A malformed `key` on `/v1/documents/commit` is refused `400` with NRV-E0109 and
`applied: false`, the code `/v1/commit` already gives it, not a documents (E05xx) code.

**Why.** The key is a commit key, not a document key: one code means one cause across routes
(P147c), and a client that matches E0109 needs no second case.

**Cost.** None: ERRORS.md's E0109 already names the key messages, whatever the route.
