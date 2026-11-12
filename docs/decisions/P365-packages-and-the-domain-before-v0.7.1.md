---
id: P365
date: 2026-11-12
area: Releases
amends: P360, P148, P364
---

# Signed apt and dnf repositories, and the site at nerva.pro, ship in v0.7.1

**The owner's decisions (owner, 2026-11-12).**

- The apt and dnf repositories (P360 point 10) move from v0.7.2 to v0.7.1. They are the last
  change before the tag, and the freeze holds: nothing in `src/` or `build.zig`.
- The domain is `nerva.pro`.
- Release candidates are published, in a separate `rc` channel. `stable` holds releases only.
- v0.7.1 waits for the package rehearsal.
- Workers Paid is bought only if the free quota is hit. (With the design below no Worker serves
  anything, so there is no quota to hit.)

**The owner's later decisions (owner, 2026-11-12, after the first rework).**

- Cloudflare owns the site's deploy: Cloudflare Pages builds and deploys the site repository's
  `main` through its Git integration, and GitHub Pages is turned off. Cloudflare's GitHub App is
  installed on the site repository only. No Cloudflare token for the site is in GitHub; the only
  Cloudflare credential in GitHub is the R2 token in `package-repos`.
- `nerva.pro` is the Pages project's custom domain. `site-check` and the ruleset still gate the
  site's `main`.

**Decision.** The design is `docs/releases/packages.md`. In short:

1. **The site is built and deployed by Cloudflare Pages, at `https://nerva.pro/` (amends P148).**
   The project `nerva-site` builds the site repository's `main`; a merge is still a deploy. The
   release pull request flow does not change; P364's "published" now means that Cloudflare
   deployed the merge (amends P364). `www.nerva.pro` is a 301 to the apex by a Cloudflare redirect
   rule. GitHub Pages is off, and `https://nervalog.github.io/` answers 404: a redirect would need
   Pages kept on or the site repository renamed, for few inbound links.
2. **The Pages build command is the gate.** Set in the dashboard, where no pull request can change
   it, it refuses `functions/`, `_worker.js`, `_routes.json` and `wrangler.*`, and every package
   manifest, lock file and version file that would make Cloudflare install dependencies before
   the command runs (NRV-E1152). The project sets `SKIP_DEPENDENCY_INSTALL` to `1`, and the
   command refuses to run without it. It copies `index.html` alone into the output directory. So a site merge cannot run code on
   Cloudflare or bind the bucket. Preview deployments are on for pull requests, with the same
   gate, and Cloudflare's check is not required.
3. **Nothing the packages' trust depends on is in the site repository.** The public key and the
   pinned fingerprints are `packaging/keys/` in this repository, with the code that writes and
   checks the repositories, under the guard that protects the release workflows. The site's
   code-owner rule, which owned nothing and could never be met, is turned off, and its CODEOWNERS
   file is removed.
4. **The repositories are the R2 bucket `nerva-packages`, served read-only by R2's public custom
   domain `packages.nerva.pro`.** No Worker or Function is in the path. Each dnf channel has its
   own copy of its rpms.
5. **Bucket locks make packages, manifests and lock objects permanent.** Five lock rules with
   indefinite retention cover `apt/pool/`, `rpm/stable/packages/`, `rpm/rc/packages/`,
   `manifest/` and `lock/`. The bucket token is "Object Read & Write" and cannot change them.
   Every write run probes that they hold (NRV-E1149).
