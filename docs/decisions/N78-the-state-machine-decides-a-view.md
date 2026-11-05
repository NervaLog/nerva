---
id: N78
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# The state machine decides a view's name only while the catalog has no document for it.

Since N75, `PUT /v1/views/<name>` declares the view, then writes its catalog document. Two
gateways could race in between (#70): A's definition declared, B's different one then answered
`different` but cataloged anyway, leaving `/definition` describing B and `/groups` serving A for
good. And a view cataloged unmaintained (its table's views full), whose field a ledger then took,
answered 409 to the identical PUT that had been accepted. Now, with no document under the name,
`different` and `ledger_field` answer 409 and write nothing, so the catalog only ever takes the
definition the state machine holds or one it did not maintain for capacity; A's retry finds
`exists` and writes its own. With the identical document already there, every answer is 200, the
reason saying why it is not maintained, as before N75. A document written before this fix under a
`different` declaration stays as it is (views are immutable; the reason says so). Rejected: writing
the document first (a refused view would then need deleting, and a crash in between leaves it).
Verified: a unit test of both orders against the fake catalog (it fails without the fix),
`tests/api/ledgers.py`, and the hardening probe, which hit the window twice in 40 tries and each
time left one definition.
