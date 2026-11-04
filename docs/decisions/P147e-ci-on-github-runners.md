---
id: P147e
date: 2026-11-04
area: Releases
supersedes: N57, N59
---

# Every workflow runs on GitHub's hosted runners, not Botpike's Fly runners

The owner made the repository's organisation public on 2026-11-04 and agreed to move CI to
GitHub's runners. Every job in `ci.yml`, `fuzz.yml`, `release.yml`, `perf-nightly.yml` and
`pages.yml` now `runs-on: ubuntu-24.04`. For a public repository that is 4 vCPU and 16 GB, free.

- **The toolchain** comes from Actions' cache, keyed by `zig/download.sh`'s hash, where
  `INSTALL_ZIG` already looked for it. A miss downloads it, as before.
- **The nightly perf run** still measures on a dedicated Fly Machine (`fly-run.sh`). Only its
  controller job moved.
- **`free_disk.sh`** stays (N65). On a fresh runner it finds enough room and only logs.
- **The long fuzzing** (`fuzz.yml`) no longer needs runners started by hand (N59). The always-on
  search is R2's fleet.

**Why.**
- **A public repository must not use self-hosted runners.** A pull request from a fork would run
  its code on them, with whatever they can reach.
- **The memory is enough for Jepsen.** GitHub's 16 GB hosted runner can hold the Jepsen suite,
  which ran out of memory on the 8 GB Fly runners (#107).
- **Each run starts clean,** so jobs no longer share a volume (#101).

**Cost.**
- Every job builds without Zig's global build cache, which the Fly volumes kept. Only the
  toolchain is cached, so builds start cold.
- Jobs are bound by GitHub's concurrent-job limit and 6-hour job limit.
