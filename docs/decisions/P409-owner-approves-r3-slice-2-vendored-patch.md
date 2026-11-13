---
id: P409
date: 2026-11-13
area: Testing
amends: P406d
---

# The owner approves R3 slice 2's patch to `src/nerva_main.zig`

**Decision.** The owner approved (2026-11-13, in the supervising session) the vendored patch that
R3's brief (`docs/briefs/r3.md`, "The vendored patch") names for slice 2: `command_start` in
`src/nerva_main.zig` reads the budget from `src/nerva/start_memory.zig`, wraps the base allocator
in a one-shot `MemoryBudget` under the `CountingAllocator`, and reports an allocation it refuses
as NRV-E0723. Nothing else in the file changes, and slice 2 extends that file's `UPSTREAM.md` row
with the sentence the brief quotes, in the same commit. The approval covers that patch only; any
other change to a vendored file, including slice 5's `build.zig` step, still needs its own.

**Why.** CLAUDE.md's stop item 2 lets a vendored file change only when the task names the patch;
the v0.7.1 patches to this file (P284b, #271) also carried the owner's approval, and this one now
does too, so slice 2 starts without a stop.

**Cost.** One more local patch to keep when TigerBeetle's `main.zig` is next brought in. Slice 2
still merges only after the v0.7.1 tag (`src/` is frozen until then).
