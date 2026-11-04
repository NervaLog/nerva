---
id: P147g
date: 2026-11-04
area: Releases
---

# A gateway runs beside the process it serves; a native JVM client follows in R8

The owner decided on 2026-11-04: a sidecar gateway now, a native client later.

**Now (R4).**
- **The documented topology:** `nerva api` on `127.0.0.1` beside each client process, connected to
  every replica, one cluster session per client process. It is no longer a shared service beside
  the replicas.
- **For Botpike,** this moves its gateways from the cluster's Machines onto the app's. Botpike's
  side is specified in Botpike/app.

**Later (R8).**
- Nerva's client library over a C ABI, called from the JVM through Java 21's foreign-function API.
  There is no gateway and no JSON, and concurrent calls are batched into one op.
- The gateway stays as the language-neutral API (N39).

**Why.**
- **A shared gateway is an extra network hop** and a failure shared by every client behind it. Its
  plain HTTP and key cross the network, and its one session caps every client together (12
  callers per gateway in Botpike, P99b).
- **A gateway beside its client** fails only with that client and needs no TLS. Its capacity
  grows with the clients.
- **The native client** removes the remaining hop and JSON. It batches as the vendored engine is
  meant to be driven.

**Cost.**
- Each client process takes one of the cluster's 64 sessions.
- Client machines must reach the replicas' port. Until now only peers could, and a client that
  reaches it can act as any client, as `nerva api` already can.
- R8 adds a binary wire format, which is a stop when it is built, and native builds to publish.
