---
id: P196
date: 2026-11-06
area: Errors
amends: P176b
---

# `start` reuses NRV-E0010 for a `--statsd` address it cannot send to

**Decision.** A replica that cannot set up its statsd socket exits with NRV-E0010, as the gateway
does, instead of registering a sibling code. The mapping is at `start`'s call site; the vendored
tracer is unchanged.

**Reason.** Same cause, same blame, same fix (give `--statsd` a usable address). One code per
cause keeps ERRORS.md short.

**Cost.** The code's wording now covers two commands; the first words of the line (`start:` or
`api:`) tell them apart. Any non-memory error from the tracer's setup with `--statsd` set is
reported this way, which is right today because only the statsd socket can fail there.

Unlike the gateway, `start` also refuses an address the host has no route to ("the network is
unreachable"): the vendored `StatsD.init_udp` connects its socket. Tolerating that needs a
vendored patch and is left to its own issue.
