---
id: P285
date: 2026-11-10
area: CI
amends: N68
---

# Pull requests type-check the release targets, and every compiling job caches Zig's build

**Decision.** On a pull request, the `release targets` job runs `zig build check -Dtarget=T` for
the four release targets instead of four `-Drelease` builds. A push to main (and release.yml's call
of ci.yml) still builds all four with `-Drelease`, after the type-check. Every job that compiles
Nerva restores `~/.cache/zig` and `.zig-cache` (key: job, OS, `zig/download.sh`, `build.zig`,
`src/**`, with older entries of the same job as fallback) and saves them only on a push to main.

**Reason.** The release builds took 15 minutes, the critical path. `check` builds the same
`nerva` executable from `src/nerva_main.zig` in Debug for the target, so it analyses the code the
release build reaches. With #277's fix reverted it fails for both macOS targets with
`diagnostic.zig:211: expected type '*[32]u32', found '*u32'`. Pull requests never save the cache,
so a fork's pull request cannot poison it.

**Cost.** Debug and ReleaseSafe differ in `comptime` branches on the mode, so an error reachable
only in ReleaseSafe is found on main, not on the pull request. Main's targets job is slightly
longer (the type-check runs first, to populate the cache). A pull request's first run after a
change to `build.zig` or `src/**` is only as warm as main's last save.
