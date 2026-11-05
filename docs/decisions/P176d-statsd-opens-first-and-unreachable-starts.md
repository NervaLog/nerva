---
id: P176d
date: 2026-11-05
area: Releases
amends: P176b
---

# The statsd socket opens before the client registers, and an unreachable collector starts

**Decision.** `nerva api` opens the `--statsd` socket before `Client.init` registers a session,
so a bad address exits with NRV-E0010 at once, with the cluster down or up, and burns no session.
The listen address is added to the tags later (`Emitter.set_listen`). Only a socket that cannot
exist fails the start: no such address family, no permission (a broadcast address), no
descriptors. A `connect` that reports `NetworkUnreachable`, `ConnectionRefused` or
`ConnectionTimedOut` does not: P176b said an address that is "merely unreachable still starts", and
now it does. Every send names the destination (`sendto`) and every refusal, including
`ConnectionRefused` from an earlier ICMP error, is a dropped packet counted in `statsd_dropped`.
`posix.send` is not used: the pinned std makes those errors `unreachable`, which panicked the
gateway about ten seconds after start when nothing listened on the port.

**Why.** A start check that needs the cluster first waits 30 s (NRV-E0604) or spends a session on a
start that fails. A missing collector is a normal state for UDP and must never take the gateway down.

**Cost.** The socket exists before the gateway has its listen address, so the emitter has two
steps. A collector that never listens produces only a rising `statsd_dropped` that nobody receives.
