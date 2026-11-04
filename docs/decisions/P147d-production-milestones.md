---
id: P147d
date: 2026-11-04
area: Releases
---

# Production readiness is milestones R1 to R7; R1 to R5 gate the first client's money

The owner asked on 2026-11-04 for the fixes found in a production review to be milestoned in
Zigbox's style. `docs/PRODUCTION.md` sets them out, and each milestone ends in a demo that runs
in CI:

| Milestone | What |
| --- | --- |
| R1 · Proven | Jepsen nightly with keys, `retry` and gateway faults |
| R2 · Fleet | An always-on VOPR and fuzzer fleet |
| R3 · Measured | The real topology and its sizing |
| R4 · Gateway | No ambiguous 503, metrics, several gateways |
| R5 · Recover | A lost replica and a restore, with the cluster open |
| R6 · Upgrade | Rolling upgrades |
| R7 · Retention | Bounded growth |

**R1 to R5 gate** strangers' money on Nerva (Botpike/app P121b). R6 and R7 follow.

**Why.**
- **The engine already does what the money needs.** Conserved ledgers, commit keys and records
  beside the money are built.
- **The gaps found are operational:**
  - Jepsen never ran on keys or records;
  - about 300 VOPR seeds per push;
  - sizing measured on one host only;
  - #120;
  - a lost replica or an upgrade closes the cluster;
  - nothing is trimmed.

**Cost.** The roadmap's engine items (effect sinks, view snapshots, object storage) wait behind R1
to R5.
