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
nothing on any zone, R2 or KV. Setup step 2 may go ahead once slice 5a's site pull request and
this pull request (slice W, #410, which adds the gate to pin) have merged: packages.md's table
puts step 2 after both.

**Why.** A separate Cloudflare account would remove the residual reach, but at the cost of moving
`nerva.pro`'s zone or giving the site another domain, which P365 rules out. The owner judged the
reach that remains small enough beside that cost.

**What remains.** Workers Scripts Edit is account-wide. A leaked token could deploy another
Worker, and a Worker bound to `nerva-packages` could put or delete objects the bucket's locks do
not hold. It could not remove a lock, sign anything or change the key, and the next write run
reports any tampering. Whether uploading a Worker with an R2 binding also needs an R2 permission
is not documented and is not assumed. The token is used only by the commands the build runs after
the pinned gate, from a directory the gate wrote: `npm ci --ignore-scripts` from the gate's lock
file and the Wrangler it installs (P410b). No package outside that lock file is installed, and no
install script runs. P410d's "only the pinned Wrangler" means this.

**What it costs.** That reach stays for as long as the site is in this account. A later move to a
separate account is a new decision that supersedes this one.
