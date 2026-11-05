---
id: N40
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Releases are cut by committing a new `VERSION`, not by pushing a tag.

The agents working on Nerva can push commits to `main` but not tags. `release.yml` now runs
when a push to `main` changes `VERSION` (or by hand): it checks the version is semver and not
already tagged (releasing twice fails), runs the full CI on that commit, builds the four
targets, and creates tag `v<VERSION>` on exactly that commit while publishing the release with
`SHA256SUMS`. A version with a suffix (`0.2.0-rc.1`) is a prerelease. Pushing a tag no longer
releases: one way in is simpler to reason about, and a tag created by a workflow could not
trigger another workflow anyway. `VERSION` names the release; the binary's release string stays
`0.0.1+<commit>` (N32). First release: `0.1.0`.
