---
id: P286b
date: 2026-11-10
area: Releases
amends: P286
---

# The gateway unit restarts on exit 1; the installer's refusals each name their own cause

**Decision.** `nerva-api@.service` sets `RestartPreventExitStatus=2` only, not `1 2` as P286 said,
and caps a loop with `StartLimitIntervalSec=10` and `StartLimitBurst=5`. The replica unit's list
(`1 2 3 4 5 6 7 8`) is unchanged. `install.sh` gives every refusal its own registered code
(`docs/ERRORS.md`, 11xx): NRV-E1104 now means only "the tarball's `nerva` is for another
architecture" (read from the ELF header against `uname -m`, so an emulator does not hide it), and
new are NRV-E1106 (usage), E1107 (the `nerva` cannot run, for example a `noexec` mount), E1108 (a
file of the tarball is missing) and E1109 (no `sha256sum`). NRV-E1105 also covers a group `nerva`
without the user, and a user `nerva` whose primary group is not `nerva`. `--uninstall` disables the
enable links of `nerva@*` and `nerva-api@*`. `packages.yml` runs on every push to `main`, and on a
pull request that changes `src/nerva_main.zig`, `src/nerva/diagnostic.zig` or `VERSION` as well.

**Reason.** The gateway exits 1 both for a bad flag or key and for NRV-E0604 (no reply from the
cluster within 30 s), and a gateway that starts before a quorum, at the boot of a cluster, must keep
restarting. The two cannot be told apart by status, so the cure is the start limit: a bad flag exits
at once and stops after five starts, while a gateway that waits 30 s for the cluster never reaches
it. Giving E0604 its own exit status would change `src/`, outside this slice. One cause per code
keeps the `cause` line, which is the code's summary, true.

**Cost.** A gateway with a bad flag is started five times before it stays failed. A host that
disables the start limit gets a one-second restart loop for such a flag. NRV-E1104's meaning narrows
before any release has shipped it, so no operator has seen the old one.
