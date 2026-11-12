# The domain, and the apt and dnf repositories: spec, setup, slices

Status: spec, 2026-11-12 (P365, which amends P360 point 10 and P148). Nothing here is built
yet. It is the last change before the v0.7.1 tag: the owner moved the repositories from v0.7.2 to
v0.7.1 on 2026-11-12. The domain is not named yet, so this document writes `<domain>`
throughout. Slice 6 replaces it once the owner names it.

The freeze holds. Nothing here touches `src/` or `build.zig`. The change is workflows, scripts,
documents, the site repository and Cloudflare settings. No new dependency enters the Zig build.

## Goal

1. Nerva's site moves from `https://nervalog.github.io/` to `https://<domain>/` on Cloudflare.
   It is still the one page `index.html` in `NervaLog/nervalog.github.io`, and a merge to its
   `main` is still a deploy. The release pull request flow (the App, `site-check`, the ruleset,
   auto-merge) does not change.
2. The same domain serves signed apt and dnf repositories of every release. A user installs with
   `apt install nerva` or `dnf install nerva`, and later upgrades with `apt upgrade` or
   `dnf upgrade`.
3. The release is still one approval: the owner approves `mac` in `apple-signing`, and
   everything after it, the repositories included, runs without anyone. Nothing is published by
   hand afterwards.

## Architecture

### The domain's layout

```
https://<domain>/                              index.html: Cloudflare Pages, built from the site repository's main
https://<domain>/keys/nerva-release.asc        the repository key (public, armored): a file in the site repository
https://<domain>/apt/...                       the apt repository     ┐ a Pages Function in the site repository
https://<domain>/rpm/...                       the dnf repository     ┘ reads them from the R2 bucket nerva-packages
https://nervalog.github.io/                    GitHub Pages: a page that sends the browser to https://<domain>/
```

There is one Cloudflare Pages project, `nerva-site`, connected to `NervaLog/nervalog.github.io`
through Cloudflare's Git integration. It has no build command: Pages publishes the repository
root as it is. Its `functions/[[path]].js` is a Pages Function, which is a Worker deployed with
the page, and `_routes.json` runs it on `/apt/*` and `/rpm/*` only. Every other path is a static
file and never runs code. The function has one binding, the R2 bucket `nerva-packages`, from
which it only reads.

### The bucket

```
nerva-packages/
  apt/pool/main/n/nerva/nerva_<filever>-1_<amd64|arm64>.deb                  immutable, the release's own file
  apt/dists/<stable|rc>/InRelease, Release, Release.gpg                      replaced by each run (signed)
  apt/dists/<stable|rc>/main/binary-<amd64|arm64>/Packages, Packages.gz      replaced by each run
  apt/dists/<stable|rc>/main/binary-<amd64|arm64>/by-hash/SHA256/<hex>       immutable (Acquire-By-Hash)
  rpm/pool/nerva-<filever>-1.<x86_64|aarch64>.rpm                            immutable, signed copy of the release's file
  rpm/<stable|rc>/repodata/<hex>-<primary|filelists|other>.xml.gz            immutable (unique names)
  rpm/<stable|rc>/repodata/repomd.xml, repomd.xml.asc                        replaced by each run (signed)
  manifest/pool.asc                                                          replaced by each run (clearsigned)
```

`<filever>` is the version in the release's file names (`0.7.1`, or `0.7.1.rc.2` for a candidate,
P311). The version inside each package keeps `~` (`0.7.1~rc.2`), so a candidate sorts before its
release in both apt and dnf.

