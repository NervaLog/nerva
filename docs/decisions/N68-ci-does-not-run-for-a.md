---
id: N68
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# CI does not run for a change to Markdown alone.


A push or pull request whose every changed file is Markdown (the README, WORKLOG, DECISIONS,
CHANGELOG, docs/) starts no CI run: `ci.yml` has `paths-ignore: ['**.md']` on both. No code or
test reads a Markdown file, so such a run could only repeat the last result, in nine jobs for
about five minutes. No check is required on `main` (the repository's plan has no branch
protection), so a run that never starts blocks no merge. A release still runs CI first:
`release.yml` calls `ci.yml`, and a call is not filtered by paths. If a test ever reads a
Markdown file, it must be added back to the filter.
