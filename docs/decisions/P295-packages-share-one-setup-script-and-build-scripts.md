---
id: P295
date: 2026-11-10
area: Releases
amends: P284b
---

# The packages share one setup script, and each format has one build script

**Decision.** v0.7.1's `.deb` and `.rpm` are built by `packaging/linux/build-deb.sh` (`dpkg-deb`) and
`packaging/linux/build-rpm.sh` (`rpmbuild -bb` of `nerva.spec`), both taking
`<nerva> <arch> <version> <out-dir>`, and are tested by `tests/packaging/packages.py` in the `packages` job
of `packages.yml`. Three choices the brief left open:

1. **One maintainer script, `packaging/linux/package-setup.sh`**: the deb's `preinst` and, embedded by the
   spec, the rpm's `%pre`. It creates the user `nerva`, `/var/lib/nerva` (0750) and `/etc/nerva` (0750) and
   nothing else. There is no `postinst`, `prerm`, `postrm` or `%post*`, so nothing starts, enables, formats or
   removes anything, and `remove` and `purge` leave the data, the settings and the user. A foreign `nerva`
   user or group is refused with the existing **NRV-E1105**, in the `preinst`, before anything is unpacked; no
   new code is registered (ERRORS.md's 11xx text already names the package maintainer scripts).
2. **`build-rpm.sh` exists** (the brief lists only `build-deb.sh` and the spec), so the spec's macros and the
   reproducibility settings are written once and slice 7's `release.yml` calls a script, as it does for the deb.
3. **Weak dependency on systemd** (`Recommends`), a hard one on the tool that creates the user (`passwd`,
   `shadow-utils`): the units are useless without systemd, but the binary runs without it.

**Reason.** Two copies of the user logic would drift; one file cannot. The tarball's `install.sh` keeps its own
copy of the same checks (slice 4 owns it); the test in `install.py` and `packages.py` pin both to the same
message.

**Cost.** One more file under `packaging/linux/`. The package's message begins `nerva package:` where
`install.sh`'s begins `install.sh:`. A unit file is not reloaded by the package; `systemctl enable` and `start`
read it from disk.
