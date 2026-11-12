---
id: P382
date: 2026-11-12
area: Releases
amends: P287b
---

# A refused or lost fleet round counts against its commit

The decision: a round the reporter refuses (past `ROUND_FAILURES_MAX` failing seeds, a malformed
`results` line) is recorded in the commit's entry as `refused`, and `soak` reads any commit with
a refused round as not clean (exit 1). A round the reporter never finished (its timeout, a kill,
a crash) is recorded the same way by `sim_fleet.py refuse`, which `run.sh` runs for any `ingest`
exit but 0, 1 and 2. An uncaught exception in the reporter exits 70. The reporter's messages stay
plain text, not `NRV-` codes, as P147i set.

The reason: P287b's soak clause says the commit has no failing seed, but the record `soak` reads
was written only by a successful `ingest`, so the worst round (a mass failure) was the one that
vanished, and a later clean round made the commit read clean (#370). Refusing the round stays
right (a bounded reader); counting that it happened is what the gate needs. A GitHub rate limit
(exit 2) is not a lost round, so it does not make a commit not clean.

What it costs: one refused round makes a commit permanently not clean, even if the cause was the
host and not the candidate (a full disk); the owner then reads the round in `last-failed-round`
and moves the pin to a new commit, as for any failure. A killed reporter that had already saved
its state is counted twice (counted and refused), which errs toward not clean.
