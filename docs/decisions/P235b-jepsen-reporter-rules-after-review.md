---
id: P235b
date: 2026-11-06
area: Releases
amends: P235
---

# Jepsen reporter: leaf checkers, verdict over exit code, crashed runs, statuses only move up

Found by the adversarial review of #235. For `ops/jepsen/`:

- **Fingerprints name the leaf checker.** A composed checker (`:workload` for bank, which holds
  `:bank`, `:source`, `:view`, `:refusals`) is walked into, and the failing leaf is named by its
  path (`workload.source`); the class table is keyed by the leaf's last key. A `:violations`
  count at a checker's own level (protocol) is the class `violations`.
- **A written verdict outranks the exit code.** An invalid or unknown `results.edn` is filed even
  if the run then exited 124 or 137 while cleaning up.
- **A crashed run is Nerva's.** A `jepsen.log` with no `results.edn`, and an exit code that is not
  124, 125, 126 or 137, means Jepsen started and the test threw (a replica died at setup). It is
  the fingerprint `<workload>|run|crashed`, filed with the end of `jepsen.log`; status `failure`.
  No `jepsen.log` at all (the build, Docker, `lein`) stays the host's. Cost: a Jepsen exception
  from the host's own trouble (ssh, Docker) is filed once as an issue a person closes.
- **A commit's status only moves up** (error, success, failure), per context, kept in the state
  file (`verdicts`, 256 commits). A later night never turns a `failure` green, and a night that
  could not run never turns a `success` into `error`. A night that could not fetch posts no status
  (`--no-status`). Cost: a lost state file forgets the ranks until the next night.
- **A body never exceeds its bound.** The excerpt's budget counts omission markers and decoding
  and is re-rendered smaller until the rendered text fits; at worst it is left out.
- **A dry run keeps to itself:** its own state file, night directory and archive; the numbers it
  makes up are never remembered.
- **`nightly.sh` runs the tip's own script:** after the fetch it re-executes the tip's
  `nightly.sh` (stage 2) if it differs, and every step of the fetch is checked by hand.
