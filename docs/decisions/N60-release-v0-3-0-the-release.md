---
id: N60
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Release v0.3.0: the release string moves to `0.0.3`; clients from `0.0.2` are still accepted.

Maintained views (N52) changed what a commit does on every replica (5 timestamps per entry,
operations 132–134, trees 5–8) without moving the release string, so v0.2.0 and later binaries
both said `0.0.2` (#34). Owner's decision (N32, option (a) of #34): bump `release` to `0.0.3`
and reformat, as for N43. `release_client_min` stays `0.0.2`: the client protocol only gained
operations, and a v0.2.0 `nerva api` was measured committing and reading against a `0.0.3`
cluster. Measured on what the bump does and does not do:
- A `0.0.3` replica opening a `0.0.2` data file stops with `multiversion unsupported`: it looks
  for `0.0.2` among the releases bundled in its binary, and Nerva bundles only its own (N43).
- It does **not** keep releases apart on the wire. In a three-replica cluster with two v0.2.0
  replicas and one freshly formatted `0.0.3` replica, the `0.0.3` replica joined as a backup,
  was needed for quorum (and committed) once a v0.2.0 replica stopped, and panicked with
  `checkpoint diverged` at op 960, the first checkpoint. TigerBeetle expects a newer binary to
  run older releases' prepares with the older code it bundles; Nerva has no older code to run.
  N61 makes replicas ignore peers of another release, so a mixed cluster cannot diverge.
- The golden checksum of a formatted data file did not change: only the development release
  `0.0.1` writes a different superblock (N43).
v0.3.0's notes list #30–#33 as known issues; #38's fixes (#26–#29, #36) and N61 (#34) ship in
it.
