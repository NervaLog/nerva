---
id: P312
date: 2026-11-11
area: Releases
---

# MATURITY.md's "What was tested" points to the release notes, and holds no figures

- **Decision:** `docs/MATURITY.md`, "What was tested for this release", says what a release's
  testing covers and links the "What was tested" subsection of that release's section in
  `CHANGELOG.md`. The soak line, the Jepsen result, the two review verdicts, the release audit and
  the macOS run are written once, in the CHANGELOG section, which `release.yml` publishes as the
  GitHub release notes.
- **Why:** the figures are known only at release, from the release commit. Written in two places,
  one copy goes stale or disagrees, and MATURITY.md on `main` would describe a commit that is not
  the release. The release notes are the record a user of the release reads, and they are tied to
  its tag.
- **What it costs:** MATURITY.md alone does not show the figures; a reader follows one link. The
  link names v0.7.1 and the anchor `#what-was-tested` reaches the newest section's subsection, so
  each release updates the sentence that names it.
