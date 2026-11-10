---
id: P269
date: 2026-11-10
area: Releases
amends: P147
---

# R6 slice 1 runs alongside R1

Owner, 2026-11-10: R6 slice 1 (release identity and the format digest) is built while R1 is
still open. This is an exception to the rule P147 adopted, "work one milestone at a time"
(CLAUDE.md, "Milestones and demos").

The exception covers slice 1 only: `format_digest.zig`, `nerva version`'s new lines, the release
assertion in `build.zig` and the registered codes. Slices 2 to 7 start only when the milestone
rule allows it, or when the owner says so again.

**Why.** Slice 1 changes no persisted format, no wire format and no behaviour of a running
cluster, and touches none of R1's files (Jepsen, the fleet). It gives R6's later slices and the
release workflow the digest to read.

**Cost.** Two milestones are open at once, so a review and a release gate see both. The slice
adds a golden digest (`tests/errors/commands.py`, `format_test.zig`) that any layout change in
R1's work must update.
