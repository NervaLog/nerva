---
id: P312b
date: 2026-11-11
area: Releases
---

# A release's CHANGELOG section links documents by absolute GitHub URLs

- **Decision:** links in a release's section of `CHANGELOG.md` to files in this repository are
  absolute `https://github.com/NervaLog/nerva/blob/main/...` URLs, not paths relative to the
  repository.
- **Why:** the section is published unchanged as the GitHub release notes, where a relative path
  resolves against the releases page and breaks.
- **What it costs:** the links follow `main`, not the tag, so a page may have moved on since the
  release. Issue and pull request references (`#291`) need no URL: GitHub links them in both places.
