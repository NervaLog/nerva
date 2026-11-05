---
id: N30
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Not built: attributed approvals and claim leases. They need an identity model.

G7 asks that every approval be attributed to an identity, and claims that outlive a process
need a lease held by someone. Nerva's gateways authenticate with one shared key, so they cannot
tell one approver from another. Attribution needs either (a) the caller asserting an identity,
recorded beside the claim in one transaction (trusting whoever holds the key), or (b) each
approver signing the answer with a key the application issues, verified before it is recorded.
That choice settles a wire format and stored records, and belongs to the application's owner,
so it is not assumed.
