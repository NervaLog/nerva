---
id: P319
date: 2026-11-11
area: Releases
amends: P295
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

**Cost.** A tarball install laid over an installed package is not caught on the package's next upgrade:
`install.sh` already refuses the reverse, and the shadowing is the operator's own doing once the
package is installed.
