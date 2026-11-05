---
id: N56
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# A nightly A/B performance run on one Fly Machine.

`perf-nightly.yml` (06:47 UTC, and by hand) measures `main` against the last night that passed:
- **Where.** The job runs on Botpike's CI runners (N47) and creates one dedicated Machine for the
  night (performance-8x, 16 GB, a 50 GB volume) in the `nerva-perf` app, with both builds baked
  into its image, and destroys it on exit, failure included; each night first sweeps anything
  older than four hours. One Machine (three replicas and the load on localhost) keeps noise low
  and the orchestration simple; replicas on separate Machines are a later step (v2).
- **What.** `perf/nightly/run.sh` runs each build in each of three rounds, in alternating order
  (A B, B A, A B) so drift over the night falls on both: every `benchmark:` test, then nine
  `bench:load` workloads (c1, c1 batch 64, c2, c3, c3_adds, c4, c4 batch 64, c5 batch 1024, c7;
  8 clients, 20 s each) against three replicas in production config. One JSON line per result.
- **Verdict.** `perf/nightly/compare.py` pairs the builds within each round. A metric fails when
  the candidate is worse than its threshold in every round (at least two), warns when the median
  is worse, and improves when the median is better. Thresholds, fixed until calibrated: 10% for
  throughput and microbenchmarks, 15% for p50, 25% for p99. A failed night files a
  `perf-regression` issue and does not move the baseline; it never blocks a release (owner's
  decision).
- **Records.** Each night's results, log, verdict and summary go to `results/<date>-<commit>/` on
  the `perf-results` branch, whose `baseline` file names the commit to beat.
- **The baseline must build `bench:build`** (added here). A baseline from before it is replaced
  by the candidate itself, which makes that night a measure of noise.
- **Credentials.** The secret `FLY_API_TOKEN_PERF`; meant to be a deploy token scoped to
  `nerva-perf` rather than an organization token.
- **Trial** (2026-10-05, from a session, the same commit as both builds, 2 rounds of 5 s):
  every metric passed, within 9% at the median. The Machine and volume were destroyed.
- **Found by the trial, the first thing to investigate:** in production config on the Fly
  volume, 8 clients reach only about 245 operations a second with a 31 ms median (c1, c4), against
  about 1 ms locally with `--development`. The microbenchmarks match local numbers, so the CPU is
  not the difference: most likely Direct IO writes, from three replicas sharing one volume capped
  at 16,000 IOPS and 64 to 128 MiB/s. Until that is understood, the nightly's load numbers mostly
  measure the volume; they still detect regressions, which is what they are for.
