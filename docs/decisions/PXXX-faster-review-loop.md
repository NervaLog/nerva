---
id: PXXX
date: 2026-11-05
area: Releases
amends: P148b
---

# The review loop: GitHub does the waiting, re-reviews read the delta, merge on no MUST

**Decision** (owner, 2026-11-05): the supervisor runs each pull request's review loop this way.

1. **GitHub updates branches.** When `main` moves, the supervisor uses GitHub's "update
   branch" (merge commit) rather than an agent. An agent is started only for a conflict.
2. **Auto-merge waits for CI.** Once a fresh Opus review has no MUST, the supervisor enables
   auto-merge (merge commit) and GitHub merges when CI is green. The authority to merge is
   still the owner's instruction for that work; auto-merge only does the waiting.
3. **Re-reviews read the delta.** After a fix, the fresh Opus reviewer is given the diff since
   the commit last reviewed and that review's findings, not the whole pull request.
4. **Text-only fixes go to Haiku:** a finding that changes only a pull request description, a
   README row, a decision note or a worklog.
5. **Short reports.** An agent's final report is at most 15 lines: its SHA, its gate result
   lines and its handoff note. Long output stays in files.
6. **Merge on no MUST; SHOULDs follow.** A review with no MUST merges once the description is
   true of the diff (a Haiku edit, if it is not). The remaining SHOULDs and NITs go into one
   follow-up pull request, or into the next slice, and are replied to on the reviewed pull
   request with where they will land. A SHOULD that touches correctness or a test the brief
   requires is fixed before the merge.
7. **Each agent logs into its own directory** (`scratchpad/<task>/`), never the scratchpad
   root: two reviews running at once overwrote each other's `check.log` on 2026-11-05.

Unchanged: a fresh agent per task, a fresh Opus review of each slice, a reply to every review
comment (P185), the PR statements, and the release gate.

**Why:** the time and tokens went into the loop around each pull request, not the code: an
agent to merge `main` in, the supervisor polling CI, full re-reviews of unchanged code, and a
whole fixer cycle and CI wait for findings that were not blocking.

**Cost:** SHOULDs land a day or so after their slice, and `main` can carry a known, reviewed
weakness in between. The follow-up is tracked on the reviewed pull request, so none is lost.
