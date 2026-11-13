---
id: P382
date: 2026-11-12
area: Releases
amends: P287b
---

# A fleet round is settled by a record in the state file, and a refused round counts against its commit

The decision: every fleet round is either counted or refused, and `soak` reads a commit with a
refused round as not clean (exit 1). Whether a round was settled is a fact on disk, never an exit
code. `run.sh` gives each round a random id (`<seconds>-<16 hex>`), written with the commit into
the round directory, which is made whole under `round.new` and then renamed. `sim_fleet.py ingest`
counts the round (or refuses it whole: past `ROUND_FAILURES_MAX` failing seeds, or a malformed
`results` line) and saves that, with `last_round = {id, commit, outcome}`, in one atomic write of
the state file (temporary file, fsync, rename, fsync of the directory), before it reads the token
or asks GitHub anything. A missing token, a 401 or GitHub down then stop only the reports; a state
rebuilt from nothing keeps `rebuild` set until the issue markers are read, and files nothing
before that. After `ingest` ends, however it ends, `run.sh` looks for the id in the state file.
If it is not there, `sim_fleet.py refuse` records the round as refused. If it is still not there
(the state is unreadable or cannot be written), the round stays in `state/round`, `run.sh` exits 1
and systemd starts it again. `ingest` and `refuse` do nothing for an id already recorded, so a
round is never counted twice. At start, a round left in `state/round` with a valid id and commit
(a stop, a reboot, a crash, or the exit above) is settled the same way, from the results its
workers wrote; a seed ended by the stop's SIGTERM (exit 143) is not recorded. A leftover
`round.new`, or a round without an id, is deleted uncounted. A leftover round with no results yet
is counted as an empty round, not refused.

A refused round cannot be cleared: there is no marker and no state edit for it. With this design a
round is refused only for bad input or a reporter bug, which is what the gate must not miss. When
the owner judges that the host and not the candidate caused it (read `state/last-failed-round` and
the journal), the owner waives it in writing in the release PR, as the release gate allows for any
blocker, or the fleet soaks a new candidate. The reporter's messages stay plain text, not `NRV-`
codes, as P215c (resting on P147i) set.

The reason: P287b's soak clause says the commit has no failing seed, but the record `soak` read
was written only by a successful `ingest`, so the worst round (a mass failure) was the one that
vanished, and a later clean round made the commit read clean (#370). Three rounds of review then
found that every exit-code table had a hole: argparse and a missing script also exit 2, a stop
had no trap, exit 75 lost the round, and `unrecorded-` markers were unbounded. A record written in
the same atomic save as the count has no such table: it is there or it is not. Counting a leftover
round from its results, instead of refusing it, keeps a restart (a deploy, `systemctl restart`
to move the pin) from voiding a soak; refusing it would protect nothing, since its seeds are on
disk.

What it costs: a refused round makes a commit not clean until the owner waives it or moves the
pin. A state file that cannot be written stops the fleet (systemd retries every 30 s) instead of
running rounds it cannot record. A round cut by a stop loses the seeds that were running; the
rest count. `run.sh` finds the record with `grep` for the id, which is safe because the id is
random and appears in the state only in `last_round`.
