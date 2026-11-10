---
id: P293
date: 2026-11-10
area: CI
---

# The arm64 Mac job builds both macOS targets once; the Intel job only runs them

**Decision.** `macos-arm64` cross-compiles `aarch64-macos` and `x86_64-macos` with `-Drelease`,
joins them with `lipo`, signs only the universal binary ad hoc, smoke-tests the arm64 thin and
the universal binary, runs `test:unit`, and uploads the three binaries. `macos-x86_64` (an Intel
runner) downloads them and runs the smoke test on the x86_64 thin binary, unsigned as
release.yml ships it, and on the universal one. Until `zig build -Drelease mac-release` (#291) is
used (slice 7), the job makes the universal binary with its own `lipo`.

**Departs from the brief.** docs/briefs/v0.7.1.md, slice 2, item 1 says the job "takes the
`targets` job's release binaries as an artifact". It does not: `targets` type-checks on pull
requests and builds nothing, and making it build and upload four ReleaseSafe binaries would put
about 16 minutes on that job. The brief's instruction is replaced by the `macos-arm64` artifact,
so the supervisor should accept this knowingly.

**Reason.** Zig cross-compiles, so one fast runner builds both targets and the Intel runner,
the slow one, builds nothing. Each architecture still runs its own binary natively.

**Cost.** The binaries run here are built on macOS, not by release.yml on Ubuntu, so the smoke
test does not run the shipped assets byte for byte (slice 7's verify does). The pull request's
critical path is the arm64 job plus the Intel smoke test.