6. **The manifest is a locked series.** Each write is a new `manifest/<generation>.asc`, written
   if absent, with its generation inside; the highest generation that verifies is current, so it
   cannot be rolled back, and an object that does not verify is ignored. It is verified only
   against the keys `packaging/keys/fingerprints` pins, parsed strictly (one signed block, one
   valid signature, only `gpgv`'s output). It records the SHA-256 of every index file a run
   writes (`index`) and of the accepted hash it replaced (`index-was`), and its state: a run
   writes `writing` before it uploads the indexes and `complete` after they are served. After a
   `complete` manifest only `index` hashes are accepted. An index that matches neither is
   rewritten, then the run ends red (NRV-E1142).
7. **New package content is bound to the approved run attempt, while the release is a draft.**
   `repos-ready` binds the draft's four packages only if the release reads `draft: true` when it
   checks (NRV-E1148 otherwise), and only in the run attempt of the `mac` job the owner approved
   (NRV-E1153 otherwise: `mac` outputs its attempt). A failed `repos-ready` is retried with
   "Re-run all jobs", which asks for the approval again. `repos` signs only bytes equal to that binding or to an entry of
   the signed manifest. A dispatch, a "Re-run all jobs" or the refresh binds nothing new.
8. **`repos` waits for the publication, not for `publish`'s success.** `publish` gains the output
   `public`, read from the release after the publish step under `if: always()`; `repos` runs when
   it is `true`, even if the tap or the site failed afterwards. The recovery, "Re-run failed jobs",
   is open for GitHub's 30 days.
9. **Writes converge, and runs queue on a lock in the bucket, never cancel** (NRV-E1147). Every
   package object is listed as `pending` in a signed manifest before it is written. The lock
   search starts from the `lock` line of the current manifest. A lock is stale 100 minutes after
   its time, longer than the jobs' 90-minute timeout, a lock time in the future is ignored, and a
   holder checks before every write that no newer lock exists. A `pending` entry whose release is
   gone is marked `abandoned` and never served (NRV-E1154).
10. **apt's `Release` carries `Valid-Until`, 21 days on, and a weekly workflow re-signs.** Against
    GitHub's 60-day disabling of schedules, the refresh fails from day 45 without a commit, and a
    `repos-fresh` job in `ci.yml` (pushes to `main` only, not required) fails when `Valid-Until`
    is within 7 days (NRV-E1150).
11. **Four jobs in `release-finish.yml` (amends P360 point 10, which planned one):** `repos-ready`,
    `repos`, `repos-verify` in the environment `package-repos` (only `main`, no reviewer, no admin
    bypass), and `site-verify`, which polls `nerva.pro` for the release for 15 minutes
    (NRV-E1151). The release stays one approval. `repos-verify` runs INSTALL.md's commands on
    Debian 12 and 13, Ubuntu 22.04 and 24.04, Rocky 9 and Fedora 43 and 44 (dnf5 with the fix
    for the key-import hang, no `rpm --import`), and Fedora 45 if it is out by slice 4, on amd64
    and arm64. Fedora 41 and 42 are past their end of life and are not supported.
12. **One OpenPGP key, RSA 4096, sign-only, SHA-512, no expiry, no subkeys.** Its secret part and
    passphrase are in `package-repos` only. Rotation every two years: during the overlap apt's
    metadata is signed by both keys, and `previous` stays for good.
13. NRV-E1139 to NRV-E1157 are reserved for these failures (the spec first took E1139 to E1148,
    then E1152).
14. **Junk written by a token holder is tolerated, not fatal.** An object under a locked prefix
    that no manifest lists is noted and skipped, and the run finishes, then ends red (NRV-E1142);
    only junk at a name the run must write stops it. The owner removes junk with the spec's
    procedure "Removing an object from a locked prefix": rotate the token, lift that one lock rule,
    delete, restore the rule, check the audit log.

**Reason.**

- Users get `apt install nerva` and `dnf install nerva`, and later upgrades, from v0.7.1.
- One guard, merging to Nerva's `main`, already protects the release workflows and the signing
  environments. Putting the key, the fingerprints and the writer behind it adds no second target.
  The site repository is merged by bots and needs no security role.
- Cloudflare deploying the site keeps the domain, the site and the packages in one account,
  without a Cloudflare token in GitHub for the site. The build gate takes away the one way a site
  merge could reach Cloudflare resources.
- R2's public custom domain has no write path and no code. The locks take deletion and
  replacement away from the token, so rollback and freeze need no outside anchor.
- Binding to the approved run while the release is a draft is the only fixed record of what the
  owner approved.
- The `rc` channel lets the rehearsal run every write, signature and install check against the
  real bucket and host before v0.7.1.

**Cost.**

- **More moving parts at the release.** A Cloudflare zone, a Pages project, a bucket with locks,
  a weekly workflow, a CI job, and a key whose custody is the owner's.
- **The site's gate lives in a dashboard.** Adding a file to the site means the owner extends the
  build command. If Cloudflare starts reading a config file under a new name, a site merge could
  gain the bucket token's power until the command is extended.
- **`https://nervalog.github.io/` breaks,** bookmarks and outside links included.
- **`repos-ready` blocks the release on a bucket fault.** With R2 down or an object planted, the
  GitHub release, the tap and the site wait too, though they do not depend on the packages.
- **Failures land after the release is public.** The fix is "Re-run failed jobs" of the same run,
  within 30 days. After that, an unbound release needs a new decision; its files install by hand.
- **A failed `repos-ready` costs a second approval.** "Re-run failed jobs" would bind from an
  attempt the owner did not approve, so it is refused; only "Re-run all jobs" binds.
- **Nothing in the bucket can be deleted by a run.** Candidates' packages (abandoned ones
  included), every manifest and every lock object stay for good. Above 2,000 entries or 4 GiB
  (about 100 releases) the job refuses and a pruning decision is needed.
- **Each run's work grows with the bucket.** It checks every listed object (by HEAD) and
  downloads every package to rebuild the indexes. Up to the bound that is minutes and a few GiB
  of runner disk, which the run checks first (NRV-E1156). Incremental indexes were not chosen:
  they would add state that can drift from the manifest.
- **The R2 token can still deny service, but cannot get anything installed that the key did not
  sign.** It can delete or replace index files, which the next write run repairs and reports. It
  can replay an older signed index set, which apt's `Valid-Until` bounds and dnf does not, until
  the next write run (at most a week), which notices it. It can plant junk under a locked prefix
  that only the owner can remove, which makes every run end red until the owner does, and it can
  write lock objects that hold the writers off for up to 100 minutes at a time.
- **The lock refusal's exact status is confirmed only at the rehearsal.** `probe-locked` pins it
  from Cloudflare's documentation and fails closed on any other answer.
- **Two copies of each release's rpm** (about 14 MB), to keep dnf paths physical.
- **A short window for dnf** between `repomd.xml` and its signature.
- **Two failed refreshes in a row,** or a quiet repository ignored past day 60, break `apt update`
  for everyone after `Valid-Until`.
- **dnf 5 on Fedora 43 and 44 needs a recent dnf5** for `repo_gpgcheck`; the fallback,
  `repo_gpgcheck=0`, keeps per-rpm signatures but loses signed metadata.
- **A key rotation breaks apt users who never fetch the key again,** at the end of the overlap.
  Shipping the key in a package is the fix, a decision for before the first rotation.
- **A key compromise needs a new decision,** because locked rpms cannot be re-signed.
- **The bucket is public,** manifests and locks included; they hold only what releases and runs
  already show.
- **Not exercised before v0.7.1.** The first write to `stable` and `site-verify` run for the first
  time on v0.7.1 itself.
