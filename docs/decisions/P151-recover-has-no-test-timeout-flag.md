---
id: P151
date: 2026-11-05
area: Releases
---

# `nerva recover` has no test-only timeout flag, and refuses `--addresses=0`

**Decision.** `recover` waits at most 60 s for the cluster (`recover_timeout`), and there is no flag that
shortens this. Its test reaches the timeout for real by stopping the other replicas with SIGSTOP. Those
replicas still accept TCP connections but never answer, so the test waits about 60 s.

`recover --addresses=0` is refused with NRV-E0002, because recovering needs the running cluster's
addresses. A failure to create `<path>.recovering`, such as a full disk, is reported through the shared
file failure (NRV-E0706) rather than a recover-specific code.

**Why.** The brief suggested a `--timeout-test-ms` flag. A shipped binary cannot tell whether it is
running in a test, since `release.testing()` is false for it, so such a flag would be live in
production. A real wait costs a minute of test time, and nothing ships that operators could misuse.

**Cost.**
- `tests/recover/recover.py` takes about a minute longer.
- No test yet triggers NRV-E0716, a recovering replica evicted by the cluster: the vsr client's
  eviction callback is wired to it, but nothing exercises it.
