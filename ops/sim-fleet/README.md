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
   workers each (at least one), `SIM_FLEET_WORKERS_VOPR_NERVA` to the rest; 0 stops a dedicated
   kind (mixed workers rotate through all kinds). On a 16-thread, 64 GB host that is 12, 1 and 1
   (14 workers: memory, not cores, is the limit). Each worker starts seeds for `SIM_FLEET_ROUND_SECONDS`
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
  issue markers rebuild it (the latest 500 issues labelled `sim-fleet`) before anything is filed;
  until they can be read, rounds are still counted and nothing is filed. A state file that exists
  but cannot be read is an error (`soak` exit 2); it is never taken for empty or overwritten.
  Deleting a corrupt `state.json` to get past that erases the candidate's refused count (and its
  fingerprints): never do it for a commit you mean to release.
- **Every round is settled by a record, never by an exit code** (#370, P382). `run.sh` gives each
  round a random id (`state/round/id`, beside `commit`) and waits for each worker. If any worker
  died before the round's end (any failed command, such as a full disk), the round is refused
  without being read: that worker may have lost a failing seed. Otherwise `sim_fleet.py ingest`
  counts the round, or refuses it whole (past 4096 failing seeds, or a malformed `results`
  line), and saves that, with the id in `last_round`, in one atomic write of the state file,
  before it reads the token or asks GitHub anything; a missing token or GitHub down then stops
  only the reports. An unterminated last line, which only a power cut or a full disk leaves, is
  a failure when it has a code that is not 0, and is dropped otherwise. After `ingest` ends,
  however it ends, `run.sh` looks for the id in the state file. Not there (a usage error, a
  crash, a timeout, a kill): `sim_fleet.py refuse` records the round as refused. Still not there
  (the state cannot be written): the round stays in `state/round/`, `run.sh` exits 1, and
  systemd starts it again 30 s later. A counted round is deleted; a refused one, or one `ingest`
  did not exit 0 on, is kept in `state/last-failed-round/` for a look. `ingest` and `refuse` do
  nothing for a round already recorded, so no round is counted twice. A refused round makes its
  commit not clean for `soak`, and the tracker's daily totals say how many rounds were refused.
- **A restart is safe.** A round that a stop, a reboot or a crash left in `state/round/` is
  settled from the results its workers wrote, before the next one starts, under the round's own
  commit: its finished seeds count, and a failing one makes that commit not clean (a seed's
  `results` line is its only record: written first, and fsynced when the seed did not pass,
  before its log and its full-log replay). A stop kills the seeds that were running with their
  workers, and they are not recorded: a seed that had not finished had not failed yet, so this
  loses seed-hours, not failures. Two rare cases do lose one failing seed: a worker that died
  in a round that a stop then cut before the round's end, and a power cut that tears a failing
  seed's line before its code (P382).
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
     leaves `HTTP 401` in the journal and `(writes stopped: refused)` on the round's line; the
     rounds are still counted, nothing is filed, and the daily totals stop appearing on the
     tracker.
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

## The Jepsen window

The Jepsen nightly ([ops/jepsen](../jepsen/README.md), R1) shares this host. At **01:17 UTC**
`jepsen.service` stops `sim-fleet.service` (a stop is a clean `SIGTERM`; the loop's state
survives, so the round in flight is lost and nothing else), runs for about 2.5 h and at most
3 h, and starts the fleet again, whether the night passed, failed or was killed. A fleet that
is stopped for the window is normal: its tracker line for that day is late, not missing. Do not
start the fleet by hand during the window.

## Release soak

A release is cut from a frozen `main` commit, the candidate (docs/briefs/v0.7.1.md, P284b), and
the gate asks that the fleet ran it for 24 hours. The fleet counts that itself.

**What it counts.** For each of the last 64 commits (the oldest is dropped past that, bounded in
`sim_fleet.py` and asserted) the state file keeps the hours its rounds ran, the seeds by kind
(`vopr-nerva`, `vopr-testing`, `fuzz`) and the failing seeds. A round's hours are its busiest
worker's seconds, summed from that worker's `results` file: the rounds' own records, never wall
time, so a stopped fleet (the Jepsen window, a crash) adds nothing. One seed counts for at most
`SEED_SECONDS_MAX` (3600 s: a seed's deadline plus its replay), so a clock step cannot add hours;
hours are floored to a tenth. The entry also keeps the seeds past their deadline and killed by the
host, and the failure fingerprints its rounds hit (at most 64, the rest counted), whether or not a
report was posted. Each daily tracker comment has
a "Commits that ran" list, one line per commit that ran that day: its hours that day, its hours in
all and its seeds that day. A state file written before this counting loads and starts counting
from its next round; commits that ran before have no hours.

**The line the release PR quotes**, from the state file alone (no token, no network):

```
python3 -I /var/lib/sim-fleet/state/bin/$(cat /var/lib/sim-fleet/state/built)/sim_fleet.py soak --commit <SHA> --state /var/lib/sim-fleet/state/state.json
soak 1a2b3c4: 24.6 h, vopr-nerva 182,311 seeds, vopr-testing 15,020, fuzz 9,874; 0 failures, 0 past the deadline, 0 killed by the host; sim-fleet issues its rounds hit: none
```

(The built commit's copy, or any checkout's `ops/sim-fleet/sim_fleet.py`, works: `soak` reads only the state file. `--commit`
is the full SHA or a prefix of at least 7 hex digits.) Exit 0 if the commit ran and is clean; 1 if the state
has no round of it (the line then says `0.0 h`), the prefix names two commits, or the commit is not
clean: any failing seed, any seed past its deadline or killed by the host (a candidate that hangs
its seeds is not clean, however many hours they fill), any failure fingerprint hit, or any
refused round (a worker died, past 4096 failing seeds, a malformed line, or a reporter that left
no record; the line then ends `; N rounds refused or lost by the reporter, their seeds
unknown`); 2 if the state file is missing or unreadable. "Failures" counts failing seeds, not distinct bugs. "Issues
its rounds hit" lists the issue of every failure fingerprint the commit's rounds hit, from the
rounds' own records and so independent of throttling, a hold or a rate limit (`not filed (...)`
is a failure whose report was not posted); the state does not see a closed issue, so confirm each
listed issue on GitHub (`label:sim-fleet is:open`) before quoting it. The gate wants 24 hours and no open
issue; the line does not decide that, the reader does.

**A refused round cannot be cleared.** A refused round now means a worker that died (a full
disk, a failing command), bad input or a reporter bug (a token, GitHub, a restart or a slow disk
no longer refuses a round), so the state has no way to undo one and `run.sh` writes no marker to
remove. Read the round in `state/last-failed-round/`
and the journal; if it was the host and not the candidate, the owner waives it in writing in the
release PR, or the fleet soaks a new candidate.

**Pointing the fleet at the candidate.** Set `SIM_FLEET_BRANCH` in `/etc/sim-fleet/fleet.env` to
the candidate's **full 40-character SHA** and `systemctl restart sim-fleet`. `run.sh` runs
`git fetch origin $SIM_FLEET_BRANCH`, takes `FETCH_HEAD` as the commit and checks it out, and
that works with a SHA unchanged: GitHub serves any commit of a public repository to `git fetch`
by its full SHA (checked from a clone with `main`'s tip three commits ahead of the SHA: the fetch
succeeds, `FETCH_HEAD` is the SHA, the checkout is detached on it). An abbreviated SHA does not
fetch (`couldn't find remote ref`; the loop logs `git fetch failed` and keeps what it has, so a
typo soaks the old commit silently: check `journalctl -u sim-fleet` for `building <SHA>`). The
fleet then stops following `main`; the soak restarts at a new commit when the owner moves the
pin (a fix merged to `main` first), and when the soak ends the owner removes the line and
restarts the service. A restart kills the round in flight; the next start settles it from the
lines it holds, before it builds anything when a reporter is already built (otherwise right
after the first build; the log says `settling round ... left by a stop or a
crash`). Read `soak` for the old candidate only after that line, and for the new one only after
its first round ends.

**The candidate must contain this loop.** `run.sh` runs from the checkout it builds, and the
reporter is copied from the commit it built, so pinning the fleet to a commit runs that commit's
`run.sh` and `sim_fleet.py`. The guarantees above (#370, #387, P382) hold only for a candidate
that contains #382. An older candidate runs the old loop: its reporter refuses `ingest
--round-id` and `refuse`, the new `run.sh` exits 1, systemd restarts the checkout's old `run.sh`,
and that deletes the round in flight uncounted. Pin a candidate that contains #382; one whose
`src/`, `build.zig`, `build.zig.zon` and `zig/` match an older candidate soaks the same code.

**Before the soak counts** (the owner's host steps, in order; none is done by this repository):

1. Provision the host (docs/briefs/r1.md, "The host").
2. Create the two tokens (R1 owner question 3): fleet Issues only; Jepsen Issues and Commit
   statuses.
3. Run both `setup.sh` (trackers #177 and #266). The fleet installs only `sim-fleet.service`
   (P240 applies to `ops/jepsen/` only): it runs `run.sh` from its own checkout, and `run.sh` runs
   the `sim_fleet.py` copied from the commit it built. So counting starts as soon as the fleet
   builds a commit that contains it, and during the soak **the candidate's own `sim_fleet.py`
   counts and files**: a candidate that changes the reporter grades itself. The owner confirms
   `ops/sim-fleet/sim_fleet.py` is unchanged between the soak's commit and the reviewed one (or
   notes the change in the release PR); `soak` itself can be run from a checkout of the last
   release, since it reads only the state file. A `soak` run before any counted round finds no
   `commits` and says `0.0 h`.
4. Watch one full day on `main` (a tracker post from each).
5. Run R2's canary (a scratch-branch fault, filed once, then commented on and not filed again).
6. Run R1's teeth night (`--expect-invalid` on the keys-off build files one `jepsen` issue). A
   fleet that has never filed anything passes the gate silently; steps 5 and 6 prove it would not.
   For v0.7.1 the owner skipped step 4 and ran steps 5 and 6 during the soak (P359).

The Jepsen clause of the same soak is in [ops/jepsen](../jepsen/README.md#release-soak). Jepsen
stops the fleet for about 2.5 h a night, so 24 hours of rounds take about 27 of wall time.

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
