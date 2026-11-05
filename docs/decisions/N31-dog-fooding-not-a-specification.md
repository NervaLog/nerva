---
id: N31
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Dog-fooding, not a specification.

Owner's direction (2026-10-04): Nerva is tested on a real application, not specialized for it.
Nerva grows only general capabilities (transactions, the change feed, history, layouts, views).
An application's own rules live in the application, on top of the generic API. A gap the
application finds is reported as the general gap it exposes, not patched with an
application-only route. N39 removed the one application-specific gateway Nerva had.
