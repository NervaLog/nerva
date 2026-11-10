---
id: P259b
date: 2026-11-10
area: Releases
---

# The release string moves with every VERSION

Owner, 2026-11-10: from vR on, the release string moves with every published `VERSION`, so that one string always means one code. Nerva does not keep a protocol release that moves only when the protocol or state machine does.

**Why.** The alternative is the v0.6.1 hazard: two binaries under one release string that may hold different state machine code, which N61's guard admits and nothing checks. Multiversion also needs distinct, increasing releases.

**Cost.** Every release, even one that changes no protocol, moves the string and so needs a rolling upgrade (or an export and import) to adopt. `release_client_min` stays at or below the previous release's so that N's gateways stay valid.
