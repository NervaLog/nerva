---
id: P332
date: 2026-11-11
area: Security
---

# The env examples' placeholder keys are refused at startup

**Decision.** `nerva start` refuses `NERVA_CLUSTER_KEY` and `NERVA_CLUSTER_KEY_NEXT`, and `nerva api`
refuses `NERVA_KEY` and `NERVA_KEY_NEXT`, when the value is exactly the placeholder that
`packaging/linux/replica.env.example` or `api.env.example` ships. The codes stay NRV-E0901 and
NRV-E0008; only their messages grew. The examples keep their placeholders.

**Why.** The placeholders pass the length check and are published, so a copied, unedited example ran
a cluster on a known key (#306). Refusing the exact strings needs no packaging change and also
covers a hand-typed copy.

**Cost.** Only the exact strings are caught; any other published or weak key is not. The constants
and the examples are two copies of one string and could drift. No new code, so no ERRORS.md row.
