---
id: P404
date: 2026-11-13
area: Releases
---

# `PACKAGES_BASE_URL` is a repository variable, not the `package-repos` environment's

**Decision.** Setup step 6 sets `PACKAGES_BASE_URL` with `gh variable set ... --repo NervaLog/nerva`,
without `--env package-repos`, and the check in step 10 reads it among the repository's variables.
If an earlier setup put it on the environment, it is deleted there, so the two cannot disagree.
`repos-verify` no longer falls back to a built-in URL: an empty value refuses with NRV-E1139.

**Reason.** Three jobs read the URL and have no environment: `ci.yml`'s `repos-fresh`, the daily
watch in `package-repos-watch.yml`, and `release-finish.yml`'s `repos-verify`. An environment's
variables reach only jobs that declare that environment, so with the URL on `package-repos` the
first two refused NRV-E1139 on every run once `REPOS_LIVE` was set (and never made the freshness
check they exist for), and the third silently installed from the default host whatever the
publish had written to. Declaring `environment: package-repos` on them would hand them the
environment's secrets and its main-only deployment rule, which they do not need; a constant in each
workflow would put the host in four places. A repository variable is the smallest change to the
spec's setup: the jobs that run in the environment still read the same name.

**Cost.** One more repository-level variable, readable by every workflow in the repository. It is
a public URL, not a secret.
