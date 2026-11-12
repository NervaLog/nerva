---
id: P376b
date: 2026-11-12
area: Releases
amends: P147b
---

# The draft is refused unless the release commit records its gates; built after v0.7.1

**Decision (owner, 2026-11-12, on the Zigbox team's review).** P147b's gates are a rule that
people follow, and nothing enforces them yet. A new check, `release_check.sh gates <tag>
<commit>` (NRV-E1159), enforces their form. It reads the version's CHANGELOG section at
`<commit>` and requires its `### What was tested` block to hold these three lines:

- **Simulation.** The line quotes, in backticks, the line that `sim_fleet.py soak --commit
  <candidate>` printed, which reads `soak <7 hex>: <H> h, ...; <F> failures, <T> past the
  deadline, <K> killed by the host; sim-fleet issues its rounds hit: none`. `<H>` is at least
  24.0, and `<F>`, `<T>` and `<K>` are each `0`. The 7 hex digits are a prefix of
  `release/candidate`'s SHA where that file exists (P374).
- **Jepsen.** The line quotes `` `jepsen/nightly success <40 hex>` ``, where the SHA is
  `release/candidate`'s, followed by a link to the run on `github.com/NervaLog/nerva`.
- **Two adversarial reviews.** The line holds two verdicts. Each is one of `ship`,
  `ship after fixes` or `do not ship`, followed by a link to a `github.com/NervaLog/nerva` issue
  or pull request, and the two links differ. A `do not ship` passes only with a `waived:` link to
  the owner's written waiver.

In addition, no `TO FILL` may be left anywhere in the version's section.

**Where it runs.** The check runs after `release_check.sh candidate` (P374), and only for a
release, never for a candidate:

- in `release.yml`'s `version` job, before CI and any build;
- in `release-finish.yml`'s `publish` job, before the draft is published.

A failure stops the run before the draft is made or published.

**What it cannot do.** It checks that the gates are recorded and well formed. It cannot check
that they are true: that the soak ran for those hours, that the Jepsen run passed, or that the
reviewers were independent and fresh. The release reviewers and the owner's approval of `mac`
remain the check on that.

**When.** The check is built as slice G, after #374 merges, because it uses
`release/candidate`, and after the v0.7.1 tag. v0.7.1's gates are filled in by hand as P147b
says, and the owner checks them at the approval. That is the recommendation, and the reasons are
these:

- The release freeze holds, and v0.7.1 waits only on the packages' rehearsal.
- G touches `release_check.sh`, its test and both release workflows, which #374 is changing now.
- A new refusal added on the release path right before the tag is itself a release risk.

**Reason.** The rule was written down but nothing refused a release without it. A format check
catches a forgotten gate, `TO FILL` left in the section, or a soak on another commit. It does
this at no cost to the owner.

**Cost.**
- About 120 lines of shell and tests.
- One more code.
- The CHANGELOG lines take a fixed form, and a release that needs another form needs a decision.
