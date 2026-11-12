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
3. The site entry's date is the release's `published_at` (UTC), so a rerun on another day writes the same
   line. It can be a day after the CHANGELOG heading's date (a release published after 00:00 UTC): the
   two are different facts, the heading says when the section was written and the entry when the
   release became public, and the difference is not to be "fixed" by hand.
4. The tap and site logic lives in `.github/scripts/release_finish.sh`, so it is tested locally with a
   stand-in `gh` and real git, not only by reading YAML.
5. A prerelease's site pull request is not merged; the last step of `publish` waits for the site's
   `site-check` check-run (read over REST, since the repository is public) to succeed. A release's
   wait ends at once on a failed check.
6. `mac-verify.yml` takes a `tap-ref` input (`main` or `rc/v<version>`) and fetches that ref instead of
   pulling main. Header comments of `release.yml` and `mac-verify.yml` that this slice leaves stale are
   slice C's.
7. Review of #362: the site's pull request is found through the REST list with `head=<owner>:<branch>`
   and kept only if its head repository is the site, its author is the App and (for an open one) its
   head is the commit just pushed. Auto-merge that cannot be asked is a refusal (NRV-E1136) unless
   the site's `site-check` run on the pull request's head has concluded `success` (not
   `mergeable_state`: `site-check` is not a required check until the site's setup is done); then the
   pull request is merged with `--match-head-commit`. `site-wait` accepts a merge in release mode only
   with a `success` check on the merged head.
8. Everything that can refuse without writing runs before the draft is published (latest-release check,
   site sentence, App token, tap diff, site edit on a scratch clone, which stands in today's UTC date).
9. A release is refused (NRV-E1138) when a published release is newer, and the tap's `main` is never
   taken to an older version (NRV-E1135). Versions are compared with `sort -V`; a candidate is exempt.
10. A dispatch for a release that is already published skips `mac` only; `mac-verify` still checks
    the published zip (steps 1 to 4; its new `brew` input is `no`, as the tap has no formula yet) and
    `publish` needs it to succeed. `publish` then makes the formula from the template and the zip's published checksum, because no signing run
    produced one.
13. Before the draft is published, a tag `v<X>.<Y>.<Z>` that already exists at another commit than the
    draft's target is refused (NRV-E1138). Every `gh` failure in the script and the workflow ends in
    a coded refusal of its step's code (E1134 formula, E1137 guard, E1138 publication, E1136 site).
11. Only `v<X>.<Y>.<Z>` and `v<X>.<Y>.<Z>-rc.<N>` pass the guard (P361).
12. No step writes a command substitution inside `echo >> $GITHUB_OUTPUT` (it hides the failure), and
    `release-finish.yml` runs every step with `bash -eo pipefail`; a test refuses both. `release.yml`,
    `mac-verify.yml` and `mac-sign.yml` keep `set -eu`: some of their pipelines (`strings | grep -q`)
    would fail on a closed pipe under `pipefail`.

**Reason.** Closest to the existing scripts and tests; each choice keeps a failure coded and testable.

**Cost.** The wait on `site-check` depends on that job's name in the site repository. Untested against
GitHub until the rc.2 rehearsal.
