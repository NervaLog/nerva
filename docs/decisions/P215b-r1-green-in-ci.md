---
id: P215b
date: 2026-11-06
area: Releases
---

# R1's "green in CI" is the host's commit status, with a hosted-runner workflow for slices

The decision: a night is green when the host posts the commit status `jepsen/nightly` =
`success` on the `main` commit it tested; R1's "green for 7 nights" is seven consecutive such
statuses. Before the host exists, and for every slice, `.github/workflows/jepsen.yml` runs the
real suite on GitHub's hosted `ubuntu-24.04` runner (5 nodes in Docker, runs of up to 20 minutes),
started by a push to a scratch branch `jepsen/<slice>-<slug>` or by `workflow_dispatch`, and the
teeth build runs there too. A hosted run never files an issue.

The reason: CLAUDE.md delivers a milestone only on a demo green in CI. The repository is public,
so the host cannot be a self-hosted runner (P147e); a commit status from the host is the record
GitHub shows beside the commit. The hosted runner lets slices 2 to 6 run Jepsen for real before
the host is provisioned, as Zigbox's `vm/*` branches do.

What it costs: two places run the same suite with different limits (16 GB and 20 minutes on the
hosted runner), so a run can pass on one and fail on the other; the host's verdict is the one
that counts. The host's token gains Commit statuses write.
