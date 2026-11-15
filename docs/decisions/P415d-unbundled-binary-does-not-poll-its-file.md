---
id: P415d
date: 2026-11-14
area: Releases
amends: P415
---

# A replica running an unbundled binary needs a restart to move to a new release

**Decision.** P415's unbundled `nerva` never opens `MultiversionOS`, so it never calls
`timeout_start`, does not notice that its file on disk was replaced, and keeps advertising its own
release (and `replica_releases_offered` stays at it). Replacing the binary on every host without a
restart (the brief's risk 3) therefore upgrades a cluster only from the first bundled release on.
For a cluster whose replicas run the first R6 release as an unbundled binary, the upgrade is a
restart of each replica into the new binary, which re-executes from it as the demo does.

**Reason.** Polling needs `MultiversionOS.open_sync`, which needs the `.tb_mvb` and `.tb_mvh`
sections; an unbundled binary has none, and there is no packer until slice 3. Faking the open
would run upstream's code on data it was not written for.

**Cost.** One operational step the README's "Upgrading a cluster" must name. Slice 3 may remove
it by having its packer always write a header, even with no past release, so that the first
release is "bundled with nothing" and polls; that is its decision and is not taken here.

**Also.** `start` opens the bundle on every build, `cluster 0` test builds included, not only
release builds (the brief kept `.single_release` for those). It is harmless while no packer
exists, and a test build with a bundle then exercises the same path as a release.
