---
id: P240
date: 2026-11-06
area: Releases
amends: P235
---

# The Jepsen runner is installed by setup.sh; the night never runs the tip's ops/jepsen/

Found by three reviews of #240 (and #241). P235b had `nightly.sh` fetch the tip of `main` and
re-run the tip's own script (stage 2), so the runner's script and reporter were taken from the
tip every night. Each review found a way for a bad commit to silence the night: a script that did
not parse, one that died at run time, a broken `jepsen_report.py`, a systemd stop that killed
both stages, a rate-limited reporter misread as dead. Each fix added more machinery. This removes
the cause. For `ops/jepsen/`:

- **The runner is installed.** `setup.sh` copies `nightly.sh`, `jepsen_report.py`,
  `jepsen.service` and `jepsen.timer` from the checkout it is run in to `/opt/jepsen/bin` and
  `/etc/systemd/system` (root-owned; `/opt` is read-only inside the unit, which a directory
  under `jepsen`'s home would not be). Each file is moved into place, so a night running now keeps
  its copy. The unit runs `/opt/jepsen/bin/nightly.sh`.
- **The night fetches code, not tooling.** It fetches the tip into `/var/lib/jepsen/nerva`, builds
  it and runs `tests/jepsen` from it. It never runs the tip's `ops/jepsen/`. A failed fetch or
  checkout is the host's failure, as before; so is a failed build (P235b).
- **A runner change reaches the host only when `setup.sh` runs again** (the README says so, in the
  deploy steps). Cost: a merged fix to the runner does nothing until the owner runs it; the
  reporter's tests run in `setup.sh`, so the commit installed is the commit tested.
- **Gone:** the re-exec and child, `JEPSEN_STAGE*`, `JEPSEN_LOCK_HELD`, `restore_checkout`, the
  `reported` marker, the copied reporter, the tip `bash -n` check, the `nightly|script|unparsable`
  and `nightly|script|died` findings, and P235b's last bullet ("`nightly.sh` runs the tip's own
  script"). A broken `nightly.sh` on `main` is now caught by review and by `setup.sh`'s tests, and
  changes nothing about a night.
- **An interrupted night is reported.** A TERM or INT trap in `nightly.sh` stops the child, records
  the run in flight as exit 143 (the host's: `HOST_CODES`) or writes a `host-failure` if no run had
  finished, and posts `jepsen/nightly` `error` and the tracker's line, with the reporter bounded by
  `timeout 60` and the child given 20 s. `TimeoutStopSec=120` leaves room. The long steps run in
  the background and are waited for, so bash runs the trap at once.
- **One lock, taken once** by the one process, held to its exit; long children get fd 9 closed.
  A second night logs the pid from `nightly.pid`.
- **Kept from the first review of #240:** a crashed canary uses the canary's fingerprint, title,
  body and reproduce command; `nightly.sh --check-token` is the unit's first `ExecStartPre`;
  `setup.sh` disables the timer when there is no token; a run's history is freed after its last
  finding is reported.

Cost: the runner on the host can lag `main` until `setup.sh` runs. The first night after this
merges still runs the previously installed (or checkout's) script; the owner runs `setup.sh` once
to move the unit.
