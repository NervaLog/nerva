---
id: P365
date: 2026-11-12
area: Releases
amends: P360, P148
---

# Signed apt and dnf repositories, and the site on its own domain, ship in v0.7.1

**Decision.** The owner decided on 2026-11-12 to move the apt and dnf repositories (P360 point 10)
from v0.7.2 to v0.7.1. They are the last change before the tag, and the freeze holds: nothing in
`src/` or `build.zig`. The design is `docs/releases/packages.md`. In short:

1. **The site moves to `https://<domain>/` on Cloudflare (amends P148).** A Cloudflare Pages
   project builds `NervaLog/nervalog.github.io`'s `main` through Git integration, with no build
   step and no preview deployments. A merge to `main` is still a deploy, and the release pull
   request flow (the App, `site-check`, the ruleset, auto-merge) is unchanged. GitHub Pages stops
   serving `main` and serves an orphan branch, `github-pages-redirect`, whose page sends visitors
   to the new address and keeps the `#section`.
2. **The repositories are in an R2 bucket, `nerva-packages`, served at `/apt` and `/rpm` by a
   Pages Function in the site repository.** The function has a read-only R2 binding, serves GET and
   HEAD on the layout's names only, and refuses anything else with NRV-E1147. The alternative,
   static files in a Pages deployment, was rejected for these reasons: its 25 MiB a file and
   20,000 files a deployment limits; every deployment replaces the whole tree; its token covers
   every Pages project of the account; and it would end "Pages builds `main`".
3. **Three jobs in `release-finish.yml` (amends P360 point 10, which planned one):**
   - `repos-ready` runs before `publish` and refuses without writing.
   - `repos` runs after `publish`. It adds the release's packages to the pool only if they are
     absent, signs the rpms, and regenerates every channel's metadata from the whole pool.
   - `repos-verify` has no secret. It installs from the domain on Debian, Ubuntu, Rocky and
     Fedora, on amd64 and arm64.
   - They run in their own environment, `package-repos`, which only `main` can deploy and which
     has no reviewer. It holds an R2 token for one bucket (Object Read & Write) and the signing
     key. The release stays one approval, `apple-signing`.
4. **Published packages are never replaced.** A signed manifest of the pool is the authority. A
   name already published with other content is refused (NRV-E1141). An object that the manifest
   does not list is refused (NRV-E1142), so a leaked bucket token cannot get a file signed. A
   failed run is re-run, and it converges.
5. **Prereleases go to a separate `rc` channel.** `stable` holds releases only. `rc` holds
   releases and candidates, and both share one pool. The function refuses a candidate's file under
   `stable`.
6. **One OpenPGP key, RSA 4096, sign-only, no expiry, no subkeys.**
   - The owner makes it in a throwaway keyring.
   - Its secret part and passphrase are in `package-repos` only. They are never in an argv or the
     log.
   - Its public part is `keys/nerva-release.asc` in the site repository, and its fingerprint is in
     INSTALL.md.
   - It is rotated every two years, with both keys published for one release.
   - The release's own assets stay unsigned (P295). The repository's rpms are signed copies, and
     its debs are the release's files.
7. NRV-E1139 to NRV-E1147 are reserved for these failures.

**Reason.**

- Users get `apt install nerva` and `dnf install nerva`, and later upgrades, from v0.7.1.
- R2 gives a credential for one bucket, write-once objects, and no egress fee.
- Serving through a function in the site repository keeps the routing and its code under the
  site's review, with no second deploy path.
- The `rc` channel lets the rc.2 rehearsal run every write, signature and install check against
  the real bucket and domain before v0.7.1, without touching `stable`.

**Cost.**

- **More moving parts at the release.** A Cloudflare account, a bucket, a Pages project, a
  domain, and a key whose custody is the owner's.
- **Failures land after the release is public.** A failure in `repos` or `repos-verify` happens
  then. The fix is a re-run or a dispatch, with no approval (P362 point 10).
- **A short window for dnf.** A client can read `repomd.xml` and `repomd.xml.asc` from two
  different runs, and fails once.
- **Request quota.** The function's requests count against Workers' free 100,000 a day.
- **The R2 token can delete.** R2 has no write-only grant.
- **No `Valid-Until`,** so a replayed old `InRelease` is not caught.
- **Candidates' packages stay in the pool for good.**
- **A key compromise needs a new decision,** because the pool's signed rpms cannot be re-signed
  in place.
- **Not exercised before v0.7.1.** The first write to `stable`, and the push-triggered path, run
  for the first time on v0.7.1 itself.
