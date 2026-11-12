---
id: P362
date: 2026-11-12
area: Releases
amends: P360
---

# `release-finish.yml` choices the spec left open

**Decision.**
1. A `guard` job runs first (the ref must be main, the tag `v<VERSION>`, NRV-E1137), because a job that
   calls a reusable workflow cannot hold steps, so the spec's "first job" refusal needs a job of its own.
2. A fifth code, NRV-E1138, covers a failed publication or a tag not at the checked commit; the spec
   names four codes.
3. The site entry's date is the release's `published_at`, so a rerun on another day writes the same line.
4. The tap and site logic lives in `.github/scripts/release_finish.sh`, so it is tested locally with a
   stand-in `gh` and real git, not only by reading YAML.
5. A prerelease's site pull request is not merged; `verify` waits for the site's `site-check` check-run
   (read over REST, since the repository is public) to succeed.
6. `mac-verify.yml` takes a `tap-ref` input (`main` or `rc/v<version>`) and fetches that ref instead of
   pulling main. Its header comment and `release.yml`'s are left for slice C.

**Reason.** Closest to the existing scripts and tests; each choice keeps a failure coded and testable.

**Cost.** The wait on `site-check` depends on that job's name in the site repository. Untested against
GitHub until the rc.2 rehearsal.
