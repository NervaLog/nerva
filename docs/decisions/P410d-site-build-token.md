---
id: P410d
date: 2026-11-13
area: Releases
---

# The site's build uses a narrower user token than the one Cloudflare offers

**Decision.** Workers Builds deploys `nerva-site` with a user API token the owner makes: Account
Workers Scripts Edit and Account Settings Read on the one account, User Details Read and
Memberships Read, nothing on any zone, no R2 and no KV. The token Cloudflare offers to create
("Create new token") is not used.

**Why.** Cloudflare's docs list that token as Account Settings read, Workers Scripts edit, Workers
KV Storage edit, Workers R2 Storage edit, Workers Routes edit on all zones, and two user reads.
R2 Storage edit reaches `nerva-packages`, the bucket of P365. The site needs none of R2, KV or
routes: it has no binding, and its custom domain is set once in the dashboard, which a deploy
without routes leaves alone.

**What it costs, and what remains.** Workers Builds supports only user tokens, and Workers Scripts
Edit is account-wide: a leaked token could deploy another Worker, and a Worker bound to
`nerva-packages` could put or delete objects the bucket's locks do not hold. It could not remove a
lock, sign, or change the key, and the next write run reports any tampering. Whether uploading a
Worker with an R2 binding also needs an R2 permission is not documented and is not assumed. The
token is used only by the pinned Wrangler after the pinned gate. The owner must accept this
residual reach in writing before setup step 2; until then the setup waits. A separate Cloudflare
account for the site would remove it, at the cost of moving `nerva.pro`'s zone or giving the site
another domain, which P365 rules out.
