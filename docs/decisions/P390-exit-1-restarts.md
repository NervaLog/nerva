---
id: P390
date: 2026-11-13
area: Releases
---

# QUICKSTART was wrong about exit 1; the unit restarts it (P339 item 4)

**Decision.** `nerva@.service` keeps `RestartPreventExitStatus=2 3 4 5 6 7 8 70`. Exit 1 restarts,
bounded by `StartLimitBurst=20` in 300 s, as P339 item 4 decided. QUICKSTART is corrected to say so (#385).

**Reason.** Exit 1 covers a lock the dead process still held (NRV-E0703) and a collector with no
route at boot (NRV-E0010), which a restart cures; the unit's comments and `test_restart_policy`
already state this. The other statuses (disk, data file limits, bugs, origin mismatch) are not
cured by a restart.

**Cost.** A permanent exit 1 (a bad flag) retries about 100 s before the unit stays `failed`.
