---
id: P365
date: 2026-11-12
area: Releases
amends: P360, P148
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

**Decision.** The design is `docs/releases/packages.md`. In short:

1. **The site stays on GitHub Pages, at `https://nerva.pro/` (amends P148).** The site repository's
   `main` is still served by GitHub Pages and a merge is still a deploy, now under the custom
   domain `nerva.pro`, verified for the organisation. GitHub answers `https://nervalog.github.io/`
   with a 301 to the new address. The release pull request flow does not change. `nerva.pro`'s DNS
   is a Cloudflare zone, with the site's records DNS only.
2. **Nothing the packages' trust depends on is in the site repository.** The public key and the
   pinned fingerprints are `packaging/keys/` in this repository, and the code that writes and
   checks the repositories is here too, under the guard that already protects the release
   workflows. The site page carries no key or repository line and links to INSTALL.md. Someone who
   can merge to the site can change the page, nothing else. The site's code-owner rule, which
   could never be met by the App or by `topwombat` on their own pull requests and which owned
   nothing, is turned off, and its CODEOWNERS file is removed.
3. **The repositories are the R2 bucket `nerva-packages`, served by R2's public access through
   the custom domain `packages.nerva.pro`.** Public access is read-only by construction: it serves
   GET and HEAD of stored objects, with the `Content-Type` and `Cache-Control` the job stored. No
   Worker or Pages Function is in the path. There is no read-only R2 binding, and a Pages project
   built from the site repository could bind the bucket through a `wrangler.toml` in it, so the
   first draft's Pages Function was dropped. Each dnf channel has its own physical copy of its
   rpms, so no path needs mapping.
4. **The manifest's signature is pinned.** `manifest/pool.asc` is verified only against the keys
   in `packaging/keys/nerva-release.asc` whose fingerprints `packaging/keys/fingerprints` lists.
   The signing key's fingerprint must be the `current` one. Nothing read from the bucket, the site
   or the network is a trusted key.
5. **New package content is bound to the approved run.** `repos-ready`, after the owner approves
   `mac` and before `publish`, reads the four packages' digests from the draft (`bound`). `repos`
   lists and signs only bytes equal to `bound`, or bytes equal to an entry already in the signed
   manifest. A dispatch, a "Re-run all jobs" or the weekly refresh binds nothing new: it finishes
   pending entries and re-signs indexes. Mutable release assets therefore cannot get new content
   signed (NRV-E1148). Older releases are not backfilled.
6. **Writes are ordered so that re-runs converge.** Every package object is listed as `pending` in
   a signed manifest before it is written, put only if absent, compared before it is adopted, then
   promoted to `published`; indexes are regenerated from the published entries, `InRelease` and
   `repomd.xml` last. A crash at any step leaves a bucket the next write run accepts. Published
   package objects are never replaced or deleted (NRV-E1141, NRV-E1142).
7. **Write runs queue on a lock in the bucket, never cancel.** `repos` has no concurrency group.
   The lock is a sequence of write-if-absent objects `lock/<generation>`, with a 60-minute stale
   takeover and a 45-minute holder deadline (NRV-E1147).
8. **apt's `Release` carries `Valid-Until`, 21 days on,** and a weekly workflow,
   `package-repos-refresh.yml`, re-signs both channels without a release.
9. **Channels are told apart where apt checks.** `stable` and `rc` have their own Label, Suite and
   Codename (`nerva-stable`, `nerva-rc`), so apt on a host that has read `stable` refuses a copied
   `rc` `InRelease`. dnf's `stable` directory never holds a candidate's file.
10. **Three jobs in `release-finish.yml` (amends P360 point 10, which planned one),** `repos-ready`,
    `repos`, `repos-verify`, in their own environment, `package-repos`, which only `main` can
    deploy and which has no reviewer. It holds an R2 token for one bucket and the signing key. The
    release stays one approval, `apple-signing`. `repos-verify` installs on Debian 12 and 13,
    Ubuntu 24.04, Rocky 9 and Fedora 43, on amd64 and arm64.
11. **One OpenPGP key, RSA 4096, sign-only, SHA-512, no expiry, no subkeys,** made by the owner in
    a throwaway keyring, its secret part and passphrase in `package-repos` only, never in an argv
    or the log. Rotation every two years, through `next` and `previous` in `fingerprints`. The
    release's own assets stay unsigned (P295); the repository's rpms are signed copies, its debs
    the release's files.
12. NRV-E1139 to NRV-E1148 are reserved for these failures.

**Reason.**

- Users get `apt install nerva` and `dnf install nerva`, and later upgrades, from v0.7.1.
- One guard, merging to Nerva's `main`, already protects the release workflows and the signing
  environments; putting the key, the fingerprints and the serving decision behind it adds no
  second place an attacker could aim at. The site repository is merged by bots and needs no
  security role.
- R2's public custom domain has no write path and no code, so no merge anywhere can turn the
  reader into a writer. R2 gives a credential for one bucket, write-if-absent puts and no egress
  fee.
- Binding to the approved run, not to release assets, is the only fixed record of what the owner
  approved.
- The `rc` channel lets the rehearsal run every write, signature and install check against the
  real bucket and host before v0.7.1, without touching `stable`.

**Cost.**

- **More moving parts at the release.** A Cloudflare zone, a bucket and its public host, a weekly
  workflow, and a key whose custody is the owner's.
- **Failures land after the release is public.** A failure in `repos` or `repos-verify` happens
  then; the fix is "Re-run failed jobs" of the same run. A release whose approved run never wrote
  its entries cannot be added later without a new decision.
- **Two copies of each release's rpm** (about 14 MB), to keep dnf paths physical.
- **A short window for dnf.** A client can read `repomd.xml` and `repomd.xml.asc` from two runs,
  and fails once.
- **dnf has no signed expiry,** so a replayed `repomd.xml` works until the next write run (at most
  a week); apt's is bounded by `Valid-Until`. A cached apt host refuses a channel swap; a fresh one
  only warns, and dnf does not check.
- **Two failed refreshes in a row** before `Valid-Until` runs out break `apt update` for everyone.
- **The R2 token can delete.** R2 has no write-only grant; deletion is a denial of service the
  next run reports.
- **The bucket is public,** manifest and lock included; they hold only what releases and runs
  already show.
- **Candidates' packages stay in the bucket for good.**
- **A key compromise needs a new decision,** because signed rpms cannot be re-signed in place.
- **Not exercised before v0.7.1.** The first write to `stable` runs for the first time on v0.7.1
  itself.
