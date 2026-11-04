---
id: P148
date: 2026-11-04
area: Releases
supersedes: P146, P147f
---

# The site is its own repository, NervaLog/nervalog.github.io

The site (`index.html`) moves from `site/` here to `NervaLog/nervalog.github.io`. GitHub Pages
serves that repository's `main` from its root at <https://nervalog.github.io/>, with no workflow.
`site/` and `.github/workflows/pages.yml` are removed. `ci.yml` stops ignoring `site/**`, so N68's
rule is again Markdown only.

**Why:** the owner's call. A site in this repository needed its own deploy workflow, kept apart
from CI by path rules (P147f), and could not deploy at all while the runners were self-hosted
(P146). In its own repository, a push is a deploy.

**What it costs:** the status rule (CLAUDE.md, "README and site status") now spans two
repositories, so a change of status here and on the site are two pushes, not one. The site's
links into this repository are absolute (`SITE.repo`), so they need no change.
