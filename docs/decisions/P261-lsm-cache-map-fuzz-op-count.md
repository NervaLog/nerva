---
id: P261
date: 2026-11-10
area: Testing
---

# The lsm_cache_map fuzzer draws at most 1E7 ops, mean 1E6

**Decision.** `src/lsm/cache_map_fuzz.zig` draws its op count from an exponential of mean 1E6,
capped at 1E7 (or `events_max`), like `lsm_tree` and `manifest_log`. It was mean 1E8, cap 1E9.

**Reason.** The ops are one array allocated before the run, so memory is proportional to the draw.
A draw of 458M ops took about 9 GiB and the fleet's runners failed with `OutOfMemory` (#252).

**Cost.** The fuzzer no longer reaches more than 1E7 ops in one run. Longer coverage comes from
more seeds, not one huge one. This is a vendored patch (UPSTREAM.md).
