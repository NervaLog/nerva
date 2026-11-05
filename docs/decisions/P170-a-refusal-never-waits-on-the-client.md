---
id: P170
date: 2026-11-05
area: Releases
amends: P168c
---

# A refusal is one non-blocking send, so it never waits on a client

**Decision.** The Receiver writes a refusal (`503 busy`, `408`, or one of the `400`s) as a single non-blocking `send` of at most 512 bytes, head and body together, then shuts down the send side. If the client's buffer cannot take the reply, the reply is lost, but the gateway does not wait.

**Why.** The gateway is single-threaded. A refusal that blocked on a slow client would stall every other connection, which is the failure the refusal exists to prevent.

**Cost.** A client whose receive buffer is full may see a reset instead of the reply.
