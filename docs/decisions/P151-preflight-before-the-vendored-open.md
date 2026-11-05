---
id: P151
date: 2026-11-05
area: Releases
amends: P149
---

# Pre-flight reads the superblock with the vendored quorum code, before the vendored open

Taken while building R5's slice 2 (`docs/briefs/r5.md`).

- **`src/nerva/preflight.zig` checks a `start` before `IO.init` and `Storage.init`:** the path
  exists and is a file or block device (NRV-E0006, E0702), no other open file description holds
  its `flock` (E0703), its superblock has a quorum (E0702) written by this release (E0701), and,
  without `--development`, its file system accepts `O_DIRECT` (E0704). `format`, `start` and
  `import` also refuse a kernel below 5.11 (E0705) before they create any IO.
- **The superblock is judged by the vendored `superblock.Quorums.working(.open)` on the file's
  four copies, unmodified,** so pre-flight accepts exactly what the vendored open accepts and
  refuses with E0702 each error that open turns into a panic (`NotFound`, `QuorumLost`, `Fork` and
  the rest; the name goes in the message). The release judged is
  `vsr_state.checkpoint.release`, the one `release_transition` compares (#95), not
  `release_format`.
- **The lock is taken and dropped, retried five times 50 ms apart,** as the vendored open does,
  because `io_uring` can keep a killed process's file description alive for a moment. A lock taken
  between pre-flight and open still reaches the vendored panic.
- **Exit statuses:** E0704 and E0705 exit 2 (the environment); E0006, E0701, E0702, E0703 exit 1.
- **Linux only.** Elsewhere the vendored behaviour is unchanged.
- **The storage-limit text** (owner answer 3, P149) names NRV-E0707 and says Nerva has no flag to
  raise the limit; `--limit-storage` does not exist here. Statuses 4 and 5 are unchanged.

**What it costs:** a second read of four superblock copies and one `flock` per start; the vendored
panics remain for races; E0704 is covered by code review and E0705 by a unit test of the version
parse only, since a test host has direct IO and a new kernel.
