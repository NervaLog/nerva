---
id: N36
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# The seat demo: Python standard library, the seat map as a view, crashes that keep quorum.

- The demo server, supervisor and client are Python with no dependencies (`demo/`), so running
  the demo needs only the `nerva` binary and Python 3. The page is one HTML file with plain
  JavaScript. The API key stays in the server; visitors reach Nerva only through endpoints that
  validate what they send (seat ids, view names prefixed `v_`, at most 24 visitor views,
  bodies up to 16 KiB).
- The venue is a typed table (N34) and three declared views (N35). The seat map itself is a
  view (`group_by` section, row and number; `max(sold)`, `max(buyer)`), so rewinding is the
  same view read `as_of` the slider's op: the demo uses Nerva's feature, not a side channel.
- A purchase is a read at the version seen plus a write; a lost race answers 409. A commit is
  never retried by the client: a retry after a crash could report a seat that was won as lost.
  "Sold out" is judged by the view, because a purchase whose reply was lost to a crash still
  sold its seat.
- Crashes are SIGKILL. The supervisor refuses to stop a second replica while one is down, so
  the cluster keeps quorum and the demo never stalls; crashed processes restart after 20 s.
- Two view processes compute sales by section; the server reads view b as of the op view a
  answered at, so the page compares their hashes at exactly the same op.
- SIGTERM to the server stops the cluster (found when a stop left six processes behind).
- `tests/demo/seats_chaos.py` (`zig build test:demo`, in CI) crashes random processes for a
  minute while buyers and visitors buy. It was mutation-tested: purchases as blind writes
  (no read) sell seats twice, and the test fails.
