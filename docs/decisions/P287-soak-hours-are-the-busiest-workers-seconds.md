---
id: P287
date: 2026-11-10
area: Releases
amends: P284
---

# A round's soak hours are its busiest worker's seconds

**Decision.** The fleet counts a commit's hours as, per round, the largest per-worker sum of the
`<seconds>` column of `results`, added over the rounds that ran the commit.

**Reason.** The gate counts the rounds' own records, not wall time (P284). Workers run at once, so
no worker's busy time exceeds the round's; the maximum never claims more than ran. Seed seconds are
differences of whole-second timestamps, unbiased over many seeds. Adding `run.sh` timing would
have touched a script the slice does not own.

**Cost.** Gaps between seeds are not counted, so hours slightly under-count; a round of one long
seed counts that seed. "Open issues against it" comes from the reporter's state, which does not see
a closed issue: the owner confirms on GitHub.
