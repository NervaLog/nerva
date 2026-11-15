---
id: P403
date: 2026-11-13
area: Testing
amends: P225
---

# A `--development` replica keeps 8 request slots, so ten gateways connect

Decision: `nerva start --development` sets `pipeline_requests_limit` to 8 (capped at the build's
`pipeline_request_queue_max`), not 0. A development replica takes 16 client connections, not 8
(#231, option 1). Production is unchanged.

The reason: each gateway is a client on every replica, so Jepsen's `--gateways 2` on five nodes put
ten clients on each replica, and the last two were closed by all of them (P225's cut). The change
is a start-time option, not a persisted format, and touches no vendored file.

What it costs: a development replica allocates 8 more messages in its pool. Not done: the
wrong-blame NRV-E0604 text for a replica that refuses a client for lack of slots (#231, option 2);
that needs a way to see the close, which may mean `src/vsr/client.zig`, a vendored patch and a
stop. #231 stays about that if the owner wants it, and `two-gateway-nodes` in
`tests/jepsen/src/jepsen/nerva/db.clj` (R1 demo cut) is restored by a Jepsen change, not this one.
