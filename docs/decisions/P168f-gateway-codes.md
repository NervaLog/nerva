---
id: P168f
date: 2026-11-05
area: Releases
---

# NRV-E0605 is split from NRV-E0601; NRV-E0116 is new

**Decision.**
- **NRV-E0605:** the gateway has no cluster session, so the request was never sent. It answers
  `applied: false`. Before, NRV-E0601 "cluster unavailable" covered it.
- **NRV-E0601** keeps "sent, and no reply came back", with `applied: "unknown"`.
- **NRV-E0116:** a request that did not arrive whole within its deadline, answered `408`.

**Why.** "Not applied" and "unknown" need different codes for a client to act on them.

**Cost.** Two more codes, both registered in `docs/ERRORS.md`.
