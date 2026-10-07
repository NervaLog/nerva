---
id: P105
date: 2026-10-06
area: Releases
---

# Every release is preceded by an adversarial review

Before the `VERSION` commit, a bot that did none of the release's work reviews the release
candidate to break it: the diff since the last tag, every vendored patch, upgrade and downgrade,
the invariants in CLAUDE.md, plus VOPR seeds, the fuzzers and the release, integration and Jepsen
suites. Findings are issues labelled `release-review`. The release waits until each blocker is
fixed or waived by the owner in writing, and the CHANGELOG section links them. CLAUDE.md states
the rule beside the release steps.

**Why.** A pull request review looks at one change at a time. A release ships them together, with
their interactions and its upgrade path. During 0.5.0's work, reviews found a bug that two
releases had shipped with: clients older than the cluster's release could not register with a
multi-replica cluster (#93, present since v0.3.0).

**Cost.** A release takes longer: the review runs the long suites and its blockers must be fixed
before `VERSION` moves.
