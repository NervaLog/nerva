---
id: P235
date: 2026-11-06
area: Releases
amends: P215c
---

# The Jepsen reporter is tooling: no NRV codes, its own GitHub client, the fleet stopped by the unit

The decision, for `ops/jepsen/` (R1 slice 6):

- **No `NRV-` codes.** `jepsen_report.py` is operator tooling like `sim_fleet.py` (P147i); it
  prints `jepsen: ...` lines to the journal and exits 0 (done), 1 (refused input) or 2
  (environment or GitHub). The registry is for failures a client or `nerva` itself shows.
- **A GitHub client of its own**, duplicated from `sim_fleet.py` (no redirects, token from a
  file, never printed). The two reporters have different state and fingerprints; a shared
  module would couple two hosts' deploys.
- **The unit stops and starts the fleet** (`ExecStartPre=+` and `ExecStopPost=+`), not the
  script, so a killed script or a deadline still brings the fleet back.
- **Host failures are never issues,** and a host failure does not hide a finding: `failure`
  outranks `error`. Exit 124, 125, 126, 137, a run with no `results.edn`, and a verdict naming
  no failing checker (graphs that did not draw) are the host's. A night with no `runs` file
  and no `host-failure` is read from the test directories.
- **The canary** (`--expect-invalid`) uses the context `jepsen/canary` and its own
  fingerprints; it is `success` only if every finished run is invalid with a `duplicate`.
- **`nightly.sh` runs a private copy of itself,** because it moves its own checkout to the tip.

Cost: two GitHub clients to keep alike; a stop of the fleet loses its round in flight.
