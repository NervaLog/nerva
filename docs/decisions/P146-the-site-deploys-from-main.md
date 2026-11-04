---
id: P146
date: 2026-11-04
area: "Milestone 3: positioned reads and the first views"
---

# The project site is `site/`, deployed to GitHub Pages from `main` on Botpike's runners

`site/` is a static page with no build step, in the Zigbox and Zigcube sites' design.
`.github/workflows/pages.yml` deploys it on every push to `main` that changes `site/**` (or by
hand), with `actions/upload-pages-artifact` and `actions/deploy-pages`, and Pages' source set to
"GitHub Actions". The job runs on `[self-hosted, fly]`, as every other job here, and checks out
with the same pinned `actions/checkout` commit; the Pages actions are pinned by major version, as
the Zigbox and Zigcube workflows pin them.

Every status the site shows (goals, next steps, releases) is data at the top of its script, and
must be traceable to `README.md`, `docs/GOALS-1.0.md` or `CHANGELOG.md`. Terminal output on it is
taken from `docs/TUTORIAL.md`, whose replies are real output, and links to its section.

**Why.** The site goes live only from reviewed code on `main`, like a release; one data block is
what a later session updates when a goal or a release lands.

**What it costs.** The site can fall behind the README: nothing checks it, so a release that
changes what it says must update `RELEASES` and `SITE` by hand. `ci.yml` ignores only `**.md`,
so a pull request that changes only `site/` still runs the full CI (N68 was not extended to
`site/**`; that is the owner's call). If a self-hosted runner cannot run the Pages actions, the
job moves to `ubuntu-latest`, as Zigbox's and Zigcube's do.
