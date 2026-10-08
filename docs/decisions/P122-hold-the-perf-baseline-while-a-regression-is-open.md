---
id: P122
date: 2026-10-08
area: "Milestone 3: positioned reads and the first views"
amends: P121
---

# The perf baseline holds while a regression issue is open; an open issue is found by its metric; a pass closes only filed issues

Two bugs in P121, found in review:

1. **A warn night moved the fingerprint.** The fingerprint is `<metric>:<baseline>`, and the
   workflow advanced the baseline after any night that did not fail, a warn night included. So
   fail, warn, fail filed a second issue for one regression, and the regressed candidate of the
   warn night became the baseline: the regression was absorbed into what later nights are
   measured against, and could stop failing without ever being fixed.
2. **A passing night closed every open `perf-regression` issue**, hand-filed ones included.

Decision:

- **The baseline holds while a regression is open.** `file_issue.py` now runs before the results
  are recorded and writes `advance_baseline=true|false` to the step's output: a failing night
  never advances it, a passing night always does, and a warn or no-comparison night only when
  no `perf-regression` issue carrying a fingerprint is open once the night is filed. The
  decision uses the measured verdict (a forced verdict changes issues, not the baseline, as in
  P121). If the issue step gives no answer (it failed), only a measured pass moves the baseline.
  This is the fix that keeps the baseline honest: a regression stays measured against the
  commit from before it until a night passes or someone closes its issue (accepting it).
- **An open issue is also found by its metric**, whatever baseline its fingerprints name: an
  open issue for a metric is the same regression. This covers issues filed under P121 against a
  baseline that has since moved, a manual run with its own baseline, and an issue opened before
  this change. A closed issue is still found only by an exact fingerprint, so a regression of
  the same metric against a later baseline, after the first was fixed, opens a new issue as
  before. The fingerprint format is unchanged, so P121's markers keep working.
- **A pass closes only issues with a `<!-- nerva-perf:fingerprint=... -->` marker**, the ones
  this script filed. Hand-filed issues are left open, and do not hold the baseline.

Rejected: fingerprinting on the metric alone, for closed issues too. It fixes the duplicate but
not the absorbed baseline, and would reopen a months-old issue for an unrelated regression of the
same metric.

Cost: while a fingerprinted issue stays open the baseline does not move, so nights compare
against an older commit and may warn on unrelated drift; closing the issue (by a passing night,
or by hand to accept the regression) releases it. Two unrelated regressions of one metric while
its issue is open share that issue (P121 already folded them when the baseline matched).
