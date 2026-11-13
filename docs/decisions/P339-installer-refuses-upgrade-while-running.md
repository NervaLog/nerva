---
id: P339
date: 2026-11-11
area: Releases
amends: P286b
---

# install.sh refuses --upgrade while units run; the replica unit restarts exit 1

**Decision.**
1. `install.sh` refuses with NRV-E1118 (exit 1, also with `--dry-run`) when any `nerva@*` or
   `nerva-api@*` unit is active, starting or stopping and the tarball's nerva differs from the one the
   units run now: `/usr/local/bin/nerva`, else a package's `/usr/bin/nerva` (which needs no `--upgrade`,
   since nothing is replaced, but would still be shadowed by the new binary on a replica's next
   restart). A refusal, not a warning: that restart runs the new binary, which is a cluster of two
   releases or NRV-E0701. Installing the same binary is not refused. If `systemctl list-units` fails,
   the check cannot tell and refuses with NRV-E1102 (exit 2; no new code): it fails closed. A unit
   started after the check and before the copy is not seen.
2. A package's `/usr/bin/nerva` next to the tarball's `/usr/local/bin/nerva` is warned about with
   NRV-W1102 (stderr, the install goes on, not on `--uninstall`). The fix line says to leave the package
   installed: removing it (its prerm) and `install.sh --uninstall` both disable the enabled `nerva@N` and
   `nerva-api@N` links, which the two installs share, so the cluster would not start at the next boot
   unless the operator enables the instances again, and the line says so. Not a refusal: NRV-W1101 is
   the package side's warning of the same shadowing.
3. `install.sh` sets `PATH=/usr/sbin:/usr/bin:/sbin:/bin` and unsets `CDPATH` after `set -eu`; reads
   directories with `stat -L`; and does not `chmod` the tarball's `nerva` under `--dry-run` (it says it
   would, and skips running it). The next-steps text already printed `install -m 0600` (#286's fixes).
4. `nerva@.service`: `RestartPreventExitStatus=2 3 4 5 6 7 8 70` (exit 1 removed, 70 added), with
   `RestartSec=5`, `StartLimitIntervalSec=300` and `StartLimitBurst=20` in `[Unit]`. Exit 1 includes
   failures a restart or the boot cures (NRV-E0703 a lock the dead process held, NRV-E0010 a collector
   with no route yet), and 7 and 70 are both bugs. The limit counts every start, not only exit 1: any
   loop that restarts more often than every 15 s (a permanent exit 1, a panic, a signal) ends as
   `failed` after about 100 s (20 starts: the first and 19 restarts; systemd refuses the next one, and
   `Result` stays `exit-code` on systemd 255), and a slower one never does. That is about 100 s of retries after a boot,
   not 10 s, for a route that appears late (DHCP, no `*-wait-online`).
5. `release_check.sh binary` (NRV-E1113) also fails a `nerva version` that carries `+keys-off` (#271),
   beside the existing check of `commit_keys deduplicate`; no new code.

**Why.** #292 and #271, from the reviews of #286 and v0.7.0. The release soak is running, so none of it
touches `src/` or `build.zig`.

**Cost.** An operator whose units are running stops them before an install over a different nerva, as
the docs already said. A mistyped flag in `replica-N.env` shows as a restart loop for about 100 s
before `failed`, where it used to fail at once. A disk failure (NRV-E0708, a panic) is a signal, not an
exit status the unit can name: it restarts every 5 s and the same limit ends it after about 100 s. A
replica that is down for a short outage restarts at most every 5 s, not every second. The unit's
policy is tested under systemd in `tests/packaging/install.py` (CI, `packages.yml`).
