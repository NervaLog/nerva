---
id: P287b
date: 2026-11-10
area: Releases
amends: P287
---

# A soak that hung, failed or was killed is not clean

**Decision.** The per-commit record also keeps the seeds past their deadline (124) and killed by
the host (125, 126, 137), and the failure fingerprints its rounds hit (at most 64). `soak` prints
them and exits 1 unless the commit ran and has none of: a failing seed, a seed past its deadline,
a seed killed by the host, a fingerprint hit. A seed counts for at most 3600 s, and hours are
floored to a tenth.

**Reason.** Hung seeds fill hours, so a candidate that hangs every seed would read as a clean soak
(review of #287). "Open issues against it" read the last commit a comment was posted for, which a
hold, a rate limit or a day's cap leaves stale. A clock step added to one seed's seconds could claim
any number of hours, and P287's "never claims more than ran" held only while every seed's seconds
were true.

**Cost.** The cap under-counts a seed that truly ran past 3600 s (deadlines are 600 and 900 s by
default, a replay 1800 s). The release PR for a soak with any failure must explain it, since the
command exits 1. The fleet runs the reporter from the commit it built, so the candidate's own
`sim_fleet.py` grades its soak: the owner confirms that file is unchanged since the reviewed commit.
