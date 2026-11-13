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
exit but 0, 2 (counted, GitHub stopped the reports) and 3 (refused and recorded). `ingest` gives
each end its own code (4 nothing recorded, 64 usage, 70 a bug), so `run.sh` never takes a usage
or import error (exit 1) for a recorded round. A missing token file, or GitHub unreachable while
the state is rebuilt, counts the round as refused before returning. A round a killed `run.sh`
left in `state/round` is counted as refused, against the commit written in its `commit` file,
before the next round deletes it. `run.sh` deletes the round once its outcome is recorded (exit 0, 2, 3, or `refuse` succeeded), so
the next round does not count it as a leftover. When `refuse` fails too (an unwritable state, a
full disk), `run.sh` leaves the empty file `unrecorded-<commit>` in the state directory (it needs
an inode, not a data block) and `soak` reads that commit as not clean while it exists; if the
marker cannot be written either, `run.sh` exits 75 so systemd restarts it and the leftover-round
path counts the round. The marker was chosen over a non-zero exit alone because it survives and
is visible to `soak`. The reporter's messages stay plain text, not `NRV-` codes, as
P215c (resting on P147i) set.

The reason: P287b's soak clause says the commit has no failing seed, but the record `soak` reads
was written only by a successful `ingest`, so the worst round (a mass failure) was the one that
vanished, and a later clean round made the commit read clean (#370). Refusing the round stays
right (a bounded reader); counting that it happened is what the gate needs. A GitHub rate limit
(exit 2, after counting) is not a lost round, so it does not make a commit not clean.

What it costs: one refused round makes a commit permanently not clean, even if the cause was the
host and not the candidate (a full disk); the owner then reads the round in `last-failed-round`
and moves the pin to a new commit, as for any failure. A killed reporter that had already saved
its state is counted twice (counted and refused), which errs toward not clean.
