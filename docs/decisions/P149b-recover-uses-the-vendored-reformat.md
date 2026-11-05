---
id: P149b
date: 2026-11-05
area: Releases
---

# `nerva recover` drives the vendored replica reformat unchanged

`nerva recover` runs the vendored `ReplicaReformatType` with the real message bus and storage, so
the code the VOPR checks is the code that runs. It writes `<path>.recovering` and gives it its
final name only once formatting is done, as import does (N81).

**Why:** a second recovery path would be untested by the simulator.

**What it costs:** recover inherits the vendored code's limits. `done()` refers to a field that
does not exist and is never called; the brief's slice 3 uses `pending()` and `format()` instead.
