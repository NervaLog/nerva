---
id: P169
date: 2026-11-05
area: Releases
---

# Every decision is its own file in docs/decisions/

**Decision.** The owner directed this on 2026-11-05, following Zigbox's `docs/decisions/`. N1 to N83 move word for word
out of `docs/DECISIONS.md` into `docs/decisions/N<n>-<slug>.md` and keep their numbers. The ranges
the old log wrote as one superseded entry stay one file each. `docs/DECISIONS.md` stays as a
pointer. A new decision is `docs/decisions/P<pr>-<slug>.md`, one file per decision. A merged
decision file is never edited; a later one amends or supersedes it.

**Why.** One file per decision means two branches never edit the same file, and a reader lists the
folder instead of searching a 1,500-line log.

**Cost.** Older text that cites line numbers in `docs/DECISIONS.md` (R4's and R5's briefs) now
points into the pointer file. The N ids still resolve.
