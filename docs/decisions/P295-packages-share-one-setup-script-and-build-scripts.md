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

## Findings from the container runs, and signing

Measured in the Packages workflow (the `FINDING:` lines of `tests/packaging/packages.py`), not assumed:

- **Unsigned packages.** `dnf install /path/nerva-*.rpm` with the defaults installs the unsigned file on Rocky 9
  (rpm 4.16, dnf 4) and on Fedora latest (rpm 6.1, dnf 5): neither checks a local file's signature
  (`localpkg_gpgcheck` is off). rpm 6.1 itself, run directly, refuses the same file (`rpm -U`:
  `package nerva-0.7.0-1.x86_64 does not verify: no signature`); `rpm -U --nosignature` installs it. Rocky's rpm
  4.16 takes `rpm -U` unsigned without an option. So a user installing our unsigned `.rpm` on Fedora uses
  `dnf install ./nerva-<version>-1.<arch>.rpm`, or `rpm -U --nosignature` with rpm directly. The test uses
  exactly those and no `--no-gpgchecks`.
- **Signing.** Packages are **unsigned in 0.7.1**; the release already publishes `SHA256SUMS` beside them.
  Signing the `.rpm` (and a signed apt/dnf repository) is a follow-up issue, because it needs a release key
  and its custody, which the owner has not decided.
- **dpkg doc excludes.** The `ubuntu` image carries `/etc/dpkg/dpkg.cfg.d/excludes` (`path-exclude=/usr/share/doc/*`),
  so dpkg does not unpack `/usr/share/doc/nerva/*` there; the deb flow removes that file before installing.
  dnf's equivalent is `tsflags=nodocs`, set empty with `--setopt=tsflags=`. Real hosts are unaffected.
- **apt lists.** The images ship no apt package lists, and a package installed from a local file is not in
  them, so `apt-get remove` and `purge` cannot find it; the test removes with `dpkg -r` and `dpkg -P`, which
  run the same maintainer scripts.
- **`cmp`.** Rocky's image has no `cmp`; the checks compare SHA-256 sums.
