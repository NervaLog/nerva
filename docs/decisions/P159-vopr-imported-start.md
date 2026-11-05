---
id: P159
date: 2026-11-05
area: Releases
---

# The VOPR starts about half of its `nerva` seeds at an imported checkpoint

**Decision.**
- **The draw.** The `nerva` lane draws, per seed and with its own salted PRNG (`vopr_start.drawn`), whether the cluster starts imported. No other draw of a seed moves.
- **The export.** When it does, one deterministic export is built from the seed in memory (`src/nerva/vopr_start.zig`): version 1 or 2, `as_of` between 1 and the third checkpoint, no rows.
- **The import.** `import.zig`'s importer restores it into every replica's simulated storage after the format, with storage faults off. The cluster asserts that every replica holds the same checkpoint.
- **The checker and the origin.** The state checker starts at that checkpoint (`start_at`), and every replica's origin is the export's identity.
- **The summary line.** The end-of-run summary says `imported start=<bool> checkpoint=<op> reformats=<n>`.

**Why.** Production clusters start imported (P90), and reformats had never run on one in the simulator. Owner question 5 of the R5 brief asked for this (P149).

**Cost.**
- The export carries no changes, views or ledgers, because the workload's model starts empty. Workloads over imported rows are not covered.
- Three vendored files carry the patch, recorded in `UPSTREAM.md`: `Options.import` in `src/testing/cluster.zig`, `start_at` in `src/testing/cluster/state_checker.zig`, and the lane draw in `src/vopr.zig`.
