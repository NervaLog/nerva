---
id: P240
date: 2026-11-06
area: Releases
amends: P235
---

# A tip whose nightly.sh does not parse is the repository's defect: status failure and an issue

Found by the review of #240. For `ops/jepsen/`:

- **Classification.** A `main` whose `ops/jepsen/nightly.sh` fails `bash -n` is a defect in
  Nerva's repository, not the host's. P235 keeps host failures out of issues and at status
  `error`; that fits a full disk, not a broken script that stays broken until someone fixes
  `main`. The night writes `store/repo-failure` (what `bash -n` said); the reporter sets status
  `failure` (the commit's nightly cannot run, so it is not green) and files one issue,
  fingerprint `nightly|script|unparsable`, deduplicated like any other finding.
- **Its own reporter.** The night reports with the reporter copied at stage 1, because the
  tip's reporter may not take the old script's arguments.
- **A canary's crash is the canary's.** A crashed `--expect-invalid` run uses the `canary|`
  fingerprint, a canary title and body, and the `-Dtest-commit-keys=off` reproduce command (P235).
- **The lock variable is checked.** `JEPSEN_LOCK_HELD` counts only in stage 2, when fd 9 is the
  lock file and `flock -n 9` succeeds on it.
- **No token, no night.** `nightly.sh` exits with one journal line before any work; the unit's
  first `ExecStartPre` is `nightly.sh --check-token`, ahead of the step that stops the fleet.
  `setup.sh` without a token disables a timer that is already enabled.
- **History.** A run's history is freed after its last finding is reported.

Cost: a broken `nightly.sh` on `main` pins that commit at `failure` and opens an issue, where
before it was a quiet `error`. The first night after this merges still runs the old stage 1.
