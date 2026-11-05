---
id: P157
date: 2026-11-05
area: Releases
amends: P149g
---

# NRV-E0711 names the recover fix, and the VOPR reports reformats with origins

**Decision.** When a replica refuses a peer of another export, its `origin_mismatch` exit prints
`NRV-E0711:` right after the log prefix and offers `nerva recover --origin=<the export's SHA-256>` as
the fix. The exit status stays 8, and the rest of the vendored message is unchanged.

The VOPR's end-of-run summary prints `reformats=<n> origin=none|non-zero`, so a run shows whether it
exercised a reformat on a cluster with an origin. About 1 seed in 80 does; this PR names 20.

**Why.** This is the one vendored runtime exit an operator causes directly, by passing the wrong
`--origin` to `recover`, so it gets its code and its fix. The summary line is how slice 4, and
later slice 5, show that the seeds exercise reformats on imported clusters, not just that they pass.

**Cost.** One more patched message in `src/vsr/replica.zig` and one log line in `src/vopr.zig`,
both recorded in `UPSTREAM.md`.
