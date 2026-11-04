---
id: P147i
date: 2026-11-04
area: "Milestone 3: positioned reads and the first views"
---

# The fleet's reporter is Python 3, standard library only

`ops/sim-fleet/sim_fleet.py` reads a round, fingerprints its failures and talks to GitHub's REST
API with `urllib` (no third-party package, no `gh`). Its tests (`test_sim_fleet.py`,
`unittest`, no network) cover the fingerprints, the dedup, the caps, the rate-limit hold and the
state file. `run.sh` runs the copy built with the commit under test, so a change to the reporter
reaches the host with the commit that makes it.

**Why.** Nerva's existing issue filing is Python (`perf/nightly/file_issue.py`, run in CI), as
are its tests of scripts (`.github/scripts/test_sbom.py`). Zigcube wrote its reporter in Zig
because its own code is Zig and its std HTTP client could do it; in Nerva the reporter would be
the first Zig code outside `src/` with TLS and JSON to a third party, built by the vendored build
graph, for a job of parsing text and making a few HTTPS requests. Python is about a third of the
size of Zigcube's reporter and is on every Ubuntu host.

**What it costs.** The host needs `python3` (Ubuntu 24.04 has 3.12). The reporter's checks are
its unit tests and its asserts, not TigerStyle review; its bounds are constants at the top of the
file. Python's `urllib` has no request deadline of its own beyond the socket timeout; `run.sh`'s
`timeout` is the deadline of a whole report.
