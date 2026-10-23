---
id: P143
date: 2026-10-23
area: "Milestone 3: positioned reads and the first views"
amends: N45
---

# `nerva api` answers the commits and lookups that are waiting together with one cluster request

The gateway read up to 16 connections at once (N45) but ran one request at a time over one cluster
session, and every request was one cluster request: one log op, about 0.7 ms whatever it carries.
After P135 a Botpike submit is 2 log ops (a `lookup_rows`, then a `commit`) and one gateway did
about 510 to 580 submits a second at 1 to 12 callers, flat: the gateway was the limit (#134).

- **Decision.** When the gateway is about to run a `POST /v1/commit` or `POST /v1/lookup` it also
  takes every other *complete* request already waiting in the `Receiver` for the same route (never
  waiting for more, so nothing is delayed), with an accepted key and a body of at most 16 KiB, at
  most 16 in all, and answers them with one multi-batch cluster request: one batch, one transaction,
  per HTTP request. `commit` and `commit_wide` are combined by the operation the first of them
  needs; a lookup of rows is combined (its probes, P135, included in its batch); a lookup of
  records, a member of the other operation, or one that does not fit the request with the others
  (the batch size limit, `event_max`, the replies in one message: the replicas' `input_valid`)
  runs alone. Every other route stays serial. No wire, on-disk or `Operation` change: a multi-batch
  request is the client protocol already (the client sent one batch until now, and the state machine
  executes and admits every batch of a request on its own, `views_busy` existing for this case).
- **Each member answers as it would alone.** Parsing, layouts and every refusal (the 400s) happen
  before anything is sent. A request refused under a kept layout is looked at again with every
  layout read from the log, as for a single request (P135), and a request that is refused is
  answered at once and never sent. The state machine judges each transaction in order against the
  rows the earlier ones in the op wrote, as it judges transactions of separate ops, so `conflict`,
  `out_of_bounds`, `row_absent` and the rest are the member's own. Replies carry the op the
  member's transaction committed at, which is the one op of the request.
- **`views_busy` never reaches the caller.** A transaction refused `views_busy` was refused only
  because earlier transactions of the same op filled the op's views budget. It is sent again on its
  own, once: alone it commits or is `views_too_large`, as today. At most one re-send per member, so
  at most 15 per request.
- **Commit keys (P123)** are per transaction: two requests under one key in one op answer
  `committed` then `committed_before` (with the first's op), and other entries under the key
  `key_reused`, `key_collision` as in sequence (state machine test, API tests).
- **Layouts (P135).** Each member has its own layouts for the request. Its probes go in its own
  batch and it compares them with the versions it kept, so a layout another member's retry
  refreshed is detected, not assumed.
- **Failure.** A timeout, a lost session or an eviction anywhere in the group fails every member
  that has no answer yet with 503, and breaks the client and clears the kept layouts, as for one
  request. Whether the transactions of the lost request committed is not known, as for one request:
  a caller (Botpike's `NervaLedger`, P99) resolves a lost answer by reading under the key (P123),
  and a retry under the same key answers `committed_before` if it did.
- **Connections (N45, #28).** A group is gathered by `Receiver.take`, which reads and accepts what
  is already there without waiting and never displaces a connection (with every slot taken, a
  waiting connection waits in the backlog). Answering a group frees its slots at once, so the
  table refills with connections whose clients have connected but not yet sent, and #28's rule,
  which displaces the oldest connection still sending its request for a waiting one, then cut
  off clients that were about to send (the fifty-thread reservation test failed in 5 of 8 runs).
  A connection is now displaced only when it is 50 ms old (`displace_grace_ns`); the wait ends
  then. A flood of idle connections still cannot lock clients out, it delays one by at most 50 ms.
- **Memory (N69).** A member's body is at most 16 KiB, so the 16 of a group take at most ~50 MiB
  parsed (a parsed body costs up to ~200 times its size), inside the one request's 128 MiB; the
  group's arena is given back when the last reply is written.
- **Measured** (`bench:load --local --workload=botpike`, release, 20 s, 3 `--development` replicas
  and one gateway on 4 CPUs; two passes before, two after; submits per second, p50, p99): 1 caller
  280 to 307 before, 287 to 344 after; 4 callers 335 to 373 (11 ms, 27 to 30 ms) before, 654 to 717
  (5.1 to 5.6 ms, 20 ms) after; 12 callers 326 to 356 (33 to 35 ms, 70 to 78 ms) before, 1,360 to
  1,451 (7.4 to 7.9 ms, 28 to 31 ms) after; 24 callers 344 to 374 (61 to 70 ms, 119 to 123 ms)
  before, 1,706 to 1,725 (12 to 13 ms, 41 ms) after. The direct-client workloads (`c1`, `c4` at 1
  and 4 clients) do not go through the gateway and did not move beyond drift.
- **Considered and rejected.** More sessions (the primary's per-tick commit stall, P136, applies
  to a second prepare in flight); waiting to gather more (adds latency to every request); combining
  `changes`, `history`, `row` and the views (they render fields or page and are not the hot path).

Cost: a request that waits behind others now shares their op and, after a `views_busy`, can commit
after them; the replies of a group are written one after another, so a slow reader delays those
after it by up to the reply deadline (N45's known limit, unchanged). A group's requests lose the
op order of their arrival only inside the op. A `views_busy` re-send costs one more op.
