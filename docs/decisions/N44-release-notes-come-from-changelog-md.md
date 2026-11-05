---
id: N44
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Release notes come from `CHANGELOG.md`.

The release notes said only "Changes: WORKLOG.md", a log of work rather than what a user needs.
Each release now has a "what's new" section in `CHANGELOG.md` (`## v<VERSION> — <date>`):
new capabilities with examples, fixes with their issues, and upgrade steps. `release.yml`
publishes that section as the GitHub release notes (`.github/scripts/release_notes.sh`), and
refuses, before CI runs, to release a version without one. v0.1.0's section was written after
the fact, for completeness.
