---
id: P168b
date: 2026-11-05
area: Releases
---

# The gateway's answer contract: every connection answered, `applied` on every failure

**Decision.** Every connection the gateway accepts gets a status line before it is closed. Every
non-`2xx` reply carries `code` (`docs/ERRORS.md`) and `applied`, beside the identifiers clients
already match on, which keep their spelling.
- `applied` is `false` when no write for the request left for the cluster. The gateway counts
  them with `Client.writes_sent`.
- `applied` is `"unknown"` when a write left and no reply came back.

A reply comes within `queue_wait_max` + `--request-timeout` + 1 s.

**Why.** Today a busy or slow request is closed with no reply (#120), and one 503 covers both
"never sent" and "sent, no answer". A client can only resend safely if it can tell them apart.

**Cost.** Every error path needs a test that asserts both fields. A slow client waits up to the
stated bound for its answer.
