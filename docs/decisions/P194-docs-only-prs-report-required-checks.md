---
id: P194
date: 2026-11-06
area: "Milestone 3: positioned reads and the first views"
amends: N68
---

# A docs-only pull request reports every required check.

**Decision.** `ci.yml` no longer has `paths-ignore` on `pull_request` (it keeps it on `push`, so
Markdown pushed to `main` still starts nothing). A `changes` job lists the pull request's files
(`gh api .../pulls/<n>/files --paginate`) and `.github/scripts/docs_only.sh` prints `code=false`
only when every file ends in `.md` and none is read by a build or test (today `docs/ERRORS.md`,
read by three unit tests, and `UPSTREAM.md`, read by the bill-of-materials script). Every other job
`needs: changes` and still runs; each of its steps has `if: needs.changes.outputs.code == 'true'`,
so a docs-only pull request reports all nine required checks green in seconds. It fails closed:
if the listing fails, is empty, or is truncated (3000 files), `code=true`. `release.yml`'s `ci`
call grants `pull-requests: read`, which a called workflow needs for the `changes` job.

**Reason.** N68 assumed no check was required on `main`. The ruleset now requires nine, so a
Markdown-only pull request never started them and could not merge (#191). A job-level `if` would
not do: a skipped matrix job reports under its bare name, so `vopr (1)` and the other required
names would never appear.

**Cost.** A docs-only pull request starts about nine short jobs (checkout, one API call). A new
Markdown file that a test reads must be added to `docs_only.sh` (its header says how to find them).

**Owner, 2026-11-06.** A docs-only pull request may always auto-merge, without waiting for an Opus
review (amends P188).

**Status commits.** A status-only commit made on a pull request must not carry `[skip ci]`: that
skips the required checks and blocks the merge. A push to `main` of Markdown alone still starts
nothing.
