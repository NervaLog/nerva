---
id: P343
date: 2026-11-11
area: Releases
amends: P284, P311, P325
---

# The Developer ID signature and the notarization run in CI, behind an environment the owner approves

**Decision.** The owner's decision, "Mac signing in CI for v0.7.1, on 2026-11-11": the universal
macOS zip is signed with the Developer ID Application certificate and notarized in
`mac-sign.yml`, on a hosted `macos-15` runner, by the same `zig build -Drelease mac-release
-Dnotarize=true` the owner ran on their Mac. P284's "CI holds no Apple secret" and P311's and
P325's "only on the owner's Mac" are amended as follows.

1. The Apple secrets live only in the GitHub environment `apple-signing` (`APPLE_DEVELOPER_ID_P12`,
   `APPLE_DEVELOPER_ID_P12_PASSWORD`, `APPLE_NOTARY_KEY_P8`, `APPLE_NOTARY_KEY_ID`,
   `APPLE_NOTARY_ISSUER_ID`). The environment requires the owner's approval of every run, accepts
   only `main`, and does not let administrators bypass it. No repository-level Apple secret
   exists, and `ci.yml` and every pull request's run hold none.
2. The secrets are given only to the step that runs `.github/scripts/mac_keychain.sh create`: a
   temporary keychain with a random password, which holds the identity and the notary profile
   `nerva-notary`, is first in the user search list and is the default, so `mac-release` needs no
   change. `destroy` removes it under `if: always()`. The job uses no cache, and pins every
   action by full commit SHA.
3. The job signs the commit the draft targets, never the workflow's ref, and only a draft.
4. `ci.yml`'s `mac-keychain` job tries the keychain mechanics on every pull request with a
   self-signed test certificate and no secret. The Developer ID chain and the notary profile are
   tried only by the rehearsal on a prerelease, before the real tag.
5. The owner's Mac stays a documented fallback (P311's block) when the notary service or the
   runner fails on release day. `mac-release` is unchanged.
6. New codes NRV-E1119 to NRV-E1123 (`docs/ERRORS.md`).
7. The owner's answers of 2026-11-11. (a) The CI signing change after candidate 5d7d806 does not
   restart the 24-hour soak or the two release reviews: one focused Opus review covers the new
   workflows as part of the release diff. (b) The rehearsal is approved, as `v0.7.1-rc.2` (an
   `rc.1` draft still exists), from a branch that is never merged and that the owner deletes
   afterwards. (c) CI uses a separate Developer ID Application certificate, not the laptop's.
   (d) CODEOWNERS for `.github/workflows/`: "yes, but pending". The owner said yes and has not yet
   settled the details (who is listed), so no CODEOWNERS file is added by this change, and the
   pull request that adds it waits for the owner.

**Reason.** The release should not depend on one person's laptop, and a signing step that runs
from a reviewed workflow, behind a human approval, is repeatable. The key never reaches a pull
request, a fork or an unapproved run.

**Cost.** Apple's signing key and notary key are stored in GitHub, and a workflow change that
names `apple-signing` is a way to use them (the owner's approval of the deployment is meant as the guard; see the open item below).
The release commit gains a `.github/` change after the release reviews have begun. The Developer
ID certificate for CI is separate from the owner's own, so it can be revoked alone.

**Open item for the owner (not solved by this decision).** The required-reviewer approval on
`apple-signing` is not a human gate today. Sessions in this repository authenticate to GitHub as
the owner's account, `topwombat`, which is also the environment's required reviewer, and "Prevent
self-review" is off. A session holding that token can approve a waiting `mac-sign` deployment
through the API (`POST /repos/NervaLog/nerva/actions/runs/{id}/pending_deployments`) with no
human involved. Because `mac-sign.yml` runs `mac_keychain.sh` from the draft's target, which for a
prerelease may be any branch, an unattended session could then reach the Developer ID key. The
owner must choose before the rehearsal: (a) a separate bot account for sessions, with the owner's
account the only reviewer; or (b) enable "Prevent self-review" on the environment together with a
second reviewer. Until then the guard is the owner's attention, not a technical barrier, and
nothing in this decision should be read as saying otherwise.
