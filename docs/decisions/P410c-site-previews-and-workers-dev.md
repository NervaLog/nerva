---
id: P410c
date: 2026-11-13
area: Releases
---

# The site's Worker keeps its workers.dev address and builds Previews of other branches

**Decision.** The configuration the gate writes sets `workers_dev` and `preview_urls` to true and
an empty `previews` block. Workers Builds' **Enable Preview Builds** is on: every non-production
branch of the site repository runs the same build command, then the pinned preview command
(`wrangler preview`). Cloudflare's check stays out of the site's required checks; `site-check`
stays the only one. `compatibility_date` is pinned at `2026-10-23`, the date of the workerd that
Wrangler 4.153.0 ships.

**Why.** This keeps the spec's "Preview deployments" choice from the Pages design: the rehearsal
tests the gate on a pull request without a merge, and reviewers see a page before it merges. The
`workers.dev` address lets setup step 2 check the site before the custom domain exists, as the
`pages.dev` address did. A Preview takes no setting from production, and its block is empty, so it
has no binding.

**What it costs.** Preview and `workers.dev` addresses are public (served with
`X-Robots-Tag: noindex`); a site branch's page is visible to anyone who guesses the address. The
owner can turn previews off with no other change than the rehearsal's gate test needing a merge.
