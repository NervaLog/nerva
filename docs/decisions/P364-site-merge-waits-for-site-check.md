---
id: P364
date: 2026-11-12
area: Releases
amends: P362
---

# The site's pull request is merged only after its site-check has passed

**Decision.** `release_finish.sh site` no longer asks for auto-merge first. For a release it waits
(`SITE_WAIT_SECONDS`, polling every `SITE_POLL_SECONDS`) until the site's `site-check` check run on the
pull request's head commit has concluded `success`. A failure, or no result by the deadline, is
NRV-E1136 and the pull request stays open. On success it runs
`gh pr merge <pr> --squash --match-head-commit <head_sha>`. Only if that is refused does it try
`--auto --squash --match-head-commit <head_sha>`; if that is refused too, NRV-E1136. A prerelease's
pull request is still never merged.

**Reason.** `gh pr merge --auto` on a pull request that is already mergeable merges it at once. Where
`site-check` is not a required check (another repository, or the ruleset removed), that merged before
the check had passed, and `site-wait` noticed only afterwards. A direct merge at the checked commit is
deterministic and cannot take in a later push; auto-merge is kept only for a rule that is still pending.

**Which check.** Only the latest (highest id) `site-check` check run whose app is GitHub Actions
counts, so a check run another app created under that name, or an older run of the same head, is not
taken for the result. A conclusion other than `success` (`failure`, `cancelled`, `skipped`, and the
rest), or none yet, never merges.

**One deadline.** The `site` and `site-wait` steps share one deadline, `SITE_DEADLINE` (epoch seconds):
the workflow sets it 20 minutes ahead before `site` and exports it to `site-wait`, which reads it. A run
of either step alone starts its own from `SITE_WAIT_SECONDS`. The job's `timeout-minutes` goes from 30 to
45, so the deadline, not the job timeout, ends the wait, and it ends it with a coded NRV-E1136 line.
`SITE_POLL_SECONDS` below 1 (or a non-number) is refused rather than spinning.

**What stops a later push.** `--match-head-commit` on the `--auto` fallback is checked when auto-merge is
turned on, not when it fires. A push to the branch after that is stopped only by the site's ruleset
(required `site-check` from Actions, no bypass), and `site-wait` refuses a merged pull request whose head
has no passing check. The direct merge, the normal path, does pin the commit.

**Cost.** The step waits for the check before it merges, inside the shared 20-minute budget. `gh` gives no
stable code for "refused because of pending rules", so any refusal of the direct merge falls back to
auto-merge, which then reports its own refusal.
