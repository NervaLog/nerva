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

1. **One setup script, `packaging/linux/package-setup.sh`**: the deb's `preinst` and, embedded by the
   spec, the rpm's `%pre`. It creates the user `nerva`, `/var/lib/nerva` (0750) and `/etc/nerva` (0750) and
   nothing else. Nothing in any maintainer script starts, enables, formats or removes anything, and `remove`
   and `purge` leave the data, the settings and the user (the other scripts, added in "Review fixes", only
   reload systemd and disable enable links). A foreign `nerva` user or group is refused with the existing
   **NRV-E1105**, in the `preinst`, before anything is unpacked.
2. **`build-rpm.sh` exists** (the brief lists only `build-deb.sh` and the spec), so the spec's macros and the
   reproducibility settings are written once and slice 7's `release.yml` calls a script, as it does for the deb.
3. **Weak dependency on systemd** (`Recommends`), a hard one on the tool that creates the user (`passwd`,
   `shadow-utils`): the units are useless without systemd, but the binary runs without it.

**Reason.** Two copies of the user logic would drift; one file cannot. The tarball's `install.sh` keeps its own
copy of the same checks (slice 4 owns it); the test in `install.py` and `packages.py` pin both to the same
message.

**Cost.** One more file under `packaging/linux/`. The package's message begins `nerva package:` where
`install.sh`'s begins `install.sh:`.

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

## Review fixes (P295b)

The adversarial review of this pull request found these; each changes what the packages do.

- **The binary is checked.** `build-deb.sh` and `build-rpm.sh` source `check-elf.sh`, which reads the ELF
  header as `install.sh`'s `elf_machine` does and refuses, with **NRV-E1110** (new, `docs/ERRORS.md`), a file
  that is not an ELF executable or is for the other architecture. `install.sh` checks the ELF magic and the
  machine and then runs `nerva version`; the build scripts cannot run a foreign binary, so they check the
  magic and the machine only. `packages.py` compares the packaged `/usr/bin/nerva` with its input byte for byte,
  needs a real `aarch64-linux` build (`--aarch64`) for the arm64 and aarch64 packages, and builds with the
  wrong binary, `/bin/true` and a script to see them refused. The other refusals of the two build scripts (usage,
  an unknown architecture name, a malformed version, a missing file) are not coded: release tooling run with
  fixed arguments by `release.yml` and `packages.py`, not an operator surface.
- **The examples live in `/usr/share/nerva/`**, not under `/usr/share/doc` where a doc filter drops them
  (minimized systems, `nodocs`). They are not `%doc`. `install.sh` puts the same files in `/etc/nerva`, so
  with the package an operator copies `/usr/share/nerva/replica.env.example` to `/etc/nerva/replica-0.env`; the
  package never writes `/etc/nerva` itself. The deb's licence is also installed as `copyright` (the file a
  doc exclusion keeps) and the rpm marks `LICENSE` `%license`. The container tests no longer lift the images'
  doc filters: they prove the examples arrive under them. The statement above that "real hosts are unaffected"
  was wrong.
- **The package does what `install.sh` does around systemd**, with two more maintainer scripts for the deb and
  one for the rpm, none of which starts, stops or restarts anything (an upgrade leaves a running replica
  running): `package-reload.sh` (the deb's `postinst` and `postrm`) runs `systemctl daemon-reload` when systemd
  runs, so that `systemctl restart nerva@0` loads a changed unit; the rpm needs none, systemd's rpm file
  triggers reload. `package-prerm.sh` (the deb's `prerm`, the rpm's `%preun`), on removal only (`remove`,
  count 0; a purge removes first), disables the instances in `*.wants/` as `install.sh --uninstall` does
  (P286b), so a later install does not revive them. The brief allowed scripts that only create the user and
  the directories; the review showed that was not the behaviour of the other install path.
- **A tarball install is refused**, not warned about: `package-setup.sh` refuses with **NRV-E1111** (new) when
  `/usr/local/bin/nerva` or a unit in `/etc/systemd/system` exists, before it creates anything. That is
  `install.sh`'s own handling of a conflicting `/usr/local/bin/nerva` (NRV-E1103) and of units it does not own
  (NRV-E1105): a conflict stops the install and says what to do. A package would otherwise install and then
  never run, since the old binary and units win.
- **Tests.** An upgrade to the next patch version and a downgrade (same binary), checking the data, a settings
  file, the user and an enabled replica; the three other branches of `package-setup.sh` and both leftover
  cases; the exact message (code, headline, cause, fix) in every container, which an earlier pipe could not
  fail; `dpkg --verify` and `rpm -V` (the deb now has `md5sums`); a stand-in `systemctl` in the containers
  records what the scripts call.
- **Reproducibility test**: the second build changes the time zone, locale, umask, output directory and working
  directory. It does not change the file system or the tool versions, so it does not show that archive
  entries are sorted; the earlier claim is dropped.
- **Not changed.** The deb's `Maintainer` is `The Nerva authors <https://github.com/NervaLog/nerva>`, which
  Debian policy 5.6.2 does not accept (it wants an email address); the repository names no contact address,
  and inventing one is the owner's to decide (issue filed). `Requires(pre)` now names `coreutils` and
  `glibc-common`. Slice 6a's `docs/INSTALL.md` carries the commands for the unsigned rpm on Fedora
  (`dnf install ./nerva-<version>-1.<arch>.rpm`, or `rpm -U --nosignature`).
