---
id: P145
date: 2026-10-26
area: Releases
---

# The project site publishes a listed set of pages, rendered by GitHub's Markdown API

GitHub Pages serves a site publicly even from a private repository (outside Enterprise Cloud), so
the site is a list, not a directory: `site/build.py` publishes a home page (`site/index.md`),
`docs/TUTORIAL.md`, `docs/GOALS-1.0.md`, `README.md` and `CHANGELOG.md`, and nothing else. The
decision log, worklog, design notes, test plans and code stay unpublished; a link to them from a
published page goes to github.com, where only members can read it. Adding a page means adding it
to `PAGES` on purpose.

- **Rendering.** Each page goes through GitHub's Markdown API (`POST /markdown`, GFM, in the
  repository's context), so the site reads as the repository does, and the build needs only
  `python3`, which the runners have: no Jekyll, no Docker action, no package. Heading ids lose
  GitHub's `user-content-` prefix so that `#part-1-…` anchors work on a static page.
- **Milestones.** The home page summarizes the milestones of `docs/GOALS-1.0.md` in a table
  written by hand; the build fails when the goals list a milestone number the table does not, so
  a new milestone cannot be missed. A milestone's state in the table is still updated by hand,
  with the goals.
- **Deployment.** `pages.yml` builds and deploys on a push to `main` that changes a published
  page, `VERSION` or `site/`, on Botpike's runners like every other job, with the official
  `upload-pages-artifact` and `deploy-pages` actions pinned by commit. `ci.yml` runs the builder's
  tests, which use no network.

Costs: the site depends on the Markdown API answering during a build (a failed build leaves the
last site up), and the repository's Pages source must be set to "GitHub Actions" once, by an
owner. If the plan does not offer Pages for a private repository, the workflow fails at deploy
until it does.
