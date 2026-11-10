---
id: P259d
date: 2026-11-10
area: Releases
---

# The packer is upstream's build_multiversion.zig if it needs only Zig, else a Zig packer of Nerva's own

Owner, 2026-11-10: `-Dbundle` packs with upstream's `build_multiversion.zig` brought back from the pinned commit unchanged if it needs nothing but Zig. Otherwise Nerva writes a small Zig packer under `src/nerva/` that writes the same header. Never a downloaded `llvm-objcopy`.

**Why.** `llvm-objcopy` would be a new dependency, which is a stop item (toolchain changes). Upstream's file keeps the vendored patch minimal.

**Cost.** If upstream's file needs more than Zig, Nerva owns and maintains a packer. If neither option works, the implementer stops and asks.
