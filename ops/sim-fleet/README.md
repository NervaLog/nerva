# The simulation fleet

One host that runs the VOPR (Nerva's state machine and the testing one) and the fuzzers on fresh
random seeds around the clock, at the tip of `main`, and files what it finds as GitHub issues
(P147h). CI runs about 300 VOPR seeds a push (N74) and the long fuzzing runs only by hand (N59);
this is the always-on fleet N74 left for later. It is modelled on Zigcube's
(`Zigbox/zigcube`, `ops/sim-fleet/`).

## What runs

`run.sh` (under systemd, as the unprivileged user `simfleet`, one loop per state directory: it
takes `flock` on `state/lock`) loops over rounds:

1. `git fetch origin main` (5 minute deadline). If the tip is a commit it has not built, check it
   out and build, into `state/bin/<sha>/`, the five binaries a round needs, in ReleaseSafe as
   `fuzz_loop.sh` builds them: `vopr:build -Drelease -Dvopr-state-machine=nerva|testing` (the
   short log, as CI), the same with `-Dvopr-log=full` (only to replay a correctness failure, see
   below), and `fuzz:build -Drelease`; plus a copy of that commit's `sim_fleet.py` (1 hour
   deadline for all of it; `./zig/download.sh` first, so a toolchain bump is followed). Only a
   build that succeeded becomes the one in use (`state/built`); a tip that does not build is
   recorded in `state/broken`, logged once, and the last good build keeps running. Both survive a
   restart, so a restart neither rebuilds a good commit nor retries a bad one.
2. **Workers**, one core and about 4 GB of RAM each, `SIM_FLEET_WORKERS` of them (default: the
   smaller of every core but one, which is left for git, builds and the reporter, and
   `memory / SIM_FLEET_SEED_MEMORY_MB`, at least 1; memory is MemTotal minus
   `SIM_FLEET_RESERVE_MB` (1024), or, when lower, the lowest `memory.max` of the service's
   cgroup and its parents, which is already MemTotal minus 1 GiB under `setup.sh`'s cap, so the
   reserve is taken once; the `workers:` log line says which). With fewer than 3 workers the
   workers are all "mixed": each rotates through the kinds seed by seed (vopr-nerva,
   vopr-testing, vopr-nerva, fuzz), so no kind goes uncovered. The split, all in `fleet.env`:
   `SIM_FLEET_WORKERS_VOPR_TESTING` and `SIM_FLEET_WORKERS_FUZZ` default to an eighth of the
   workers each (at least one), `SIM_FLEET_WORKERS_VOPR_NERVA` to the rest; 0 stops a kind. On a
   16-thread host that is 13, 1 and 1. Each worker starts seeds for `SIM_FLEET_ROUND_SECONDS`
   (900): a fresh random 64-bit seed per run, `vopr-<sm> <seed>` or `fuzz <fuzzer> <seed>`, each
   under its own deadline (`SIM_FLEET_VOPR_SEED_TIMEOUT` 600 s, `SIM_FLEET_FUZZ_SEED_TIMEOUT`
   900 s; past it, a seed is counted as a timeout, never filed, as `fuzz_loop.sh` does). A fuzz
   worker moves to the next fuzzer of `SIM_FLEET_FUZZERS` (the sixteen `fuzz.yml` runs) after
   every seed, and each starts at a different one.
3. Each seed is a line of the worker's `results`: target, seed, exit code, seconds. A failing
   seed keeps the last 64 KiB of its output (`tail.log`). A VOPR correctness failure (exit 129)
   is replayed once with the full-log binary, and its last 20 `[err]` lines are kept
   (`errors.log`): the short log mode prints only the simulator's and the cluster's state
   transitions, so the state checker's message never reaches it.
4. `sim_fleet.py ingest` (10 minute deadline) reads the round, counts it, and reports.

**Exit codes.** The VOPR exits 0 when the seed passed, and also on `unimplemented` (on purpose:
`vopr.zig`), 127 crash, 128 liveness, 129 correctness (`src/testing/cluster.zig`, `Failure`). A
panic aborts (134). The reporter's classes: for the VOPR, 128 is liveness, 129 correctness, and
anything else nonzero a crash; for a fuzzer every nonzero exit is a crash. 124 (past the seed's
deadline), 125 and 126 (`timeout` or the exec failed) and 137 (SIGKILL: the OOM killer) are the
host's: counted, never filed. A seed killed by SIGHUP would exit 129 too; the unit never sends
one.

## Issues

