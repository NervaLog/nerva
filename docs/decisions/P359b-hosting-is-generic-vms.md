---
id: P359b
date: 2026-11-12
area: Releases
---

# Fly is no longer a design target; Nerva plans for generic VM hosting, most likely Azure first

**Decision.** The owner decided on 2026-11-12 that running on Fly is no longer a hard design goal
for Nerva, Botpike or Zigbox, since Zigbox is unlikely to run on Fly at all. Plan for generic
virtual machines. Azure is the likeliest first host, because of its startup credits.

- Nerva's own design never depended on Fly. Its packages (rpm and deb), its static binary and the
  three-replica layout already suit any Linux VM.
- R3 ("Measured", `docs/PRODUCTION.md`) measures on the topology that production actually uses.
  The Fly p99 numbers stay as one data point. R3's brief names the host once Botpike chooses it.
- The `perf/fly/` harness and Botpike's `botpike-nerva*` Fly apps are kept until something
  replaces them. This decision moves nothing.
- New Nerva work must not depend on Fly-only features, such as Fly's private WireGuard network
  standing in for TLS on the gateway (`docs/PRODUCTION.md`, "TLS on the gateway").

**Why.** The owner's direction. Zigbox needs a host where it can run rootless and, for its
microVM isolation (Zigbox S1), use KVM. A Fly Machine is a Firecracker VM and does not offer
that. Botpike's runs go where Zigbox goes, and its ledger should stay close to them.

**Cost.** Planned work that assumed Fly's network must find another answer when it is next
touched: the gateway's TLS, and how replicas reach one another privately. Botpike's record of
the same decision is Botpike/app#161.
