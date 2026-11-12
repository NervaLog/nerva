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

**Cost.** The step waits for the check before it merges, so the 20-minute budget is shared between that
wait and `site-wait`. `gh` gives no stable code for "refused because of pending rules", so any refusal of
the direct merge falls back to auto-merge, which then reports its own refusal.
