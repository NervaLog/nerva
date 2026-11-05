---
id: P183c
date: 2026-11-05
area: Releases
---
The `--listen-remote` warning is a coded log line, NRV-W0010, and only for a non-loopback address.

**Decision.** With `--listen-remote` and a `--listen` address that is not loopback, the gateway
logs one warning, `NRV-W0010`, before it listens, saying that the key and every reply cross the
network unencrypted. On a loopback address the flag is accepted silently. The code is registered
in `docs/ERRORS.md` (00xx) and, like NRV-W1003, is only logged.

**Why.** The review (S4) pointed out that W1003, W0201 and W0310 are coded warnings that are not
failures, so P147c's rule covers this line too; a script can now match the code. The text is false
on loopback, so it is not logged there (S5). This amends the first version of this decision, which
left the line uncoded.

**Cost.** One more registered code. A log scraper must match `NRV-W0010`, not the text.
