---
id: P325
date: 2026-11-11
area: Releases
amends: P311, P291
---

# CI runs `mac-release` ad hoc, and the command is `zig build -Drelease mac-release`

**Decision.** (1) The `macos-arm64` job in `ci.yml` runs `./zig/zig build -Drelease mac-release
-Dsign-identity=-` (ad hoc, not notarized) on a local tag `v<VERSION>` that it makes on the runner
and never pushes, then checks the zip from outside: its `.sha256`, `lipo -archs` (`x86_64 arm64`),
`codesign -v` and `Signature=adhoc`, `nerva version`, `tests/macos/smoke.py`, and that
`nerva.rb` is produced (`test -f` only; `brew install` and `brew test` run in `mac-verify.yml` on
the published release). The hand-made `lipo` binary stays as the smoke test's subject, so a break in either path shows apart.
(2) Everywhere a document gave the owner's command, it now says `zig build -Drelease mac-release
-Dnotarize=true`: `build.zig` refuses `mac-release` without `-Drelease`. P311's commands above
(its release-day block) read the same way: use `-Drelease`. The brief (`docs/briefs/v0.7.1.md`),
`mac-verify.yml`'s header, `docs/INSTALL.md` and the CHANGELOG are corrected. (3) What P291 says CI
runs (`-` "is what CI runs", "CI's ad hoc run") and what the CHANGELOG's #278 entry says of
`mac-release` were not true until this change: they are true from it. What still runs only on the
owner's Mac is the Developer ID signature, the hardened runtime and the notarization.

**Reason.** Release review #315: `mac-release` had never been run by anything, and the first run
would have been the owner's on release day, with a command the step refuses.

**Cost.** About 20 seconds more on the macOS job, a second build of both thin binaries
(cached). `src/nerva/mac_release.zig` changes (#328: its paths were relative; the owner approved it in writing): release tooling that `build.zig` runs, not compiled into the `nerva` binary. `build.zig` does not change. The step writes `zig-out/mac-release` inside
the checkout (git ignores it); the output directory is fixed by `build.zig`, so it was not moved
outside.
