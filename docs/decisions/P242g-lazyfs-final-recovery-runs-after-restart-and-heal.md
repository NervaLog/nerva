---
id: P242g
date: 2026-11-09
area: Releases
amends: P242c
---

# The final `lazyfs-recover` is listed after `db-package` and `partition-package`

The decision: in `nemesis-package`, `lazyfs/package` comes after `combined/db-package` and
`combined/partition-package` (and after `heal-package`), before `nemesis/package`.

The reason: final generators run in list order. The final `lazyfs-recover` is judged (NRV-E0604).
Listed first, it ran before `kill`'s restart and before the partition heal, so a `kill :all` or a
majority partition at the time limit left it no quorum and the run failed on a correct cluster. The
review of #242 (MUST 4) found it. It was left until the keyed bank (#239) merged, as both edit
`core.clj` (P250).

What it costs: the final gateway start in `nemesis/package` still follows it, so the recovery's
settle and that start both judge gateways; the double check is cheap. P242c's statement that
`lazyfs/package` is listed before `db-package` no longer holds.
