---
id: N50
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Replicas export metrics with `--statsd` and spans with `--trace`.

Nightly performance tests and anyone running Nerva need the replica's timings, and the vendored
tracer already records them (request latency per operation, commit stages, compaction, lookups
and scans per tree, storage IO, cache hits) and emits them every 10 s. `nerva start` simply
gave it no output. Now:
- `--statsd=<host:port>` sends them over UDP in TigerBeetle's statsd format (port 8125 by
  default; a bare port means 127.0.0.1; IPv6 in brackets; port 0 refused). UDP never blocks
  the replica, and a lost packet loses one window of numbers, not correctness.
- `--trace=<path>` writes the JSON span trace (Perfetto, chrome://tracing). It writes each span
  as it happens, unbuffered, so it is for diagnosis, not for timed runs.
- No vendored file changed. Names keep the `tb.` prefix and TigerBeetle's tag spellings
  (`operation:Operation.commit`): renaming would patch the vendored tracer for no gain yet.
- `format`, `api` and `view` export nothing: `format` is brief, and the gateways are measured
  from outside (load tools see their latency directly).
- Not done here: the client's round-trip time is still reported as 0 by the vendored VSR client,
  so `client_request_round_trip` stays empty.
- `test:integration` starts replica 0 with `--statsd` (to a UDP socket the test binds) and
  replica 1 with `--trace`, then waits up to 15 s for request, commit and cache metrics and
  checks the trace holds commit spans. Mutation-tested: dropping either wiring fails it.
