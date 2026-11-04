---
id: P147h
date: 2026-11-04
area: "Milestone 3: positioned reads and the first views"
amends: N74
---

# An always-on simulation fleet runs the VOPR and the fuzzers at the tip of `main` and files what it finds

N74 left "the always-on fleet (Hetzner, the owner's choice)" for later; this is it, modelled on
Zigcube's (`Zigbox/zigcube`, `ops/sim-fleet/`). `ops/sim-fleet/` holds the loop (`run.sh`), the
reporter (`sim_fleet.py`), the systemd unit, `setup.sh` and the README the owner deploys from.

- **One host**, Ubuntu 24.04 (suggested: a dedicated Hetzner AX-class server, 8 cores / 16
  threads, 64 GB). A systemd service runs as the unprivileged user `simfleet`, `Nice=10`,
  `ProtectSystem=strict`, no capabilities, `MemoryMax=56G`.
- **What it runs.** `run.sh` polls `origin main`, builds each new tip once in ReleaseSafe into a
  directory of its own (the VOPR for `nerva` and `testing`, each also with `-Dvopr-log=full`, and
  the fuzz binary), keeps running the last good build if a tip does not build, and remembers
  built and broken commits across restarts. Workers are every core but one (configurable): an
  eighth each to the testing state machine and to a rotation through the sixteen fuzzers
  `fuzz.yml` runs, the rest to Nerva's state machine. Each runs fresh random seeds for a
  15-minute round, under a per-seed deadline.
- **What it files.** One GitHub issue labelled `sim-fleet` per distinct failure. Its fingerprint
  is the target, the exit class (crash, liveness 128, correctness 129) and a normalised signature
  (a crash's panic message and top three frames inside `src/`; the liveness reason; the last
  `[err]` line of a full-log replay for a correctness failure, since a passing run logs client
  evictions at that level too), with addresses stripped and
  digits replaced by `N`; never the seed or the commit. The issue carries the seed, the commit,
  the exact replay command, a bounded tail of the log and a hidden
  `<!-- vopr-fleet fingerprint: ... -->` marker that rebuilds a lost state file. A known failure
  gets a comment only for a commit not yet reported, at most 4 a day; at most 64 distinct
  failures are looked at a day; a tracking issue gets one comment per finished UTC day with the
  totals, and a missing one is the outage alarm. A rate limit holds every write until GitHub's
  wait is over; no request follows a redirect.
- **Token.** A fine-grained PAT scoped to this repository with Issues read/write only, delivered
  by systemd `LoadCredential`; for a private repository, a read-only deploy key the same way.
  Any commit on `main` runs as the service user and can read both, which is why their scope is
  that narrow.

**Why.** CI runs about 300 VOPR seeds a push (N74) and the long fuzzing runs only by hand (N59);
a bug that shows once in 100,000 seeds is found by neither. One host searching all day (an
estimated 150,000 to 250,000 VOPR seeds a day) finds it, and an issue per fingerprint keeps the
finding in front of the owner without a flood.

**What it costs.** A host to rent and watch (the daily post is the only alarm), a token to renew
before it expires, and five ReleaseSafe builds per commit on `main`. Correctness failures need a
second, full-log replay to be told apart, and one that does not reproduce in it shares a fixed
signature with its state machine's others. The full-log binary (`-Dvopr-log=full`) is assumed to
replay a seed as the short-log one does, since the log mode changes only what is printed. The
fleet tests `main` only. `ci.yml`, `fuzz.yml` and `fuzz_loop.sh` are unchanged.
