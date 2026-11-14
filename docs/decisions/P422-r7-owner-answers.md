---
id: P422
date: 2026-11-13
area: Releases
amends: P394
---

# The owner answered R7's eight questions: the brief's recommendations, with keys and facts cut

P394 recorded `docs/briefs/r7.md` as a proposal with eight owner questions. The owner answered
them in session on 2026-11-13 (comments on #394): question 7 is (a), and questions 1 to 6 and 8
are the brief's recommendations. The brief is now R7's design. This decision records each answer,
and amends GOALS-1.0 goal 7, PRODUCTION.md's R7 section and the README's R7 row to the scope
below. N27 and N62 (history and view versions kept forever) are replaced only by the horizon the
operator declares, and their default, forever, is unchanged. P123 stands: key rows are never
removed.

## The answers

1. **Order.** R7 waits for R6 (`demo_r6` green on `main`). Reason: the owner chose to wait, since
   slice 1 moves the digest R6's admission reads. Cost: R7 starts later.
2. **The feed below the horizon.** It is refused as `before_horizon` by default, with an opt-in
   to the compacted prefix for `nerva view` and export. Reason: the owner chose refusal, so a
   consumer that counts changes is never silently wrong. Cost: the opt-in is one more flag.
3. **The demo's time scale.** 60 s horizon over 30 horizons on a real cluster, with the VOPR
   drawing horizons per seed beside it. Reason: the owner chose the real cluster over a
   VOPR-only demo. Cost: about 35 minutes of demo, and `docs/demos/r7.md` amends PRODUCTION.md's
   "at simulated time".
4. **The default horizon.** Forever: nothing is trimmed unless declared. Reason: the owner chose
   it so no cluster loses data it never asked to lose, and behaviour holds across export and
   import into R7's release. Cost: a cluster that never declares one grows as today.
5. **`retention_min`.** 60 s. Reason: the owner chose the demo's minimum; a larger minimum
   belongs in the operator's declaration. Cost: an operator can declare a horizon short enough
   to lose history they wanted.
6. **Pulses instead of compaction.** Pulses write tombstones and compaction only reclaims them;
   PRODUCTION.md's line "Compaction drops what is older, deterministically" is amended to say
   so. Reason: the owner chose it because compaction never rewrites the append-only trees. Cost:
   the mechanism differs from the earlier scope, and trimming doubles compaction's writes for
   what it trims.
7. **Keys and facts: (a).** Retention of commit keys and of facts is cut from R7 and moves to a
   later milestone, with the open questions under the brief's "Cuts". R7 trims history and view
   versions only, so disk use is bounded by the live set plus one horizon. Reason: the owner
   chose (a), since every key design so far had a double apply and the key check guards the one
   promise P123 exists for. Cost: keys and new rows or records still grow by each one and its
   last change, and GOALS-1.0 goal 7 no longer promises their retention.
8. **The lag bound: (a).** No change: R7 ships the stated bound, W0704 as the alarm, and a demo
   step asserting the drain. Reason: the owner chose it because the backlog is disk, not memory,
   and drains, and it needs neither a wire change nor a vendored patch. Cost: under q writers
   heavier than the bound the backlog grows until the load eases; status 25 and a replica patch
   stay available as later upgrades.

## Text amended

- `docs/GOALS-1.0.md`, goal 7: no longer lists "retention of keys and facts" as next.
- `docs/PRODUCTION.md`, R7: scope, goal, why, demo and the table row read "history and view
  versions trimmed below a horizon; bounded by the live set plus one horizon".
- `README.md`: R7's Production table row has the same scope. Its status stays "Brief written".
