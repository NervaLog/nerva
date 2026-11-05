---
id: N58
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Gateway fixes from the second hardening pass: routes, recovery, slots, trace files.

Five bugs found by the second pass, each reproduced before it was fixed:
- **`GET /v1/views/groups` crashed `nerva api` (#26).** The path matched both the views prefix and
  the groups suffix, and the name between them was sliced from 10 to 9. A path is a groups route
  only with a name between the two: `/v1/views/groups` is the view named `groups`, which can now
  be read and declared, and `/v1/views/groups/groups` reads its groups.
- **One timeout disabled `nerva api` for good (#27).** A client that timed out or was evicted
  stays unusable, and the gateway never replaced it, while `/healthz` said 200. The gateway now
  keeps the client's health: after a timeout or eviction it answers 503 at once, and the next
  request for the cluster at least 5 s later replaces the client (`Client.reconnect`, or `init`
  alone if a replacement failed partway, never `deinit` twice). `/healthz` answers 503 until it
  is ready again, so a load balancer stops sending to it. The 5 s bound keeps an outage from
  tying up the gateway's thread with a registration per request. `nerva view` still exits when
  it cannot follow the feed, leaving recovery to its supervisor.
- **Idle connections locked clients out (#28).** N45's 16 slots each held an idle connection for
  its whole 10 s deadline, while new connections queued behind them: 200 idle connections held
  `/healthz` up for 85 s, with no key. With every slot busy, the `Receiver` now still polls the
  listening socket, and a waiting connection displaces the oldest one still sending its request
  (closed without a reply). A client that sends its request promptly is served; an attacker must
  open connections faster than a request arrives, not merely hold sixteen. Not a per-peer limit:
  behind a proxy every client has one address. Amends N45, whose further connections waited in
  the backlog.
- **`--trace=<path>` truncated whatever it named (#29)**, a data file included. It is now
  created exclusively, and an existing file is refused with a message.
- **A body with a newline was refused when it arrived with its head (#36).** N45's early
  refusal of a bare LF scanned every byte read so far, body included, so `curl -d` with
  pretty-printed JSON (the README's own examples) got `400 malformed request` whenever head and
  body shared a read. The scan now stops at the end of the head; the body is bytes.
Tests that fail on the binary before these fixes: a view named `groups` read and declared
(`tests/views/maintained.py`); 200 idle connections and `/healthz` within 3 s, `start --trace`
of an existing file leaving it intact, and a replica stalled past the client's timeout, then
resumed, with the gateway reporting itself unhealthy and recovering (`tests/api/api.py`); and a
`Receiver` unit test of displacement; and a multi-line body sent in one write with its head
(`tests/api/api.py`, and a `Receiver` unit test that also keeps a bare LF in the head refused).
