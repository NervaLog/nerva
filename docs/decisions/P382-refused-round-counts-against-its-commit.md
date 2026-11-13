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
the round directory, which is made whole under `round.new`, fsynced and then renamed (the rename
and its directory fsynced too) before the first worker starts.

A seed's only record is its `results` line, written as soon as the seed ends and fsynced when it
did not pass, before its log and its full-log replay. `run.sh` waits for each worker by its pid:
a worker that exited non-zero (any failed command under `set -e`, such as a full disk) may have
lost a failing seed, so the round is refused without being read (`sim_fleet.py refuse`).
Otherwise `sim_fleet.py ingest` counts the round, or refuses it whole (past `ROUND_FAILURES_MAX`
failing seeds, or a malformed terminated `results` line), and saves that, with
`last_round = {id, commit, outcome}`, in one atomic write of the state file (temporary file,
fsync, rename, fsync of the directory), before it reads the token or asks GitHub anything. A
missing token, a 401 or GitHub down then stop only the reports; a state rebuilt from nothing
keeps `rebuild` set until the issue markers are read, and files nothing before that. After
`ingest` ends, however it ends, `run.sh` looks for the id in the state file. If it is not there,
`refuse` records the round as refused. If it is still not there (the state is unreadable or
cannot be written), the round stays in `state/round`, `run.sh` exits 1 and systemd starts it
again. `ingest` and `refuse` do nothing for an id already recorded, so a round is never counted
twice; `ingest` exits 1 for one recorded as refused, so `run.sh` keeps it in
`last-failed-round` as it keeps every refused round. At start, a round left in `state/round` with
a valid id and commit (a stop, a reboot, a crash, or the exit above) is settled the same way,
under its own commit, from the lines its workers wrote, before `follow_main` (which may build
for an hour or die), by the reporter already built; with none built, `run_round` does it. When a
worker died, `run.sh` first renames the round's `id` to `id.refuse` (a rename needs no disk
space) and then calls `refuse`; a leftover round with `id.refuse` is settled with `refuse`, never
counted, so a full disk that stops `refuse` cannot turn the refusal into a count after a restart. A leftover `round.new`, or a round
without an id, is deleted uncounted. A refused round is counted on its UTC day too, and the
tracker's daily totals say how many.

One rule covers a torn file: an unterminated last `results` line (only a power cut or a full
disk leaves one) is a failure of that seed when its third field, the code, is a number other
than 0 (a cut code is still not 0), and is dropped otherwise. Every other line must parse, or
the round is refused. Every collection the reporter reads is bounded and checked as it grows:
worker directories (`WORKERS_MAX`), bytes of `results` (`RESULTS_BYTES_MAX`), lines
(`RESULTS_LINES_MAX`) and failing seeds (`ROUND_FAILURES_MAX`).

A refused round cannot be cleared: there is no marker and no state edit for it. With this design a
round is refused only for a worker that died, bad input or a reporter bug, which is what the gate
must not miss. When
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
disk. A fifth review found that a bare `wait` discarded a dead worker's exit, so a failing seed
could vanish (#387, older than this PR); waiting on each pid and refusing the round is the
one rule that covers every way a worker can die. Writing a seed's line first leaves one record
per seed, so the reporter no longer reconciles `fail-*` directories with lines (that scan was
unbounded and counted a torn seed twice).

What it costs: a refused round makes a commit not clean until the owner waives it or moves the
pin, and a full disk now refuses a round. A state file that cannot be written stops the fleet
(systemd retries every 30 s) instead of running rounds it cannot record. A stop kills the seeds
that were running with their workers, unrecorded: a seed that had not finished had not failed,
so a stop loses seed-hours, not failures. Two rare cases lose one failing seed, and are
accepted rather than given more machinery: a worker that died in a round a stop then cut (the
loop that would have seen its exit is gone), and a power cut that tears a failing seed's line
before its code (its fsync had not returned). `run.sh` finds the record with `grep` for the id,
which is safe because the id is random and appears in the state only in `last_round`.
