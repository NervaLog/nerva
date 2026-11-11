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
(2) A version with a suffix (`0.7.1-rc.1`) is packaged as `0.7.1~rc.1`, which `dpkg` and `rpm` both
sort before `0.7.1`; `build-deb.sh` and `build-rpm.sh` accept `N.N.N~suffix`. (3) The release's own
refusals (a `version` line that is not `VERSION`, a binary without `commit_keys deduplicate`, an
existing tag or draft, a draft whose assets are not the built files) are NRV-E1112 to NRV-E1115,
printed by `.github/scripts/release_check.sh`. (4) `nerva version --verbose` ends with
`commit_keys deduplicate` (or `off`), the line (3) reads; it is verbose-only so that `version`'s first
lines are unchanged. `SHA256SUMS` lists tarballs, packages and the bill of materials, never the Mac zip.

**Reason.** The owner uploads the Mac zip after `release.yml` ends, so the release cannot be public
yet. A `+` suffix would sort a prerelease after its release. The refusals need a stable name to be
found in the log.

**Cost.** `~` is not certain to survive GitHub's asset renaming: NRV-E1115 catches it on the first
prerelease run, and then the packages' names for prereleases change. The `version` job holds write
access to contents.
