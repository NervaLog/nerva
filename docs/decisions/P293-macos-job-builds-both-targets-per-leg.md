---
id: P293
date: 2026-11-10
area: CI
---

# The `macos` job builds both targets on each runner and runs ad hoc

**Decision.** Each leg of the `macos` matrix (`macos-15`, `macos-15-intel`) cross-compiles
`aarch64-macos` and `x86_64-macos` with `-Drelease`, joins them with `lipo`, signs ad hoc, and runs
the smoke test on its own architecture's thin binary and on the universal one. It does not take
the `targets` job's binaries as an artifact, and until `zig build mac-release` (#291) is on main
it makes the universal binary itself.

**Reason.** `targets` type-checks on pull requests and builds nothing; making it build and upload
four ReleaseSafe binaries on every pull request would cost about 16 minutes of its job. Zig
cross-compiles, so the Mac legs do the two builds they need, and stay independent of one another.

**Cost.** Each Mac leg builds both targets (cached on main). The lipo and ad hoc `codesign` steps
duplicate what `mac-release` will do and are replaced by it.
