---
id: P339
date: 2026-11-11
area: Releases
amends: P286b
---

# install.sh refuses --upgrade while units run; the replica unit restarts exit 1

**Decision.**
1. `install.sh --upgrade` that would replace a different `/usr/local/bin/nerva` refuses with NRV-E1118
   when any `nerva@*` or `nerva-api@*` unit is active, starting or stopping (exit 1, also with
   `--dry-run`). A refusal, not a warning: a restart of a replica runs the new binary, which is a
   cluster of two releases or NRV-E0701. Replacing the same binary is not refused.
2. A package's `/usr/bin/nerva` next to the tarball's `/usr/local/bin/nerva` is warned about with
   NRV-W1102 (stderr, the install goes on, not on `--uninstall`). Not a refusal: removing the package
   is the operator's choice, and NRV-W1101 is the package side's warning of the same shadowing.
3. `install.sh` sets `PATH=/usr/sbin:/usr/bin:/sbin:/bin` and unsets `CDPATH` after `set -eu`; reads
   directories with `stat -L`; and does not `chmod` the tarball's `nerva` under `--dry-run` (it says it
   would, and skips running it). The next-steps text already printed `install -m 0600` (#286's fixes).
4. `nerva@.service`: `RestartPreventExitStatus=2 3 4 5 6 7 8 70` (exit 1 removed, 70 added), with
   `StartLimitIntervalSec=60` and `StartLimitBurst=10` in `[Unit]`. Exit 1 includes failures a restart
   or the boot cures (NRV-E0703 a lock the dead process held, NRV-E0010 a collector with no route yet),
   and 7 and 70 are both bugs. A permanent exit 1 (a bad flag) now stops after ten starts, about ten
   seconds, as `failed`, instead of at once.
5. `release_check.sh binary` (NRV-E1113) also fails a `nerva version` that carries `+keys-off` (#271),
   beside the existing check of `commit_keys deduplicate`; no new code.

**Why.** #292 and #271, from the reviews of #286 and v0.7.0. The release soak is running, so none of it
touches `src/` or `build.zig`.

**Cost.** An operator whose units are running stops them before an upgrade, as the docs already said.
A mistyped flag in `replica-N.env` shows as a restart loop for ten seconds before `failed`, where it
used to fail at once. Left alone: a disk failure (NRV-E0708, a panic) restarts every second, since it
is not an exit status the unit can name.
