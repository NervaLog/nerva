---
id: P368
date: 2026-11-12
area: Releases
---

# `package_repos.sh`: what slice 2 fixes that the spec leaves open

**Decision.** Slice 2 of `docs/releases/packages.md` (`.github/scripts/package_repos.sh`,
`repo_install_check.sh`) takes these choices:

- **The commit in an entry is `GITHUB_SHA`.** `ready` records the commit `publish-ready` checked; it
  must be 40 hex digits (NRV-E1139 otherwise). `publish` never reads a branch head for it.
- **`MAC_ATTEMPT` against `GITHUB_RUN_ATTEMPT`.** `ready` refuses (NRV-E1153) unless the attempt that
  approved the `mac` job is the attempt it runs in, so a re-run cannot bind a draft the approval did
  not see.
- **Dual signing goes through `gpg-preset-passphrase`.** During a rotation both secret keys sign
  every index. Each passphrase is preset into a throwaway agent (`allow-preset-passphrase`,
  `allow-loopback-pinentry`) under a short `GNUPGHOME`; no passphrase is in an argument or a log.
- **An extra subcommand, `verify-manifest <file> <generation>`.** It verifies one manifest object
  exactly as `ready`, `publish` and `served` do (same parser, same pinned keys), so the tests and
  `served` share one checker.
- **Test-only overrides:** `PACKAGE_KEYS_DIR`, `R2_PY`, `PACKAGE_REPOS_FREE_KIB` and
  `PACKAGE_REPOS_KILL_AT`. The script refuses (NRV-E1139) any of them when `GITHUB_ACTIONS` is set,
  so a release run cannot take another key directory, another `r2.py`, a fake disk size or a kill
  point; the tests run with a clean environment that omits `GITHUB_ACTIONS`.
- **NRV-E1155 is deferred, not raised at once.** A GitHub error on one pending entry is recorded
  with `defer`; the run finishes the other entries and the indexes, then ends red. The entry stays
  `pending`.
- **Staged packages get mtime `@0`** (`touch -d @0`) before `createrepo_c` and `apt-ftparchive`, which
  record file times: the same packages then give the same `repodata` file names, so a second run
  writes the same objects and the idempotence table holds.
- **`Valid-Until` comes from `ValidTime=1814400`.** The spec says 21 days after `Date`;
  `apt-ftparchive` takes that as seconds (21 x 86400) in `APT::FTPArchive::Release::ValidTime` and
  writes the header itself, so the script does not edit `Release` after the tool.
- **Tests name noarch rpms by architecture.** `rpmbuild` cannot cross-build the aarch64 package on an
  x86_64 host, so the test packages are noarch rpms whose file names say `x86_64` and `aarch64`.

**Reason.** Each is the option closest to the spec's text and to `r2.py` (P367), and each keeps
secrets out of arguments and the run repeatable.

**Cost.** One more subcommand to keep in step with the manifest format; the override guard depends on
`GITHUB_ACTIONS` being set on every runner (it is); noarch test rpms do not exercise per-architecture
rpm headers, which the container cells in `tests/packaging/repos.py` cover on CI.