The function maps `/rpm/<channel>/packages/<file>` to `rpm/pool/<file>`, so each rpm is stored
once and both channels list it. It serves only names that match the layout above. For any other
path it answers 404, and for any method but GET and HEAD it answers 405. Either answer has the
one-line body `error[NRV-E1147]: <domain>: <what>`. It never lists a directory. It refuses a
candidate's file (a name holding `.rc.`) under `stable`. It sets `Content-Type` and `ETag`, and
honours `Range` and `If-None-Match` (R2's `get` with `range` and `onlyIf`). Immutable names get
`Cache-Control: public, max-age=31536000, immutable`. The names a run replaces get
`Cache-Control: no-cache`. Each response carries `X-Nerva-Packages: 1`, the function's layout
version. The job checks that header, so a function that was not deployed, or differs from the
version this spec describes, fails the run (NRV-E1145) and does not serve wrong paths quietly.

### Channels: prereleases go to `rc`

Each format has two channels, and they share one pool:

| Channel | apt | dnf | Holds |
|---|---|---|---|
| stable | `deb https://<domain>/apt stable main` | `baseurl=https://<domain>/rpm/stable` | releases (`X.Y.Z`) only |
| rc | `deb https://<domain>/apt rc main` | `baseurl=https://<domain>/rpm/rc` | releases and candidates (`X.Y.Z-rc.N`) |

**Why a separate channel, and not "not at all":**

- **The rehearsal needs it.** The rehearsal on `v0.7.1-rc.2` is the gate (P360 point 8), and
  only a candidate can run before v0.7.1. With a channel for candidates, the rehearsal runs every
  write, every signature and every install check against the real bucket, the real function and
  the real domain. Without one, the repositories would first run on the v0.7.1 release.
- **Users cannot reach a candidate by mistake.** `stable` never lists one, and the function
  refuses a candidate's file under `stable`. Someone who opts in to `rc` gets the release too,
  because `0.7.1` sorts after `0.7.1~rc.2`, so `rc` never leaves them behind.
- **It costs almost nothing.** A candidate adds four files (about 24 MB) to the pool. The rpm is
  stored once.

The cost: a candidate's packages stay in the pool even after its GitHub release is deleted, which
is what P343 7b does to `v0.7.1-rc.2` after the rehearsal. They are real builds of `main`'s code
(`publish-ready` ties a candidate's target to `main` plus `VERSION` and `CHANGELOG.md`, P343). A
later candidate takes the next number. If someone tried to publish `v0.7.1-rc.2` again with other
files, the job would refuse it (NRV-E1141).

### Why R2 behind a function, and not Pages

The trees grow with every release, by about 24 MB at today's sizes (two debs of about 5 MB, two
rpms of about 7 MB, taken from `v0.7.1-rc.1`'s assets).

| | R2 behind the site's Pages Function (chosen) | The trees as Pages static files |
|---|---|---|
| Per file | no practical limit | 25 MiB a file. Packages are 5 to 7 MB now, and the binary grows |
| Per deployment | — | 20,000 files, and every deployment carries the whole tree |
| How files get there | one object at a time, written only if absent (`If-None-Match: *`) | each deployment replaces everything. A buggy run that leaves a package out removes it from users |
| Credential | an R2 token for **one bucket**, Object Read & Write | Direct Upload with an API token of "Cloudflare Pages: Edit", which covers **every** Pages project of the account. Or binaries committed to the site repository, which then grows by 24 MB a release, forever, with every page edit redeploying them |
| Site flow | unchanged: Pages still builds the site repository's `main` | needs a second project or Direct Upload, which ends "Pages builds `main`" |
| Atomic update | no. apt is made safe by `InRelease` and `Acquire-By-Hash`; dnf has a short window (below) | yes: a deployment switches at once |
| Request limit | the function's requests count as Workers requests: 100,000 a day free, then error 1027 on `/apt` and `/rpm` only (the page is static and unaffected) until Workers Paid ($5 a month, 10 M a month) | static requests are free and unlimited |
| Cost | storage $0.015 per GB-month after 10 GB free; writes $4.50 per million after 1 M a month free; reads $0.36 per million after 10 M free; no egress fee. Today that is $0 | $0 |

**Failure modes of the choice, and what each does:**

- **R2 or the function is down:** `apt update` and `dnf` fail on `<domain>`. The page and the
  key still load (static), and the GitHub release still carries every package, so INSTALL.md's
  download-and-install path keeps working.
- **The free request quota runs out:** `/apt` and `/rpm` answer error 1027 until midnight UTC.
  The page is unaffected. The fix is Workers Paid (Question 4).
- **Cloudflare's bot protections challenge apt or dnf:** a challenge page is HTML, so apt says
  "Clearsigned file isn't valid" and dnf says "repomd.xml parser error". The setup turns off Bot
  Fight Mode, and the rehearsal's install checks would show the problem.
- **A dnf client that reads during a run:** dnf fetches `repomd.xml` and then `repomd.xml.asc`,
  in two requests. The job writes them back to back, last of all, but a client whose two requests
  fall on either side of that write gets a signature error once, and its next try succeeds. Every
  dnf repository served from plain storage has this window. apt has none: it reads one signed
  `InRelease`, then fetches the indexes by hash, from names that never change.
- **The R2 token leaks:** its holder can add, replace or delete objects in one bucket. It cannot
  sign. apt and dnf refuse metadata that is not signed by the key, and dnf refuses an rpm that is
  not signed by it, so a planted package is not installed. The next run refuses the bucket
  (NRV-E1142) instead of signing what it finds there, because the pool must match the signed
  manifest (below). Deletion is a denial of service. Rebuilding the pool from the GitHub releases
  is then the owner's decision.
- **The signing key leaks:** this is the one compromise that reaches users. See "Rotation and
  compromise".

### The old URL

GitHub Pages stops serving `main`. It serves an orphan branch, `github-pages-redirect`, that holds
`index.html` and `404.html`, which are the same small page, and `.nojekyll`. The page:

```html
<!doctype html>
<meta charset="utf-8">
<title>Nerva has moved</title>
<link rel="canonical" href="https://<domain>/">
<meta http-equiv="refresh" content="0; url=https://<domain>/">
<script>location.replace("https://<domain>/" + location.hash)</script>
<p>Nerva's site is now at <a href="https://<domain>/">https://&lt;domain&gt;/</a>.</p>
```

A browser goes to the new address and keeps the `#section` (the site is one page, so the hash is
the whole deep link). A ruleset protects the branch from force pushes and deletion.

GitHub Pages cannot send a real 301 to a host it does not serve. Setting `<domain>` as the Pages
custom domain would make GitHub send `nervalog.github.io` to it, but then GitHub would treat
`<domain>` as a host it serves, while Cloudflare actually serves it. That is a fragile split, so
it is not used. The repository keeps its name, which the redirect needs.

## The release graph

`release-finish.yml` (P360, P362) gains three jobs:

```
guard ── mac (apple-signing: THE ONE APPROVAL) ── mac-verify ─┬─ repos-ready (package-repos) ─┐
                                                               └───────────────────────────────┴─ publish (release-publish)
                                                                                                    ├─ verify        (brew; unchanged)
                                                                                                    └─ repos (package-repos)
                                                                                                         └─ repos-verify (no environment)
```

- `publish` gains `repos-ready` in its `needs` and its `if`. Everything that can refuse without
  writing still runs before the draft is published (P362 point 8). A setup mistake therefore
  leaves a draft, not a published release with no packages.
- `verify` does not wait for `repos`, and `repos` does not wait for `verify`. Each checks a
  different thing.
- A failure in `repos` or `repos-verify` happens after the release is public. Its fix is "Re-run
  failed jobs", or a dispatch of `release-finish.yml` from `main` with the tag. For a published
  release, that dispatch skips `mac` (P362 point 10), so it needs no approval. The same dispatch
  backfills a release that was published before the repositories existed.

### `repos-ready`

- `needs: [guard, mac, mac-verify]`, with the same `if` as `publish` (mac success or skipped,
  mac-verify success). It runs after the approval, because `release_check.sh publish-ready`
  checks that the draft's target is `main` (or `main` plus `VERSION` and `CHANGELOG.md` for a
  candidate, P343). That check must hold before the key touches a package built from the draft's
  target, and it needs the twelve assets, which exist only after `mac` (P361).
- `runs-on: ubuntu-24.04`, `timeout-minutes: 15`, `environment: package-repos`,
  `permissions: contents: write` (reading a draft's assets needs it, P311), and job-level
  `concurrency: { group: package-repos, cancel-in-progress: false }`.
- Steps:
  1. Check out the workflow's own ref, with `persist-credentials: false`.
  2. `release_check.sh publish-ready "$TAG"`. It is unchanged.
  3. Install the pinned tools (see "Tools").
  4. `package_repos.sh ready "$TAG"`. The environment's secrets and variables reach this step
     only, through `env:`. It writes nothing. It refuses with a code:
     - an environment that lacks a secret or a variable, a key that does not import, a key whose
       fingerprint is not `REPO_SIGNING_FINGERPRINT`, or a key at
       `$PACKAGES_BASE_URL/keys/nerva-release.asc` that does not hold that fingerprint (NRV-E1139);
     - a draft without exactly its four packages, or a package that does not match `SHA256SUMS`
       (NRV-E1140);
     - a package name that is already in the pool with other content. For a deb, other content
       means another SHA-256. For an rpm, it means another NEVRA or payload digest (NRV-E1141);
     - a manifest whose signature is not by a key in the served key file, a pool object that the
       manifest does not list, or a pool over its bound (NRV-E1142);
     - a bucket that cannot be listed or read with the token (NRV-E1143);
     - a function that does not answer `X-Nerva-Packages: 1` on
       `$PACKAGES_BASE_URL/apt/dists/stable/InRelease`, where a 404 is accepted only while the
       bucket is still empty (NRV-E1145).
  5. Under `if: always()`: `package_repos.sh cleanup`. It runs `gpgconf --kill all` and removes
     the temporary `GNUPGHOME`.

### `repos`

- `needs: [guard, publish]`, `runs-on: ubuntu-24.04`, `timeout-minutes: 30`,
  `environment: package-repos`, `permissions: contents: read` (the release is public now), and
  the same job-level `concurrency` as `repos-ready`. Releases for different tags are therefore
  never written at once, because `release-finish`'s own group is per tag.
- Steps 1 and 3 as in `repos-ready`. Then `package_repos.sh publish "$TAG"`, with the same `env:`
  as before. It does this, in this order:
  1. **Keys.** It imports the key into a fresh `GNUPGHOME` under `$RUNNER_TEMP` (mode 0700). It
     writes the passphrase from the environment with `printf`, a shell builtin, so the passphrase
     is never in an argv, to `$GNUPGHOME/passphrase` (mode 0600). `gpg.conf` gets
     `pinentry-mode loopback` and `passphrase-file`. It checks the fingerprint and the served key,
     as `ready` does.
  2. **The release's packages.** It downloads the four packages and `SHA256SUMS` from the
     published release with `gh release download`, then runs `sha256sum -c`.
  3. **The pool.** It reads `manifest/pool.asc` and verifies its signature against the served key
     file. It lists `apt/pool/` and `rpm/pool/` and refuses any object that the manifest does not
     list (NRV-E1142). It downloads every listed object and checks its SHA-256 against the
     manifest. With no manifest and an empty pool, it starts from an empty pool. A pool that has
     objects but no manifest is refused.
     - **Bound:** at most 2,000 objects and 8 GiB in the pool. Above that the job refuses
       (NRV-E1142), and a decision is needed: a pruning policy, or indexes built from the
       manifest instead of the files. At 24 MB a release, that is about 300 releases away.
  4. **Add.** Each deb goes to `apt/pool/main/n/nerva/<file>` with a write-if-absent put. If the
     object exists with the same SHA-256, the put is skipped (a re-run). If it exists with another
     SHA-256, the job refuses (NRV-E1141). Each rpm works the same way, except that what is
     uploaded is a signed copy. If `rpm/pool/<file>` already exists, its signature is checked with
     the key and its NEVRA and payload digest are compared with the release's file. If they
     match, the existing object is kept: a signature is not reproducible, so a re-run must not
     sign again. If they differ, the job refuses (NRV-E1141). Otherwise the job signs (see
     "Signing"), checks that the signed copy has the same NEVRA and payload digest as the
     release's file (NRV-E1144), and puts it if absent.
  5. **The manifest.** It adds the new entries (`<sha256>  <size>  <key>`, sorted) and clearsigns
     the manifest. Then it puts `manifest/pool.asc`. The pool is written before the manifest, and
     the manifest before any index, so a run that stops at any point leaves either the old
     manifest with an extra object the next run recognises (step 4's "exists" branch, then
     adopted), or the new manifest.
  6. **Indexes.** It regenerates both channels of both formats from the **whole pool**: `stable`
     from the releases, and `rc` from everything. The pool, not the GitHub releases, is the set of
     published packages, so the result does not depend on what happens to a release afterwards.
     - **apt:** for each channel it makes a staging tree of hard links to that channel's debs,
       then runs `apt-ftparchive -a <arch> packages pool/main/n/nerva` for `amd64` and `arm64`,
       writing `Packages` and `Packages.gz`. It then runs `apt-ftparchive release` with Origin
       `Nerva`, Label `Nerva`, Suite and Codename `<channel>`, Architectures `amd64 arm64`,
       Components `main`, and `Acquire-By-Hash: yes`, with no `Valid-Until`. The script makes the
       `by-hash/SHA256/<hex>` copies itself. It signs `InRelease` (clearsign) and `Release.gpg`
       (detached).
     - **dnf:** for each channel it makes a staging tree with `packages/` holding hard links to
       the channel's rpms, then runs `createrepo_c --general-compress-type=gz --checksum=sha256
       --no-database --revision <the release's published_at, as epoch seconds>`. That writes
       unique names for everything but `repomd.xml`. It signs `repomd.xml.asc` (detached,
       armored).
  7. **Upload the indexes.** First every immutable name (`by-hash/...`, the hashed `repodata`
     files), each write-if-absent. Then the names a run replaces, apt's `Packages`,
     `Packages.gz`, `Release` and `Release.gpg` for each channel, with `InRelease` last. Then for
     each channel `repomd.xml.asc` and `repomd.xml`, back to back, last of all. `r2.py put`
     refuses to replace any name outside the replaceable set (the `Cache-Control: no-cache`
     names and `manifest/pool.asc`), so a bug cannot overwrite a package.
- `package_repos.sh served "$TAG"` (no secrets) fetches over `https://<domain>`: each channel's
  `InRelease` and `repomd.xml` must equal the bytes just uploaded and carry
  `X-Nerva-Packages: 1`, and the new packages must be served with their SHA-256 (NRV-E1145).
- `package_repos.sh cleanup` runs under `if: always()`.

**Idempotence.** Every write is either write-if-absent of content the job compares first, or the
regeneration of indexes from the whole pool, so a run repeated from any point converges. A
second run of a finished release writes no pool object and no manifest. It re-signs the indexes,
which have the same content but a new `Date:` and new signatures. Nothing in the pool is ever
replaced or deleted by the job.

### `repos-verify`

- `needs: [guard, repos]`, no environment, no secret, `permissions: contents: read`.
- A matrix of `runs-on` × image, with every image pinned by digest:

  | Runner | Images |
  |---|---|
  | `ubuntu-24.04` (amd64) | `debian:12`, `ubuntu:24.04`, `rockylinux:9`, `fedora:42` |
  | `ubuntu-24.04-arm` (arm64) | the same four |
- Each cell runs `.github/scripts/repo_install_check.sh <apt|dnf> <channel> <base-url>
  <fingerprint> <version>` in the container. It uses the channel the tag belongs to: `rc` for a
  candidate, `stable` for a release. The script runs **INSTALL.md's own commands** (the same text,
  kept in step by a test in slice 2 that compares them). It fetches the key and checks its
  fingerprint. For apt it writes the `.sources` file and runs `apt-get update` and
  `apt-get install -y nerva=<package version>`. For dnf it writes the `.repo` file with
  `gpgcheck=1` and `repo_gpgcheck=1` and runs `rpm --import` after the fingerprint check, then
  `dnf install -y nerva-<package version>`. Then `nerva version`'s last line must be
  `version <V>`.
- **A candidate also checks `stable`:** with the `stable` channel configured, `apt-cache policy
  nerva` and `dnf list --showduplicates nerva` must not list the candidate.
- A failure is NRV-E1146. The release is already public, so the message says that, and that the
  GitHub release's files still install by hand (INSTALL.md).

### Recovery

| What stopped | Do |
|---|---|
| `repos-ready` refused | Fix the setup it names, then "Re-run failed jobs". Nothing was published |
| `repos` stopped part way | "Re-run failed jobs" (or a dispatch from `main` with the tag). It converges |
| `repos` refused NRV-E1141 or NRV-E1142 | Stop. The bucket holds something the signed manifest does not, or a published name has other content. This is the owner's decision, not a re-run |
| `repos-verify` failed | Read which image failed. If it is the environment (a mirror is down), re-run. Otherwise it is a finding: file it |

## Signing

**One OpenPGP key, RSA 4096, sign-only, with no expiry and no subkeys.**

- **RSA 4096, not Ed25519:** apt (`gpgv` on Ubuntu 24.04, `sqv` on newer Debian), Rocky 9's
  rpm 4.16 and Fedora's rpm 6 (Sequoia) all verify RSA with SHA-512. rpm 4.16's support for EdDSA
  and for subkeys is the weak point of older RPM distributions, and one primary key avoids both
  questions.
- **No expiry:** apt refuses a signature by an expired key. A key file in
  `/etc/apt/keyrings/nerva.asc` does not refresh itself, so an expiry date would break every user
  on that day. Rotation is a policy instead: every two years, and at once on a compromise.
- **Digest:** `--digest-algo SHA512` for every signature, and `%_gpg_digest_algo sha512` for rpm.

It signs:

| What | How |
|---|---|
| apt `InRelease`, `Release.gpg` | `gpg --clearsign`, `gpg --detach-sign --armor` of `Release` |
| dnf `repomd.xml.asc` | `gpg --detach-sign --armor repomd.xml` |
| each rpm in the pool | `rpmsign --addsign`, with `--define "_gpg_name <fingerprint>"`, `--define "_gpg_path $GNUPGHOME"` and `--define "_gpg_sign_cmd_extra_args --pinentry-mode loopback --passphrase-file $GNUPGHOME/passphrase"`. The path to the passphrase file is in the argv; the passphrase is not |
| `manifest/pool.asc` | `gpg --clearsign` |

**The release's assets stay as P295 left them: unsigned, and covered by `SHA256SUMS`.** The repo's
rpm is a signed copy. `rpmsign` adds a signature header and changes neither the main header nor
the payload, and the job checks this (NRV-E1144). Debs are not signed one by one, because apt's
trust comes from the signed `InRelease` and its hashes. The repository's deb is therefore the
release's file, byte for byte. Signing the assets themselves would mean the key in `release.yml`'s
`release` job, before the approval. That is a larger change to the release, and it is left for
later.

**Custody.** The armored secret key is the secret `REPO_SIGNING_KEY` of the environment
`package-repos`, and its passphrase is `REPO_SIGNING_PASSPHRASE` in the same environment. They
reach only the two `package_repos.sh` steps, through `env:`, and never an argv, a URL or the log.
GitHub masks both, and the scripts never echo them. A backup of the key, its passphrase and its
revocation certificate is in the owner's password manager, and nowhere else. The public
fingerprint is the variable `REPO_SIGNING_FINGERPRINT` and appears in INSTALL.md.

**Publication.** The public key is `keys/nerva-release.asc` in the site repository, served at
`https://<domain>/keys/nerva-release.asc`. It changes only through a reviewed pull request (the
site's CODEOWNERS), never through the release App: `site-check` already allows a release pull
request to change `index.html` alone. INSTALL.md prints the fingerprint, and `repos-ready` checks
that the served file holds it.

**Rotation (every two years).**

1. The owner makes a new key, using setup step 2 below.
2. A site pull request makes `keys/nerva-release.asc` hold **both** keys, and INSTALL.md and the
   CHANGELOG say so. The job verifies the manifest against any key in the served file, so the old
   manifest still verifies.
3. One release later, the owner replaces `REPO_SIGNING_KEY`, `REPO_SIGNING_PASSPHRASE` and
   `REPO_SIGNING_FINGERPRINT`. From then on, metadata and new rpms are signed with the new key.
   The rpms signed earlier keep the old signatures, so the old key stays in the file while they
   are in the pool. A user who never refreshed the key file sees `NO_PUBKEY <new id>` and follows
   INSTALL.md again.

**Compromise.** The owner publishes the revocation certificate, makes a new key and removes the
old one from `keys/`. Old rpms cannot be re-signed without replacing pool objects, which this spec
forbids, so a compromise is a new decision, recorded then.

## Install instructions (what INSTALL.md gains)

Slice 6 writes this in INSTALL.md's Linux section, before the download-and-install text, which
stays as the path that needs no repository. The recorded output comes from the rehearsal, and is
marked "not run" until then.

**Debian 12, Ubuntu 22.04 and 24.04** (apt 2.4 or later reads an armored key file):

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://<domain>/keys/nerva-release.asc | sudo tee /etc/apt/keyrings/nerva.asc > /dev/null
gpg --show-keys /etc/apt/keyrings/nerva.asc     # the fingerprint must be <FINGERPRINT>
sudo tee /etc/apt/sources.list.d/nerva.sources > /dev/null <<'EOF'
Types: deb
URIs: https://<domain>/apt
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/nerva.asc
EOF
sudo apt update && sudo apt install nerva
```

(`gpg` is not on a minimal Debian. In that case, compare the fingerprint on another machine, or
install `gnupg` first.)

**Fedora, Rocky Linux and RHEL 9:**

```bash
sudo tee /etc/yum.repos.d/nerva.repo > /dev/null <<'EOF'
[nerva]
name=Nerva
baseurl=https://<domain>/rpm/stable
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://<domain>/keys/nerva-release.asc
EOF
sudo dnf install nerva      # dnf shows the key's fingerprint and asks: it must be <FINGERPRINT>
```

- **Upgrades:** `sudo apt update && sudo apt upgrade`, or `sudo dnf upgrade nerva`. A package
  upgrade replaces the binary and never restarts a replica (P295b). Restart them as OPERATING.md
  says.
- **Candidates:** use `Suites: rc`, or `baseurl=https://<domain>/rpm/rc`. That channel also has
  every release.
- **Switching from a downloaded package:** add the repository. The package installed from the
  file is the same package, and the next upgrade comes from the repository.

The text "They are not signed in v0.7.1, and there is no apt or dnf repository yet (they are
planned for v0.7.2)" changes: the repository's rpms and metadata are signed, while the files on
the release page are not, and are checked with `SHA256SUMS`.

## Tools on the runner, pinned

| Tool | From | Pin |
|---|---|---|
| `apt-ftparchive` | `apt-utils` (Ubuntu 24.04) | `apt-get install apt-utils=<noble version>`, then assert `apt-ftparchive --version` |
| `createrepo_c` | `createrepo-c` (Ubuntu 24.04) | the exact noble version string, then assert `createrepo_c --version` |
| `rpmsign`, `rpm` | `rpm` (Ubuntu 24.04) | `rpm=4.18.2+dfsg-2.1build2`, as `release.yml` pins it |
| `gpg`, `gpgconf` | `gnupg` (on the image) | assert `gpg --version` is 2.4.x |
| S3 calls to R2 | `.github/scripts/r2.py`: Python 3 standard library only (SigV4 with `hmac` and `hashlib`, `urllib.request`), `python3 -I` | assert Python 3.12 |
| `curl`, `sha256sum`, `gh` | the image | as the other release scripts use them |
| container images for `repos-verify` | Docker Hub | pinned by digest |

Slice 2 writes the exact noble version strings, read with `apt-cache policy`, as `release.yml`
does for `rpm`.

**Why not `wrangler` or the AWS CLI:**

- `wrangler` needs npm and a Cloudflare API token for "Workers R2 Storage: Edit", which covers
  every bucket in the account. The R2 S3 token can be limited to one bucket.
- The AWS CLI would be a new pinned download, and needs a recent release for conditional puts.
- Plain `curl --aws-sigv4` would need the secret on its command line, or a config file.

`r2.py` is about 150 lines. It reads `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID` and
`R2_SECRET_ACCESS_KEY` from the environment only. Its subcommands are `list <prefix>`,
`get <key> <file>` (it checks `x-amz-meta-sha256` when present), `put-new <key> <file>`
(`If-None-Match: *`; exit 0 written, 3 exists) and `put <key> <file>`. `put` is allowed only on
the names a run replaces, and every put sends `x-amz-content-sha256` (a signed payload) and
`x-amz-meta-sha256`. It retries a 5xx or a broken connection three times with backoff, and fails
on any 4xx but 412 with NRV-E1143. Its message names the operation, the key and the HTTP status,
never a header or a credential.

## Error codes (reserved here; slice 0 registers them)

The highest code on `origin/main` is NRV-E1138. The open pull requests #363 and #364 add none.
This spec takes **NRV-E1139 to NRV-E1147**. Each is printed as
`error[NRV-E11xx]: <script or host>: <what>`, with a `cause` and a `fix` line, and exits 1, like
the other release codes.

| Code | Summary | Printed by | Blame |
|---|---|---|---|
| NRV-E1139 | The package-repos environment is incomplete, or its key is not the published key | `package_repos.sh ready`, `publish` | release maintainer |
| NRV-E1140 | The release's packages are missing, extra, or do not match `SHA256SUMS` | `package_repos.sh ready`, `publish` | release maintainer |
| NRV-E1141 | A package of the same name is already published with other content (published packages are never replaced) | `package_repos.sh ready`, `publish` | release maintainer |
| NRV-E1142 | The pool does not match its signed manifest, or is over its bound | `package_repos.sh ready`, `publish` | release maintainer (or a leaked bucket token) |
| NRV-E1143 | The bucket refused or failed an operation | `r2.py` | release maintainer / Cloudflare |
| NRV-E1144 | Signing failed, or a signed rpm differs from the release's file in NEVRA or payload | `package_repos.sh publish` | release maintainer |
| NRV-E1145 | `<domain>` does not serve what was written, or serves another function version | `package_repos.sh ready`, `served` | release maintainer / Cloudflare |
| NRV-E1146 | Installing from the repository failed on a supported distribution | `repo_install_check.sh` (`repos-verify`) | release maintainer |
| NRV-E1147 | The repository host has no such path, or does not take that method | the Pages Function (404 or 405 body) | client |

## Setup (owner, once)

Each command works in zsh and in bash. Secrets go in through `gh`'s own prompt or standard input,
never on the command line. Run these on your Mac, signed in to `gh` as `topwombat`. The session
proxy cannot reach these settings. Where a command has `<domain>`, put the domain in first.

**1. The domain on Cloudflare.** In the Cloudflare dashboard: **Add a domain**, enter `<domain>`,
take the Free plan, and set the registrar's nameservers to the two Cloudflare names it shows (or
register the domain with Cloudflare Registrar). Wait until the zone says **Active**. Then, in the
zone:

