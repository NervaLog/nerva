---
id: P445
date: 2026-11-14
area: Ops
---

# The fleet retries a commit whose build failed, after a bound

**Decision.** `run.sh` builds a commit in `state/broken` again after 7200 s since its last
start or failure, at most 3 times (four builds in all). `state/broken-tries` holds the commit, the
builds started and the time of the last start or failure; the attempt is recorded after the checkout
and before the build, so a failed checkout (NRV-E0731) costs no attempt and a build killed midway counts. A failed retry logs the existing "build FAILED" line and keeps its
own `build.log.<n>`; a new head removes the old retry logs. A malformed `SIM_FLEET_BROKEN_RETRIES`
or `SIM_FLEET_BROKEN_RETRY_SECONDS` is refused with NRV-E0740; a leading zero is read as decimal.

**Reason.** One transient failure (a network blip during the toolchain download) left the
candidate unsoaked for good (#289). A retry bounded in count and time cannot loop a broken commit
through hour-long builds forever.

**Cost.** A commit that really does not build costs four builds (up to four hours of build time
over about six hours) before it is left. Defaults are in `fleet.env.example`; an operator clears
the state by hand as the README says.
