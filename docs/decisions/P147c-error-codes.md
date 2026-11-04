---
id: P147c
date: 2026-11-04
area: Releases
---

# Every failure a client or operator can see has a registered code, NRV-<kind><4 digits>

The owner asked on 2026-11-04 for documented error codes, after Zigbox's diagnostics standard.
`docs/ERRORS.md` is the registry: about 90 codes, each with its summary, today's surface, blame,
cause and fix. Number ranges go by subsystem. One code covers a family of texts that share a cause
and a fix, such as every malformed commit entry.

**Rules:**
- Codes are never reused or renumbered.
- A new failure path registers its code in the same pull request, with a test.
- Today's wire identifiers (`conflict`, `out_of_bounds` and the rest) keep their spelling; a code
  is added beside them, never in their place.
- **Blame** is `client`, `retry`, `operator` or `internal`. `retry` marks the only failures a
  client may resend unchanged: under its commit key, a resend commits at most once.

**Not yet on the wire.**
- **R4:** API replies gain a `code` member. Adding it is an additive wire change, made in R4 as
  its own reviewed step.
- **R5:** the commands print coded one-line diagnostics.
- **Until then:** the registry maps today's texts to codes.

**Why.**
- **Most API errors are free text** that a client cannot match on safely.
- **The same failure has three statuses:** "not yet committed" is 504, or 400 on other routes.
- **Commands misreport or crash:**
  - several print raw Zig error names (`PathAlreadyExists`, `VersionUnsupported`, `WALInvalid`);
  - 16 cases of operator input panic, a data file from another release among them (#95);
  - one names a flag that does not exist (`--limit-storage`).
- **Clients must know what is safe to retry.** A money client needs that before anything else.

**Cost.** Every failure path now has a registry entry and a test to keep, and the R4 and R5 work
grows by the codes.
