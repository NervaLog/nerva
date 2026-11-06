---
id: P239d
date: 2026-11-06
area: Releases
amends: P239c
---

# Keyed `bank` fails a refused key that has a record, reads the record first and keeps the final phase's attempts

**Decision.**
- `refused-with-record`: a record in the final read of a key that no `2xx` answered but a
  Nerva refusal did (`answered-by-refusal?`: no `:unknown` attempt before it, or a final-phase
  refusal) makes the run invalid. A key with a record committed, and keys are kept forever, so a
  resend of it must replay; a refusal means the cluster did not match the resend to its key.
  A doubtful key that the final phase never answered stays `:unresolved` (`:unknown`).
- `a-refusal-after-a-lost-attempt-leaves-room-for-the-original` expected a pass for `[lost,
  out_of_bounds]` plus a record. Its claim was wrong: it argued that the original might commit
  after the refusal, but then the final phase's resend would replay, not be refused. The test is
  renamed and now expects the failure; the case with no record, and the unresolved case, still
  pass or stay unknown.
- `keyed/resolve-pending` keeps its entries and the in-progress key's attempts in volatiles,
  as the operation phase does (`attempts-or-crash`): on any `Throwable` the op ends `:info`
  `:crashed` with them in `:resolved` (an interrupt is passed on), so a duplicate `2xx` or a
  late refusal made before the throw is judged.
- A keyed transfer's entries are the pair of adds, a `read` of its record with `op_seen "0"`,
  then the `put`. `/v1/commit` accepts a `read` of a record table (`api.zig` `commit_parse`
  sets no restriction; README "Records": a transaction may read records; the state machine
  checks the read in `commit_failure` against `record_stored`, absent as `0`). A second
  application of the transfer finds the record, and answers `409 conflict`, which
  `refusal-checker` does not expect. A correct cluster checks the key first, so a resend
  replays and nothing changes for it.

**Reason.** All three were false passes: a refused key that had committed, a throw that dropped
final-phase evidence, and a re-execution after a lost reply that an upsert hid.

**Cost.** Checked on run 42205343461's history (valid): 3183 keys, 2742 committed, 0
`refused-with-record`, still valid. The teeth run's history stays invalid. The read adds one
entry to every keyed transfer, and the hash of the key's entries (so a resend carries it too).
A `conflict` on the record is now an unexpected refusal, never a silent upsert.
