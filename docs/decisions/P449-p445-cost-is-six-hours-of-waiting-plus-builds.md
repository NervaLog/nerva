---
id: P449
date: 2026-11-14
area: Ops
amends: P445
---

# P445's cost line: at least six hours of waiting, plus four builds

**Decision.** P445's **Cost** paragraph reads "four builds (up to four hours of build time over
about six hours)". That is wrong in both numbers. The retry waits `SIM_FLEET_BROKEN_RETRY_SECONDS`
(7200 s) since the last start or failure before each of its 3 retries, so a commit that never
builds waits at least 3 x 2 h = 6 h, and the four builds run on top of that wait, each for as long as
a build takes. The 6 h is the floor, not the total.

**Reason.** The review of #445 found the cost line too short; the decision text itself is not
edited once merged.

**Cost.** None: this changes no behaviour, only what P445 says the bound costs. Defaults and the
bound (3 retries, 7200 s) are unchanged.
