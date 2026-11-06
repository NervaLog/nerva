---
id: P215c
date: 2026-11-06
area: Releases
amends: N82
---

# A Jepsen failure's seed is Jepsen's `--seed`, its history is bounded, and runs still do not replay

The decision: every run passes `--seed` (Jepsen 0.3.14), drawn fresh each night and printed
first. An issue for a failure carries that seed, the commit, the exact command, the checker's
verdict, and the history as the anomalous operations with 50 operations of context on each side,
at most 48 KiB; the whole `store/` stays on the host for 90 days and the issue names its path.
Issues are deduplicated by fingerprint (workload, checker key, anomaly class), never by seed or
commit. N82's rule stands: a run does not replay, and a failure is reproduced as a VOPR seed or a
unit test before it is fixed. The suite's and the reporter's own messages are test tooling, as
the fleet's reporter is (P147i), not `docs/ERRORS.md` entries.

The reason: PRODUCTION.md's R1 asks for "the seed, the history and the commit" in each issue.
Jepsen's `--seed` steers its generators but not real process timing, so it narrows a failure
without reproducing it; calling it a replay would promise what N82 says Jepsen cannot give. A
full history can be many megabytes, beyond what an issue holds.

What it costs: a failure needs a person with access to the host for anything outside the 48 KiB
excerpt, and pinning it down still costs a VOPR seed or a unit test.
