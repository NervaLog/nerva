---
id: P173b
date: 2026-11-05
area: Releases
---

# A malformed request's code comes from its reason's family

**Decision.** `wire_code.of_bad` and `of_invalid` place each `api.bad(…)` and `catalog.invalid(…)`
reason into a registered code family through ordered rule tables. Documents name their code at the
site, with `bad_as`. A unit test fails for any reason literal in `api.zig` or `catalog.zig` that
matches no rule. At runtime, an unmatched reason falls back to E0105 (`bad`) or E0301 (`invalid`).

**Why.** About 180 sites. Classifying their texts in one table keeps every call site as it was, and
the test keeps the table complete.

**Cost.** A new reason needs a rule, or the build fails. The code depends on the reason text, so
rewording a reason can move it to another code; the test catches a reason that no longer matches
any rule.
