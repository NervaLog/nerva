---
id: P415
date: 2026-11-13
area: Releases
amends: P259
---

# An unbundled `nerva` runs as one release; a bundle that exists and cannot be read is refused

Slice 2 of R6 opens `start` on a `MultiversionOS`, which reads the `.tb_mvb` and `.tb_mvh`
sections of the running binary. There is no packer yet (slice 3), so every binary built today,
and the first release of a cluster's life, has no such sections, and `open_sync` fails on them.

**Decision.** `start` reads its own executable first. With no multiversion sections it runs as
`single_release`, exactly as before this slice. With them it opens a `MultiversionOS` (`.native`),
and any `open_sync` failure is refused with `NRV-E0719`, never run as one release: a replica that
silently dropped to its own release would stay behind when the cluster upgrades.

**Reason.** Treating every `open_sync` error as E0719 would break `test:release`,
`test:integration` and `demo_r5`, which run unbundled binaries. Falling back on every error would
hide a damaged bundle.

**Cost.** One extra read of the whole executable at start, up to the native platform's `multiversion_binary_platform_size_max` (64 MiB; 128 MiB in a Debug build), and refused beyond it. A binary whose sections are
present but corrupt is told apart from an unbundled one only by `parse_elf`'s error.
The two new gauges (`replica_release`, `replica_releases_offered`) are emitted from
`command_start`, not `replica.zig`, to keep the vendored patch to the one call site (and clear of #412).
