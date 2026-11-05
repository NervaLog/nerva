---
id: P171
date: 2026-11-05
area: Releases
---

# The VOPR says when a run stopped at upstream's liveness exemption

**Decision.** The owner approved this vendored patch on 2026-11-05. When `core_missing_primary` holds, the VOPR now:
- logs the core's bits before upstream's `unimplemented("repair requires reachable primary")`;
- logs `LIVENESS NOT CHECKED (unimplemented: …) unimplemented=true` before its exit 0.

The exit status stays 0, as upstream has it.

**Why.** About 1 seed in 100 on the `nerva` lane ends there. The cause is upstream behaviour, identical at the pinned commit: a primary outside the core, which upstream's own TODO notes. Safety is checked on every tick up to that point. Without a line of its own, such a run looks like neither a pass nor a failure. With it, R2's fleet can count these seeds as "liveness not checked".

**Cost.** Two log lines in a vendored file, recorded in `UPSTREAM.md`. The real fix, repair without a reachable primary, stays upstream's.
