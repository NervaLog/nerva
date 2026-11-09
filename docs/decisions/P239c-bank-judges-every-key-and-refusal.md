---
id: P239c
date: 2026-11-06
area: Releases
amends: P239b
---

# Keyed `bank` judges doubtful keys, late refusals and final-phase refusals

**Decision.**
- A key is answered by a `2xx`, or by a Nerva refusal that has no `:unknown` attempt of the key
  before it, or by a refusal of the final phase (`key-records` marks those attempts `:final?`).
  A doubtful key the final phase never answered (deadline passed, no healthy gateway) is
  `:unresolved`, so the result is `:unknown`, as `keyed/invoke-keyed` already treats it.
- `refused-after-commit`: a Nerva refusal after a `:committed` attempt (a discarded 200
  included) of the same key makes the run invalid. Keys are kept forever, so a resend must
  replay; a refusal means the key was lost. It is `retry`'s `applied-lies` in reverse. Checked
  against hosted histories: run 42194514844 (valid) has 0 such keys and stays valid; the teeth
  run 42199932097 has 26.
- `refusal-checker` also judges the refusals that decided no operation: those of the final phase
  and those among an `:info` transfer's attempts. Only `out_of_bounds` is expected, whichever
  phase it comes in.

**Reason.** All three were false passes: a verdict that depended on the phase in which a bug
showed, or on no answer at all.

**Cost.** A refusal in the final phase after an unanswered attempt of that phase counts as
an answer (the phase runs after healing, with the long timeout). The `:refusals` count now
includes the final phase's refusals.
