---
id: P404b
date: 2026-11-13
area: Releases
---

# The weekly refresh passes with a notice before setup, and refuses a missing bucket once live

**Decision.** `package-repos-refresh.yml`'s first step reads `R2_BUCKET`. While it is empty and the
repository variable `REPOS_LIVE` is not `true`, the run passes with a notice and refreshes nothing.
Once `REPOS_LIVE` is `true`, an empty `R2_BUCKET` refuses with NRV-E1139 and the `alarm` job files
it. The `missed` check counts the served `Date`'s age in seconds, so "over 8 days" means over
8 × 86,400 seconds, not 9 whole days.

**Reason.** Between the merge of slice 4 and setup E the schedule would otherwise fail red every
Monday (NRV-E1139 from `package_repos.sh`), which teaches people to ignore the workflow before it
matters. After the rehearsal a missing variable is a lapse: a green refresh that re-signs nothing
lets the repositories expire at `Valid-Until`, so it must refuse with its code.

**Cost.** Before the rehearsal a setup mistake on `R2_BUCKET` shows only as a notice; the rehearsal
itself (setup F) is what catches it.
