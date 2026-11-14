---
id: P445
date: 2026-11-14
area: Ops
---

# The fleet retries a commit whose build failed, after a bound

**Decision.** `run.sh` builds a commit in `state/broken` again after 7200 s since its last
failure, at most 3 times (four builds in all). The count is `state/broken-tries`. No new alarm or
error code: a failed retry logs the existing "build FAILED" line.

**Reason.** One transient failure (a network blip during the toolchain download) left the
candidate unsoaked for good (#289). A retry bounded in count and time cannot loop a broken commit
through hour-long builds forever.

**Cost.** A commit that really does not build costs four builds (up to four hours of build time
over about six hours) before it is left. Defaults are in `fleet.env.example`; an operator clears
the state by hand as the README says.