- **Fingerprint** of a failure = target (`vopr-nerva`, `vopr-testing`, `fuzz:<fuzzer>`) + exit
  class + a normalised signature, hashed: never the seed or the commit, so one bug is one issue
  across commits.
  - crash: the panic message (or `error: X` of an error returned from `main`, or the fault line),
    and the top 3 stack frames inside the checkout's `src/` as `src/vsr/replica.zig:on_prepare_ok`
    (Zig's own `lib/std` frames skipped); without a message, `killed by signal N` or `exit N`;
  - liveness: the reason `vopr.zig` logs, `no state convergence: <reason>`;
  - correctness: the last `[err]` line of the full-log replay (the checker's message, logged
    just before the exit; a passing run logs `[err] (client): ... session evicted` lines too, so
    the first would be noise; `client` lines are skipped), or a fixed text if the replay found
    none.

  Normalising replaces hexadecimal addresses with `ADDR` and every run of digits with `N`
  (line numbers, thread ids, ops, sizes), so a fix elsewhere in a file does not make a new issue.
- A fingerprint with no issue becomes an issue labelled `sim-fleet`, titled
  `VOPR nerva liveness: no state convergence: pending replica convergence` or
  `fuzz lsm_tree crash: reached unreachable code at src/lsm/tree.zig:...` (at most 120
  characters; built from the signature alone, so it is stable): the run and class, the signature,
  the commit, the seed, the exact replay (`git checkout <sha> && ./zig/zig build -Drelease vopr
  -Dvopr-state-machine=<sm> -- <seed>`, or `./zig/zig build -Drelease fuzz -- <fuzzer> <seed>`),
  the other seeds of the round that failed alike (at most 20), the `[err]` lines for a
  correctness failure, the last 60 lines (at most 8 KiB) of the log, and a hidden
  `<!-- vopr-fleet fingerprint: ... -->` marker.
- A fingerprint that has an issue (open or closed) gets a **comment** only when it fails on a
  commit it has not been reported on, and at most 4 times per failure per UTC day. A comment on a
  closed issue is a regression; reopen it by hand.
- At most 64 **distinct failures** are looked at per UTC day; past that, seeds are counted (the
  daily post says how many) and nothing is filed until the next day.
- **Seeds per day.** The state file counts seeds, failures, timeouts and host kills per target
  per UTC day, and the seeds of each failure. The first round after midnight posts the previous
  day's totals on the **tracking issue** (`SIM_FLEET_TRACKER`) *before* anything else. No comment
  for a day means the fleet did not run that day. Look at it daily; that is the alarm.
- **When GitHub says no.** An issue that is gone (404, 410, or a redirect: deleted or
  transferred) is forgotten and the failure is filed again. A locked issue (403) is skipped until
  the next commit. A rate limit (429, or 403 with `Retry-After` or no requests left) stops every
  write and holds them until the wait GitHub asked for (at most a day; an hour if it named none)
  is over; the rounds in between are counted, and their failures are reported when they recur.
  A tracking issue that refuses the totals is retried each round. A request never follows a
  redirect, so the token never goes to another host.
- Filed fingerprints are in `/var/lib/sim-fleet/state/state.json`. If that file is missing, the
  issue markers rebuild it (the latest 500 issues labelled `sim-fleet`). A state file that exists
  but cannot be read is an error (exit 2); it is never taken for empty.
- Exit codes of `sim_fleet.py`: 0 done, 1 bad input (the round is refused whole, nothing
  counted), 2 environment (state file, token, GitHub). The state is saved whatever GitHub
  answered; a round it did not finish is kept in `state/last-failed-round/`.
- Every collection is bounded (`sim_fleet.py`, the constants at the top): seeds and failing seeds
  per round, bytes read of a log, lines in an issue, fingerprints remembered (2048), days kept
  (31), pages scanned on a rebuild (5).

The reporter is Python 3, standard library only (`urllib`), as `perf/nightly/file_issue.py`
is (P147i). Its tests need no network: `python3 ops/sim-fleet/test_sim_fleet.py`.

## What the owner provides

1. **A host**: Ubuntu 24.04, x86_64, outbound HTTPS (and SSH, for a private repository) to
   github.com, api.github.com, ziglang.org and pypi.org (`./zig/download.sh`'s fallback), and
   nothing inbound. Suggested: a dedicated Hetzner AX-class server, 8 cores / 16 threads, 64 GB,
   NVMe. A VOPR seed takes 1 to 14 s in ReleaseSafe (N74; 1.4, 8.5 and 13.6 s measured for three
   seeds on 2026-11-04), about 5 s on average, so the 12 VOPR workers of the 14 that 56 GB holds run about 140,000 to 230,000
   seeds a day (SMT threads are slower than cores), against about 300 a push in CI today. Memory:
   a single seed of any kind peaks near 4 GB (anon-rss 3.2 to 3.9 GB for the VOPR of both state
   machines and the fuzzers, seen on the first deploy), so plan **about 4 GB of RAM per worker**
   (`SIM_FLEET_SEED_MEMORY_MB`, 4096). A 4-core, 8 GB host therefore runs 1 worker, at roughly a
   tenth of the suggested host's throughput. `setup.sh` caps the service with a drop-in,
   `sim-fleet.service.d/zz-memory.conf` (named to sort after a `systemctl edit` `override.conf`;
   `setup.sh` warns if the effective `MemoryMax` is not its figure), at the smaller of 56 GB and
   the host's memory minus 1 GiB (`MemoryMax`; below one seed's `SIM_FLEET_SEED_MEMORY_MB`
   `setup.sh` refuses, before it stops the service). It is worked out when `setup.sh` runs:
   **after resizing the VM, run `setup.sh` again**, so the cgroup limit is reached before the kernel's global OOM killer starts on
   sshd or the journal; a seed it kills (137) is still counted as the host's. Disk: the build caches are emptied past
   `SIM_FLEET_CACHE_MB` (16 GB); 100 GB is plenty. The Jepsen suite (N82, #106) could share the
   host later; it would take cores from the workers.
2. **A token**, a fine-grained personal access token (Settings, Developer settings, Fine-grained
   tokens):
   - Resource owner: the repository's owner. Repository access: **only** `nerva`.
   - Repository permissions: **Issues: Read and write**. Nothing else (Metadata: read is added by
     GitHub itself).
   - Expiry: the longest the organisation allows; put the date in the calendar. An expired token
     makes `sim_fleet.py` exit 2 with `HTTP 401` in the journal, files nothing, and the daily
     totals stop appearing on the tracker.
3. **No deploy key.** The repository is public, and the fleet fetches it over HTTPS
   (`SIM_FLEET_REMOTE=https://github.com/NervaLog/nerva.git`, the default). Should it ever go
   private: `ssh-keygen -t ed25519 -N '' -f nerva-fleet`, add `nerva-fleet.pub` under the
   repository's Settings, Deploy keys, **read-only**, set an `ssh` remote in `fleet.env` and give
   `setup.sh --deploy-key-file nerva-fleet`.
4. **The label** `sim-fleet` in the repository. Without it issues are still filed, unlabelled,
   and the recovery of a lost state file cannot find them.
5. **A tracking issue**, "Simulation fleet: seeds per day", pinned; its number goes in
   `SIM_FLEET_TRACKER`.

The token only ever sits in `/etc/sim-fleet/token` (root, mode 600), the deploy key in
`/etc/sim-fleet/deploy-key`. systemd hands the service private copies (`LoadCredential`), and
nothing prints them: a refused request logs its method, path and status, never a header. **Those
copies are readable by every process running as `simfleet`, which includes the VOPR, the fuzzers
and `zig build` of whatever is on `main`: any commit on `main` can read the token.** That is why
it may only read and write issues of this one repository, and why the deploy key is read-only.

## Deploy

On a fresh host, as root:

```
cd /root
git clone https://github.com/NervaLog/nerva.git nerva
sh nerva/ops/sim-fleet/setup.sh --token-file /root/github/token
editor /etc/sim-fleet/fleet.env              # SIM_FLEET_TRACKER=<the tracking issue>
systemctl restart sim-fleet
journalctl -u sim-fleet -f
```

`setup.sh` is safe to run again. It installs git, python3 and the rest, creates the `simfleet`
user, copies the secrets (never printed) to `/etc/sim-fleet` with mode 600, pins GitHub's SSH
host key, clones the repository to `/var/lib/sim-fleet/nerva`, stops the service if it
runs, downloads the pinned Zig and builds the VOPR once and runs the reporter's tests (so a broken
host shows now), installs the unit and enables it, and caps the journal at 2 GB. `fleet.env` is
copied only if it is not there yet. The service is (re)started only if the token file is not
empty.

**Redeploying** (a change to `ops/sim-fleet/`): `run.sh` is read from the checkout, which follows
`main`, so a restart picks up the new one, and the reporter is the copy built with each commit.
After a change to the unit or `setup.sh`, as root: `sh /var/lib/sim-fleet/nerva/ops/
sim-fleet/setup.sh && systemctl restart sim-fleet`.

The journal shows `building <sha>` when `main` moves and, after each round,
`sim-fleet: N seeds, F failed (seeds/failed: fuzz:ewah 3/0, vopr-nerva 2300/0, ...); filed ...`.

## Check that it works (before trusting silence)

- **Dry run**, nothing filed, no token needed. As root, with the service running or not:

  ```
  runuser -u simfleet -- env SIM_FLEET_DRY_RUN=1 SIM_FLEET_ROUNDS=1 SIM_FLEET_ROUND_SECONDS=60 \
      bash /var/lib/sim-fleet/nerva/ops/sim-fleet/run.sh
  ```

  A dry run uses its own checkout and state under `/var/lib/sim-fleet/dry/` (it clones and builds
  there first), never the service's, and prints each would-be issue and comment and the summary
  line.
- **The reporter alone**, on a made-up round: `python3 ops/sim-fleet/test_sim_fleet.py`, or write
  a `w0/results` line with a nonzero code and a `tail.log` and run
  `python3 ops/sim-fleet/sim_fleet.py ingest --dry-run --round DIR --commit abc1234 --state
  /tmp/st.json`.
- After the first real day: the tracker has a comment for it.

## Limits

- The token files issues and comments; it cannot close, label or delete. Closing and reopening
  are the owner's.
- The fleet tests the tip of `main` only; it does not look at pull requests.
- One host is a single point of failure by design. The tracker comment is how an outage shows.
- A round ends when its slowest seed does: a fuzzer seed can hold its worker's core up to
  `SIM_FLEET_FUZZ_SEED_TIMEOUT` past the round while the others wait.
- A correctness failure whose full-log replay does not reproduce it (or takes longer than
  `SIM_FLEET_REPLAY_TIMEOUT`) is filed under a fixed signature, so two such bugs of one state
  machine share an issue until someone looks.
