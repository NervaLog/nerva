---
id: P106
date: 2026-10-07
area: "Milestone 3: positioned reads and the first views"
amends: N59, N82
---

# The long fuzzers and Jepsen run every night, and a failure files one issue

The owner's decision (2026-10-07). N59 ran the long fuzzing by hand only, and N82's Jepsen suite
had no workflow, so neither searched unless someone remembered to start it.

- **Fuzzing (amends N59):** `fuzz.yml` keeps `workflow_dispatch` (`minutes`, now also
  `candidate`) and runs nightly at 01:17 UTC with 60 minutes a job: 16 fuzzers and 7 VOPR lanes,
  23 jobs, about 25 runner-hours a night with the builds. A first job resolves the candidate to
  one commit for the night (jobs queue, and `main` may move); `fuzz_loop.sh` comes from the
  workflow's ref, the code fuzzed from the candidate. Runners are no longer started by hand:
  Botpike/ci-runners starts a Fly Machine per job, as for CI.
- **Jepsen (amends N82's "where it runs"):** `jepsen.yml`, nightly at 03:23 UTC and on dispatch
  (`candidate`, `time-limit`, `nemesis`). One Fly runner builds the candidate's `nerva` in
  ReleaseSafe and runs `bank` once per nemesis spec, one after another: `kill`, `pause`,
  `partition` by default, each its own test (a spec such as `kill,partition` composes faults, as
  N82 does in code). 600 s a test by default; at most 2400 s a test and 9000 s a run, inside a
  210-minute job. The suite and scripts come from the workflow's ref; only `nerva` is built from
  the candidate. JDK (Temurin 21.0.12.1) and Leiningen (2.12.0) are downloaded in the job and
  checked against pinned SHA-256 sums. Jepsen's `store/` is uploaded as `jepsen-store`.
- **Cluster key (P102):** the job generates a fresh random `NERVA_CLUSTER_KEY` per run (32
  random bytes, hex), masked in the log; never a repository secret. The suite now passes the
  control node's `$NERVA_CLUSTER_KEY` to replicas, or a fresh random key when it is unset; the
  constant key that `db.clj` held is gone. Each node gets the key over stdin into a `600` file
  that the replica's start command reads: Jepsen's `start-daemon!` writes the daemon's
  environment into its log, which is in `store/` and so in the artifact, and P102's key is never
  logged.
- **gnuplot** is installed in the job: without it Jepsen's perf graphs are `:unknown`, and so
  would be every night's result.
- **Schedules:** fuzzing (01:17, about 65 to 95 minutes) and Jepsen (03:23, about an hour by
  default) finish before perf-nightly (06:47), which shares the runner pool.
- **Issues:** a failed or timed-out job makes a `report` job (the only one with
  `issues: write`) file one issue, labelled `fuzz` ("Long fuzzing found a failure") or `jepsen`
  ("Jepsen found a failure"), with the run's link, the commit, and each failing seed with its
  replay command, or each failing test's history path in the artifact and its `results.edn`.
  While that issue is open, any later failure (a re-run, the next night) comments on it instead
  of filing another: one open issue per suite, closed when fixed. Dispatched runs report too,
  so a release review's run at a candidate files the same way.
- **Releases (P105):** the review dispatches both at the candidate; README and CLAUDE.md say how.

**Cost.** About 25 runner-hours of fuzzing and one runner-hour of Jepsen each night. A failure
found at night waits in one issue until someone fixes it; several different failures while it is
open share that issue as comments.
