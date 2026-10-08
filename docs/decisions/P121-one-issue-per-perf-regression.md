---
id: P121
date: 2026-10-08
area: "Milestone 3: positioned reads and the first views"
amends: N56
---

# A perf regression is one issue, found again by its fingerprint, and closed by the next pass

OBS-8 part 3 (Botpike/app, decision P101m, approved by the owner on 2026-10-08). The nightly (N56)
opened a new `Performance regression at <sha>` issue on every failing night, so a regression
that lasted a week filed seven. `perf/nightly/file_issue.py` now does what Highwayman's
`tools/issues.py` does for its findings (rewritten here, not imported: Nerva does not depend on
Highwayman):

- **The fingerprint is `<metric>:<baseline commit, 12 hex>`, one per failing metric**, with the
  metric's name made safe for a marker (`load c4/b1 p99 µs` is `load-c4-b1-p99-us`); a night
  with errors adds `errors:<baseline>`, a forced fail with nothing failing `overall:<baseline>`.
  The baseline is what names the regression: the workflow moves it only after a night that did
  not fail, so it stays the same however many nights a regression lasts, while the candidate
  changes with every merge to `main`. One fingerprint per metric, rather than one for the whole
  set of failing metrics, because the set moves from night to night (a metric near its threshold
  fails one night and only warns the next), and a set fingerprint would open a new issue each
  time it moved.
- **One issue per night, not per metric.** A failing night whose fingerprints no issue carries
  opens one issue carrying all of them (a slower path usually fails several metrics at once). A
  night that shares any fingerprint with an issue comments on it with the night's table, and
  records its other fingerprints there, reopening it if closed; an open issue is preferred over a
  closed one, then the newest.
- **Recovery.** A night whose verdict is `pass` comments "recovered", with the run's URL, on every
  open `perf-regression` issue (older ones without a fingerprint included) and closes it as
  completed. A `warn` or `no-comparison` night changes nothing.
- **Idempotent.** Every post carries `<!-- nerva-perf:run=<run id> -->`; a re-run of the same run
  (same run id) finds it and changes nothing.
- **Testing it.** `file_issue.py --dry-run` reads the issues and prints what it would post; a
  manual run's `force_verdict` (`fail` or `pass`) files or closes as if the night had that
  verdict, while the results and the baseline are recorded as measured. The tests stub `gh` and
  run in CI's `system` job, beside `compare.py`'s, which ran nowhere until now.
- **Reads use REST** (`gh api`), writes `gh issue`: the reads then also work where GraphQL is not
  available, such as a dry run from a Claude Code session.

Cost: a regression that is fixed and then comes back while the baseline has not moved reopens the
old issue rather than filing a new one, which is what is wanted; a second, unrelated regression
against the same baseline that fails a metric the first already failed is folded into the first
issue. Rejected: the baseline alone as the fingerprint (merges every regression of an episode,
including unrelated ones in other metrics) and the candidate (changes nightly, the bug being fixed).
