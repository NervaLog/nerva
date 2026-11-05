---
id: P168c
date: 2026-11-05
area: Releases
amends: N45
---

# The gateway's receiver: its own socket, only silent connections displaced, `busy` unread

**Decision.** This amends N45, N58 and P143's note on displacement.
- The gateway opens its own listening socket without `SO_REUSEPORT`, so a second gateway on the
  same port is refused (#112).
- When all slots are taken, only a connection that has sent nothing yet can be displaced. A
  newcomer that cannot be placed within `queue_wait_max` (1 s) gets `503 busy`,
  `applied: false`, without its request being read.
- A request that has not arrived whole by its deadline is answered `408` (NRV-E0116).
- After a refusal the socket lingers briefly, so that the client reads the reply before the close.

**Why.** Closing a connection mid-send leaves the client unable to know what happened (#120).

**Cost.** The gateway no longer uses the vendored IO's listener, and a lingering refusal holds a
socket a little longer.
