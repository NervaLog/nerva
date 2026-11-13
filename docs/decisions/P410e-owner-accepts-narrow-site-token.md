---
id: P410e
date: 2026-11-13
area: Releases
amends: P410d
---

# The owner accepts the narrow site token, and the site stays in this account

**Decision.** The owner answered P410d's question on 2026-11-13: accept the narrow token. The
site stays in the same Cloudflare account as `nerva-packages`, built with the P410d user token:
Account Workers Scripts Edit, Account Settings Read, User Details Read and Memberships Read, and
nothing on any zone, R2 or KV. Setup step 2 may go ahead once slice 5a has merged.

**Why.** A separate Cloudflare account would remove the residual reach, but at the cost of moving
`nerva.pro`'s zone or giving the site another domain, which P365 rules out. The owner judged the
reach that remains small enough beside that cost.

**What remains.** Workers Scripts Edit is account-wide. A leaked token could deploy another
Worker, and a Worker bound to `nerva-packages` could put or delete objects the bucket's locks do
not hold. It could not remove a lock, sign anything or change the key, and the next write run
reports any tampering. Whether uploading a Worker with an R2 binding also needs an R2 permission
is not documented and is not assumed. The token is used only by the pinned Wrangler, after the
pinned gate, from a directory the gate wrote.

**What it costs.** That reach stays for as long as the site is in this account. A later move to a
separate account is a new decision that supersedes this one.
