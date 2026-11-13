---
id: P410
date: 2026-11-13
area: Releases
amends: P365
---

# The site is a Cloudflare Worker of static assets, built by Workers Builds

Also amends P398.

**Decision.** `nerva.pro` is served by the Worker `nerva-site`: static assets only, no script, no
binding, built and deployed by Workers Builds from `NervaLog/nervalog.github.io`'s `main` through
Cloudflare's GitHub App. This replaces the Cloudflare Pages project of P365 point 1. Everything
else P365 says about the site stands: one page, a merge to `main` is the deploy, GitHub Pages off,
the release pull request flow unchanged. P398's gate (the three required files, the WKD pair, the
refusals, NRV-E1152) stands too, and moves from the Pages build command into
`.github/scripts/site_build.sh` in this repository (P410b). `docs/releases/packages.md`, "The site
on a Cloudflare Worker", and setup steps 2 and 3 are the design.

**Why.** The owner decided on 2026-11-13 that Pages is legacy and heading for its end of life, and
that the site moves to a Worker now, before anyone depends on the Pages project.

**What it costs.** The Worker's configuration comes from a Wrangler file, which a repository could
supply, so the gate must write that file itself and Wrangler must be pinned (P410b). The build
token Cloudflare offers reaches R2 and must be replaced by a narrower one (P410d). Some dashboard
behaviour (the 512-character limit, field names, the preview command) is not documented and is
checked in the rehearsal instead.
