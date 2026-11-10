---
id: P286
date: 2026-11-10
area: Releases
amends: P284
---

# The systemd units name `nerva`, not a path; they restart on a crash, never on exits 1 to 8

**Decision.** v0.7.1's `nerva@.service` and `nerva-api@.service` (`packaging/linux/`) use
`ExecStart=nerva start …` and `ExecStart=nerva api …`, with no directory. systemd finds the binary on
its executable path: `/usr/local/bin` for the tarball's `install.sh`, `/usr/bin` for the packages
(slice 5). Their `RestartPreventExitStatus=` for a replica is `1 2 3 4 5 6 7 8`, every status `nerva start`
exits with on purpose (`FatalReason` in `src/vsr.zig`, and the pre-flight's 1 and 2); the gateway's is
`1 2`. `Restart=on-failure` restarts the rest: a signal (a crash, `kill -9`) and any other status.
`packages.yml` runs on a pull request that changes `packaging/`, `tests/packaging/` or itself, and on
`main`, and a draft's run waits for `ready_for_review`. It is not a required check.

**Reason.** The brief wants one set of unit files, byte for byte, in the tarball and in both packages,
and the two install the binary in different places. A bare name (systemd 239 and later; Debian 12,
Ubuntu 24.04 and Rocky 9 run 252 to 255) removes the difference without a second copy that can drift.
The brief named exits 7 and 8; the others (a flag, the disk or kernel, the data file's limits) are as
unfixable by a restart, and a loop of restarts of a replica that cannot open its file only fills the
journal.

**Cost.** A `nerva` in `/usr/local/bin` shadows a package's in `/usr/bin`; the installer does not look
for one. An operator who raises a limit and restarts by hand gets no automatic restart for it.
