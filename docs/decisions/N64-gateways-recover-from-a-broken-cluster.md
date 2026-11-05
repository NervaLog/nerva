---
id: N64
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Gateways recover from a broken cluster client on their own; a late reply is dropped.

Two follow-ups to N58 (#27), found after v0.3.0:
- **#42: a reply after the timeout panicked the client.** `Client.on_reply` asserted the
  client was waiting. After a request times out, `deinit` (and so `reconnect`) still drives IO
  while it closes the connections, and the reply to the abandoned request can arrive then.
  `on_reply` now drops a reply in `timed_out`; any other state is asserted as before. Since N58
  this could abort `nerva api` too, when the cluster was slow rather than down.
- **#42: `nerva view` exited on one timeout.** It now keeps a `ClientHealth`, as `nerva api`
  does: a request or feed read that times out (or an eviction) breaks the client; requests
  answer 503 and `/healthz` 503 until it is replaced; then the follower reads the feed on from
  its cursor, which a failed read leaves unchanged (`get_changes` is read before anything is
  applied). The view keeps everything it had built, so nothing is rebuilt. A timeout during the
  rebuild at startup still exits: the process has served nothing yet, and its supervisor
  restarts it.
- **#44: `/healthz` stayed 503 until a request arrived.** The client was replaced only inside a
  request for the cluster, so a gateway taken out of rotation by a load balancer never got the
  request that would bring it back. While the client is broken, both gateways now wake at least
  every second and try to replace it, still at most every 5 s (`reconnect_interval_ns`). An
  attempt blocks the gateway's one thread for up to the client's timeout, as it did inside a
  request.
`ClientHealth` moved from `api/server.zig` to `src/nerva/client_health.zig`, shared by both.
Tests: a unit test delivers a reply to a timed-out client (it panicked before). In `test:api`,
after a stall past the client's timeout, only `/healthz` is polled until it answers 200 (before:
503 for as long as no request came). In `test:views`, a view process stalled the same way stays
up, answers 503 and `/healthz` 503, then recovers with only `/healthz` polled and serves the
same hash as before the stall (before: it exited).
