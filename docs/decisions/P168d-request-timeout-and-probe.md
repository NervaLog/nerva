---
id: P168d
date: 2026-11-05
area: Releases
amends: N64
---

# `--request-timeout`, and an idle gateway probes its cluster

**Decision.** This amends N64.
- The hard-coded 30 s wait for a cluster request becomes `--request-timeout`, defaulting to 30 s.
- An idle gateway sends a one-row read every 5 s. `/healthz` turns 503 within 5 s plus the
  timeout after the cluster goes away.

**Why.** Otherwise an idle gateway reports healthy with no cluster. And the right timeout follows
the client's own call timeout: Botpike's is 5 s, so INF-2 sets the flag below it.

**Cost.** One small read every 5 s per idle gateway.
