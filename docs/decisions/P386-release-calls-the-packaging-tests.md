---
id: P386
date: 2026-11-13
area: Releases
amends: P360
---

# The release calls the packaging tests and does not draft without them

**Decision.** `release.yml` runs `packages.yml` (made callable with `workflow_call`) as a job beside `ci`, on the release commit, and the draft job needs it. `packages.yml`'s `cancel-in-progress` applies only to pull requests.

**Reason.** The v0.7.1 brief's demo row 6 is `packages.yml` green on the release commit, but nothing in the release chain waited for it, `ci.yml` runs no packaging tests, and a later push to main cancelled the release commit's run (#384). A called workflow is part of the release run: it cannot be cancelled by a push, and a red result stops the draft before the owner's `apple-signing` approval. A query of the push run's result in `release-finish.yml` (with a new NRV code) was the alternative; it needs a run to exist and be found by SHA, so it was not chosen.

**Cost.** About 40 more minutes of two hosted-runner jobs per release (parallel with `ci`), a duplicate standalone run on the VERSION commit's push, and a flaky packaging test (#375) now blocks a release until its job is re-run.
