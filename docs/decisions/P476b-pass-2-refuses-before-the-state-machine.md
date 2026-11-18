---
id: P476b
date: 2026-11-18
area: Errors
amends: P476
---

# Pass 2 refuses an export that stopped matching pass 1's before a row reaches the state machine

**Decision.** `Restore.change_next` (pass 2) checks every change it reads against what pass 1
planned, and returns `error.ExportChanged` (NRV-E0813) for: a row in a table that holds records
(`table_refused`, #126), a timestamp past `timestamp_restore_max`, and more rows or records than
pass 1's summary counts (`reader.change_count` and `record_change_count` against
`Plan.summary`). A fault the reader finds in pass 2 (`Corrupt`, an unsupported version) is also
`ExportChanged`, because pass 1 read the whole export without one. A fault pass 1 does not look
for (changes out of op order, an op that both declares and writes, too many changes in an op,
changes past the export's op) is reported as corrupt (NRV-E0804) only when the rest of the export,
read to its end, hashes to `Plan.origin`; otherwise it is `ExportChanged`. The `assert` on the
rest of the changes' section is now a refusal. `import.plan` refuses a file that is not a regular
file (`error.NotRegularFile`, NRV-E0810), since pass 2 seeks back to its start; a pipe or a device
cannot.

**Reason.** #481: the digest was compared only after every op had gone through the state machine,
which asserts what pass 1 checked, so a file rewritten in place panicked and left `.importing`
behind, and an export with more ops was called corrupt. Two options were open: repeat pass 1's
refusals in pass 2 and map them to `ExportChanged` (prevents the panic), or hash the rest of the
file on failure (gets the code right). This takes both, at the closest place to the existing code:
the per-change checks sit where pass 2 already reads a change, and the drain runs only on a path
that was already an error. Nothing is asserted on input bytes.

**Cost.** Pass 2 does a few comparisons per change. A genuinely corrupt export that pass 1 accepts
reads to its end once more before pass 2 says so. An input that is a pipe is refused, as it
already failed (as a truncated read, or NRV-B0004).
