---
id: N82
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# A Jepsen suite tests real processes through `nerva api`; it runs on Fly, nightly.

The VOPR simulates replicas, not processes: Jepsen's TigerBeetle report (2025) found its bugs
outside the simulator (client code, real processes, latency, upgrades, generators too
regular), and Nerva's gateway, which Botpike's app will talk to, is not simulated at all. So
`tests/jepsen/` is a [Jepsen](https://jepsen.io) suite (Clojure, Jepsen 0.3.14), the owner's
choice over a separate repository.
- **Model from the docs, not the code.** Each workload checks a promise the README or a
  decision makes, so the suite does not share the implementation's assumptions.
- **Five nodes, one replica and one gateway each**, as Docker containers on one machine
  (`run.sh`); clients talk JSON over HTTP to every gateway. `200` applied; `409`, or a
  connection never made, applied nothing; any other missing reply, or `503`, is unknown
  (`:info`) for a write and a failure for a read; `400` is a bug in the test.
- **First workload, `bank`:** a declared ledger's conservation (N75) under Jepsen's bank
  checker, plus a sum view that must always answer the funded total, a source that must not
  move, and transfers refused only as `out_of_bounds`. Faults: kill, pause (replica only) and
  partition, from Jepsen's combined packages, composed one by one because
  `combined/nemesis-package` installs every package's tools (it downloads a bit-flipper with
  `wget`) whether its fault is on or not.
- **Planned, in order:** `retry`, `claim`, `register` (Elle), then `feed`, LazyFS and bit
  flips, a nightly workflow that files issues; then clock faults on separate machines (`nerva`
  is static, so libfaketime cannot move its clock, and containers share one), and upgrades.
- **Where it runs (assumed until the workflow lands):** nightly on one Fly runner (they run
  Docker as root), not on the Hetzner fuzzing fleet: a few hours a night bills by the second.
- **Not replayable.** A run has no seed; a failure is reproduced as a VOPR seed or unit test
  before it is fixed, so it stays covered.
