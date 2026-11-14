---
id: P427
date: 2026-11-14
area: Errors
amends: P196
---

# `start` sends statsd without connecting its socket; an unroutable address warns, NRV-W0733

**Decision.** The owner answered the question on PR #427 with option (a): patch the vendored
`StatsD.init_udp` (`src/trace/statsd.zig`, this patch only) so the UDP socket is not connected and
each packet is sent to the address, as `nerva api`'s emitter does. An address this host has no
route to, or may not send to (a broadcast address), no longer stops `nerva start`: it warns once
with NRV-W0733 (at the emit after the first failed packet) and runs on; later failures are only
counted. NRV-E0010 stays for a `--statsd` address whose family the host has no socket for.

**Reason.** The metrics are a side channel: a collector that is unreachable must not take a replica
down (#198, and the same stance as P176d for the gateway). `IO.send` has no destination, so the
patch sends with `sendto` in `statsd.zig` itself; no other vendored file changes.

**Cost.** One more vendored patch (UPSTREAM.md). `start` no longer refuses a broadcast address, as
`api` still does (its emitter connects, which fails on it): a typo there is a warning in the log
rather than a refusal. P196's closing paragraph, which left this to its own issue, is answered.
