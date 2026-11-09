---
id: P239e
date: 2026-11-09
area: Releases
amends: P239d
---

# Keyed `bank`: a `conflict` after a commit is a `duplicate`; the final records read has a deadline

**Decision.**
- In `analyze-keys`, a key that committed (`:committed` attempt) and was then refused `409
  conflict` counts in `:duplicate`: the transfer ran a second time and the record read of P239d
  refused it. `:refused-after-commit` keeps every other status. The run is invalid either way.
- The nightly canary (`ops/jepsen/nightly.sh`, `JEPSEN_WORKLOADS` `retry bank`, `--expect-invalid`)
  counts a run as caught only when a finding named `duplicate` appears, and `docs/briefs/r1.md`
  slice 5 says "with teeth: invalid with `duplicate`". Both stay as they are. A reporter test
  ingests a teeth-shaped bank store with `--expect-invalid` and expects `jepsen/canary` success.
- The alternative, per-workload expected classes in the reporter and an amended brief, was not
  taken: it would add a table to keep in step with every class the workload gains, and the
  duplicate is the truthful name for a re-execution however it was detected.
- `invoke-records` has a named total, `records-deadline-ms` (180 s, plus the request in flight),
  checked before every try and every scan, and skips a gateway that is not healthy. Past it the
  op ends `:fail :no-answer`; with no records read the keys' verdict is `:unknown`, never a
  finding against Nerva.
- `jepsen_report.py` reads `bank-no-keys` also from the test directory's name
  (`nerva bank no-keys ...`), since a `test-all` store has no `--workload`.

**Reason.** The fourth review (PR #239): hosted teeth run 42215100073 had `:duplicate 0` and the
canary would have called `bank` blind every night, then filed the teeth's findings as `main` bugs.

**Cost.** A `conflict` after a commit is named a duplicate although it is a refused second
application, not a second 2xx; the `:conflict true` mark in the example says which.
