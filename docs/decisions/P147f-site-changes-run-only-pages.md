---
id: P147f
date: 2026-11-04
area: Releases
amends: N68
---

# A change to site/ alone runs only the Pages deploy, not CI

`ci.yml` ignores `site/**` as it ignores Markdown (N68). `pages.yml` deploys `site/` on every push
to `main` that changes it, so a site-only change runs that workflow and nothing else.

**Why.** The site is static HTML with no build step. Running the Zig suite for a status update
spent runner time and delayed the deploy. Zigbox and Zigcube already skip their CI for site-only
changes.

**Cost.** A broken page is caught only by looking at it. The check before merging is a local
render (CLAUDE.md, "README and site status").
