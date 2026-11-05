---
id: P183c
date: 2026-11-05
area: Releases
---
The `--listen-remote` warning is a log line at startup, without a code.

**Decision.** With `--listen-remote`, the gateway logs one `warning` before it listens, saying that
the key and every reply cross the network unencrypted. It carries no `NRV-W` code.

**Why.** P147c codes failures a client, operator or script can see. This line is not a failure:
the operator asked for the behaviour by name, and nothing is refused or degraded. A code would only
be matched by a script that already passes the flag.

**Cost.** A log scraper cannot match it by code; it matches the text. If an operator later needs
to alert on it, a code can be added beside the text (P147c) without changing it.
