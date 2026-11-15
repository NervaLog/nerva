---
id: P459
date: 2026-11-14
area: Releases
amends: P362
---

# The two calls in the release chain pass `secrets: inherit`

**Decision.** `release.yml`'s `finish` job calls `release-finish.yml`, and `release-finish.yml`'s
`mac` job calls `mac-sign.yml`, each with `secrets: inherit`. No other job inherits secrets, and
`test_release_finish.py` holds both calls to that.

**Reason.** A called workflow sees no secret unless its caller passes it, one level down at a time,
and this includes the secrets of the environment its own job names. Without inherit, every `APPLE_*`
secret was empty in `mac-sign.yml` when `release-finish.yml` called it, although `apple-signing`
held them and the owner had approved the run. v0.7.1's signing failed with NRV-E1121 twice for this
reason (run 43640702787). The same gap would empty the R2, package-signing and release-app secrets
when `release.yml` calls `release-finish.yml`. #362 forbade inherited secrets (in its test and a
comment in `release.yml`; the decision P362 itself does not mention secrets). That rule could only
work when `mac-sign.yml` is dispatched directly, which is the one path the chain never takes.

**Cost.** The called workflows can read every repository and organization secret, not only the ones
their jobs name. All three workflows are in this repository and run only from `main`, behind the
environments' own approvals and branch rules, so they gain no reach that an edit to them does not
already have. Passing each secret by name would be narrower, and GitHub allows it even for a secret
that exists only in the called job's environment. It was not chosen because the chain is two levels
deep, so eleven names would have to be kept in step across three files, and a name that is missed
fails in exactly the way this decision fixes: as an empty secret, at the owner's approval, during a
release.
