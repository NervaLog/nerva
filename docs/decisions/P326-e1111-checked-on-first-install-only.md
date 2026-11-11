---
id: P326
date: 2026-11-11
area: Releases
amends: P295b
---

# The package refuses a shadowing file on a first install only

**Decision.** `package-setup.sh` checks for `/usr/local/bin/nerva` and the two units in
`/etc/systemd/system` (NRV-E1111) only on a first install: dpkg `install` (with or without an old
version) and rpm `1`. It skips the check for dpkg `upgrade` and rpm 2 or more. Its cause and fix lines
no longer assume a tarball install: the file is not the package's (a tarball install, a source build
or a full unit override), and the fix is `install.sh --uninstall` for a tarball and moving or removing
the file otherwise. The code keeps its number; only the text changed.

**Why.** After `systemctl edit --full nerva@.service` or a source-built `/usr/local/bin/nerva`, an upgrade
was refused with the wrong blame and a fix (`install.sh --uninstall`) that would delete the edit (#319).

**Cost.** `install.sh` does not look for the package's `/usr/bin/nerva`, so nothing refuses a
tarball install laid over an installed package (#292, still open). On an upgrade, a
`/usr/local/bin/nerva` left behind (a tarball install, a source build) shadows the package's new
binary: `/usr/local/bin` comes before `/usr/bin` on the path, and both units run `nerva` by name, so
the replicas keep running the old file while the package manager reports the new version. Before this
decision the next upgrade was refused with NRV-E1111, the only signal; the reason P295b gives for
refusing (a package would install and then never run) still holds on an upgrade. So the preinst now
prints a warning, NRV-W1101, for that one file on an upgrade and goes on: refusing would repeat #319
for a source-built binary, and the warning keeps the signal. A full unit override in
`/etc/systemd/system` is a deliberate systemd choice and gets no warning. The warning goes to stderr,
which apt and dnf show; it is not a guard, and #292 remains the open fix for the installer's side.
