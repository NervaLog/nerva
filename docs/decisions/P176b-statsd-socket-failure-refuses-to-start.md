---
id: P176b
date: 2026-11-05
area: Releases
amends: P176
---

# A gateway whose statsd socket cannot be set up refuses to start (NRV-E0010)

**Decision.** `nerva api --statsd=<addr>` sets up its UDP socket before the gateway says it
listens and prints its port. If the socket cannot be created or connected (a broadcast address, an
IPv6 address on a host without IPv6), the gateway exits with `error[NRV-E0010]: api: cannot send
statsd to <addr>: <reason>`, exit 1, blamed on the operator and on `--statsd`. It does not run
without the metrics it was asked for.

**Why.** Before, such an address ended in `bug[NRV-B0004]` or in NRV-E0007 ("cannot listen"),
which blames the wrong flag, after the gateway had already announced a port. An operator who asked
for metrics and silently got none would find out when a dashboard stays empty; refusing is the
louder, safer choice, and matches how `--listen` failures behave.

**Cost.** A gateway cannot be started with a metrics address that is wrong on this host. Sending
to an address that is merely unreachable still starts (UDP, non-blocking: those packets are dropped
and counted). The code takes E0010 because E0009 is slice 6's.
