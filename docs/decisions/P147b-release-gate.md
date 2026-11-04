---
id: P147b
date: 2026-11-04
area: Releases
amends: P105
---

# A release needs a sim-clean, Jepsen-clean commit, two independent reviews, and a retro afterwards

Adopted from Zigbox's release rule (owner, 2026-11-04). A release is cut only from a `main`
commit that is:

1. **Sim-clean,** once R2's fleet runs: the fleet has run 24 hours on that commit, and no
   `sim-fleet` issue is open against it.
2. **Jepsen-clean,** once R1's nightly runs: the suite passes on that commit.
3. **Reviewed adversarially by two independent reviewers.** Each is a fresh session given the
   diff since the last tag and the briefs, never the other's findings nor the implementers'
   conclusions. P105's review, its `release-review` issues and its blocking rule stay as they
   were; there are now two of them.

The release pull request quotes the fleet's tracker line, the Jepsen result and both verdicts.
Within a day of the release, a short retro goes in `docs/retros/<version>.md`: which assumptions
were wrong, what each cost, and what changes. A rule it changes lands in CLAUDE.md or
`docs/decisions/` in the same pull request.

**Why.**
- **v0.6.1 shipped with Jepsen not run** (#139), as did every release since v0.4.0. That was
  waived each time because there was no Docker.
- **One reviewer sees what one reviewer sees.** Zigbox and Zigcube found that a second, blind
  reviewer catches what the first one rationalised.

**Cost.** Releases wait on the fleet and Jepsen once they exist, and take two reviews. Until R1
and R2 deliver, items 1 and 2 do not apply, and the release pull request says so.
