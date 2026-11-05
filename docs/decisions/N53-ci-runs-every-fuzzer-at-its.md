---
id: N53
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# CI runs every fuzzer at its smoke size.

`ci.yml`'s `test` job runs `zig build fuzz -- smoke` after the unit tests: every vendored fuzzer
and Nerva's own (N46), each at a fixed seed and a size chosen to stay within its smoke budget.
#6 went unnoticed because nothing ran the fuzzers; now a fuzzer that stops working fails CI. It
was held back while CI moved to Botpike's own runners (N47). The fixed seed makes smoke a
regression check, not a search: finding new bugs takes many seeds, which is a scheduled job's
work, not every pull request's. `lsm_segmented_array` logs "too slow for the smoke mode" in a
Debug build (about 20 s against its 10 s budget); that is a warning, not a failure.