- **SSL/TLS:** Overview, set the mode to **Full (strict)**. Edge Certificates, turn on
  **Always Use HTTPS**, and set **Minimum TLS Version** to 1.2.
- **Security:** Bots, turn **Bot Fight Mode off**. It challenges apt and dnf, which cannot answer
  a challenge.

**2. The signing key.** On your Mac, with GnuPG (`brew install gnupg`), in a throwaway keyring:

```bash
export GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
cat > "$GNUPGHOME/params" <<'EOF'
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: Nerva release signing key
Name-Email: nerva@nerva.pro
Expire-Date: 0
EOF
gpg --batch --generate-key "$GNUPGHOME/params"
```

GnuPG asks for a passphrase twice. Make a long random one and keep it in your password manager.
(The address is the deb's Maintainer address, P331.)

```bash
fpr="$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
echo "$fpr"
gpg --armor --export "$fpr" > "$HOME/nerva-release.asc"
```

```bash
gpg --armor --export-secret-keys "$fpr" | gh secret set REPO_SIGNING_KEY --env package-repos --repo NervaLog/nerva
```

```bash
gh secret set REPO_SIGNING_PASSPHRASE --env package-repos --repo NervaLog/nerva
```

```bash
gh variable set REPO_SIGNING_FINGERPRINT --env package-repos --repo NervaLog/nerva --body "$fpr"
```

(Run step 4's two environment commands before these three, so the environment exists with its
branch rule.) Then put the key, its passphrase and its revocation certificate in the password
manager. `pbcopy` puts each one on the clipboard in turn:

```bash
gpg --armor --export-secret-keys "$fpr" | pbcopy
```

```bash
pbcopy < "$GNUPGHOME/openpgp-revocs.d/$fpr.rev"
```

Then remove the throwaway keyring:

```bash
gpgconf --kill all && rm -rf "$GNUPGHOME" && unset GNUPGHOME
```

**3. The bucket and its token.**

- In the dashboard, open **R2 Object Storage**. If R2 is not enabled on the account, enable it;
  Cloudflare asks for a payment method even for the free tier.
- **Create bucket:** name `nerva-packages`, location Automatic, storage class Standard. In its
  **Settings**, leave **Public access** off: no `r2.dev` URL and no custom domain. Only the
  function reads it.
- **Manage R2 API Tokens**, then **Create Account API token**:
  - name `nerva-release-package-repos`;
  - permission **Object Read & Write**;
  - **Apply to specific buckets only:** `nerva-packages`;
  - TTL **Forever** (rotation is by hand; see the end of this section).
- Create it. The page shows the **Access Key ID**, the **Secret Access Key** and the S3 endpoint,
  `https://<account-id>.r2.cloudflarestorage.com`. Leave the page open for step 4.

**4. The GitHub environment `package-repos`** (`main` only, no reviewers):

```bash
printf '%s' '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' | gh api -X PUT repos/NervaLog/nerva/environments/package-repos --input -
```

```bash
gh api -X POST repos/NervaLog/nerva/environments/package-repos/deployment-branch-policies -f name=main -f type=branch
```

`gh` prompts for each secret's value. Paste it from the token page.

```bash
gh secret set R2_ACCESS_KEY_ID --env package-repos --repo NervaLog/nerva
```

```bash
gh secret set R2_SECRET_ACCESS_KEY --env package-repos --repo NervaLog/nerva
```

```bash
gh variable set R2_ENDPOINT --env package-repos --repo NervaLog/nerva --body 'https://<account-id>.r2.cloudflarestorage.com'
```

```bash
gh variable set R2_BUCKET --env package-repos --repo NervaLog/nerva --body nerva-packages
```

```bash
gh variable set PACKAGES_BASE_URL --env package-repos --repo NervaLog/nerva --body 'https://<domain>'
```

Then run step 2's three `gh` commands for the key.

**5. The public key on the site.** This is a pull request on the site repository, which you
merge. CODEOWNERS asks for your review.

```bash
cd "$(mktemp -d)" && gh repo clone NervaLog/nervalog.github.io site && cd site
git switch -c keys/release-key && mkdir -p keys && cp "$HOME/nerva-release.asc" keys/nerva-release.asc
git add keys/nerva-release.asc && git commit -m "The package repositories' signing key" && git push -u origin keys/release-key
gh pr create --repo NervaLog/nervalog.github.io --fill --base main
```

Tell the supervisor the fingerprint (`echo "$fpr"`). It is public, and slice 6 puts it in
INSTALL.md.

**6. Cloudflare Pages.** Do this after slice 3 has merged in the site repository.

- In the dashboard, open **Workers & Pages**, then **Create**, then **Pages**, then **Connect to
  Git**, then GitHub.
- Install **Cloudflare Workers and Pages** on the NervaLog organisation, with **Only select
  repositories:** `nervalog.github.io`.
- Choose the repository. Set:
  - project name `nerva-site`;
  - production branch `main`;
  - framework preset **None**;
  - build command empty;
  - build output directory empty (the root).
- **Save and Deploy.**
- Project **Settings**:
  - **Build**, then **Branch control**: set **Preview branch** to **None**. Release pull requests
    need no preview, and none should run the function.
  - **Bindings**, then **Add**, then **R2 bucket**: variable name `PACKAGES`, bucket
    `nerva-packages`, for **Production**. Then **Deployments**, and **Retry deployment** on the
    latest, so that the binding takes effect.
  - **Custom domains**, then **Set up a custom domain:** `<domain>`. Cloudflare adds the DNS
    record itself, because the zone is in the same account.
- Optional: `www.<domain>`. In the zone, under **Rules**, then **Redirect Rules**, add a rule
  that sends `www.<domain>` to `https://<domain>` with a 301, keeping the path. Add a proxied DNS
  record for `www` (an `AAAA` to `100::`).

Check it:

```bash
curl -sI 'https://<domain>/' | head -n1
```

```bash
curl -s 'https://<domain>/keys/nerva-release.asc' | gpg --show-keys
```

```bash
curl -si 'https://<domain>/apt/nothing' | grep -i -e '^HTTP' -e '^x-nerva-packages'
```

Expect a 200; then your fingerprint; then a 404 with `x-nerva-packages: 1`.

**7. The old URL.** Do this after slice 4 has pushed the branch `github-pages-redirect`.

```bash
gh api -X PUT repos/NervaLog/nervalog.github.io/pages -f build_type=legacy -f 'source[branch]=github-pages-redirect' -f 'source[path]=/'
```

```bash
printf '%s' '{"name":"github-pages-redirect","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/github-pages-redirect"],"exclude":[]}},"rules":[{"type":"non_fast_forward"},{"type":"deletion"}]}' | gh api -X POST repos/NervaLog/nervalog.github.io/rulesets --input -
```

```bash
gh repo edit NervaLog/nervalog.github.io --homepage 'https://<domain>/' && gh repo edit NervaLog/nerva --homepage 'https://<domain>/'
```

**8. Check the GitHub side.**

```bash
gh secret list --env package-repos --repo NervaLog/nerva && gh variable list --env package-repos --repo NervaLog/nerva
```

```bash
gh api repos/NervaLog/nerva/environments --jq '.environments[] | [.name, (.protection_rules | map(.type) | join(","))] | @tsv'
```

Expect four secrets (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `REPO_SIGNING_KEY`,
`REPO_SIGNING_PASSPHRASE`) and four variables (`R2_ENDPOINT`, `R2_BUCKET`,
`REPO_SIGNING_FINGERPRINT`, `PACKAGES_BASE_URL`), and `package-repos` with `branch_policy` only.
Then tell the supervisor.

**Rotating the R2 token** (yearly, or if it may have leaked): create a new token as in step 3,
set both secrets again as in step 4, then delete the old token in the dashboard. A run in
progress fails with NRV-E1143 and is re-run.

**Least privilege, in summary:**

- **The R2 token** can touch one bucket. It sits in one environment that only `main` can deploy,
  and it reaches two steps.
- **The signing key** sits in the same environment and reaches the same two steps.
- **The Pages project** needs no token in GitHub. Cloudflare's GitHub App reads one repository.
- **The release App** is unchanged, and does not get the bucket or the key.
- `package-repos` has no reviewer, as `release-publish` has none, so the release is still one
  approval. The same accepted risk applies (automation.md, "Security notes"): any workflow merged
  to `main` can name the environment, and merging is the guard.

## What changes elsewhere

- **P148:**
  - The site is served by Cloudflare Pages (project `nerva-site`, built from the site
    repository's `main`, no build step), at `https://<domain>/`.
  - GitHub Pages serves only the redirect branch.
  - A merge to `main` is still a deploy.
  - The site repository also holds the function that serves the repositories, and the public key.
  - The decision file says this. P148 itself is not edited.
- **P360 point 10:** the repositories come in v0.7.1, not v0.7.2, as three jobs (not one), in the
  environment `package-repos`. `verify` does not wait for them, and `publish` waits for
  `repos-ready`.
- **Nerva's CLAUDE.md:**
  - "README and site status": "served by GitHub Pages from that repository's `main` at
    <https://nervalog.github.io/>" becomes "served by Cloudflare Pages from that repository's
    `main` at <https://<domain>/> (P365); <https://nervalog.github.io/> sends visitors there".
  - The release paragraph adds that the release also publishes the apt and dnf repositories.
  - "Environment facts" notes that the session proxy cannot reach Cloudflare.
- **The site's CLAUDE.md and README:**
  - The served-by line, as in Nerva's CLAUDE.md.
  - `functions/`, `_routes.json` and `keys/` are code and key material: changed only by a
    reviewed pull request, never together with the release data (`site-check` already refuses
    `.github/` together with release data, and a release pull request touches `index.html`
    only).
  - The key is changed only by the owner.
- **Nerva's README** has no link to the site; nothing changes there. The repositories' homepages
  change in setup step 7.
- **docs/releases/automation.md**, the section "`apt` and `dnf` repositories (v0.7.2): the hook",
  becomes a pointer to this document (slice 6). The rest of it stands.
- **The site's `NEXT`:** the v0.7.2 line "apt and dnf repositories with signed packages" moves to
  v0.7.1 in the supervisor's status pull request, and is marked delivered only after
  `repos-verify` is green on the v0.7.1 run.
- **CHANGELOG.md's v0.7.1 section** gains the repositories, with the install lines, in the
  `VERSION` pull request.

## The rehearsal: `v0.7.1-rc.2` exercises it

Prerequisites: setup steps 1 to 8 are done, slices 0 to 5 have merged, and slice 3 is deployed.

1. **If the rc.2 rehearsal of automation.md has not run yet,** it runs as automation.md says, and
   now includes `repos-ready`, `repos` and `repos-verify`. That is still one approval.
2. **If it has already run, and `v0.7.1-rc.2` is still published** (its cleanup not yet done), the
   supervisor dispatches `release-finish.yml` from `main` with `tag=v0.7.1-rc.2`. `guard` sees a
   published release and skips `mac` (P362 point 10), so **no approval is needed**. `mac-verify`,
   `repos-ready`, `publish` (which publishes nothing and checks the tag, the tap and the site),
   `repos`, `repos-verify` and `verify` run.
3. **If rc.2 has already been deleted,** this needs a `v0.7.1-rc.3` rehearsal, run as in
   automation.md, with the one approval.

**Pass:**

- `repos-ready` is green before `publish`.
- `repos` writes four pool objects, the manifest and both channels of both formats. `stable` is
  signed and empty, because no release has packages yet; that exercises the subset rule. `served`
  is green.
- `repos-verify` is green in all eight cells, on amd64 and arm64: `nerva version` ends with
  `version 0.7.1-rc.2`, and `stable` offers no candidate.
- **A second dispatch** with the same tag writes no pool object and no manifest, re-signs the
  indexes, and is green.
- Before the dispatch, `curl -sI https://<domain>/` answers 200 from Pages, and
  `https://nervalog.github.io/` loads the redirect page.

**Afterwards:** the cleanup in automation.md stays as it is. `0.7.1~rc.2` stays in the `rc` channel
and the pool. Nothing is deleted from the bucket. The run link goes in the worklog note of the pull
request that records the result.

**Not verified until the rehearsal** (slices 1 to 3 test the rest locally, with stand-ins, and in
containers):

- `r2.py` against real R2: SigV4 with region `auto`, `If-None-Match: *` answering 412, and the
  `x-amz-meta-sha256` round trip.
- The Pages Git integration with no build, the function's R2 binding, and `_routes.json` on the
  custom domain.
- Cloudflare's security features against apt's and dnf's user agents, from GitHub's runners.
- The environment `package-repos`, its secrets, and the key's import with the passphrase file on
  the runner.
- `ubuntu-24.04-arm` running the arm64 cells.
- The redirect of `nervalog.github.io`.

**Not verified until v0.7.1** (the same code with another filter):

- the first release package in `stable`;
- `repos-verify` installing from `stable`.

The fallback is the same as for the tap and the site in automation.md: the release is already
public, its files install by hand, and a re-run or a dispatch of `release-finish.yml` finishes the
repositories.

**If the rehearsal has not passed when v0.7.1's other gates pass:** see Question 3.

## Slices

Concurrent slices touch different files (P250). Each gets a fresh agent and is reviewed
adversarially by a fresh reviewer, who posts the findings on its pull request. Tiers as in
CLAUDE.md (P148b).

| Slice | What | Files | Tier | Order |
|---|---|---|---|---|
| 0 | Register NRV-E1139 to NRV-E1147 from the table above: entries with surface, blame, cause and fix, plus the intro paragraph of the 11xx section naming the scripts that print them | `docs/ERRORS.md` | mechanical; supervisor checks the diff | first; small, merges before 1 and 2 |
| 1 | `r2.py` and its tests. The tests run a fake S3 server (`http.server`, in the test file), check the SigV4 signature against AWS's published test vectors, and cover `If-None-Match` and 412, the replaceable-name refusal, retries, NRV-E1143's text, and that no credential appears in argv or any message. One line in `ci.yml`'s release-scripts step | `.github/scripts/r2.py`, `.github/scripts/test_r2.py`, `.github/workflows/ci.yml` (one line) | implementation; review | after 0; parallel with 3 and 4 |
| 2 | `package_repos.sh` (`ready`, `publish`, `served`, `cleanup`) and `repo_install_check.sh`. Tests with real `gpg`, `apt-ftparchive`, `createrepo_c` and `rpmsign`, a throwaway key, a stand-in `gh`, and `r2.py` against slice 1's fake server. They cover every code from NRV-E1139 to NRV-E1142, E1144 and E1145; a re-run from each step; the rpm "exists, keep it" path; the bound; and that the stable channel holds no candidate. `tests/packaging/repos.py` serves the generated trees over local HTTP to the debian, ubuntu, rocky and fedora containers in `packages.yml`, through `repo_install_check.sh` (NRV-E1146 included), and checks that its commands equal INSTALL.md's block once slice 6 lands. `ci.yml` installs the pinned tools for the scripts step | `.github/scripts/package_repos.sh`, `.github/scripts/repo_install_check.sh`, `.github/scripts/test_package_repos.py`, `tests/packaging/repos.py`, `.github/workflows/ci.yml` (the tools and one line), `.github/workflows/packages.yml` (one step) | implementation; review (security focus: secrets, argv, refusals) | after 1 |
| 3 | The site repository: `functions/[[path]].js` (the layout, 404 and 405 with NRV-E1147, `Range` and `onlyIf`, headers, `X-Nerva-Packages: 1`), `_routes.json` (`/apt/*`, `/rpm/*`), `_headers` (`/keys/*` as `application/pgp-keys`), `node --test` for the function with a stand-in R2 binding, a `node --check` and that test in `check.yml`'s `site-check` job, and the README and CLAUDE.md text from "What changes elsewhere" | `NervaLog/nervalog.github.io` only | implementation; review | parallel with 1 and 2 |
| 4 | The orphan branch `github-pages-redirect` in the site repository, with the page above (`index.html`, `404.html`, `.nojekyll`), pushed directly; the branch has no ruleset yet | that branch only | mechanical; supervisor checks it | any time; setup step 7 needs it |
| 5 | `release-finish.yml`: jobs `repos-ready`, `repos`, `repos-verify`; `publish`'s `needs` and `if`; the header comment; images pinned by digest. Tried with a dispatch on a published release before review where possible: a dispatch skips `mac` for a published release, and `repos-ready` refuses NRV-E1139 cleanly while the environment is not set up | `.github/workflows/release-finish.yml` | implementation; review (security focus: environments, `needs`/`if`, concurrency) | after 2 |
| 6 | `<domain>` and the fingerprint in this spec, INSTALL.md (the repositories' section and the signing sentence), CLAUDE.md (the site lines, the release line, the environment fact), automation.md's hook section as a pointer here, and the worklog | `docs/INSTALL.md`, `CLAUDE.md`, `docs/releases/automation.md`, `docs/releases/packages.md` | mechanical; supervisor checks | after #363 and #364 merge (they change INSTALL.md, CLAUDE.md and automation.md), after setup step 2 (the fingerprint), and after the owner names the domain |
| E | Setup steps 1 to 8 | Cloudflare, GitHub | owner | step 6 after 3, step 7 after 4 |
| F | The rehearsal, and its run link recorded | worklog | supervisor | after 0 to 5 and E |

Slices 1, 3 and 4 can run at once. Slice 2 needs slice 1's fake server. Slice 5 needs slice 2's
script interface. Slice 6 changes no code and can go last.
