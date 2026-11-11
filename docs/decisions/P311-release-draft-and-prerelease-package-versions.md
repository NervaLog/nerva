---
id: P311
date: 2026-11-11
area: Releases
amends: P284b
---

# The release is a draft; a prerelease's packages use `~`; the refusals have codes

**Decision.** (1) `release.yml` creates a draft (P284b step 5). A draft has no tag, so the
"already released" check lists the repository's releases and refuses a release or draft of the tag as
well as the tag itself; listing a draft needs `contents: write` on the `version` job, which only reads.
The check runs again, in the `release` job, immediately before `gh release create`: "Re-run failed
jobs" re-runs only the failed job and reuses the `version` job's result, so a second run would
otherwise make a second draft. It fails closed: any error from GitHub other than a 404 for the tag
stops the run. (2) A version with a suffix (`0.7.1-rc.1`) is packaged as `0.7.1~rc.1`, which `dpkg`
and `rpm` both sort before `0.7.1`; `build-deb.sh` and `build-rpm.sh` accept `N.N.N~suffix`. The
**file names** have `.` for the `~` (`nerva_0.7.1.rc.1-1_amd64.deb`, `nerva-0.7.1.rc.1-1.x86_64.rpm`),
because GitHub renames an asset whose name has a character other than alphanumerics, `-`, `_` and
`.`; the version inside the package, which `dpkg` and `rpm` read from the control data and the
header, keeps the `~`. `SHA256SUMS` and NRV-E1115 use the file names. A release's names are
unchanged. (3) The release's own refusals (a `version` line that is not `VERSION`, a binary
without `commit_keys deduplicate`, an existing tag or draft, a draft whose assets are not the built
files, a release dispatched from a ref other than `main`) are NRV-E1112 to NRV-E1116, printed by
`.github/scripts/release_check.sh`. A version without a suffix is cut only from `main` (P147b); a
prerelease may be dispatched from a branch, which is how the draft's mechanics are tested. (4)
`nerva version --verbose` ends with `commit_keys deduplicate` (or `off`), the line (3) reads; it is
verbose-only so that `version`'s first lines are unchanged. `SHA256SUMS` lists tarballs, packages and
the bill of materials, never the Mac zip. (5) `mac-verify.yml` ties the zip to the release: `nerva
version`'s first line must hold `+<first 7 of the commit the release or draft targets>` and its last
line must be `version <VERSION>`; the zip must hold `nerva`, `LICENSE` and `NOTICE`; the signature
must carry a secure timestamp. The token is given to the download step only. On a draft the `brew`
step is skipped with a notice (the owner commits the formula after publishing), so that a green
dispatch on the draft means checksum, binary, signature and smoke passed; the run on the
`release` event does `brew`. (6) The other three targets' binaries cannot run on the runner (no
`qemu-user`); `release.yml` checks that each holds the version string (`strings`), and the x86_64
binary is the one run.

**The owner's Mac step (brief, step 6).** A draft has no tag, and `mac-release` refuses unless
`git tag --points-at HEAD` lists `v<VERSION>`. So, before `mac-release`, the owner makes the tag
locally at the draft's target commit, which `gh release view v0.7.1 --json targetCommitish` shows:

```
git fetch origin && git checkout --detach <targetCommitish>
git tag v0.7.1 <targetCommitish>          # local only: never pushed; publishing the draft creates the tag
./zig/download.sh && ./zig/zig build mac-release -Dnotarize=true
```

then uploads the zip and its `.sha256`, dispatches `mac-verify.yml` with the tag (green before
publishing: it checks the commit, the signature and the smoke test), publishes, and commits the
formula. `mac-verify.yml` fails a zip built from any other commit.

**Reason.** The owner uploads the Mac zip after `release.yml` ends, so the release cannot be public
yet. A `+` suffix would sort a prerelease after its release. The refusals need a stable name to be
found in the log.

**Cost.** The package file names of a prerelease differ from the package versions inside them. The
`version` job holds write access to contents, and `mac-verify.yml` too (listing a draft needs it; no
step but the download has the token). The aarch64 and macOS binaries are not run on the runner.
