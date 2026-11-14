---
id: P427
date: 2026-11-14
area: Errors
amends: P196
---

# `start` sends statsd without connecting its socket; an unroutable address warns, NRV-W0733

**Decision.** The owner approved option (a) of #198 on 2026-11-14 (owner, 2026-11-14; recorded
here from the task brief, as it was not yet written on GitHub):  patch the vendored
`StatsD.init_udp` (`src/trace/statsd.zig`, this patch only) so the UDP socket is not connected and
each packet is sent to the address, as `nerva api`'s emitter does. An address this host has no
route to, or may not send to (a broadcast address), no longer stops `nerva start`: it warns
with NRV-W0733 (at the emit after the first failed packet) and runs on. The warning is once per
failing stretch: later failures are only counted, and an emit with no failure re-arms it, so a
transient error (`EAGAIN`) does not use it up and a later failure names its own cause. Worst case,
a route that fails and recovers on alternate emits, is one line per two emit intervals (20 s),
still fewer than upstream's per-emit "failed to send N packets". NRV-E0010 stays for a
`--statsd` address whose family the host has no socket for.

**Reason.** The metrics are a side channel: a collector that is unreachable must not take a replica
down (#198, and the same stance as P176d for the gateway). `IO.send` has no destination, so the
patch sends with `sendto` in `statsd.zig` itself; no other vendored file changes.

**Cost.** One more vendored patch (UPSTREAM.md). `start` no longer refuses a broadcast address, as
`api` still does (its emitter connects, which fails on it): a typo there is a warning in the log
rather than a refusal. Sends are `MSG_DONTWAIT`, where upstream's blocking send waited for buffer
space: a burst past the socket buffer (about 65 packets of 1400 bytes; an emit has up to 211) drops
the rest of that emit to a healthy collector. The drop is counted (`send_dropped_count`) and not
warned about: W0733 means only a route failure.
P196's closing paragraph, which left this to its own issue, is answered.
