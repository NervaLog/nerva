# The domain, and the apt and dnf repositories: spec, setup, slices

Status: spec, 2026-11-12 (P365, which amends P360 point 10, P364 and P148; amended the same day
after the Zigbox team's review of the pipeline, P376, P376b and P376c). Reworked four times
the same day after adversarial reviews, and after the owner's decision that Cloudflare deploys the
site. The fourth rework cut the lock in the bucket: one GitHub concurrency group keeps the writers
apart instead. Nothing here is built yet. It is the last change before the v0.7.1 tag: the owner moved the
repositories from v0.7.2 to v0.7.1 and named the domain, `nerva.pro` (owner, 2026-11-12).

The freeze holds. Nothing here touches `src/` or `build.zig`. The change is workflows, scripts,
documents, two key files under `packaging/keys/`, a few lines in the site repository, and
Cloudflare and GitHub settings. No new dependency enters the Zig build.

## Goal

1. Nerva's site is served at `https://nerva.pro/`. It is still the one page `index.html` in
   `NervaLog/nervalog.github.io`, and a merge to that repository's `main` is still a deploy. Now
   **Cloudflare Pages builds and deploys it**, through its Git integration. GitHub Pages is
   turned off. The release pull request flow (the App, `site-check`, the ruleset, P364's merge)
   does not change.
2. `https://packages.nerva.pro/` serves signed apt and dnf repositories of every release from
   v0.7.1 on. A user installs with `apt install nerva` or `dnf install nerva`, and later upgrades
   with `apt upgrade` or `dnf upgrade`.
3. The release is still one approval: the owner approves `mac` in `apple-signing`, and
   everything after it, the repositories included, runs without anyone. Nothing is published by
   hand afterwards.
4. **Everything the packages' trust depends on lives in `NervaLog/nerva`,** under the same guard
   as the release workflows and the signing environments: the public key, the pinned
   fingerprints, and the code that writes and checks the repositories. The site repository holds
   a static page and a copy of the public key for WKD (P376). That copy is a second channel for
   users to compare against. The job never trusts it, and a merge in the site repository can
   change nothing the job relies on.

## Architecture

### The hosts

```
https://nerva.pro/                 index.html: Cloudflare Pages project nerva-site, built from the site repository's main
https://www.nerva.pro/             a Cloudflare redirect rule: 301 to https://nerva.pro/<path>
https://nervalog.github.io/        GitHub Pages is off: GitHub's 404 (accepted, see "The old URL")
https://packages.nerva.pro/        the R2 bucket nerva-packages, public, read-only (R2 custom domain)
https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc
                                   the repositories' public key: a file in Nerva's repository
https://nerva.pro/.well-known/openpgpkey/hu/ndqm47zydhyqyzabecddtdk1q3bponab?l=nerva
                                   the same key by WKD's direct method (P376), from the site
                                   repository: the second channel users compare with
```

`nerva.pro` is a Cloudflare zone in the same account as the Pages project and the bucket. Pages
and R2 both require that: an apex custom domain on Pages, and an R2 custom domain, must be in a
zone of the project's or bucket's own account. Every record is proxied, and Cloudflare issues every
certificate.

### The site on Cloudflare Pages

**How it deploys.** The Pages project `nerva-site` is connected to `NervaLog/nervalog.github.io`
through Cloudflare's GitHub App. The App is installed on that one repository only. Its production
branch is `main`: a merge to `main` starts a build, and a green build is the deploy. No Cloudflare
token for the site exists in GitHub. The only Cloudflare credential anywhere in GitHub is the R2
token in Nerva's `package-repos` environment (below).

**The build command is the gate, and it lives in Cloudflare, not in the repository.** A Pages
project built from a repository runs that repository's `functions/` directory as Functions, runs a
`_worker.js` in the output directory, and reads bindings from a `wrangler.toml` (or
`wrangler.json`, `wrangler.jsonc`) in it (Cloudflare's Pages Functions and configuration docs).
A binding could name any R2 bucket of the account, with `put` and `delete`: there is no read-only
binding. So the project's build command, set in the dashboard (setup step 2), refuses a tree that
holds any of those names, then copies five named files into an empty `dist/`, the output
directory: `index.html`, `404.html`, `_headers`, and the two WKD files (see "The key by WKD").
It copies nothing else, and refuses any of the five that is missing or is a symlink.
`404.html` makes Pages answer an unknown path with 404; without one, Pages treats the project
as a single-page app and answers any path, including another WKD hash, with `index.html` and
status 200. `_headers` gives `/.well-known/openpgpkey/*` the headers WKD clients expect:
`Content-Type: application/octet-stream` and `Access-Control-Allow-Origin: *`.

**Cloudflare installs dependencies before the build command runs.** Its build image runs
`npm install` (or the Python, Ruby or other tool) when it finds a `package.json`, a lock file or a
version file, and a `postinstall` script would run before the gate. So the project sets
`SKIP_DEPENDENCY_INSTALL` to `1` (setup step 2), the build command refuses to run without it, and
it refuses those files too. A name that is a dangling symlink is refused as well. The command:

```
set -eu; if [ "${SKIP_DEPENDENCY_INSTALL:-}" != 1 ]; then echo "error[NRV-E1152]: site build: SKIP_DEPENDENCY_INSTALL is not 1; nothing is deployed" >&2; exit 1; fi; for p in wrangler.toml wrangler.json wrangler.jsonc functions _worker.js _routes.json package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb requirements.txt Pipfile Pipfile.lock pyproject.toml poetry.lock Gemfile Gemfile.lock .tool-versions .nvmrc .node-version .python-version .ruby-version runtime.txt; do if [ -e "$p" ] || [ -L "$p" ]; then echo "error[NRV-E1152]: site build: $p is not allowed in the site repository; nothing is deployed" >&2; exit 1; fi; done; rm -rf dist; mkdir -p dist/.well-known/openpgpkey/hu; for f in index.html .well-known/openpgpkey/policy .well-known/openpgpkey/hu/ndqm47zydhyqyzabecddtdk1q3bponab; do if [ -L "$f" ] || [ ! -f "$f" ]; then echo "error[NRV-E1152]: site build: $f is missing or is a symlink; nothing is deployed" >&2; exit 1; fi; cp "$f" "dist/$f"; done
```

The command does not check what the WKD file holds. The site's own check does that (NRV-E1162),
and the release checks it again (`site-live`). If the WKD file is wrong, users see a mismatch.
The job is not affected (see "The key by WKD").

A failed build deploys nothing, so the last good deployment keeps serving. A pull request in the
site repository cannot change the build command: only a member of the Cloudflare account can.
The site's `site_check.mjs` refuses the same names too (slice 5), so a pull request fails before
it merges, but that check is the pull request's own code. The build command is what holds.
If the site gains another file, the owner adds it to the build command's list.

**Preview deployments: on, for pull requests (recommended).** Cloudflare builds every
non-production branch of the site repository with the same build command and posts its preview
URL on the pull request. Why on:

- The gate can be tested without a merge. The rehearsal opens a pull request that adds a
  `wrangler.toml` binding the bucket, a `functions/` file, and a `package.json` whose
  `postinstall` writes `dist/_worker.js`. Its preview build must fail with NRV-E1152.
- A reviewer of a site pull request, a release's included, sees the page before it merges.
- A preview has no more reach than production: the same gate, no secrets, and a
  `*.nerva-site.pages.dev` address that nobody links to.

Cloudflare's check on a pull request is **not** a required check in the site's ruleset. A
Cloudflare outage must not block the site's pull requests, the release's included; `site-check`
stays the only required check. If the owner prefers fewer moving parts, previews off ("None" under
Preview branches) changes nothing else in this spec except the rehearsal's gate test, which then
needs a merge.

**What someone who can merge to the site's `main` can do, afterwards.** That is a session acting
as `topwombat`, or the release App, whose token can open and merge site pull requests.

- **Can:** change the page, which is a deploy: deface it, or put misleading text on it. So the page
  shows no fingerprint and no repository line of its own. It links to INSTALL.md in this
  repository for them (slice 5).
- **Can:** replace the WKD key. Users who follow INSTALL.md then see two different primary
  fingerprints and stop. The job never reads the site's key, so nothing is signed or trusted
  differently. The next site pull request fails its check (NRV-E1162), and so does the next
  release's `site-live`.
- **Cannot:** run code on Cloudflare, or bind the bucket (the build command refuses it, and the
  repository cannot change the build command). Cannot read or write the bucket (no credential).
  Cannot change the key, the fingerprints or the scripts (all in this repository). Cannot get
  anything signed, or change what `packages.nerva.pro` serves (R2 serves it, not the Pages
  project).
- **If the gate ever failed** (for example, Cloudflare starts reading a config file under a new
  name), a site merge would gain the bucket token's power and nothing more. "The R2 token leaks"
  below bounds that: it cannot sign, the bucket locks stop it from deleting or replacing a package
  or a manifest, and the next write run reports any tampering.

### The key by WKD (P376)

The site serves the public key through the Web Key Directory's **direct method**. The advanced
method needs a host `openpgpkey.nerva.pro` with a record and a certificate of its own. It adds
nothing here, and GnuPG falls back to the direct method when that host does not resolve.

- **Files in the site repository:** `.well-known/openpgpkey/policy`, which is empty, and
  `.well-known/openpgpkey/hu/ndqm47zydhyqyzabecddtdk1q3bponab`. That second name is the z-base-32
  of the SHA-1 of the local part `nerva`, from the user ID's address `nerva@nerva.pro`. Slice 5
  checks it with `gpg-wks-client --print-wkd-hash nerva@nerva.pro`. The file holds the binary
  form of this repository's `packaging/keys/nerva-release.asc` (`gpg --dearmor`), byte for byte:
  the primary, its subkeys, and any revocations.
- **Who keeps it equal:** every change to `packaging/keys/` here is followed, the same day, by a
  site pull request that replaces the file.
  - **One reference for both checks: the key file at the commit that the site's `RELEASES` data
    names as the latest release.** The WKD file changes only with a release.
  - `site_check.mjs` fetches `packaging/keys/nerva-release.asc` at that commit, dearmors it and
    compares, on every site pull request. A difference is **NRV-E1162**.
  - At release time, `release_finish.sh site-live` fetches the served WKD file, without cache
    busting, and compares it with the key file at the release commit (NRV-E1162), which is the
    same reference once the site pull request has merged.
  - **Who opens the site pull request:** `release-finish.yml`'s `site` job, which already opens
    the site's pull request for the release, and which now also replaces the WKD file with the
    dearmored key file of the release commit. A key change on `main` between releases does not
    block the site, and the WKD file lags `main` by design. For a revocation that cannot wait,
    the owner cuts a patch release (see "Compromise"), which is the one path.
- **INSTALL.md** asks users to compare the primary fingerprint of the key from GitHub with the
  one from WKD (see "Install instructions").
- **It is a second channel, never a source.** No job reads the site's key. The manifest, the
  signatures and the alarms are checked only against `packaging/keys/` in this repository.

**What a compromise of one side can do:**

| Who | Can | Cannot |
|---|---|---|
| The site alone (a merge to the site's `main`, or the Pages project) | Serve another key by WKD. A user who checks both channels sees a mismatch and stops. A user who checks only WKD, against INSTALL.md's advice, could trust the wrong key, but that key's signatures are not in the repositories. | Get anything signed. Change the key the job checks against, the bucket, or the packages. |
| GitHub alone (a merge to Nerva's `main`) | Change the workflows, and with them make the CI subkey sign anything. Replace the key file that users fetch from GitHub. | Change the WKD key. Users who check both channels see that a swapped key file disagrees with WKD. It cannot make a new subkey either, because the primary is offline. So it cannot replace the CI subkey with its own, and a revoked or expired CI subkey ends its reach. In the single-key fallback the whole key is in CI, so that last limit does not exist. |
| Both together | Everything: a full compromise | |

WKD protects against a swapped key file, which GitHub alone could otherwise do without anyone
noticing. It does not protect against a merge that uses the existing subkey. That threat is the
one the release's guard on `main` already covers.

### The old URL

**Decision: accept the break.** `https://nervalog.github.io/` answers GitHub's 404 once Pages is
off. A redirect needs GitHub Pages switched on for a repository named `nervalog.github.io`. That
means either keeping Pages on in the site repository (which contradicts the owner's decision), or
renaming the site repository and making a new one for the redirect. A rename would change P148,
the release App's installation, `release_finish.sh`'s `SITE_REPO`, the ruleset's target and the
release workflows, all for one redirect.

What breaks is small. On `main` today, no document, no release note and no package names the
site's URL: Nerva's README does not link to it, the Homebrew formula's `homepage` is the GitHub
repository, and the CHANGELOG has no link to it. The two repository homepage fields change in setup
step 9. What stays broken: bookmarks, and any outside page that linked to the old address.

If the owner wants the redirect after all, the cheapest way is a second GitHub Pages source in the
site repository: a workflow that deploys a fixed two-file artifact (an `index.html` and a
`404.html` that send `location.pathname` and `location.hash` to `https://nerva.pro`), never the
repository's own page. That is one workflow file in the site repository, and Pages stays on for
it alone. This spec does not do that.

### The bucket, served read-only by construction

The bucket's **public access through a custom domain** is the only reader. It serves GET and HEAD
of an object's exact key and nothing else: no listing, no writes, no code. Whoever holds no R2
token can change nothing in it, whatever they merge anywhere.

| | R2 custom domain, public (chosen) | A Worker deployed from Nerva (considered) |
|---|---|---|
| Write access in the serving path | none: public access is read-only | the Worker's binding has `put` and `delete`; its deploy token (Workers Scripts: Edit) covers every Worker of the account |
| Code in the request path | none | a Worker, its tests, and a deploy workflow with a Cloudflare API token |
| Headers | `Content-Type` and `Cache-Control` stored on each object by `r2.py`, served as stored | set by code |
| `Range`, `If-None-Match`, `ETag` | served by R2 | by code, with R2's `range` and `onlyIf` |
| Request limit | none of Workers' kind; reads are R2 Class B operations, 10 M a month free, then $0.36 a million; cached reads are free | Workers' 100,000 a day free, then error 1027 until Workers Paid |
| What it cannot do | map one key to two paths, refuse a path by rule | — |

The two things a Worker could add are handled in the layout instead. Each dnf channel has its own
copy of its rpms (below), so no path is mapped. And what a channel may hold is enforced by the job
that writes it, which is checked on every run (steps 3 and 5 of `repos`), not by the server.

The owner's answer to the Workers Paid question (owner, 2026-11-12: only if the free quota is
hit) stands, and with this design there is no Worker quota to hit.

The bucket is public, so its manifests are readable by anyone. They hold only hashes, names and
tags, which the public releases already show.

**Bucket locks.** The bucket has four R2 bucket lock rules, each with indefinite retention, on the
prefixes `apt/pool/`, `rpm/stable/packages/`, `rpm/rc/packages/` and `manifest/` (setup step 5).
R2 then refuses to delete or overwrite any object under them, whoever asks. The bucket token is
"Object Read & Write" and cannot change lock rules, which needs an admin permission. So the token
can add objects there, but cannot remove or replace a package or a manifest. Every write run
checks that the locks are in force (step 3 of `repos`, NRV-E1149). The names a run replaces (the
indexes) cannot be locked, and the manifest records their hashes instead (below).

The rules stay on packages and manifests because they still earn their place: without them the
token could delete a published package or roll the manifest back, and the job could not tell. The
fifth rule, on `lock/`, is cut with the lock in the bucket (see "One writer at a time").

**The token can add objects that nobody can remove without the owner.** A locked object is
permanent, junk included. So the job never trusts an object for being there, and an object it
does not expect never stops it from re-signing:

- an object under a locked prefix that no signed manifest lists, a manifest object that does not
  verify, is **noted and ignored**: never indexed, never signed.
  The run re-signs what the current manifest allows, then ends red with NRV-E1142 and names each
  one;
- a name the job wants to write that junk already holds is skipped: the next manifest takes the
  next free name, and a package entry whose name is taken stays `pending` and is not indexed
  (noted, NRV-E1142);
- the owner removes junk with "Removing an object from a locked prefix" (under "Recovery").

What this does not promise: a token holder can still deny service, for example by deleting the
index files every minute, by taking the name of a release's package before the release, or by
flooding a prefix past `r2.py`'s listing bound. Each of those ends red with a code, and none can
make apt or dnf install anything the key did not sign.

### The bucket's layout

```
nerva-packages/
  apt/pool/main/n/nerva/nerva_<filever>-1_<amd64|arm64>.deb                  locked, the release's own file
  apt/dists/<stable|rc>/InRelease, Release, Release.gpg                      replaced by each write run (signed)
  apt/dists/<stable|rc>/main/binary-<amd64|arm64>/Packages, Packages.gz      replaced by each write run
  apt/dists/<stable|rc>/main/binary-<amd64|arm64>/by-hash/SHA256/<hex>       written once (Acquire-By-Hash)
  rpm/<stable|rc>/packages/nerva-<filever>-1.<x86_64|aarch64>.rpm            locked, signed copy of the release's file
  rpm/<stable|rc>/repodata/<hex>-<primary|filelists|other>.xml.gz            written once (unique names)
  rpm/<stable|rc>/repodata/repomd.xml, repomd.xml.asc                        replaced by each write run (signed)
  manifest/<generation, ten digits>.asc                                      locked, one per manifest write (clearsigned)
```

`<filever>` is the version in the release's file names (`0.7.1`, or `0.7.1.rc.2` for a candidate,
P311). The version inside each package keeps `~` (`0.7.1~rc.2`), so a candidate sorts before its
release in both apt and dnf.

A release's rpm is stored twice, under `rpm/stable/packages/` and `rpm/rc/packages/`, as the same
signed bytes; a candidate's only under `rc`. That costs about 14 MB a release and keeps every dnf
path physical. The job refuses to write a candidate's name (one holding `.rc.`) under
`rpm/stable/`, and refuses a bucket that holds one there (NRV-E1142). apt's pool path carries no
channel, so for apt the channel is only what each channel's signed `Packages` lists.

The objects carry `Cache-Control: public, max-age=31536000, immutable` for names written once and
`Cache-Control: no-cache` for the names a run replaces, and a `Content-Type` per kind
(`application/vnd.debian.binary-package`, `application/x-rpm`, `text/plain`, `application/gzip`,
`application/xml`, `application/pgp-signature`).

### The manifest

The manifest is the authority over what the bucket may hold. Each write of it is a **new** object,
`manifest/<generation>.asc`, written only if absent, and locked. **The current manifest is the one
with the highest generation that verifies** (below); an object under `manifest/` that does not
verify is noted and skipped. Nothing can roll it back: an older manifest cannot be put back over a
newer one (locked), the newer one cannot be deleted (locked), and a copy of an older one under a
higher name fails its `generation` line. A run writes its next manifest at the first free name
above the current one. Before it puts a manifest, the run verifies its own file exactly as a reader
would (below), so this pipeline never writes a manifest object that does not verify. It is
clearsigned text:

```
nerva-packages manifest 4
generation <n>
state <writing|complete>
package <state> <sha256> <size> <key> <source-sha256> <tag> <commit>
...
index <sha256> <key>
...
index-was <sha256> <key>
...
```

- **`generation`** must equal the number in the object's name. A copy of an older signed manifest
  under a new, higher name therefore does not verify, and is noted as junk.
- **`state`** is `writing` until the run has uploaded the indexes and `served` has checked them.
  Then the run writes one more generation, the same with `state complete`.
- **`package` lines,** one per package object, sorted by key. `<state>` is `pending`,
  `published` or `excluded` (P376: the object is locked and stays, but no index lists it; it is
  set only by step 5b, and is never reversed). `<sha256>` and `<size>` are the stored object's. For a deb they equal the
  release file's. For an rpm they are the signed copy's, and `-` until a run has signed it (step 4
  of `repos`). `<source-sha256>` is the release asset's, as the approved run read it from the
  draft. `<tag>` and `<commit>` are the release's tag and the commit `publish-ready` checked.
- **`index` lines** give the SHA-256 of every name a run replaces (`InRelease`, `Release`,
  `Release.gpg`, `Packages`, `Packages.gz`, `repomd.xml`, `repomd.xml.asc`, for each channel and
  architecture), as this run uploads them. **`index-was` lines** give, for each name, the hash
  the run found and accepted, or the previous manifest's `index` hash where it found something
  else. A hash the run noted as tampered is never recorded.
- **A generation that changes only `package` lines** (the binding in `repos-ready`, or an rpm's
  new signature in step 4 of `repos`) copies the current manifest's `state`, `index` and
  `index-was` lines unchanged. So it never widens what the next run accepts: after a `complete`
  manifest, it is still `complete`.
- **Which index hashes the next run accepts.** After a `complete` manifest, only its `index`
  hashes. After a `writing` one (a run stopped between writing it and finishing), its `index` or
  its `index-was` hash, name by name. Anything else is tampering (see "The R2 token leaks"). So a
  replay of an older index set is caught by the next run, whatever its age.
- **Bound:** generations are ten digits. A release writes one in `repos-ready` and two to four in
  `repos`; a refresh two.

**It is verified only against the pinned fingerprints.** `packaging/keys/fingerprints` in this
repository lists the fingerprints the job trusts, each with a role. With the subkey model (P376,
adopted if slice K passes):

```
primary <40 hex>     exactly one; never changes; signs nothing the job makes or accepts
current <40 hex>     the signing subkey CI holds: signs everything
next <40 hex>        only during a rotation: also signs InRelease and Release.gpg
retired <40 hex>     a subkey that signed objects still in the bucket: accepted on manifests
                     until the next write run replaces the current one, and on rpms for good
revoked <40 hex>     a subkey whose revocation the key file carries: never accepted
anchor <generation> <sha256>
                     only after a revocation: the one manifest object accepted by its hash
                     although its signer is revoked, so that the chain restarts from it
```

In the single-key fallback, the roles are those of P365: `current`, `next` and `previous`, each a
primary key.

`packaging/keys/nerva-release.asc` holds exactly those keys, armored. In the subkey model, that
means the primary, every listed subkey, and their binding and revocation signatures. **Expiry is
written only in the key file**, never in `fingerprints`. The job reads it from the key file with
`gpg --with-colons --show-keys` (field 7 of each `sub` line). The job builds a keyring from that
file with `gpg --dearmor` (`gpgv` does not read an armored keyring) and verifies with
`gpgv --status-fd 3 --output -`. **NRV-E1139** refuses any of these:

- a key file whose primary is not `primary`;
- a key file that holds a subkey `fingerprints` does not list;
- a key file that misses a listed subkey;
- a subkey listed `revoked` that the file does not revoke;
- `current` or `next` revoked or expired in the file.

Nothing the job reads from the bucket, the site or the network is ever a source of trusted keys.

**The signature check, the same everywhere** (P376). Every `gpgv` call the job makes,
`repos-fresh`'s included, writes its status to a file descriptor. One function in
`package_repos.sh` judges it. Each `VALIDSIG` line is
`[GNUPG:] VALIDSIG <fpr> <date> <ts> <expire> <ver> <reserved> <pk-algo> <hash-algo> <class> <primary-fpr>`.
It is split on spaces, and a line that is not exactly 12 fields is refused. With awk's numbering:

- `$12`, the primary key's fingerprint, equals `primary`.
- `$3`, the key that made the signature, is listed with a role that may sign that kind of file,
  and is not equal to `$12`. A signature by the primary itself is refused. The roles are:
  - a manifest: `current`, `retired`;
  - `InRelease` and `Release.gpg`: `current`, `next`;
  - `repomd.xml.asc`: `current`.
- `$9` is `1` (RSA) and `$10` is `10` (SHA-512).
- `$11` is `01` for a clearsigned file and `00` for a detached signature.
- The status holds no `BADSIG`, `ERRSIG`, `EXPSIG`, `EXPKEYSIG`, `REVKEYSIG` or `NO_PUBKEY`.
- It holds exactly one `VALIDSIG`. For `InRelease` and `Release.gpg` during a rotation, it holds
  exactly two, by `current` and `next`.

In the fallback, `$3` must equal `$12`, and both must be listed. Every other rule is the same.

**rpm signatures** are not checked with `gpgv`. The job reads the issuer with
`rpm -qp --qf '%{RSAHEADER:pgpsig}\n' <rpm>` (`RSA/SHA512, <date>, Key ID <16 hex>`). The Key ID
must be the last 16 hex digits of `current` for an rpm this run signed. For an rpm already in the
bucket, it may also match `retired`. It is never the primary's (in the fallback, `current`'s or
`previous`'s). `rpmkeys -K` checks the signature itself (see step 5b of `repos`).

**Before P376**, slice 2's `verify_manifest` checked only the last field of `VALIDSIG` (`$NF`, the
primary). That accepts a signature by any subkey of a listed primary, and by the primary itself.
Slice 2b replaces it with the check above.

**Parsing is strict** (the clearsign pitfalls). A manifest object verifies only if:

- the file starts with `-----BEGIN PGP SIGNED MESSAGE-----` on its first line, holds that line
  and `-----BEGIN PGP SIGNATURE-----` exactly once each, and ends with
  `-----END PGP SIGNATURE-----` and one newline. Nothing comes before or after the one signed
  block;
- the signature check above passes, for a manifest (one `VALIDSIG`, by `current` or `retired`).
  The only exception is an object that `anchor` names, whose SHA-256 must equal the anchor's.

It then parses **only what `gpgv --output -` printed**, which is the signed text with the
dash-escaping removed, never the file itself. Slice 2 tests unsigned lines appended or prepended,
a second signed block, a dash-escaped line, and a signature by a key that is in the key file but
not listed. Slice 2b adds these tests:

- a signature by the primary;
- a signature by an unlisted subkey of the primary;
- a signature by `next`;
- a signature by a `revoked` subkey;
- a signature by an expired `retired` subkey (`EXPKEYSIG`);
- a SHA-256 signature;
- a status line with 11 fields;
- an anchored manifest.

**A retired subkey and expiry.** Once a subkey expires, `gpgv` reports `EXPKEYSIG` for its
signatures. The swap is made 14 days before expiry, and the weekly refresh writes a manifest
signed by the new `current` within 7 days, so no current manifest is ever signed by an expired
subkey. If one were, the run would refuse with NRV-E1142, which says no current manifest
verifies. The owner would then anchor it.

### Channels: prereleases go to `rc`

The owner's decision (owner, 2026-11-12): candidates are published, in a separate `rc` channel,
and `stable` holds releases only. Both share the apt pool.

| Channel | apt | dnf | Holds |
|---|---|---|---|
| stable | `Suites: stable` | `baseurl=https://packages.nerva.pro/rpm/stable` | releases (`X.Y.Z`) only |
| rc | `Suites: rc` | `baseurl=https://packages.nerva.pro/rpm/rc` | releases and candidates (`X.Y.Z-rc.N`) |

- **The rehearsal needs it.** Only a candidate can run before v0.7.1. With a channel for
  candidates, the rehearsal runs every write, signature and install check against the real
  bucket and host.
- **Users cannot reach a candidate by mistake.** `stable`'s signed indexes never list one, and
  dnf's `stable` directory never holds one. Someone who opts in to `rc` gets the release too,
  because `0.7.1` sorts after `0.7.1~rc.2`.
- **A copied channel is caught where apt can catch it.** Each channel's `Release` has its own
  Origin `Nerva`, Label (`Nerva` or `Nerva candidates`), Suite and Codename (`stable` and
  `nerva-stable`, or `rc` and `nerva-rc`). Someone with the R2 token who copies `rc`'s `InRelease`
  over `stable`'s gets a valid signature, but apt on a host that has read `stable` before refuses
  the update, because the Label and Codename changed (apt's `AllowReleaseInfoChange`, an error
  unless the user passes `--allow-releaseinfo-change`). A host reading `stable` for the first
  time only warns ("Conflicting distribution"). dnf checks nothing of the kind. Either way the
  packages are Nerva's own signed candidates, not foreign code. The next write run reports the
  copy (its hash is neither `index` nor `index-was`) and writes `stable` back. Slice 2's container
  test performs the copy and asserts apt's refusal.
- **Pinning.** The Suite name `stable` is also Debian's. A user who pins Nerva should pin by
  Origin (`Pin: release o=Nerva`), never by `a=stable`. INSTALL.md says so.

The cost: a candidate's packages stay in the bucket even after its GitHub release is deleted
(P343 7b), and with the locks they cannot be removed. They are real builds of `main`'s code
(P343). A later candidate takes the next number. Publishing a used tag again with other files is
refused (NRV-E1141).

### Failure modes, and what each does

- **R2 or `packages.nerva.pro` is down:** `apt update` and `dnf` fail on that host. The site is
  unaffected, and the GitHub release still carries every package, so INSTALL.md's
  download-and-install path keeps working. During a release, `repos-ready` cannot read the bucket
  (NRV-E1143), so the draft waits (see "`repos-ready`").
- **Cloudflare Pages is down, or a build fails:** `nerva.pro` keeps serving the last good
  deployment, or nothing during an outage. On a release, `site-verify` reports it (NRV-E1151). The
  packages host is R2, not Pages, and is unaffected.
- **Cloudflare's bot protections challenge apt or dnf:** a challenge page is HTML, so apt says
  "Clearsigned file isn't valid" and dnf says "repomd.xml parser error". The setup turns off Bot
  Fight Mode, and the rehearsal's install checks would show the problem.
- **A dnf client that reads during a run:** dnf fetches `repomd.xml` and then `repomd.xml.asc` in
  two requests. The job writes them back to back, last of all, but a client whose two requests fall
  on either side of that write gets a signature error once, and its next try succeeds. apt has no
  such window: it reads one signed `InRelease`, then fetches the indexes by hash.
- **GitHub disables the weekly refresh** after 60 days with no commit to this repository. See
  "The 60-day rule".
- **The R2 token leaks** (or the site's build gate fails, which gives the same power). Its holder
  can add objects anywhere, and replace or delete the names that are not locked. It cannot sign.
  - **A planted package** is not installed: apt and dnf refuse metadata not signed by the key, and
    dnf refuses an rpm not signed by it. The job never indexes an object the current manifest
    does not list. The next write run notes it and ends red (NRV-E1142).
  - **Deleting or replacing a package or a manifest** is refused by the bucket locks.
  - **Rolling the manifest back** is impossible: the current manifest is the highest generation
    that verifies, and none can be deleted. A copy of an old manifest under a higher name fails
    its `generation` line and is ignored.
  - **Freeze and replay.** The holder can put back an older signed `InRelease` or `repomd.xml`
    with its signature, so users stay on an old version. apt refuses an `InRelease` past its
    `Valid-Until` (at most 21 days old, below). dnf has no signed expiry. The next write run, at
    most a week later, finds a hash the current manifest does not accept (see "Which index hashes
    the next run accepts"), **writes fresh indexes anyway, then ends red with NRV-E1142.** So users
    are healed and the owner is alarmed; a refusal that left the old indexes in place would let the
    holder break `apt update` for everyone once `Valid-Until` passed. The only replay the next run
    accepts is of the set the stopped run replaced, and only after a run that did not finish.
  - **Channel swap:** as in "Channels" above, detected and repaired the same way.
  - **Deleting an index file** is a denial of service until the next write run, which rewrites it
    and reports it the same way.
  - **Junk under a locked prefix** is permanent until the owner removes it. It is ignored and
    reported, never trusted (see "Bucket locks"). Junk at the name of a coming release's package
    stops that package until the owner removes it (`repos-ready` refuses, NRV-E1142).
  - **The key file** is not in the bucket, so the token cannot change it.
- **The CI signing subkey leaks:** the one compromise that reaches users. CI never holds the
  primary, so the owner revokes the subkey and certifies a new one, and the pinned fingerprint
  stays the same. See "Compromise". In the fallback, the leaked key is the whole key.
- **A refresh, `repos`, `repos-verify` or `repos-fresh` fails:** the `alarm` job opens an issue
  labelled `package-repos`, or comments on the open one (see "Alarms").

## The release graph

`release-finish.yml` (P360, P362, P364) gains four jobs and one output:

```
guard ── mac (apple-signing: THE ONE APPROVAL) ── mac-verify ─┬─ repos-ready (package-repos; binds) ─┐
                                                               └──────────────────────────────────────┴─ publish (release-publish; output public)
                                                                                                    ├─ verify        (brew; unchanged)
                                                                                                    ├─ site-verify   (no environment; a release only)
                                                                                                    └─ repos (package-repos; runs if public, even when publish failed later)
                                                                                                         └─ repos-verify (no environment)
```

A new workflow, `package-repos-refresh.yml`, runs the same writer weekly without a tag (see
"`Valid-Until`, and the weekly refresh").

- `publish` gains `repos-ready` in its `needs` and its `if`. Everything that can refuse without
  writing still runs before the draft is published (P362 point 8), so a setup mistake leaves a
  draft, not a published release with no packages.
- **`publish` gains the output `public`.** Its last step, `Is the release public`, runs under
  `if: always()` once `ready` has passed. It asks `gh api repos/$GITHUB_REPOSITORY/releases/tags/$TAG
  --jq .draft` and writes `public=true` when the answer is `false`. It never fails the job. So
  `public` is `true` whenever the release is public, whatever failed after the publish step: the
  date read (NRV-E1138), the tap (NRV-E1135), or the site pull request or its wait (NRV-E1136).
- **`repos` is gated on the publication, not on `publish`'s success:**
  `if: ${{ !cancelled() && needs.repos-ready.result == 'success' && needs.publish.outputs.public == 'true' }}`.
  A tap or site failure after the release is public no longer stops the packages from being
  bound. (Before this, `repos` needed the whole `publish` job to be green.)
- `verify` does not wait for `repos`, and `repos` does not wait for `verify`.
- A failure in `repos` or `repos-verify` happens after the release is public. By then
  `repos-ready` has written the binding into a signed manifest in the bucket (see "What the key
  signs, and who can make it sign"), so **any later write run finishes it**: "Re-run failed jobs"
  of the same run, a dispatch of the tag, or the weekly refresh. There is no 30-day limit.

### What the key signs, and who can make it sign

Release assets stay mutable after publishing, and `SHA256SUMS` is one of them, so a check against
it proves nothing after the fact. A dispatch for a published release skips `mac` (P362 point 10)
and needs no approval. The design therefore binds **new** package content to the approved run
attempt itself, and only while the release is still a draft:

1. **`repos-ready` reads the four packages from the draft and writes the binding,** in the same
   run attempt as the `mac` job the owner approved, so after the approval and before `publish`.
   These checks apply only when `guard` found a draft (`PUBLISHED` is `false`). On a dispatch for
   a published release, `ready` checks neither, binds nothing and writes nothing.
   - **The attempt.** `mac` gains the output `attempt` (`$GITHUB_RUN_ATTEMPT`). `ready` refuses
     with **NRV-E1153** unless it equals its own `GITHUB_RUN_ATTEMPT`. A re-run that does not
     re-run `mac` keeps `mac`'s old output, so a re-run of a failed `repos-ready`, or a "Re-run
     this job" of a green one, binds nothing. Draft assets swapped between the approval and such a
     re-run are never read. The way forward is "Re-run all jobs", which re-runs `mac` and asks the
     owner again.
   - **The draft.** It binds only if the release reads `draft: true`, from its own `gh api` call,
     made before it downloads the packages and again after it has hashed them. It never trusts
     `guard`'s output for this. Where `guard` found a draft but the release now reads published,
     `ready` refuses with NRV-E1148.

   It checks the packages against the draft's `SHA256SUMS` (NRV-E1140). Then it writes the next
   manifest generation with the tag's packages as `pending` entries: each deb once, each rpm
   under `rpm/rc/packages/`, and for a release also under `rpm/stable/packages/`. That manifest is
   its only write. It copies the current manifest's `state`, `index` and `index-was` (see "The
   manifest"). If the tag already has entries with the same `<source-sha256>` (a "Re-run all
   jobs"), it writes nothing. If they differ, see "Pending entries of a release that never
   published".
2. **From then on the signed manifest carries the binding.** Any write run finishes those
   entries from the release's assets once the release is public, but only with bytes whose SHA-256
   equals the entry's `<source-sha256>` (NRV-E1148 otherwise).
3. **A run outside the approved attempt adds no entry.** A dispatch for a published release, a
   "Re-run all jobs" after publication (which re-runs `guard`, now seeing a published release), or
   the weekly refresh: each finishes `pending` entries and re-signs the indexes from the manifest.
   `repos` stops with NRV-E1148 for a tag the manifest has no entries for. A release published
   before the repositories existed is therefore not backfilled; its files install by hand.

So the key signs:

| What | Who can cause it | Bounded by |
|---|---|---|
| A new manifest entry | only `repos-ready` in the run attempt whose `mac` the owner approved, while the release is a draft | the bytes read from the draft in that attempt, recorded at once as `<source-sha256>` |
| An rpm, for a `pending` entry | any write run, once the release is public | the entry's `<source-sha256>`, in a manifest signed by a pinned key |
| `InRelease`, `Release.gpg`, `repomd.xml.asc`, a manifest | any write run: a release run, a dispatch, a re-run, the weekly refresh | a deterministic function of the signed manifest, after the bucket is checked against it |

What the draft held when the approved attempt read it is what gets signed. The approval binds the
run attempt, not the bytes: the owner approves `mac` before any hash of a deb or rpm is read. Anyone who can change a
draft's assets before the approval can already change what the release ships (the Mac zip apart,
which `mac` signs). That is the existing risk of the release, and this spec does not widen it.
Anyone who can merge to `main` here can change the workflows and scripts, and with them all of
the above. That is the guard the release already relies on (automation.md, "Security notes"), and
this design puts the packages' trust in that one place instead of adding a second.

Not chosen: GitHub's immutable releases (published assets cannot change). Its effect on P343 7b's
cleanup of a candidate, which deletes the release and its tag, was not checked, and the binding
above does not need it. It can be added later as a second layer.

### One writer at a time

Every job that writes the bucket runs under one GitHub Actions concurrency group:

```yaml
concurrency:
  group: nerva-packages-bucket
  cancel-in-progress: false
  queue: max
```

`queue: max` (GitHub, 2026-05-07) lets up to 100 jobs wait in order, and cancels none of them. It
is valid only with `cancel-in-progress: false`. Whether GitHub honours it on a job-level group
is not documented; the rehearsal checks it (see "Not verified"). If it does not, the design falls
back to the default queue, described under "The trap".

It is set on the job, not the workflow, on exactly three jobs: `repos-ready` and `repos` in
`release-finish.yml` (a release run and a dispatch alike), and the one job of
`package-repos-refresh.yml`. A concurrency group is per repository, so it spans both workflows. No
other job, workflow or person writes the bucket. There is no lock in the bucket: no `lock/` prefix,
no lock search, no stale or wait timer. The old lock budget (the 30-minute wait, the 100-minute
takeover) no longer applies. A queued writer waits in GitHub's queue for as long as the running job
takes, at most its `timeout-minutes` (90).

**The trap (the fallback, if `queue: max` is not honoured).** With the default queue, GitHub keeps
one running and at most one *pending* job per group. When a third queues, it cancels the older
pending one. So a refresh that queues behind a release's pending
`repos` can cancel it. The design makes that harmless:

- **Every write run does all the work there is.** `repos`, a dispatch and the refresh all finish
  every `pending` entry whose release is public, and re-sign both channels from the manifest.
  None of them needs the job output of another run.
- **The binding is in the bucket before the release is public.** `repos-ready` writes it into a
  signed manifest (see "What the key signs"), and `repos` reads it from there.

**The guarantee.** At most one job writes the bucket at a time. A cancelled `repos` or refresh
loses nothing: the job that replaced it, or the next one to run (the weekly refresh at the latest,
or "Re-run failed jobs", or a dispatch), finishes its work without a new approval. A cancelled
`repos-ready` has written nothing, so the draft waits; "Re-run all jobs" binds it, with a second
approval. That needs two other write jobs at once, one running and one queuing, and is rare.

If the group is ever bypassed (a workflow without it), two writers race on the next manifest name.
`put-new` lets only one of them write it, and the other stops with NRV-E1147 before it writes
anything more (step 2 of `repos`).

### `repos-ready`

- `needs: [guard, mac, mac-verify]`, with the same `if` as `publish`. It runs after the approval,
  because `publish-ready` checks the draft's target (P343), and the twelve assets exist only after
  `mac` (P361).
- `runs-on: ubuntu-24.04`, `timeout-minutes: 15`, `environment: package-repos`,
  `permissions: contents: write` (reading a draft's assets needs it, P311), and the concurrency
  group above. It reads `needs.mac.outputs.attempt`.
- Steps:
  1. Check out the workflow's own ref, with `persist-credentials: false`.
  2. `release_check.sh publish-ready "$TAG"`. It is unchanged.
  3. Install the pinned tools (see "Tools"). A tool that does not install or does not report its
     pinned version is NRV-E1139.
  4. `package_repos.sh ready "$TAG" "$PUBLISHED"`. The environment's secrets and variables reach
     this step only, through `env:`. It runs steps 1 to 3 of `repos` (keys, the current manifest,
     the bucket check, without the disk and own-tag checks), then binds as "What the key signs" says. Its one write is the binding
     manifest, after every check below has passed. It refuses with a code:
     - an environment that lacks a secret, a variable or a pinned tool, a key that does not
       import, a key whose fingerprint is not the `current` one in `packaging/keys/fingerprints`,
       or a key file that does not hold exactly the listed keys (NRV-E1139);
     - a draft without exactly its four packages, or a package that does not match `SHA256SUMS`
       (NRV-E1140);
     - a package name the manifest already lists with another `<source-sha256>`, where any object
       of that tag exists (NRV-E1141);
     - an object already at one of the tag's package names that the manifest does not list, or a
       bucket that step 3 of `repos` refuses before writing (NRV-E1142). Other junk is only
       noted: it does not block the release;
     - a bucket that cannot be listed or read with the token (NRV-E1143);
     - the current manifest served at `https://packages.nerva.pro/manifest/<generation>.asc` that
       differs from the bucket's object (NRV-E1145);
     - a manifest name taken by a manifest that verifies (NRV-E1147, "One writer at a time");
     - `PUBLISHED` false while the release reads published (NRV-E1148, above);
     - with `PUBLISHED` false, a run attempt other than `mac`'s (NRV-E1153, above);
     - a GitHub API call or a download that fails for a reason other than a mismatch
       (NRV-E1155).
  5. Under `if: always()`: `package_repos.sh cleanup`. It runs `gpgconf --kill all` and removes
     the temporary `GNUPGHOME`.

**It blocks the release on a bucket fault, on purpose.** With R2 down, or an object planted in the
bucket, `repos-ready` refuses, and the GitHub release, the tap and the site wait with it, though
none of them depend on the repositories. This keeps P362 point 8 (refuse before publishing): a
release is never published while its packages cannot follow. The recovery is in the table below,
and P365 lists it as a cost.

#### Pending entries of a release that never published

A binding stays armed until its release is deleted: whoever publishes the draft by hand, anyone
with `contents: write`, puts the bytes the owner approved into `stable` at the next write run.
The owner disarms a release they will not ship by deleting the draft and its tag (see Recovery).

`repos-ready` writes the binding before `publish`, so a release can be bound and then never
published: `publish` fails before its publish step and nobody re-runs it, the owner decides not to
ship, or a candidate is deleted (P343 7b). The rule:

- **A run puts a `pending` entry's object only when its release reads published** (`draft:
  false`). A release that reads draft, or answers 404, is skipped: its entries stay `pending`, are
  never indexed, and the run says so in its log as a notice. It is not an error, and it never
  stops or slows any other entry or run. Nothing is ever marked dropped: if the release is
  published later, the next write run finishes it.
- **A GitHub error is never a verdict.** A call that fails for any other reason leaves that tag's
  entries `pending`; the run finishes everything else, then ends with NRV-E1155. A stable release
  is therefore never dropped or wedged by GitHub: at worst it lands one run later.
- **The release's own run is stricter.** `repos` exists to land its own tag, so it ends red if any
  of that tag's entries is still `pending` at the end: NRV-E1155 for a GitHub error, NRV-E1148 for
  a mismatch.
- **Cleanup is not needed.** An inert entry costs one manifest line and one GitHub read per run,
  within the 2,000-entry bound. The one case that needs a change cleans itself up: if the approved
  attempt of the same tag later reads other bytes from the draft (a draft deleted and made again),
  and no object of the tag's old entries exists, `repos-ready` replaces those entries in its
  binding manifest. The old binding was never served, because objects are put only from a public
  release. If any object of the tag exists, it refuses with NRV-E1141: published packages are
  never replaced.

### `repos`

- `needs: [guard, repos-ready, publish]`, with the `if` above, `runs-on: ubuntu-24.04`,
  `timeout-minutes: 90`, `environment: package-repos`, `permissions: contents: read` (the release
  is public now), and the concurrency group above.
- Steps 1 and 3 as in `repos-ready`. Then `package_repos.sh publish "$TAG"`, with the same `env:`
  as before. In this order:
  1. **Keys.** It imports the key into a fresh `GNUPGHOME` under `$RUNNER_TEMP` (mode 0700). It
     writes the passphrase from the environment with `printf`, a shell builtin, so it is never in
     an argv, to `$GNUPGHOME/passphrase` (mode 0600). `gpg.conf` gets `pinentry-mode loopback` and
     `passphrase-file`. It checks the key against `packaging/keys/` as `ready` does (NRV-E1139).
     In the subkey model these are the checks:
     - the secret's primary has no secret part (`gpg --with-colons -K` shows `sec#`);
     - the one usable secret signing subkey is `current`;
     - during a rotation, the second secret, `REPO_SIGNING_KEY_NEXT`, holds only `next` in the
       same way;
     - the primary in both is `primary`.

     A secret that holds the primary's secret part is refused (NRV-E1139). Then the expiry
     check: when `current` expires in under 120 days and no `next` is listed, or in under 30 days,
     the run notes **NRV-E1160**. It finishes its work and then ends red (step 10). It also
     refuses `SOURCE_DATE_EPOCH` in its environment (NRV-E1139): `Date` is the run's clock (step
     5).
  2. **Find the current manifest.** It lists `manifest/` and takes the highest generation that
     verifies (see "The manifest"). It ignores names that are not ten digits and `.asc`, and
     verifies the others from the highest down. Every object it skips is noted. After 50 that do
     not verify, or a listing past `r2.py`'s page bound, it stops (NRV-E1142): the prefix is
     flooded, and the owner removes the junk. Then:
     - **`manifest/` is empty:** the run starts from generation 0. Objects under the package
       prefixes are noted as junk, as everywhere else. This is the first run, and also any run
       after a first run that stopped before it wrote its first manifest: that run wrote nothing.
       There is no object to probe yet, so the first run's step 3 skips the lock probe. The
       rehearsal checks the locks instead: its second write run probes them (see "The rehearsal").
     - **`manifest/` holds objects but none verifies:** it refuses before writing (NRV-E1142). It
       cannot tell junk from a manifest it cannot read. This pipeline verifies every manifest
       before it puts it, so neither a crash nor a failed run of it causes this: the R2 token
       wrote there, or `packaging/keys/` lost a key that signed the manifests.

     Every later put of a manifest is `put-new` at the first free name above the current one. If
     that name answers "exists" and the object there verifies, another writer is running (the
     concurrency group was bypassed): the run stops with NRV-E1147 and writes nothing more.
     Otherwise it is junk: noted, and the run takes the next free name.
  3. **Check the bucket.** Then:
     - **Refused before any write (NRV-E1142):** a listed object that is missing, or whose size or
       `x-amz-meta-sha256` differs from its entry (the locks make both impossible, so the locks
       have failed). A locked object cannot change, so a HEAD of each `published` object is
       enough; the job does not download them to check them.
     - **The locks (NRV-E1149, refused before any write).** It re-puts the current manifest's own
       bytes over it, unconditionally, with `r2.py probe-locked`. R2 must refuse it with the
       exact status and error code that `r2.py` pins for a locked object. If R2 accepts it (the
       bytes are identical, so nothing changes), the lock rule on `manifest/` is gone:
       NRV-E1149. Any other answer is NRV-E1143. The same probe runs on one listed object under
       each other locked prefix that has one.
     - **Noted, not refused:** it lists `apt/pool/` and `rpm/*/packages/`. An object no entry
       lists, a name `rpm/stable/` holds for a candidate, or a listing that reaches `r2.py`'s page
       bound, is noted. Noted objects are never indexed.
     - **The indexes, noted, not refused.** It reads each replaceable name and compares its
       SHA-256 with the hashes the current manifest accepts (see "The manifest"). A name that
       matches none, or that is missing while the manifest lists it, is noted. The run carries on,
       rewrites every index in step 7, and ends with NRV-E1142 (see "The R2 token leaks").
     - **Bound:** at most 2,000 entries and 4 GiB in the manifest. Above that the job refuses
       (NRV-E1142) and a decision is needed: a pruning policy, or indexes built without
       downloading the packages. At about 38 MB a release (the rpms twice), and less for a
       candidate, that is about 100 releases away. Junk does not count towards it.
     - **Disk.** Before it downloads anything it checks that the runner has free space of twice
       the manifest's package bytes plus 2 GiB, and stops with NRV-E1156 otherwise. Step 5 needs
       every package on disk.
     - **Its own tag.** `repos` stops with NRV-E1148 if the manifest has no entry for `$TAG`
       (nothing was bound). The refresh has no tag and skips this.
  4. **Put.** For every `pending` entry, of any tag:
     - the object exists with the entry's SHA-256: nothing to do (an earlier run put it);
     - it exists with other content: noted (NRV-E1142 at the end). The entry stays `pending` and is
       not indexed, until the owner removes the object ("Removing an object from a locked
       prefix");
     - it is absent: the run reads the entry's release. If it does not read published, or the
       read fails, the entry is skipped as "Pending entries of a release that never published"
       says. Otherwise:
       - a deb: download it from the release, check its SHA-256 against `<source-sha256>`
         (NRV-E1148), put it with `put-new`;
       - an rpm has one entry per channel, `rpm/rc/` and `rpm/stable/`, both for the same file. If
         the entry has a recorded hash (not `-`) and the other channel's object exists with it,
         put those bytes. Otherwise download the release's rpm, check `<source-sha256>`
         (NRV-E1148), sign it (see "Signing"), and check that the signed copy has the release
         file's NEVRA and payload digest (NRV-E1144), and **verify its signature** ("Verify an
         rpm first", below, NRV-E1161). A new signature differs, so the run
         **first** writes a manifest generation that records the new `<sha256>` and `<size>` on
         **every** entry of that file, in both `rc` and `stable`, and copies `state`, `index` and
         `index-was` (see "The manifest"). **Only then** does it put the objects, each with
         `put-new`. A crash between the two puts leaves both entries recorded, so the next run
         finds the missing object's entry hash and copies the bytes of the one that exists.

     **Verify an rpm first (P376, NRV-E1161).** Before the run records an rpm's hash in a
     manifest or puts it, including a copy of the other channel's object, it checks the exact
     bytes it is about to put, in a scratch rpm database it made at the start of this step
     (`rpmdb --initdb --dbpath <scratch>`, then `rpmkeys --dbpath <scratch> --import
     packaging/keys/nerva-release.asc`, which must leave exactly one `gpg-pubkey`):
     - `rpmkeys --dbpath <scratch> -K <rpm>` exits 0 and reports `digests signatures OK`;
     - `rpm -qp --qf '%{RSAHEADER:pgpsig}\n' <rpm>` reads `RSA/SHA512, <date>, Key ID <16 hex>`,
       with the digest `SHA512` and the Key ID as "The manifest" says.

     An rpm that fails is not recorded and not put. The run stops with NRV-E1161, and the bucket
     and the manifests hold nothing of it. So no object that fails this check ever reaches a
     locked prefix, and the locks never keep a bad one. The signing run's own key, secret and
     passphrase are the usual cause, so fixing them and re-running signs the rpm again.

     So every package object the job ever writes is listed in a signed manifest before it exists.
     A download from GitHub that fails for another reason (the network, the API) is NRV-E1155.
  5. **Indexes.** It regenerates both channels of both formats from the entries whose objects are
     all present with their SHA-256 and not `excluded` (they are about to be `published`), and
     never from anything else: `stable` from the releases, `rc` from everything. A failure of `apt-ftparchive` or
     `createrepo_c` is NRV-E1156.
     - **apt:** for each channel it makes a staging tree of hard links to that channel's debs and
       runs `apt-ftparchive -a <arch> packages pool/main/n/nerva` for `amd64` and `arm64`, writing
       `Packages` and `Packages.gz`. With only those files under `dists/<channel>/`, it runs
       `apt-ftparchive release` with the channel's Origin, Label, Suite and Codename (above),
       Architectures `amd64 arm64`, Components `main`, `Acquire-By-Hash: yes`, and `Valid-Until`
       21 days after `Date`. **`Date` is the signing run's clock**, as `apt-ftparchive` writes
       it, and not a fixed or reproducible date (P376). `Release` exists to be re-signed with a
       fresh `Valid-Until`, so two runs over the same manifest give different `Release` files on
       purpose. The run refuses `SOURCE_DATE_EPOCH` (step 1). It checks that `Date` is within
       10 minutes of its own clock (NRV-E1156 otherwise). Only then does it make the
       `by-hash/SHA256/<hex>` copies and sign `InRelease` (clearsign) and `Release.gpg`
       (detached), so `Release` never lists `by-hash/` or an old signature. During a rotation it
       signs both with `current` and `next` (see "Rotation").
     - **dnf:** for each channel it makes a staging tree whose `packages/` holds that channel's
       rpms, then runs `createrepo_c --general-compress-type=gz --checksum=sha256 --no-database
       --revision <now, epoch seconds>`, which gives unique names for everything but
       `repomd.xml`, and signs `repomd.xml.asc` (detached, armored).
  5b. **Verify before upload (P376, NRV-E1161).** Nothing of the indexes has been uploaded yet.
      The run checks its own output against the public key file alone. It uses the runner's
      rpm 4.18 and gpgv, so it checks signatures, digests and the Key ID, not the policy of rpm 6
      or Sequoia, nor an expired or revoked subkey, which rpm 4.18 does not judge as they do.
      Those are checked only by slice K's cells and by `repos-verify`, which install on real
      distributions. This step is the gate before upload, not a substitute for them:
      - **A public-key-only home.** It makes a new, empty `GNUPGHOME` under `$RUNNER_TEMP`, with
        no secret key and no agent. The only keyring is the `gpg --dearmor` of
        `packaging/keys/nerva-release.asc`, passed with `--keyring`.
      - **apt, for each channel.** `gpgv --status-fd 3 --output <out> InRelease`, and `<out>`
        must equal `Release` byte for byte. Then `gpgv --status-fd 3 Release.gpg Release`.
      - **dnf, for each channel.** `gpgv --status-fd 3 repomd.xml.asc repomd.xml`.
      - **Each status** must pass the signature check of "The manifest" for its kind.
      - **rpms.** It runs step 4's check again, with the same scratch database, on every rpm that
        either channel's `repodata` lists, including rpms put by earlier runs.
      - **What was already checked.** The manifests are verified before each put (see "The
        manifest"), and each rpm's signature, NEVRA and payload are checked in step 4 before it
        is recorded or put (NRV-E1161, NRV-E1144). This step adds the indexes, and re-checks every
        indexed rpm in one place under one key file.
      - **On a failure of an index signature** the run stops with NRV-E1161 and has written
        nothing for this step. The manifests and packages from step 4 stay, and the next run
        finishes them.
      - **On a failure of an rpm that is already in the bucket** (a key revoked since, or an
        object put before this check existed), the run does not stop, because the object is
        locked and cannot be replaced. It writes a manifest generation that marks every entry
        of that file `excluded` (copying `state`, `index` and `index-was` as step 4's generations
        do), redoes steps 5 and 5b without it, and ends red with NRV-E1161 after step 10. An
        `excluded` entry is never indexed and its object stays where it is. The other releases'
        packages are indexed and signed as usual, so apt and dnf keep working and `Valid-Until`
        is renewed. The release the rpm belongs to gets a decision, normally a patch release.
  6. **Promote and record.** It writes the next manifest generation, `state writing`: those
     entries as `published`, `index` lines with the SHA-256 of every replaceable file from step 5,
     and `index-was` lines as "The manifest" says.
  7. **Upload the indexes.** First every content-named file (`by-hash/...`, the hashed `repodata`
     files), each with `put-new`. When one already exists, the job GETs it and compares its
     SHA-256 with the name's. A mismatch is noted (NRV-E1142 at the end), and the job replaces it
     with `put`: these names are in `put`'s replaceable set, because their content is fixed by
     their name. Then the names a run replaces: apt's `Packages`, `Packages.gz`, `Release` and
     `Release.gpg` for each channel, with `InRelease` last; then for each channel `repomd.xml.asc`
     and `repomd.xml`, back to back, last of all. `r2.py put` refuses any name outside the
     replaceable set, so a bug cannot overwrite a package, and the locks refuse it too.
  8. **Served (P376: everything the run wrote).** It keeps a list of every object it put or
     replaced in this run. Over `https://packages.nerva.pro`, with no query string and no
     cache-busting header (users get what Cloudflare's edge gives), it fetches each one and
     compares the bytes with the local file it uploaded (NRV-E1145). The list covers:
     - every manifest this run wrote, the `writing` one included. The `complete` one is checked
       the same way after step 9;
     - every package object it put;
     - every content-named index file it put, and every replaceable name of both channels.

     `repos-ready` does the same for its binding manifest before it ends. The run is still the
     group's one writer, so no other run can change those bytes under it. The replaceable names
     carry `no-cache`, so the edge revalidates them. A difference is retried every 10 seconds
     for up to 2 minutes, then refused.
     - **Bound.** Each channel has 7 apt names (`InRelease`, `Release`, `Release.gpg`, and
       `Packages` and `Packages.gz` for two architectures), 4 by-hash files and 5 dnf names
       (`repomd.xml`, `repomd.xml.asc` and three hashed `repodata` files). That is 32 for both
       channels. On top come at most 4 manifests and the package objects the run put: 6 for a
       release (2 debs, and 2 rpms under each of 2 channels), about 40 MB. A refresh puts none.
       The worst case is the manifest's own bound of 2,000 entries and 4 GiB, which only a run
       finishing many releases at once could reach.
     - **Cost.** About 40 small requests and the package bytes, so under a minute for a release
       and seconds for a refresh. R2 charges nothing for egress, and the reads are Class B
       operations, far inside the free 10 million a month.
  9. **Complete.** It writes the next manifest generation, the same as step 6's with
     `state complete`.
  10. **End.** If anything was noted, it ends with NRV-E1142 and names each object and its hash.
      If step 1 noted the subkey's expiry, it ends with NRV-E1160 once everything else has passed.
      If a GitHub read failed, NRV-E1155. For `repos`, if an entry of `$TAG` is still `pending`,
      NRV-E1155 or NRV-E1148 as its cause was.
- `package_repos.sh cleanup` runs under `if: always()`.

**Idempotence.** Every write is a signed manifest that lists what will exist before it exists, a
write-if-absent put of content the job compares first, or indexes regenerated from the manifest.
A run stopped at any step leaves the bucket in a state the next write run accepts and finishes:

| Stopped after | The bucket holds | The next write run |
|---|---|---|
| anything before the first manifest of the first run | nothing | starts from generation 0 |
| `repos-ready`'s binding manifest | entries, no objects | puts them (step 4) once the release is public |
| an rpm's new-signature manifest in step 4 | the new hash on both channels' entries, no object | puts the bytes of whichever object exists, else signs again and records the newer hash on both |
| an rpm's first channel put in step 4 | both entries recorded, one object | copies that object's bytes to the other channel |
| part of step 4 | some objects of pending entries | puts the rest; adopts what is there with the entry's SHA-256 |
| step 4 | all objects, entries pending | indexes, then promotes |
| step 4's rpm check (NRV-E1161) | nothing of that rpm: no manifest line, no object | signs it again; a lasting failure is a finding |
| step 5b, an index signature (NRV-E1161) | the same: nothing of step 5 was uploaded | indexes and verifies again; a lasting failure is a finding |
| step 5b, an rpm already in the bucket (NRV-E1161) | an `excluded` generation, the object still there | indexes without it, and ends red; the owner decides the release |
| step 6 | the promoted manifest (`writing`), the old indexes (`index-was`) | accepts them, rewrites every index |
| part of step 7 | new content-named files, each replaceable name at `index` or `index-was` | accepts them, rewrites every index |
| step 7 or 8 | the new indexes, a `writing` manifest | accepts them, rewrites every index |

A second run of a finished release writes no package object; it writes manifests and the indexes
again, with the same content but new dates and signatures. The job never replaces or deletes a
package object or a manifest.

### `Valid-Until`, and the weekly refresh

apt's `Release` carries `Valid-Until`, 21 days after `Date`, so a replayed `InRelease` stops
working at most 21 days after it was signed. Something must therefore re-sign within 21 days even
when no release happens: `package-repos-refresh.yml` runs `package_repos.sh refresh` every Monday
at 05:17 UTC (and by `workflow_dispatch`), from `main`, in `package-repos`, under the shared
concurrency group (see "One writer at a time"), with `timeout-minutes: 90` like `repos`. `refresh`
is `publish` without a tag: it checks the bucket, finishes `pending` entries of public releases,
promotes, and re-signs both channels. Every release run does the same. Two refreshes can fail in a row before users see "Release file … is expired".
A failed scheduled run e-mails the account that last changed the workflow's `schedule` line, which
is `topwombat`, and its fix is a re-run. That e-mail goes to one inbox and is easy to miss, so a
failure also opens or comments on an issue (see "Alarms"). dnf has no signed expiry: the cost
stays as P365 lists it.

**A missed refresh.** GitHub can delay or drop a scheduled run, and it can disable the schedule
(see "The 60-day rule"). At its start, the refresh reads the `Date` of `stable`'s served
`InRelease`. If that is more than 8 days old, the previous refresh did not run. The refresh then
asks the `alarm` job to comment on the issue ("the refresh before this one did not run"). It
carries on regardless. `repos-fresh` (below) catches the case where no refresh runs at all.

### Alarms (P376)

Each workflow that can leave the repositories stale or unchecked ends with one more job, `alarm`:

- `release-finish.yml`, after `repos` and `repos-verify`;
- `package-repos-refresh.yml`, after its job;
- `ci.yml`, after `repos-fresh`.

The job:

- **Runs** with `if: ${{ always() && contains(needs.*.result, 'failure') }}`, and **never on
  `cancelled`**. `ci.yml` cancels a superseded run on `main` (`cancel-in-progress: true`), so two
  merges close together cancel the first run, which is not a fault. The write jobs use
  `cancel-in-progress: false`, so only a person cancels them. A run that never happens is found
  by the two clocks, not by the alarm: the refresh reports an `InRelease` signed more than 8 days
  earlier, and `repos-fresh` fails at under 10 days left, and both are `failure`.
  The refresh's job also sets the output `missed`, and the alarm runs when it is `true`. It never
  runs on pull requests. `repos-fresh` runs only on `push` to `main`, and `release-finish.yml`
  and the refresh never run on pull requests.
- **Token.** It uses the workflow's `GITHUB_TOKEN`, with
  `permissions: { issues: write }` set on the job and nothing else. It has no environment, no
  secret and no checkout of untrusted code. It checks out the workflow's own ref for
  `repos_alarm.sh`, with `persist-credentials: false`. Opening an issue and commenting on one
  need `issues: write` and no other permission.
- **What it does.** It runs `.github/scripts/repos_alarm.sh <workflow> <job> <code> <run-url>`.
  The failed job's `code` output carries the code (each `package_repos.sh` step writes the code
  it ended with to `$GITHUB_OUTPUT`; `unknown` if the job died before that). The script reads,
  through REST only, `gh api 'repos/{owner}/{repo}/issues?labels=package-repos&state=open&per_page=1'`.
  - **An open issue exists:** it adds one comment, "`<workflow>` / `<job>` failed with `<code>`:
    `<run-url>`", unless that issue already has a comment for the same (workflow, job, code)
    from the last 24 hours, read from the issue's last 100 comments. So there is at most one
    comment per (workflow, job, code) per day, and a Cloudflare or R2 outage, or the 106-day
    window of NRV-E1160, adds a few lines a day, not one per merge. The count of runs skipped
    is in the next comment that is posted.
  - **None is open:** it opens one, titled "Package repositories: `<workflow>` failed
    (`<code>`)", labelled `package-repos` and **assigned to the owner** (the login in the
    repository variable `PACKAGE_REPOS_OWNER`, setup step 6), with the same line and a pointer to
    this document's "Recovery". Assigning notifies the owner whatever their watch settings are. There is never more than one open alarm issue. Later failures, of any kind,
    become comments on it, until the owner closes it after the fix.
- **Its own failure** (GitHub down, the label missing) prints **NRV-W1103**, "the alarm could not
  be filed", and the job uses `continue-on-error: true`. An alarm never turns a run green or red.
  The failed job is still red, and the scheduled run's e-mail still goes out.
- **The label** `package-repos` and the variable `PACKAGE_REPOS_OWNER` are made once, in setup
  step 6.
- **A test.** The refresh's `workflow_dispatch` takes a boolean input `alarm_test`. With it, the
  job fails at once with the code `alarm-test`, before it reads a secret or touches R2, so the
  rehearsal tests the alarm without writing anything.

**Why this and not only the 60-day rule.** The 60-day rule catches one cause: a schedule that
GitHub disabled. A refresh that runs and fails every week, a dropped run, a failed `repos-verify`
or an expiring subkey are each silent, apart from one e-mail. An open issue stays visible in the
repository until someone closes it.

### The 60-day rule

GitHub disables a public repository's scheduled workflows after 60 days with no commit, without a
failed run to e-mail about. Then `Valid-Until` lapses about 21 days later, and every `apt update`
fails with "Release file … is expired" while dnf keeps working. Two alarms come before that:

1. **The refresh warns from day 45.** After it has re-signed, `refresh` reads the date of the
   newest commit on `main` (`gh api repos/$GITHUB_REPOSITORY/commits/main --jq
   .commit.committer.date`). If it is more than 45 days old, the run ends with NRV-E1150: "the
   repository has had no commit for N days; GitHub disables this schedule at 60". The failed
   scheduled run e-mails the owner every Monday from day 45 to day 60, and the `alarm` job
   comments on the issue each time. The fix is any commit to
   `main`, such as a worklog note. The refresh never commits by itself: `main` is protected, and
   a bot that keeps a repository looking active would hide the real state.
2. **CI checks the expiry on every push to `main`.** `ci.yml` gains a job, `repos-fresh`, on
   `push` to `main` only, never on pull requests, and not a required check, so a Cloudflare
   outage never blocks a pull request. It fetches `stable`'s `InRelease` from
   `https://packages.nerva.pro`, verifies it with `gpgv` against a keyring made from
   `packaging/keys/` with `gpg --dearmor` (`gpgv` does not read armored keys), using the same
   signature check as the job (see "The manifest"). It fails with NRV-E1150 if its
   `Valid-Until` is less than **10** days away (P376; it was 7). A run that has just re-signed
   leaves 21 days, and a weekly refresh keeps at least 14, so under 10 means at least one refresh
   was missed. That leaves more than a week to act before apt refuses. It also fails with
   NRV-E1160 when `current` in the key file expires within 120 days and no `next` is listed, or
   within 30 days. A failure runs the `alarm` job. Until the rehearsal has written
   the bucket, the job passes with a notice: it runs only when the repository variable
   `REPOS_LIVE` is `true`, which the pull request that records the rehearsal sets (one
   `gh variable set`, in "The rehearsal").

The recovery, if the refresh was disabled: `gh workflow enable package-repos-refresh.yml --repo
NervaLog/nerva`, then `gh workflow run package-repos-refresh.yml --repo NervaLog/nerva --ref main`.

### `repos-verify`

- `needs: [guard, repos]`, no environment, no secret, `permissions: contents: read`.
- A matrix of `runs-on` × image, with every image pinned by digest at slice time:

  | Runner | Images |
  |---|---|
  | `ubuntu-24.04` (amd64) | `debian:12` (gpgv), `debian:13` (sqv), `ubuntu:22.04` (apt 2.4), `ubuntu:24.04`, `rockylinux:9` (rpm 4.16), `fedora:43` (rpm 6, dnf 5), `fedora:44` |
  | `ubuntu-24.04-arm` (arm64) | the same seven |

  That is every distribution the install text names, so fourteen cells. Fedora 43 is the first
  Fedora with rpm 6 and its enforcing signature policy; Debian 13 is the first with apt verifying
  through `sqv`; Ubuntu 22.04 has the oldest apt and gpgv the text supports. If Fedora 45 has been
  released by slice 4's date, slice 4 adds `fedora:45` too, pinned the same way, and the install
  text names it. Fedora 41 and 42 are past their end of life and are not supported: the install
  text says "Fedora 43 and later".
- **dnf 5.** The `fedora:43` image is pinned at a digest whose dnf5 is at least
  `5.2.18.0-4.fc43` (the fix for RHBZ 2458182, a five-minute hang on importing a repository key),
  `fedora:44` at one with the same fix, and the check asserts `rpm -q dnf5` against that version
  before it starts.
- **Setup is not the check.** Pulling the image and installing the prerequisites the install text
  assumes (`curl`, `ca-certificates`, `gnupg` on Debian and Ubuntu) run first. A failure there is
  NRV-E1157 (the environment: a registry or a mirror), not NRV-E1146.
- Each cell runs `.github/scripts/repo_install_check.sh <apt|dnf> <channel> <base-url>
  <fingerprint> <version>` in the container, with the channel the tag belongs to: `rc` for a
  candidate, `stable` for a release. The script runs **INSTALL.md's own commands** (the same text,
  kept in step by slice 2's test), with `-y` added where they prompt. It fetches the key and checks
  its primary fingerprint (`<fingerprint>` is `primary` in `packaging/keys/fingerprints`; in the
  fallback, `current`). For apt it writes the `.sources` file and runs `apt-get update` and
  `apt-get install -y nerva=<package version>`. For dnf it writes the `.repo` file with
  `gpgcheck=1`, `repo_gpgcheck=1` and `gpgkey=`, and runs `dnf install -y nerva-<package
  version>`. It does **not** run `rpm --import`. dnf 5 verifies `repomd.xml` with its own
  repository keyring, which it fills from `gpgkey=` on first use. A key only in the rpm database
  gives "repomd.xml GPG signature verification error: Signing key not found" (Fedora 41 reports),
  and a user following INSTALL.md never runs `rpm --import` either. Then `nerva version`'s last
  line must be `version <V>`.
- **A candidate also checks `stable`:** with `stable` configured, `apt-cache policy nerva` and
  `dnf list --showduplicates nerva` must not list the candidate. The check reads their output,
  never their exit status: on an empty channel (the rehearsal's `stable`) `dnf list` exits 1 with
  "No matching packages to list", which is the right answer here.
- A failure is NRV-E1146. The release is already public, so the message says that, and that the
  GitHub release's files still install by hand (INSTALL.md).

### `site-verify`

Yes, the release checks that `nerva.pro` shows it. It is its own job, not a step of `verify`:
`verify` is the reusable `mac-verify.yml`, which runs on Macs and stays unchanged.

- `needs: [guard, publish]`, `if: needs.publish.result == 'success'` and the tag is a release (a
  candidate's site pull request is never merged, P364). No environment, no secret,
  `permissions: {}`, `runs-on: ubuntu-24.04`, `timeout-minutes: 20`.
- `release_finish.sh site-live "$TAG"` fetches `https://nerva.pro/` every 20 seconds, with
  `Cache-Control: no-cache`, until the served page holds the `RELEASES` entry for the version that
  `site_release.py` wrote (`{v:"<V>"`). Its deadline is **15 minutes** from the start of the job.
  `publish` has already waited for the merge, and a Cloudflare Pages build of one file normally
  deploys within two minutes, so 15 minutes leaves room for Cloudflare's build queue and nothing
  more.
- At the deadline it fails with **NRV-E1151**: "nerva.pro does not show <V> 15 minutes after the
  site's pull request merged; the release is public and its packages are unaffected". The fix: in
  the Cloudflare dashboard, open the `nerva-site` project's deployments. A failed build shows its
  log (NRV-E1152 if the gate refused). "Retry deployment" deploys `main` again; then re-run
  `site-verify`.
- **The WKD key (P376).** Once the page shows the release, `site-live` fetches
  `https://nerva.pro/.well-known/openpgpkey/hu/ndqm47zydhyqyzabecddtdk1q3bponab?l=nerva`, with no
  cache busting. It must equal, byte for byte, `gpg --dearmor` of `packaging/keys/nerva-release.asc`
  at the release commit. Otherwise it fails with **NRV-E1162**: "nerva.pro's WKD key differs from
  packaging/keys at <tag>; users who compare the two channels will stop". The fix is a site pull
  request that replaces the file, then a re-run of `site-verify`. It does not touch the packages.
- `publish`'s meaning of "published" (P364) changes in one word: the site pull request is merged
  after `site-check` passes, exactly as now, and the page is published when **Cloudflare** has
  deployed that merge, which `site-verify` checks.

### Recovery

| What stopped | Do |
|---|---|
| `repos-ready` refused NRV-E1139, NRV-E1140, NRV-E1145 or NRV-E1155 | Fix the setup it names (or wait for GitHub), then "Re-run all jobs": it re-runs `mac` and asks the owner to approve again. "Re-run failed jobs" would only fail with NRV-E1153. Nothing was published or written |
| `repos-ready` refused NRV-E1143 (R2 unreachable) | The draft waits. "Re-run all jobs" when R2 answers (a new approval). To ship without packages instead, the owner decides; that is a new decision, and the tag is then never bound |
| `mac-verify` failed (a brew or network fault on the Mac runner) | Use "Re-run all jobs" and approve again. "Re-run failed jobs" re-runs `repos-ready` against `mac`'s old `attempt` and ends in NRV-E1153. Nothing was written |
| `repos-ready` refused NRV-E1153, or was cancelled while pending (see "One writer at a time") | Use "Re-run all jobs" and approve again. Nothing was written |
| `repos-ready` refused NRV-E1141 or NRV-E1142 | Stop. The bucket holds something no signed manifest allows. The owner rotates the R2 token and decides. The draft waits |
| `repos-ready` refused NRV-E1148 (the release was already public) | Someone re-ran `repos-ready` alone after publication. If its binding manifest was written, nothing is needed: re-run `repos` or wait for the refresh. If not, the tag was never bound: the owner decides |
| `publish` failed after the release went public (NRV-E1135, E1136, E1138) | `repos` runs anyway (`public` is `true`). Recover the tap or the site as P362 and P364 say |
| `publish` failed before the release went public | Re-run it as P362 says. The binding waits in the manifest, inert, until the release is public (see "Pending entries of a release that never published") |
| The owner decides not to ship a bound release | Delete the draft release and its tag. The run then reads a 404, skips the entries, and they stay inert. Until that is done the binding is armed: anyone who publishes the draft puts it into `stable` at the next write run |
| `repos` stopped part way, was cancelled while pending, or failed with NRV-E1143, NRV-E1155 or NRV-E1156 | "Re-run failed jobs" of the same run, or a dispatch of the tag, at any time; the weekly refresh also finishes it. It converges (the table above). No approval is needed: the binding is in the manifest |
| `repos` or the refresh failed NRV-E1147 | Two writers ran at once: something wrote the bucket outside the concurrency group. Find the run or workflow without the group and fix it, then re-run. Nothing was half written: the loser stopped before its next write |
| `repos` refused NRV-E1148 for its own tag | The bytes on the release differ from what the approved run read, or nothing was bound (a release published before the repositories, or a binding that was never written). Stop: the owner decides (a new patch release, normally). The release's files still install by hand |
| `repos` refused NRV-E1141 or NRV-E1142 before writing | Stop. A listed object is missing or changed, an unlisted object holds a name the run must write, or `manifest/` holds objects and none verifies. A crash of this pipeline never causes these, so suspect the R2 token (or a key removed from `packaging/keys/`): the owner rotates the token and decides. Junk at a name the run must write is removed as in "Removing an object from a locked prefix" below |
| `repos` or the refresh ended NRV-E1142 after it finished | Something outside a run wrote to the bucket: an index replaced or deleted (users are already healed), or junk under a locked prefix (ignored, and its name skipped). The owner rotates the R2 token. Junk stays until the owner removes it as below; until then every run ends red with the same note |
| NRV-E1149 | A bucket lock rule is gone. The owner restores it as setup step 5 says, and checks the account's audit log for who removed it |
| `repos-verify` failed NRV-E1157 | The environment (a registry or a mirror). Re-run it |
| `repos-verify` failed NRV-E1146 | A finding: file it. The release is already public |
| `site-verify` failed NRV-E1151 | As in "`site-verify`" above |
| The weekly refresh failed, or was cancelled | Re-run it, or let the next writer run. apt users have at least a week before `Valid-Until` |
| The refresh or `repos-fresh` failed NRV-E1150 | As in "The 60-day rule" |
| A write run or `repos-fresh` ended NRV-E1160 | The CI subkey expires soon. Follow "Rotation" from the step it names: certify `next`, or swap. The run itself re-signed and is otherwise done |
| `repos` or the refresh stopped NRV-E1161 | Its own signatures do not verify against `packaging/keys/`: an rpm in step 4 (nothing of it was recorded or put), or an index in step 5b (nothing of the indexes was uploaded). Suspect a key file and secret that disagree (a rotation done halfway) or a tool change. Fix it, then re-run. It is a finding until explained. If it ended red after writing an `excluded` generation, the rpm was already in the bucket: see "Compromise" |
| `site-verify`, or a site pull request, failed NRV-E1162 | The WKD file in the site repository differs from `packaging/keys/`. Open a site pull request with the `gpg --dearmor` of the key file. If nobody here changed the key, treat it as a compromise of the site and check its history |
| An issue labelled `package-repos` was opened or commented on | Read its runs' codes and recover each as this table says. Close the issue once a later run is green. NRV-W1103 in a run means the alarm itself failed: check the label exists and GitHub's status |

#### Removing an object from a locked prefix

Only the owner can do this, in the Cloudflare dashboard, and only for an object no verified
manifest lists. It is the one way to remove junk, and it opens the lock for a few minutes, so it
follows these steps in order:

1. Rotate the R2 write token first ("Rotating the R2 token", under Setup), so whoever wrote the
   junk cannot write during the gap.
2. Make sure no write job is running or pending (Actions: `repos-ready`, `repos` and the
   refresh).
3. In the bucket's **Settings**, **Bucket lock rules**, delete the rule for the prefix that holds
   the object.
4. Delete the object or objects. Nothing else.
5. Add the rule again exactly as setup step 5 says (prefix, indefinite retention).
6. Check the account's audit log: the rule was removed and re-added, and nothing else changed.
7. Re-run the run that stopped, or dispatch `package-repos-refresh.yml`. Its step 3 probes the
   lock rules again (NRV-E1149 if the rule is not back).

## Signing

**The key model is "test, then subkey" (P376, which amends P365 point 12).** The model below is
adopted only if slice K passes. If it does not, the single key of P365 is used, as "The fallback:
one key" says. Every other part of this spec works with either.

### The subkey model

- **The primary** is an RSA 4096 key, **certify-only**, with **no expiry**. It never signs a
  repository, an rpm or a manifest, and the job refuses any signature it makes (see "The
  manifest"). It certifies the subkeys and signs their revocations, and it is used for nothing
  else. It lives offline, and CI never holds it. Its fingerprint is `primary` in
  `packaging/keys/fingerprints`. **That pin never changes:** it is the fingerprint users check
  once.
- **The signing subkey** is an RSA 4096 subkey with signing capability only, which **expires one
  year** after it is made. CI holds this subkey, or two during a rotation's overlap, and nothing
  more: `REPO_SIGNING_KEY` is an export
  of the subkey alone, in which the primary is a stub with no secret part (GnuPG shows `sec#`).
  It is `current` in `fingerprints`.
- **Why RSA 4096, not Ed25519.** apt (`gpgv` on Debian 12 and Ubuntu, `sqv` on Debian 13),
  Rocky 9's rpm 4.16 and Fedora's rpm 6 (Sequoia) all verify RSA with SHA-512. rpm 4.16's EdDSA
  support is the weak point of older RPM distributions. The self-signatures and binding
  signatures use SHA-512 (`--cert-digest-algo SHA512`), which `sqv`'s policy accepts.
- **Why test first.** rpm 4.16 is the oldest verifier in scope, and its handling of subkeys is
  the open risk. With subkeys, rpm looks up the issuer by subkey ID inside the imported
  certificate. What rpm 4.16 and rpm 6 do with a new subkey of a primary they have already
  imported is unknown here. Slice K finds out (see "Slices").
- **Why one year.** A subkey that leaks, and whose revocation a host never fetches, stops being
  accepted when it expires. apt refuses a signature by an expired key, but `InRelease` and
  `repomd.xml.asc` are re-signed every week with the current subkey, so an expiry breaks no user
  who has the current key file. Packages are another matter. An rpm keeps the signature it was
  given, and the locks forbid re-signing it, so an rpm signed by a subkey that has since expired
  must still verify. Slice K tests this on every rpm cell. **If any cell refuses such an rpm,
  subkeys are made without expiry**: rotation becomes a policy, revocation is the only bound, and
  NRV-E1160 is left out.
- **Digest:** `--digest-algo SHA512` for every signature, and `%_gpg_digest_algo sha512` for rpm.

It signs:

| What | How | Subkeys allowed |
|---|---|---|
| apt `InRelease`, `Release.gpg` | `gpg --clearsign`, `gpg --detach-sign --armor` of `Release`, with `-u <current>!` (and `-u <next>!` during a rotation). The `!` forces that exact subkey | `current`, `next` |
| dnf `repomd.xml.asc` | `gpg --detach-sign --armor -u <current>! repomd.xml` | `current` |
| each rpm | `rpmsign --addsign`, with `--define "_gpg_name <current>!"`, `--define "_gpg_path $GNUPGHOME"` and `--define "_gpg_sign_cmd_extra_args --pinentry-mode loopback --passphrase-file $GNUPGHOME/passphrase"`. The path to the passphrase file is in the argv; the passphrase is not | `current` |
| each manifest | `gpg --clearsign -u <current>!` | `current` (a `retired` one is still accepted until it is replaced) |

**The release's assets stay as P295 left them: unsigned, and covered by `SHA256SUMS`.** The
repository's rpm is a signed copy: `rpmsign` adds a signature header and changes neither the main
header nor the payload, and the job checks this (NRV-E1144). Debs are not signed one by one,
because apt's trust comes from the signed `InRelease` and its hashes, so the repository's deb is
the release's file, byte for byte. Every signature is checked again before upload (step 5b of
`repos`, NRV-E1161).

**Custody.**

- **The primary's secret key** exists only offline, on two encrypted USB drives kept in two
  places. On each drive is the export of a throwaway GnuPG home, made on the owner's Mac during
  the ceremony (setup step 4) and then deleted from the Mac. The password manager holds the
  primary's passphrase and its revocation certificate, never the secret key itself. The
  revocation certificate revokes the primary. It is used only if the primary is lost or leaked,
  which would mean a new pin for every user. The primary is brought online for the ceremony, for
  each rotation (yearly) and for a revocation, then removed again.
- **The CI subkey** is the secret `REPO_SIGNING_KEY` of the environment `package-repos`. It is an
  export of the subkey only (`gpg --export-secret-subkeys` with the subkey's fingerprint and `!`),
  re-protected before export with its own passphrase, `REPO_SIGNING_PASSPHRASE`, which is not the
  primary's. Both secrets reach only the `package_repos.sh` steps (`ready`, `publish`,
  `refresh`), through `env:`, and never an argv, a URL or the log. GitHub masks both, and the
  scripts never echo them. `package_repos.sh` refuses a secret that holds the primary's secret
  part (NRV-E1139). So a merge that dumps the secret can leak the subkey, never the primary.
- **No backup of the CI subkey** is needed. If it is lost, the owner certifies a new one, as in
  a rotation.

**Publication, and the trust anchor.** The public key is `packaging/keys/nerva-release.asc` in
this repository, next to `packaging/keys/fingerprints`. Both change only by a pull request merged
to `main` here. Users fetch it from
`https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc`, and
INSTALL.md prints the primary fingerprint to compare. The site serves the same bytes by WKD as a
second channel for users to check (see "The key by WKD"). The job never reads that copy, and the
bucket holds none. So neither a site merge nor the R2 token can change what the job trusts. A
site merge can only make the two channels disagree, which a careful user notices.

### Rotation (yearly)

The subkey expires after one year. The rotation keeps the pinned primary and changes only the
subkey. apt hosts hold the key file they wrote, and `gpgv` and `sqv` verify only against the
subkeys in it, so **every apt host needs the new key file before the swap**. The overlap gives
them time to fetch it. A keyring package would carry it automatically (see "Getting a new subkey
to users").

1. **At least 120 days before `current` expires** (NRV-E1160 warns from then on), the owner
   brings the primary online and certifies the next subkey (setup step 4's `--quick-add-key`
   line). The owner exports it as setup step 4 does, and sets it as `REPO_SIGNING_KEY_NEXT` and
   `REPO_SIGNING_PASSPHRASE_NEXT` in `package-repos`.
2. **The same day, one pull request here,** which lists the new subkey as `next` and replaces
   `nerva-release.asc` with the export that now holds both subkeys. The WKD file follows with
   the next release's site pull request, and the rotation's overlap is at least 120 days, so a
   release falls inside it. From the next write run, `InRelease` and
   `Release.gpg` carry **two signatures**, by `current` and by `next`. apt accepts a file when one
   signature verifies with a key in `Signed-By` and ignores a signature whose key it lacks, as
   Debian's own archive does with its several keys, so old and new key files both work.
   `repomd.xml.asc` and the rpms stay signed by `current` alone, so dnf hosts need nothing yet.
   The CHANGELOG of the next release, and a pinned issue, ask apt users to fetch the key file
   again.
3. **14 days before `current` expires,** the owner swaps the secrets (`REPO_SIGNING_KEY` becomes
   the new subkey, and the `_NEXT` pair is deleted). A pull request makes `next` `current` and
   the old subkey `retired`. Do both the same day. Between them, `ready` and the refresh fail with
   NRV-E1139, which is expected. From then on, everything is signed by the new subkey. Old rpms
   keep their old signatures, so the old subkey stays in the key file as `retired`, for good.
4. **dnf hosts** meet the new subkey at the swap, in `repomd.xml.asc` and in new rpms. Slice K
   tests exactly this, on rpm 4.16, 4.18 and 6: `dnf upgrade nerva` must succeed across the swap
   with no command beyond the ones in the original install. A cell that needs `sudo rpm -e
   gpg-pubkey-<id>`, a second import, or any other step means the fallback (see "Slices", K),
   because a step that can be documented is not a step users take.
5. **An apt host that never re-fetched the key file** fails `apt update` from the swap on, with
   `NO_PUBKEY` naming the new subkey. It would have failed at the old subkey's expiry 14 days
   later anyway. The fix is INSTALL.md's `curl` line again, and the pinned fingerprint is
   unchanged.

**Getting a new subkey to users, without a keyring package.** v0.7.1 ships no keyring package.
Until there is one, a user gets the new subkey by running INSTALL.md's `curl` line again, and the
primary fingerprint it shows is the same as before. The owner announces each rotation in the
CHANGELOG and in a pinned issue at step 2. **Whether to ship a `nerva-archive-keyring` package**
(a deb and an rpm that install the key file and update it on upgrade) **is the owner's open
question for after v0.7.1.** It must be answered before the first `next`, about 2027-07. Without
it, every apt user re-fetches the key file once a year.

### Compromise

- **A CI subkey leaks** (or a merge to `main` may have used it). The owner brings the primary
  online and revokes the subkey (`gpg --edit-key <primary>`, `key N`, `revkey`, reason "Key
  is compromised"). The owner then certifies a new subkey and
  replaces the secrets. The pull request here lists the old subkey as `revoked`, the new one as
  `current`, and ships the key file with the revocation. The WKD file follows with a
  patch release's site pull request.
  - **apt** hosts that fetch the key file get the revocation. Hosts that do not stop accepting
    the subkey when it expires, which is the bound the expiry gives.
  - **rpms already signed** by the revoked subkey can no longer be verified wherever the
    revocation is known (rpm 6 rejects all its signatures). The locks forbid re-signing them, so
    the job marks them `excluded` (step 5b), which leaves them out of the indexes, and each
    release they belonged to gets a decision at the time, normally a new patch release.
  - **Manifests.** If the current manifest was signed by the revoked subkey, no manifest
    verifies any more. The owner picks the last manifest known good (by date, before the leak)
    and adds `anchor <generation> <sha256>` to `fingerprints`. The next run accepts that one
    object on its hash, checks the bucket against it, and writes the next generation with the new
    subkey. Manifests above the anchor, signed by the revoked subkey, are noted and skipped. The
    anchor line is removed by the pull request after that run.
  - **Users** compare no new fingerprint: the pin is the primary's.
- **The primary leaks** (both drives, or the ceremony's Mac). Everything starts again: the owner
  publishes the primary's revocation certificate, makes a new primary, and every user installs a
  new key and checks a new fingerprint. A new decision, recorded then.

### The fallback: one key

If slice K fails on any cell (Rocky 9 included), or the rotation needs a user step that cannot
be documented, the key model is P365's:

- **One RSA 4096 primary, sign-only,** with **no expiry** and no subkeys, which CI holds as
  `REPO_SIGNING_KEY`. Its backup is the secret key, passphrase and revocation certificate in the
  password manager (setup step 4, version B).
- `fingerprints` uses the roles `current`, `next` and `previous`. In the signature check, `$3`
  equals `$12` and both are listed. In the rpm check, the Key ID is `current`'s or `previous`'s.
- **Rotation every two years,** with the same overlap: `next` dual-signs `InRelease` and
  `Release.gpg`. At the swap, `previous` keeps verifying old rpms, and apt users fetch the key
  file again, **with a new fingerprint to check**. There is no expiry alarm, and NRV-E1160 is
  registered as retired and unused.
- **The single key is in GitHub.** "CI holds only the subkey, and the primary stays offline"
  holds under the subkey model and under no other. Under this fallback the one key, which is
  also the trust anchor every user has pinned, is the secret `REPO_SIGNING_KEY` in the
  environment `package-repos`, as P365 has it today. Its custody is the one P365 set (the
  environment, the passphrase, the approved run attempt), and nothing stronger.
- **A leak** of the key is a leak of the trust anchor: the owner rotates the key itself, not a
  subkey. That means a new key, a new fingerprint for every user to check, and a new decision.
  This is the cost of the fallback, and the reason the subkey model is tried first.
- Everything else in P376 stays: the pinned check, verification before upload, the served check,
  alarms and WKD.

## Install instructions (what INSTALL.md gains)

Slice 5 writes this in INSTALL.md's Linux section, before the download-and-install text, which
stays as the path that needs no repository. The recorded output comes from the rehearsal, and is
marked "not run" until then. `<FINGERPRINT>` is the `primary` line of `packaging/keys/fingerprints`
(in the fallback, `current`): the primary key's fingerprint, the one `gpg --show-keys` prints
under `pub`, never a subkey's. Slice 2's test compares the first two `bash` blocks below with
`repo_install_check.sh`, ignoring comments, so the two-channel check is a third block of its own.

**Debian 12 and 13, Ubuntu 22.04 and 24.04** (apt 2.4 or later reads an armored key file):

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc | sudo tee /etc/apt/keyrings/nerva.asc > /dev/null
gpg --show-keys /etc/apt/keyrings/nerva.asc     # the pub line's fingerprint must be <FINGERPRINT>
sudo tee /etc/apt/sources.list.d/nerva.sources > /dev/null <<'EOF'
Types: deb
URIs: https://packages.nerva.pro/apt
Suites: stable
Components: main
Architectures: amd64 arm64
Signed-By: /etc/apt/keyrings/nerva.asc
EOF
sudo apt update && sudo apt install nerva
```

(A minimal Debian or Ubuntu image has neither `curl` nor `ca-certificates`: install both first,
`sudo apt install curl ca-certificates`. `gpg` is not there either. Compare the fingerprint on
another machine, or install `gnupg` first. `Architectures` keeps apt from asking for i386 on hosts with multiarch. To
pin Nerva, pin by Origin, `o=Nerva`: the Suite name `stable` is also Debian's.)

**Fedora 43 and later, Rocky Linux and RHEL 9** (Fedora 41 and 42 are past their end of life and
are not supported):

```bash
sudo tee /etc/yum.repos.d/nerva.repo > /dev/null <<'EOF'
[nerva]
name=Nerva
baseurl=https://packages.nerva.pro/rpm/stable
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc
EOF
sudo dnf install nerva      # dnf shows the primary key's fingerprint and asks: it must be <FINGERPRINT>
```

- **dnf 5 (Fedora 43 and later here)** fetches the key from `gpgkey=` and asks once; answering yes
  imports it for both the repository's metadata and the packages. Do not import it with
  `rpm --import` instead: dnf 5 then cannot verify `repomd.xml` ("Signing key not found"). On
  Fedora 43 and 44, update dnf5 first (`sudo dnf upgrade dnf5`) if the import hangs.
- **Fallback, if `repo_gpgcheck` still fails:** `repo_gpgcheck=0`. Each rpm is still checked
  against the key (`gpgcheck=1`), so nothing unsigned installs. What it gives up: the signed
  metadata, so a mirror or a bucket token holder could offer an older signed Nerva, or hide a new
  one.
- **Upgrades:** `sudo apt update && sudo apt upgrade`, or `sudo dnf upgrade nerva`. A package
  upgrade replaces the binary and never restarts a replica (P295b). Restart them as OPERATING.md
  says.
- **Candidates:** use `Suites: rc`, or `baseurl=https://packages.nerva.pro/rpm/rc`. That channel
  also has every release.
- **Switching from a downloaded package:** add the repository. The package installed from the file
  is the same package, and the next upgrade comes from the repository.
**Check the key through a second channel** (P376). The key file comes from GitHub. `nerva.pro`
publishes the same key by WKD, from another repository and another host. Both must show the same
primary fingerprint, `<FINGERPRINT>`:

```bash
curl -fsSL 'https://nerva.pro/.well-known/openpgpkey/hu/ndqm47zydhyqyzabecddtdk1q3bponab?l=nerva' | gpg --show-keys
```

If the two disagree, stop and do not install. Report it as a security issue. (With GnuPG's own
lookup, `gpg --auto-key-locate clear,wkd --locate-external-keys nerva@nerva.pro` does the same,
but it imports the key into your keyring.)

- **A new signing subkey, once a year** (P376). The primary fingerprint never changes, so there
  is nothing new to compare. apt reads only the key file you saved:
  - **apt:** run the `curl` line above again, in the weeks the CHANGELOG and the pinned issue
    name. If you miss it, `apt update` fails with `NO_PUBKEY` after the switch, and the same line
    fixes it.
  - **dnf:** nothing. The subkey model is adopted only if `dnf upgrade nerva` works across the
    swap with no extra command (slice K).

  In the single-key fallback, this becomes a new key every two years, with a new fingerprint to
  compare.

The text "They are not signed in v0.7.1, and there is no apt or dnf repository yet (they are
planned for v0.7.2)" changes: the repository's rpms and metadata are signed, while the files on
the release page are not, and are checked with `SHA256SUMS`.

## Tools on the runner, pinned

| Tool | From | Pin |
|---|---|---|
| `apt-ftparchive` | `apt-utils` (Ubuntu 24.04) | `apt-get install apt-utils=<noble version>`, then assert `apt-ftparchive --version` |
| `createrepo_c` | `createrepo-c` (Ubuntu 24.04) | the exact noble version string, then assert `createrepo_c --version` |
| `rpmsign`, `rpm` | `rpm` (Ubuntu 24.04) | `rpm=4.18.2+dfsg-2.1build2`, as `release.yml` pins it |
| `gpg`, `gpgv`, `gpgconf` | `gnupg` (on the image) | assert `gpg --version` is 2.4.x |
| S3 calls to R2 | `.github/scripts/r2.py`: Python 3 standard library only (SigV4 with `hmac` and `hashlib`, `urllib.request`), `python3 -I` | assert Python 3.12 |
| `curl`, `sha256sum`, `gh` | the image | as the other release scripts use them |
| container images for `repos-verify` | Docker Hub | pinned by digest |

Slice 2 writes the exact noble version strings, read with `apt-cache policy`, as `release.yml`
does for `rpm`. An install or version assertion that fails is NRV-E1139.

**Why not `wrangler` or the AWS CLI:**

- `wrangler` needs npm and a Cloudflare API token for "Workers R2 Storage: Edit", which covers
  every bucket in the account. The R2 S3 token can be limited to one bucket.
- The AWS CLI would be a new pinned download, and needs a recent release for conditional puts.
- Plain `curl --aws-sigv4` would need the secret on its command line, or a config file.

`r2.py` is about 180 lines. It reads `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID` and
`R2_SECRET_ACCESS_KEY` from the environment only. Its subcommands:

- `list <prefix>` follows `ListObjectsV2`'s continuation token through every page of 1,000 keys,
  and stops after 100 pages with exit 5 ("truncated"). The caller decides what that means: for
  `manifest/` a refusal, for the package prefixes a note (step 3 of `repos`);
- `head <key>` prints the size and `x-amz-meta-sha256` (exit 2 when absent);
- `get <key> <file>` checks `x-amz-meta-sha256` when present (exit 2 when absent);
- `put-new <key> <file>` sends `If-None-Match: *`. Exit 0 written, 3 exists. "Exists" is a 412,
  **or** the pinned lock refusal: under a locked prefix R2 may check the lock before the
  condition, and either answer means the name is taken. The caller then HEADs or GETs the object
  and decides as each step says. So the design is correct whichever answer R2 gives, and the
  rehearsal records which one it gave;
- `put <key> <file>` is allowed only on the names a run replaces and on the content-named index
  files (`by-hash/SHA256/<hex>`, `repodata/<hex>-*`), whose content their name fixes;
- `probe-locked <key> <file>` sends an unconditional put of bytes the caller has just read from
  that key and checked. Exit 0 only when R2 answers with the exact HTTP status and S3 error code
  that `r2.py` pins for a locked object; 4 when R2 accepts it; any other answer is NRV-E1143.
  Slice 1 pins the pair from Cloudflare's bucket-lock documentation. The rehearsal's first
  `repos` run confirms it against real R2: a different answer fails closed, and the pin is
  corrected before v0.7.1.

Every put sends `x-amz-content-sha256` (a signed payload), `x-amz-meta-sha256`, `Content-Type` and
`Cache-Control` for the key's kind. It retries a 5xx or a broken connection three times with
backoff, and fails on any other 4xx than 412 and the pinned lock refusal (in `put-new` and
`probe-locked`) with NRV-E1143. Its message names the operation, the key and the HTTP status,
never a header or a credential.

## Error codes (reserved here; slice 0 registers them)

The highest code on `origin/main` is NRV-E1138. This spec first took **NRV-E1139 to NRV-E1148**.
The second review and the move of the site to Cloudflare needed four more, and the third review
five more, so it takes **NRV-E1139 to NRV-E1157** (E1149 to E1157 are free on `main`). The fourth
rework cut the lock in the bucket and the `abandoned` state: NRV-E1154 is **retired, unused**, and
NRV-E1147 keeps only its overlap meaning. The Zigbox team's review (P376, P376b) adds
**NRV-E1159 to NRV-E1162** and the warning **NRV-W1103** (NRV-E1158 is #374's
`release/candidate` code). Slice 0b registers E1160 to E1162, W1103 and the amended texts of
E1139, E1145, E1150 and E1152; slice G registers E1159. No code is renumbered. Each is printed as
`error[NRV-E11xx]: <script or host>: <what>`, with a `cause` and a `fix` line, and exits 1, like
the other release codes.

| Code | Summary | Printed by | Blame |
|---|---|---|---|
| NRV-E1139 | The package-repos environment is incomplete (a secret, a variable, a pinned tool), its secret is not the `current` subkey of the pinned primary or holds the primary's secret part (in the fallback: is not the `current` key), `packaging/keys/` does not hold exactly the listed keys, or `SOURCE_DATE_EPOCH` is set | `package_repos.sh ready`, `publish`, `refresh` | release maintainer |
| NRV-E1140 | The release's packages are missing, extra, or do not match `SHA256SUMS` | `package_repos.sh ready` | release maintainer |
| NRV-E1141 | A package of the same name is already listed with other content (published packages are never replaced) | `package_repos.sh ready`, `publish` | release maintainer |
| NRV-E1142 | The bucket does not match its manifest. Refused before any write: a listed object that is missing or changed, an unlisted object at a name the run must write, a candidate under `stable`, objects under `manifest/` of which none verifies, or the bucket over its bound. Noted, and the run ends red after it has finished: an unlisted object anywhere else under a locked prefix, an index file the run replaced, or a manifest object that does not verify | `package_repos.sh ready`, `publish`, `refresh`, `served` | the bucket token's holder (no crash or failed run of this pipeline causes it; overlap is NRV-E1147) |
| NRV-E1143 | The bucket refused or failed an operation (a 412 and the pinned lock refusal excepted), a listing ran past 100 pages, or a locked object's overwrite was answered with anything but the pinned lock refusal | `r2.py` | release maintainer / Cloudflare |
| NRV-E1144 | Signing failed, or a signed rpm differs from the release's file in NEVRA or payload | `package_repos.sh publish`, `refresh` | release maintainer |
| NRV-E1145 | `packages.nerva.pro` does not serve what is in the bucket: an object this run wrote (manifests, packages, index files, every replaceable name) is not served byte for byte, within 2 minutes | `package_repos.sh ready`, `served` | release maintainer / Cloudflare |
| NRV-E1146 | Installing from the repository failed on a supported distribution | `repo_install_check.sh` (`repos-verify`) | release maintainer |
| NRV-E1147 | Two writers ran at once: a manifest that verifies holds the name this run wanted, so something wrote the bucket outside the concurrency group `nerva-packages-bucket`. (Its earlier meanings, a lock wait and a lock search, are cut with the lock) | `package_repos.sh ready`, `publish`, `refresh` | release maintainer (a workflow without the group) |
| NRV-E1148 | A package is not what the approved run bound: its bytes differ from the manifest's `<source-sha256>`, `repos` found no entry for its tag, or `repos-ready` found the release published while `guard` saw a draft | `package_repos.sh ready`, `publish`, `refresh` | release maintainer (or whoever changed a release asset) |
| NRV-E1149 | A bucket lock rule is missing: R2 accepted an overwrite under a locked prefix | `package_repos.sh publish`, `refresh` | the Cloudflare account's admin |
| NRV-E1150 | The repositories' signatures expire within 10 days, or this repository has had no commit for 45 days and GitHub will disable the refresh at 60 | `package_repos.sh refresh`, `ci.yml`'s `repos-fresh` | release maintainer |
| NRV-E1151 | `nerva.pro` does not show the release 15 minutes after the site's pull request merged | `release_finish.sh site-live` (`site-verify`) | release maintainer / Cloudflare |
| NRV-E1152 | The site's build refused: a file that would run code or bind resources on Cloudflare (`functions/`, `_worker.js`, `_routes.json`, `wrangler.*`), a package manifest, lock file or version file that would make Cloudflare install dependencies, `SKIP_DEPENDENCY_INSTALL` not set to `1`, or a file the build copies (`index.html`, the WKD policy and key) missing or a symlink | the `nerva-site` build command (Cloudflare), and the site's `site_check.mjs` | whoever added the file to the site repository, or changed the Pages project's variables |
| NRV-E1153 | `repos-ready`, binding a draft, ran in another run attempt than the `mac` job the owner approved (a dispatch for a published release is not checked) | `package_repos.sh ready` | whoever re-ran the job; use "Re-run all jobs" |
| NRV-E1154 | **Retired, unused.** It was the `abandoned` state, cut in the fourth rework: a pending entry of a release that is not public is now skipped, never marked | none | none |
| NRV-E1155 | A GitHub API call or a download from GitHub failed (the network, an outage, a rate limit), not a hash mismatch or a release that reads draft or 404; also the refresh's read of the last commit's date. The affected entries stay `pending` | `package_repos.sh ready`, `publish`, `refresh` | GitHub |
| NRV-E1156 | Index generation failed (`apt-ftparchive`, `createrepo_c`), or the runner has less free disk than the run needs | `package_repos.sh publish`, `refresh` | release maintainer |
| NRV-E1157 | `repos-verify` could not set up a distribution's container or its prerequisites (an image pull, a mirror), before any check of the repository ran | `repo_install_check.sh` (`repos-verify`) | the environment (a registry or mirror) |
| NRV-E1159 | The release commit does not record its gates in the form P376b requires: the soak line, the Jepsen line or the two review verdicts is missing or malformed, names another commit, or `TO FILL` is left in the version's section (registered by slice G) | `release_check.sh gates` (`release.yml`'s `version`, `release-finish.yml`'s `publish`) | release maintainer |
| NRV-E1160 | The CI signing subkey expires soon: under 120 days and no `next` listed, or under 30 days and not swapped. Noted; the run finishes its work, then ends red (retired, unused, if slice K takes the fallback) | `package_repos.sh publish`, `refresh`, `ci.yml`'s `repos-fresh` | the key's owner |
| NRV-E1161 | The run's own output does not verify before upload: `InRelease`, `Release.gpg` or `repomd.xml.asc` under a keyring of `packaging/keys/` only, `InRelease`'s text against `Release`, or an rpm under `rpmkeys -K` in a scratch database, which step 4 checks before the rpm is recorded or put (a bad rpm already in the bucket is marked `excluded` instead). Nothing of the indexes is uploaded | `package_repos.sh publish`, `refresh` | release maintainer (a key file and secret that disagree, or a tool change) |
| NRV-E1162 | The WKD key on `nerva.pro` is not `packaging/keys/nerva-release.asc` | the site's `site_check.mjs`, `release_finish.sh site-live` (`site-verify`) | whoever changed either key file without the other; if nobody did, the site's repository or Pages project |
| NRV-W1103 | The `alarm` job could not open or comment on the `package-repos` issue. A warning: it never changes the run's verdict | `.github/scripts/repos_alarm.sh` | GitHub, or a missing label |

## Setup (owner, once)

Run these in order. Each shell command works in zsh and in bash: no comments, no `!`, every
argument with a special character quoted. Secrets go in through `gh`'s own prompt or standard
input, never on the command line. Run the commands on your Mac, signed in to `gh` as `topwombat`.
The session proxy cannot reach these settings. Dashboard steps name each page and field.

**1. The zone `nerva.pro`.** In the Cloudflare dashboard: **Add a domain**, enter `nerva.pro`, keep
"Quick scan for DNS records" off, take the **Free** plan, and set the registrar's nameservers to
the two Cloudflare names it shows (or transfer the domain to Cloudflare Registrar). Wait until the
zone says **Active**. Then, in the zone:

- **SSL/TLS**, **Edge Certificates:** **Always Use HTTPS** on, **Minimum TLS Version** 1.2.
- **Security**, **Bots:** **Bot Fight Mode** off. It challenges apt and dnf on the `packages`
  host, and they cannot answer a challenge.
- **DNS** stays empty for now: steps 3 and 5 make every record.

**2. The Pages project.** **Workers & Pages**, **Create**, **Pages**, **Connect to Git**.

- **GitHub:** Cloudflare asks to install its GitHub App. Install it on the **NervaLog**
  organisation with **Only select repositories**, `nervalog.github.io`, and nothing else.
- Select `NervaLog/nervalog.github.io`, then **Begin setup**:
  - **Project name:** `nerva-site`;
  - **Production branch:** `main`;
  - **Framework preset:** None;
  - **Build command:** the one line in "The site on Cloudflare Pages", exactly;
  - **Build output directory:** `dist`;
  - **Root directory (advanced):** empty (the repository's root);
  - **Environment variables:** one, `SKIP_DEPENDENCY_INSTALL` with the value `1`, for both
    Production and Preview. The build command refuses to run without it.
- **Save and Deploy.** Wait for a green deployment, then open `https://nerva-site.pages.dev/`:
  it must show the site.
- In the project, **Settings**:
  - **Builds**, **Branch control:** **Enable automatic production branch deployments** on;
    **Preview branch:** "All non-Production branches" (recommended; "None" turns previews off,
    see "Preview deployments").
  - **Bindings:** none. Leave it empty, now and later.
  - **Functions** and **Variables and Secrets:** none.

**3. The site's domains.**

- In the `nerva-site` project, **Custom domains**, **Set up a custom domain**, `nerva.pro`,
  **Continue**, **Activate domain**. Cloudflare adds the record and the certificate. Wait until it
  says **Active**.
- **www:** in the zone, **DNS**, **Records**, **Add record**: type `AAAA`, name `www`, IPv6
  address `100::`, **Proxied**. (`100::` is a placeholder that goes nowhere; the redirect rule
  answers before it would be used.)
- **Rules**, **Redirect Rules**, **Create rule**:
  - **Rule name:** `www to apex`;
  - **Custom filter expression**, **Edit expression:** `(http.host eq "www.nerva.pro")`;
  - **Then:** **Type** Dynamic, **Expression** `concat("https://nerva.pro", http.request.uri.path)`,
    **Status code** 301, **Preserve query string** on;
  - **Deploy**.
- Check:

```bash
curl -sI 'https://nerva.pro/' | grep -i -e '^HTTP' -e '^server'
```

```bash
curl -sI 'https://www.nerva.pro/install?x=1' | grep -i -e '^HTTP' -e '^location'
```

Expect a 200 with `server: cloudflare`, then a 301 to `https://nerva.pro/install?x=1`.

**4. The signing key** (P376). **Wait for slice K**: its pull request says which branch is
taken. If the subkey model is adopted, follow 4A. If it fell back to one key, follow 4B. If it
took subkeys without expiry, follow 4A with `never` in place of `1y`.

**4A. An offline primary and a CI subkey.** You need two USB drives, each formatted in Disk
Utility as **APFS (Encrypted)** with a long passphrase of its own, kept in the password manager.
On your Mac, with GnuPG (`brew install gnupg`, which brings pinentry). **Turn Wi-Fi off and
unplug any network cable before you start, and keep it off until the last step of this section.**
Quit every other application, and do the work in a throwaway keyring (a temporary
`GNUPGHOME`, wiped at the end). The primary is never offline while it is made, but it should be
nowhere near the network while it exists in the clear. Better, do it on a fresh macOS user
account with no iCloud sync, or from a live USB:

```bash
export GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
export GPG_TTY="$(tty)"
gpg --batch --cert-digest-algo SHA512 --quick-generate-key 'Nerva release signing key <nerva@nerva.pro>' rsa4096 cert never
```

GnuPG asks for the **primary's passphrase** twice, in the terminal (that is what `GPG_TTY` is for;
without it pinentry fails with "Inappropriate ioctl for device"). Make a long random one and keep
it in your password manager. (The address is the deb's Maintainer address, P331.) The key can
only certify: it never signs a package or an index.

```bash
fpr="$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
gpg --batch --cert-digest-algo SHA512 --quick-add-key "$fpr" rsa4096 sign 1y
```

```bash
sub="$(gpg --with-colons --list-secret-keys "$fpr" | awk -F: '$1 == "ssb" { s = 1 } s && $1 == "fpr" { print $10; exit }')"
echo "$fpr" && echo "$sub"
gpg --armor --export "$fpr" > "$HOME/nerva-release.asc"
```

The first line printed is the primary, the second the CI subkey. Now the primary's secret, to
both drives (repeat with the second drive's name), and the revocation certificate:

```bash
gpg --armor --export-secret-keys "$fpr" > '/Volumes/NERVA-KEY-1/nerva-release-primary.asc'
cp "$GNUPGHOME/openpgp-revocs.d/$fpr.rev" "$HOME/nerva-release.rev"
```

Attach `~/nerva-release.rev` to the password manager item that holds the primary's passphrase,
as a file, not through the clipboard (Universal Clipboard would copy it to your other devices).
Eject both drives and keep them in two places.

Then the export CI gets: the subkey and a stub of the primary, under a **CI passphrase** of its
own. The passphrase is changed **before** the primary is stripped, on a copy of the keyring
(`--passwd` on a keyring whose primary is already a stub may fail or ask for a passphrase it
cannot use). (`printf '\041'` is a `!`, which forces that exact subkey; zsh would read a typed
one as history.)

```bash
export CIHOME="$(mktemp -d)"
chmod 700 "$CIHOME"
cp -R "$GNUPGHOME"/. "$CIHOME"/
gpg --homedir "$CIHOME" --passwd "$fpr"
gpg --homedir "$CIHOME" --armor --export-secret-subkeys "$sub$(printf '\041')" > "$HOME/nerva-ci-subkey.asc"
export CICHECK="$(mktemp -d)"
chmod 700 "$CICHECK"
gpg --homedir "$CICHECK" --import "$HOME/nerva-ci-subkey.asc"
gpg --homedir "$CICHECK" --list-secret-keys
```

`--passwd` asks for the primary's passphrase (the old one), then for a new one: make a second
long random passphrase, the CI passphrase, and keep it in its own password manager item. The
listing of `CICHECK`, which holds only the export, must show `sec#` (no secret primary) and
one `ssb`, and the export must unlock with the CI passphrase and not with the primary's.
Anything else, stop. Slice K's pull request runs this exact sequence in a throwaway first, so
the owner does not meet its first run. Keep this terminal open: step 6 sets the secret from
`~/nerva-ci-subkey.asc`. When step 6 is done, wipe every throwaway home (`rm -rf "$GNUPGHOME"
"$CIHOME" "$CICHECK" ~/nerva-ci-subkey.asc`), empty the Trash, and turn the network back on.

Give the supervisor `~/nerva-release.asc` and both fingerprints (the `echo` above). They are
public; slice 3 commits them to `packaging/keys/` as `primary` and `current`. Compare the
primary's with `gpg --show-keys ~/nerva-release.asc`: it is the `pub` line.

**4B. The fallback: one key.** On your Mac, with GnuPG (`brew install gnupg`, which brings pinentry), in a
throwaway keyring:

```bash
export GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
export GPG_TTY="$(tty)"
cat > "$GNUPGHOME/params" <<'EOF'
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: Nerva release signing key
Name-Email: nerva@nerva.pro
Expire-Date: 0
EOF
gpg --batch --cert-digest-algo SHA512 --generate-key "$GNUPGHOME/params"
```

GnuPG asks for a passphrase twice, in the terminal (that is what `GPG_TTY` is for; without it
pinentry fails with "Inappropriate ioctl for device"). Make a long random one and keep it in your
password manager. (The address is the deb's Maintainer address, P331.)

```bash
fpr="$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
echo "$fpr"
gpg --armor --export "$fpr" > "$HOME/nerva-release.asc"
```

Keep this terminal open: step 6 sets the secret key from it, once the environment exists. Then
save the key, its passphrase and its revocation certificate in the password manager, as files, not
through the clipboard (Universal Clipboard would copy them to your other devices):

```bash
gpg --armor --export-secret-keys "$fpr" > "$HOME/nerva-release-secret.asc" && cp "$GNUPGHOME/openpgp-revocs.d/$fpr.rev" "$HOME/nerva-release.rev"
```

Attach `~/nerva-release-secret.asc` and `~/nerva-release.rev` to one password manager item. Delete
them, and the throwaway keyring, only after step 6.

Give the supervisor `~/nerva-release.asc` and the fingerprint (`echo "$fpr"`). Both are public;
slice 3 commits them to `packaging/keys/` as `current`.

**5. The bucket, its public host, its locks and its token.**

- In the dashboard, open **R2 Object Storage**. If R2 is not enabled on the account, enable it;
  Cloudflare asks for a payment method even for the free tier.
- **Create bucket:** name `nerva-packages`, location Automatic, storage class Standard.
- In the bucket's **Settings**, **Public access**: under **Custom Domains**, **Connect Domain**,
  enter `packages.nerva.pro`, and confirm the DNS record Cloudflare proposes. Leave the
  **R2.dev subdomain** disabled.
- In the bucket's **Settings**, **Bucket lock rules**, **Add rule**, four times, each with
  retention **Indefinite**:

  | Rule name | Prefix |
  |---|---|
  | `apt-pool` | `apt/pool/` |
  | `rpm-stable-packages` | `rpm/stable/packages/` |
  | `rpm-rc-packages` | `rpm/rc/packages/` |
  | `manifests` | `manifest/` |

  No other prefix: the index names must stay replaceable.
- **Manage R2 API Tokens**, then **Create Account API token**:
  - name `nerva-release-package-repos`;
  - permission **Object Read & Write** (never **Admin Read & Write**, which could remove the
    locks);
  - **Apply to specific buckets only:** `nerva-packages`;
  - TTL **Forever** (rotation is by hand; see the end of this section).
- Create it. The page shows the **Access Key ID**, the **Secret Access Key** and the S3 endpoint,
  `https://<account-id>.r2.cloudflarestorage.com`. Leave the page open for step 6.

**6. The GitHub environment `package-repos`** (`main` only, no reviewers, no admin bypass):

```bash
printf '%s' '{"can_admins_bypass":false,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' | gh api -X PUT repos/NervaLog/nerva/environments/package-repos --input -
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
gh variable set PACKAGES_BASE_URL --env package-repos --repo NervaLog/nerva --body 'https://packages.nerva.pro'
```

Then, in step 4's terminal. **4A** (GnuPG asks for the CI passphrase for the export):

```bash
gpg --homedir "$CIHOME" --armor --export-secret-subkeys "$sub$(printf '\041')" | gh secret set REPO_SIGNING_KEY --env package-repos --repo NervaLog/nerva
```

**4B** (GnuPG asks for the key's passphrase):

```bash
gpg --armor --export-secret-keys "$fpr" | gh secret set REPO_SIGNING_KEY --env package-repos --repo NervaLog/nerva
```

Then the passphrase of what you just set (4A: the CI passphrase; 4B: the key's):

```bash
gh secret set REPO_SIGNING_PASSPHRASE --env package-repos --repo NervaLog/nerva
```

The label the alarm job files under (see "Alarms"):

```bash
gh label create package-repos --repo NervaLog/nerva --color B60205 --description 'A package repository run failed or a refresh was missed'
gh variable set PACKAGE_REPOS_OWNER --repo NervaLog/nerva --body '<your GitHub login>'
```

The variable names who the alarm issue is assigned to (P376), so a real alarm notifies you
whatever your watch settings are.

Now delete the files and the throwaway keyrings. **4A:**

```bash
rm -P "$HOME/nerva-ci-subkey.asc" "$HOME/nerva-release.rev" && gpgconf --kill all && gpgconf --homedir "$CIHOME" --kill all && rm -rf "$GNUPGHOME" "$CIHOME" && unset GNUPGHOME GPG_TTY CIHOME
```

**4B:**

```bash
rm -P "$HOME/nerva-release-secret.asc" "$HOME/nerva-release.rev" && gpgconf --kill all && rm -rf "$GNUPGHOME" && unset GNUPGHOME GPG_TTY
```

`REPO_SIGNING_KEY_NEXT` and `REPO_SIGNING_PASSPHRASE_NEXT` are set only during a rotation (see
"Rotation").

The fingerprints are not variables: they are pinned in `packaging/keys/fingerprints`.

**7. Turn off GitHub Pages**, only once step 3's check showed `nerva.pro` served by Cloudflare:

```bash
gh api -X DELETE repos/NervaLog/nervalog.github.io/pages
```

`https://nervalog.github.io/` then answers 404 (see "The old URL").

**8. The site's ruleset.** The site holds nothing the packages depend on, so it needs no code
owner. A code-owner rule could not be met anyway: the App cannot approve its own release pull
request, `topwombat` cannot approve its own, and the ruleset has no bypass. Today's CODEOWNERS (the
bare line `topwombat`) owns nothing, so `require_code_owner_review` has never applied. Turn that
one field off and keep everything else as it is live (`site-check` required, no approvals, no
bypass, the integration id and the review options it holds today). Read it, change one field,
write it back:

```bash
gh api repos/NervaLog/nervalog.github.io/rulesets/27139365 --jq '{name, target, enforcement, conditions, bypass_actors, rules: [.rules[] | if .type == "pull_request" then .parameters.require_code_owner_review = false else . end]}' > "$HOME/site-ruleset.json"
```

Compare it with the live ruleset:

```bash
gh api repos/NervaLog/nervalog.github.io/rulesets/27139365 --jq '{name, target, enforcement, conditions, bypass_actors, rules}' | jq . > "$HOME/site-ruleset-live.json" && jq . "$HOME/site-ruleset.json" | diff "$HOME/site-ruleset-live.json" -
```

The diff must show exactly one changed line, `"require_code_owner_review": true` to `false`.
Anything else, stop. Then:

```bash
gh api -X PUT repos/NervaLog/nervalog.github.io/rulesets/27139365 --input "$HOME/site-ruleset.json" && rm "$HOME/site-ruleset.json" "$HOME/site-ruleset-live.json"
```

Cloudflare's check is **not** added to the ruleset (see "Preview deployments"). CODEOWNERS is
deleted by slice 5's site pull request, which merges on `site-check` alone, as every site pull
request does.

**9. Homepages.**

```bash
gh repo edit NervaLog/nervalog.github.io --homepage 'https://nerva.pro/' && gh repo edit NervaLog/nerva --homepage 'https://nerva.pro/'
```

**10. Check it.**

```bash
curl -sI 'https://nerva.pro/' | head -n1 && curl -sI 'https://nervalog.github.io/' | head -n1
```

```bash
curl -sI 'https://packages.nerva.pro/nothing' | head -n1
```

```bash
gh secret list --env package-repos --repo NervaLog/nerva && gh variable list --env package-repos --repo NervaLog/nerva
```

```bash
gh api repos/NervaLog/nerva/environments/package-repos --jq '[.can_admins_bypass, .deployment_branch_policy.custom_branch_policies, (.protection_rules | map(.type) | join(","))] | @tsv'
```

```bash
gh api repos/NervaLog/nervalog.github.io/rulesets/27139365 --jq '.rules[] | select(.type == "pull_request") | .parameters.require_code_owner_review'
```

```bash
gh api repos/NervaLog/nervalog.github.io/pages --silent; echo "pages exit $?"
```

```bash
gh label list --repo NervaLog/nerva --search package-repos
```

Expect: a 200 from `nerva.pro`; a 404 from `nervalog.github.io`; a 404 from `packages.nerva.pro`
(served by R2: the bucket is empty); four secrets (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
`REPO_SIGNING_KEY`, `REPO_SIGNING_PASSPHRASE`) and four variables (`R2_ENDPOINT`, `R2_BUCKET`,
`PACKAGES_BASE_URL`, `PACKAGE_REPOS_OWNER`); `false`, `true` and `branch_policy`; `false`; `pages exit 1` (Pages is
off); and the label `package-repos`. Then tell the supervisor.

**Rotating the R2 token** (yearly, or if it may have leaked): create a new token as in step 5, set
both secrets again as in step 6, then delete the old token in the dashboard. A run in progress
fails with NRV-E1143 and is re-run.

**Least privilege, in summary:**

- **The R2 token** can write one bucket, and cannot remove its locks. It sits in one environment
  that only `main` can deploy and admins cannot bypass, and it reaches the `package_repos.sh`
  steps only. Nothing else in GitHub holds any Cloudflare credential.
- **The bucket's public host** is read-only by construction: R2 public access has no write path.
- **The signing key:** under the subkey model, CI holds only the signing subkey (two during a
  rotation's overlap), under a CI passphrase, and never the primary, which is offline on two
  encrypted drives (P376). Under the fallback, CI holds the single key, as P365 has it, and a
  leak means rotating the key itself. It sits
  in the same environment, reaches the same steps, and signs new package content only as bound
  by the approved run attempt, while the release is a draft. A leaked subkey is revoked offline,
  and the pinned primary stays.
- **The alarm** uses the `GITHUB_TOKEN` with `issues: write` only, outside the environment.
- **The trust anchor** (the public key and the pinned fingerprints) is in this repository.
- **The site repository and the release App** hold nothing the packages depend on. Cloudflare's
  GitHub App reads that one repository. The Pages project has no binding, and its build command,
  which no pull request can change, refuses the files that would add one.
- `package-repos` has no reviewer, as `release-publish` has none, so the release is still one
  approval. The same accepted risk applies (automation.md, "Security notes"): any workflow merged
  to `main` can name the environment, and merging is the guard.

## What changes elsewhere

- **P148:** the site is no longer served by GitHub Pages. Cloudflare Pages builds and deploys the
  site repository's `main`, at `https://nerva.pro/`. The repository, its name, its `main` and its
  pull request flow stay. P365 records this; P148 itself is not edited.
- **P364:** unchanged, except that "published" now means Cloudflare deployed the merge, which
  `site-verify` checks.
- **P360 point 10:** the repositories come in v0.7.1, not v0.7.2, as three jobs (not one) plus a
  weekly refresh, in the environment `package-repos`. `verify` does not wait for them, `publish`
  waits for `repos-ready`, and `repos` waits for the publication, not for `publish`'s success.
- **Nerva's CLAUDE.md:**
  - "README and site status": "served by GitHub Pages from that repository's `main` at
    <https://nervalog.github.io/>" becomes "built and deployed by Cloudflare Pages from that
    repository's `main` at <https://nerva.pro/> (P365)".
  - The release paragraph adds that the release also publishes the apt and dnf repositories.
  - "Environment facts" notes that the session proxy cannot reach Cloudflare.
- **The site's CLAUDE.md and README:** the served-by line, as in Nerva's CLAUDE.md; that a push to
  `main` publishes through Cloudflare; that the page carries no key, fingerprint or repository
  line (it links to INSTALL.md), and that the key is only at its WKD path, a copy of Nerva's
  `packaging/keys/nerva-release.asc` that changes only with it (P376, NRV-E1162); and that
  `functions/`, `_worker.js`, `_routes.json` and `wrangler.*` are refused, with package
  manifests, lock files and version files (NRV-E1152).
- **P365** is amended by P376: point 3 (the site now carries the key, by WKD), point 6 (the
  check is pinned to the primary and the subkey's role), point 10 (`Date`, and `repos-fresh` at
  10 days) and point 12 (the key model, once slice K passes). **P368**'s `verify_manifest` is
  replaced by slice 2b. **P147b** is amended by P376b, **P293** by P376c.
- **Nerva's README** has no link to the site; nothing changes there.
- **docs/releases/automation.md**, the section "`apt` and `dnf` repositories (v0.7.2): the hook",
  becomes a pointer to this document (slice 5). The rest of it stands.
- **The site's `NEXT`:** the v0.7.2 line "apt and dnf repositories with signed packages" moves to
  v0.7.1 in the supervisor's status pull request, and is marked delivered only after
  `repos-verify` is green on the v0.7.1 run.
- **CHANGELOG.md's v0.7.1 section** gains the repositories, with the install lines, and the new
  address of the site, in the `VERSION` pull request.

## The rehearsal

The owner's decision (owner, 2026-11-12): v0.7.1's other gates wait for this rehearsal to pass.

Prerequisites: setup steps 1 to 10 are done, and slices 0 to 5 have merged.

The rehearsal is a candidate run **with the approval**, because only an approved run binds new
packages (a dispatch for a published release would stop with NRV-E1148):

- **If automation.md's rc.2 rehearsal has not run yet,** it runs as automation.md says, and now
  includes `repos-ready`, `repos` and `repos-verify`. That is still one approval.
- **If it has already run,** a `v0.7.1-rc.3` rehearsal runs, as in automation.md, with the one
  approval.

**Pass:**

- `repos-ready` is green before `publish`.
- `repos-ready` writes the binding manifest, and nothing else, before `publish`. `repos` puts two debs and two rpms (under `rpm/rc/` only),
  then the promoted manifest and both channels of both formats. `stable` is signed and empty,
  because no release has packages yet; that exercises the channel rule. The lock probe passes
  (no NRV-E1149). `served` is green. The run's log shows which answer `put-new` got for a name
  under a locked prefix that exists (412 or the lock refusal), from a deliberate second
  `put-new` of one deb; it is recorded in the worklog.
- The locks are tested after the first run wrote the manifest and the first packages: a second
  write run (a dispatch of the same tag) probes every locked prefix (no NRV-E1149). The first run
  itself is unprobed, because an empty bucket has no object to probe.
- `repos-verify` is green in all fourteen cells (sixteen with Fedora 45), on amd64 and arm64: `nerva version` ends with
  `version 0.7.1-rc.N`, and `stable` offers no candidate.
- **A dispatch** of the same tag (no approval) writes no package object, stops nowhere, and
  re-signs the indexes; it is green. It shows that a run with nothing bound finishes without
  adding.
- **The refresh:** one `workflow_dispatch` of `package-repos-refresh.yml` is green, and
  `InRelease`'s `Valid-Until` moves.
- **The site:** `release_finish.sh site-live v0.7.0`, run by hand, passes (the page already lists
  v0.7.0). A candidate's site pull request is never merged, so `site-verify` itself runs first on
  v0.7.1.
- **The build gate:** a pull request on the site repository that adds a `wrangler.toml` binding
  `nerva-packages`, a `functions/x.js`, and a `package.json` whose `postinstall` writes
  `dist/_worker.js` gets a failed preview build with NRV-E1152 in its log,
  and the project's **Bindings** stay empty. The pull request is closed unmerged. (With previews
  off, this needs a merge; skip it and record it as not verified.)
- `https://nerva.pro/` answers 200, `https://www.nerva.pro/` answers 301 to it, and
  `https://nervalog.github.io/` answers 404.
- **Signed and served** (P376): step 5b (NRV-E1161) and step 8's fetch-back are green in both
  write runs; every signature's `VALIDSIG` names `primary` as its primary and `current` as its
  key; the rpms' Key ID is `current`'s.
- **WKD:** `gpg --auto-key-locate clear,wkd --locate-external-keys nerva@nerva.pro`, in a
  throwaway `GNUPGHOME`, finds the key, and its primary fingerprint is `primary`; INSTALL.md's
  `curl` line shows the same. Record the `Content-Type` the file is served with.
- **The alarm:** one dispatch of `package-repos-refresh.yml` with `alarm_test` set fails on
  purpose, opens an issue labelled `package-repos`, and a second such dispatch comments on the
  same issue. The issue is closed by hand afterwards.

**Afterwards:** the cleanup in automation.md stays as it is. The candidate stays in the `rc`
channel. Nothing is deleted from the bucket. The run link goes in the worklog note of the pull
request that records the result, and that pull request's author runs
`gh variable set REPOS_LIVE --repo NervaLog/nerva --body true`, which switches on `repos-fresh`.

**Not verified until the rehearsal** (slices 1 and 2 test the rest locally, with stand-ins, and in
containers):

- `r2.py` against real R2: SigV4 with region `auto`, `If-None-Match: *` answering 412, listing
  pages, and the `x-amz-meta-sha256`, `Content-Type` and `Cache-Control` round trip through the
  public host.
- R2's bucket locks: that an unconditional put under a locked prefix is refused with the status
  and error code `r2.py` pins from Cloudflare's documentation (`probe-locked` fails closed on any
  other answer, NRV-E1143, so a wrong pin stops the rehearsal and is corrected before v0.7.1);
  which answer a `put-new` of an existing locked object gets (412 or the lock refusal; either is
  "exists"); and that an "Object Read & Write" token cannot change lock rules.
- The concurrency group: that a job-level group spans `release-finish.yml` and
  `package-repos-refresh.yml`, and that with `queue: max` a third queued job waits and is not
  cancelled. Slice 2 cannot test this locally. If GitHub refuses or ignores `queue` at job level,
  remove it and keep the design as it is: a third job then cancels the pending one, which the
  design survives (see "The trap"), at the rare cost of a second approval.
- That `mac-sign.yml`'s new output `attempt` reaches `release-finish.yml` after a partial re-run.
  If GitHub drops it, `ready` refuses with NRV-E1153, which fails closed.
- That `mac-sign.yml`, re-run by "Re-run all jobs" against a draft that already holds the signed
  zip, behaves as P361 says.
- That "Re-run all jobs" asks the owner to approve `mac` again, and that a "Re-run failed jobs"
  of `repos-ready` sees `mac`'s old `attempt` output (NRV-E1153).
- R2's custom-domain public access: `Range`, `ETag`, `If-None-Match`, and Cloudflare's cache
  honouring each object's `Cache-Control`.
- Cloudflare's security features against apt's and dnf's user agents, from GitHub's runners.
- The environment `package-repos`, its secrets, and the key's import with the passphrase file on
  the runner.
- That a failed `publish` job's `public` output reaches `repos`.
- `ubuntu-24.04-arm` running the arm64 cells.
- Cloudflare Pages: that it reads `wrangler.toml` and `functions/` only for a deployment whose
  build passed, so the gate holds; and that it builds no pull request from a fork.
- Cloudflare Pages serving `dist/.well-known/`, a dot-directory, and the `Content-Type` it gives
  the WKD file, and answering an unknown path under `/.well-known/openpgpkey/hu/` with 404 and
  `policy` with 200. **WKD is adopted only if all of this passes in the rehearsal.** If not,
  P376 point 6 is cut by a decision before v0.7.1: the key stays on GitHub only, and INSTALL.md's
  second channel goes.
- The `alarm` job's `if` on a cancelled run, and `issues: write` being enough to add a label
  that exists.

**Not verified until v0.7.1** (the same code with another filter): the first release package in
`stable`, its rpm under `rpm/stable/`, `repos-verify` installing from `stable`, and `site-verify`.

The fallback is the same as for the tap and the site in automation.md: the release is already
public, its files install by hand, and a re-run finishes the repositories.

## Slices

Concurrent slices touch different files (P250). Each gets a fresh agent and is reviewed
adversarially by a fresh reviewer, who posts the findings on its pull request. Tiers as in
CLAUDE.md (P148b).

| Slice | What | Files | Tier | Order |
|---|---|---|---|---|
| 0 | Register NRV-E1139 to NRV-E1157 from the table above (NRV-E1154 as "retired, unused", so the number is never reused): entries with surface, blame, cause and fix, plus the intro paragraph of the 11xx section naming the scripts and the Cloudflare build that print them | `docs/ERRORS.md` | mechanical; supervisor checks the diff | first; small, merges before 1 and 2 |
| 1 | `r2.py` and its tests. The tests run a fake S3 server (`http.server`, in the test file) that also enforces lock prefixes, check the SigV4 signature against AWS's published test vectors, and cover `If-None-Match` and 412, `put-new` of an existing object under a locked prefix answered with 412 and, in a second mode of the fake server, with the pinned lock refusal (exit 3 both times), listing across pages and the 100-page assert, `probe-locked` both ways, the replaceable-name refusal, the stored `Content-Type` and `Cache-Control`, retries, NRV-E1143's text, and that no credential appears in argv or any message. One line in `ci.yml`'s release-scripts step | `.github/scripts/r2.py`, `.github/scripts/test_r2.py`, `.github/workflows/ci.yml` (one line) | implementation; review | after 0 |
| 2 | `package_repos.sh` (`ready`, `publish`, `refresh`, `served`, `cleanup`) and `repo_install_check.sh`. Tests with real `gpg`, `gpgv`, `apt-ftparchive`, `createrepo_c` and `rpmsign`, throwaway keys and a throwaway `packaging/keys/` directory, a stand-in `gh`, and `r2.py` against slice 1's fake server. They cover every code from NRV-E1139 to NRV-E1156 but E1143, E1146, E1151, E1152 and the retired E1154; the strict manifest parsing (appended and prepended text, two blocks, dash-escaping, a listed-key-file key that is not in `fingerprints`); a manifest copied to a higher generation; an index replaced, deleted, or copied across channels (healed, then NRV-E1142); `ready` on a release that reads published while `PUBLISHED` is false (NRV-E1148); `ready` binding a draft in an attempt other than `mac`'s (NRV-E1153), and a dispatch with `PUBLISHED` true in any attempt (not checked); the binding, and a re-bind by a later approved attempt when no object of the tag exists, refused (NRV-E1141) when one does; a missing lock rule (NRV-E1149), and a lock refusal with another status than the pinned one (NRV-E1143); junk under each locked prefix, noted and skipped, with the run still finishing and ending red (NRV-E1142), and junk at a name the run must write (refused); a manifest name taken by junk (the run takes the next one); a verified manifest at the name the run wanted (NRV-E1147, nothing more written); `manifest/` holding only objects that do not verify (NRV-E1142, refused); a first run killed before its first manifest, then a run that starts from generation 0; a pending entry whose release is a draft or answers 404 (skipped with a notice, the run green), and a GitHub error on one (NRV-E1155, the entry still `pending`, the other entries published); a generation that changes only `package` lines copying `state`, `index` and `index-was`; a run that stops after its `writing` manifest, and a later `complete` one that refuses `index-was`; a by-hash or hashed `repodata` file with wrong content (replaced, noted); too little disk (NRV-E1156); the quiet-repository check (NRV-E1150); a kill after each step of `publish` (each row of the idempotence table), including between the `writing` manifest of step 6 and the upload, and between the upload and the `complete` manifest; a run with nothing bound; the 2,000-entry limit; that `stable` holds no candidate; and a dual-signed `InRelease`. `tests/packaging/repos.py` serves the generated trees over local HTTP to the debian 12 and 13, ubuntu 22.04 and 24.04, rocky and fedora 43 and 44 containers in `packages.yml` through `repo_install_check.sh` (NRV-E1146 and NRV-E1157 included, dnf 5 without `rpm --import`, and the "must not list" check on an empty `stable`), checks apt's refusal of a copied channel on a host that read `stable` before, checks a dual-signed `InRelease` with only one key on the host (gpgv and sqv), and checks that its commands equal this spec's install block (slice 5 switches the source to INSTALL.md). `ci.yml` installs the pinned tools for the scripts step | `.github/scripts/package_repos.sh`, `.github/scripts/repo_install_check.sh`, `.github/scripts/test_package_repos.py`, `tests/packaging/repos.py`, `.github/workflows/ci.yml` (the tools and one line), `.github/workflows/packages.yml` (one step) | implementation; review (security focus: secrets, argv, refusals, the binding, the manifest parser) | after 1 |
| K | The key-model test (P376 point 1). A throwaway certify-only primary and signing subkeys S1 and S2, made in the test. It signs a small apt repository (`InRelease`, `Release.gpg`) and a dnf repository (`repomd.xml.asc`, one rpm) with S1, and installs from them on Debian 12 (gpgv), Debian 13 (sqv), Ubuntu 22.04 and 24.04, Rocky 9 (rpm 4.16), Fedora 43 and 44 (rpm 6) and the runner's rpm 4.18, on amd64 and arm64. Then: a rotation (a host holding {primary, S1} meets a dual-signed `InRelease` and rpms signed by S2, before and after it fetches the new key file; on dnf, with the primary already imported, `dnf upgrade nerva` must succeed with no other command, on rpm 4.16, 4.18 and 6, and on apt `apt update` must succeed after INSTALL.md's `curl` line alone; any other command is a failed cell); an rpm whose subkey expired after it signed (with a faked clock, `faketime` or a short-expiry subkey and a wait); a revoked subkey (refused by apt and dnf once the key file carries the revocation); and a signature by the primary itself, which the P376 check refuses. Its pull request reports each cell and records the branch taken as a decision amending P376 (subkeys, subkeys without expiry, or the fallback). It also runs setup step 4A's exact commands in a throwaway, `--passwd` and the `sec#` listing included, with the output pasted | `tests/packaging/subkeys.py`, `.github/workflows/key-model.yml` (new, so it does not touch `packages.yml`) | implementation; review | now, parallel with 2; before 2b, 3 and setup step 4 |
| 0b | Register NRV-E1160 to NRV-E1162 and NRV-W1103 from the table above, amend the texts of NRV-E1139, E1145, E1150 and E1152, and the 11xx intro (adds `repos_alarm.sh`). If K took the fallback, E1160 is registered "retired, unused" | `docs/ERRORS.md` | mechanical; supervisor checks the diff | after K's branch is known; before 2b |
| 2b | `package_repos.sh` amended to P376: the pinned check (`VALIDSIG` `$12` is `primary`, `$3` a subkey listed for the file kind, RSA, SHA-512, the class, no `EXPKEYSIG` or `REVKEYSIG`; replaces slice 2's `$NF` check), the roles of `fingerprints` (`primary`, `current`, `next`, `retired`, `revoked`, `anchor`, or the fallback's), the secret's `sec#` check and `_NEXT` pair, dual signing, the rpm Key ID, NRV-E1160, step 4's rpm check and step 5b (NRV-E1161) with the `excluded` state, step 8's fetch-back of everything written, `Date` from the run and `SOURCE_DATE_EPOCH` refused, each step's `code` output, and `.github/scripts/repos_alarm.sh` with its test (a stand-in `gh`: open, assigned to `PACKAGE_REPOS_OWNER`, comment, one comment a day per (workflow, job, code), NRV-W1103; no alarm on `cancelled`). Tests add: a badly signed rpm never recorded or put; a bad rpm already in the bucket `excluded` and indexed without; a primary-signed file refused; a subkey not listed for the kind refused; an expired and a revoked subkey; a secret holding the primary refused; a key file and secret that disagree (NRV-E1161, nothing uploaded); a served object that differs (NRV-E1145); the expiry thresholds | `.github/scripts/package_repos.sh`, `.github/scripts/test_package_repos.py`, `.github/scripts/repos_alarm.sh`, `.github/scripts/test_repos_alarm.py` | implementation; review (security focus: the check, the roles, the anchor) | after 2, K and 0b |
| 3 | `packaging/keys/nerva-release.asc` and `packaging/keys/fingerprints` (`primary <fpr>` and `current <subkey fpr>`; in the fallback, `current <fpr>`), from setup step 4 | `packaging/keys/*` | mechanical; supervisor checks both fingerprints against the owner's and against `gpg --show-keys` | after K and setup step 4; parallel with 2b |
| 4 | `release-finish.yml`: jobs `repos-ready` and `repos` (gated on `public`), both in the concurrency group `nerva-packages-bucket` with `cancel-in-progress: false`, `repos-verify`, `site-verify`; `publish`'s `needs`, `if`, last step and output `public`; `mac-sign.yml`'s new output `attempt` (`github.run_attempt` of its signing job), which `repos-ready` compares; the header comment (which still says "the site's auto-merge"; P364 merges directly); images pinned by digest. `release_finish.sh site-live` and its test. `package-repos-refresh.yml`: the weekly schedule and dispatch, its job in the same group. `ci.yml`'s `repos-fresh` job, behind `REPOS_LIVE`, failing at under 10 days and on NRV-E1160. The `alarm` job in all three workflows (P376: `issues: write` only, `continue-on-error`), the refresh's `missed` output and `alarm_test` input. `site-live` also compares the served WKD file with the release commit's key file (NRV-E1162). Tried with a dispatch on a published candidate before review where possible: `repos-ready` then refuses NRV-E1139 cleanly while the environment is not set up | `.github/workflows/release-finish.yml`, `.github/workflows/mac-sign.yml` (one output), `.github/workflows/package-repos-refresh.yml`, `.github/workflows/ci.yml` (one job), `.github/scripts/release_finish.sh` (`site-live`), `.github/scripts/test_release_finish.py` | implementation; review (security focus: environments, `needs`/`if`, outputs, `!cancelled()`, the shared concurrency group on every job that writes the bucket and on no other) | after 2 |
| 5 | The fingerprint in INSTALL.md's new section (the `primary` line; the dnf 5 notes, pinning by Origin, the signing sentence, the two-channel WKD check, and the yearly key-file fetch), CLAUDE.md (the site line, the release line, the environment fact), automation.md's hook section as a pointer here, the source of slice 2's install-block test switched from this spec to INSTALL.md (one line), and the worklog. In the site repository, one pull request: CLAUDE.md and README (Cloudflare Pages, "no key on the page", the refused names), `.github/CODEOWNERS` deleted, the WKD files (`.well-known/openpgpkey/policy`, empty, and `hu/ndqm47zydhyqyzabecddtdk1q3bponab`, the `gpg --dearmor` of the key file; the hash rechecked with `gpg-wks-client --print-wkd-hash nerva@nerva.pro`), and `site_check.mjs` refusing every name the build command refuses (NRV-E1152), dangling symlinks included, and comparing the WKD file with Nerva's `main` (NRV-E1162), with its test | `docs/INSTALL.md`, `CLAUDE.md`, `docs/releases/automation.md`, `tests/packaging/repos.py` (one line); the site's `CLAUDE.md`, `README.md`, `.github/CODEOWNERS`, `.well-known/openpgpkey/*`, `site_check.mjs` and its test | mechanical, except the `site_check.mjs` change (implementation); supervisor checks | after 2 and 3, and after setup steps 2 and 8 |
| E | Setup steps 1 to 10 | Cloudflare, GitHub | owner | in order; step 4 after K and before slice 3; step 7 only after step 3's check |
| F | The rehearsal, its run link recorded, and `REPOS_LIVE` set | worklog, a repository variable | supervisor | after 0 to 5, 0b, 2b, K and E |
| G | P376b: `release_check.sh gates` (NRV-E1159) and its tests, called in `release.yml`'s `version` job and `release-finish.yml`'s `publish`; NRV-E1159 in `docs/ERRORS.md` | `.github/scripts/release_check.sh`, `.github/scripts/test_release_check.py`, `.github/workflows/release.yml`, `.github/workflows/release-finish.yml` (one step each), `docs/ERRORS.md` | implementation; review | after #374 merges and after the v0.7.1 tag |
| M | P376c: `macos-x86_64` and `mac-verify.yml`'s x86_64 cell moved to `macos-15` under Rosetta; automation.md's wording | `.github/workflows/ci.yml`, `.github/workflows/mac-verify.yml`, `docs/releases/automation.md` | mechanical; supervisor checks | on P376c's trigger |

Slices 0 and 1 have merged; slice 2 is open (#368). The order from here (P376):

1. **2 and K at once.** K touches only its own test and workflow.
2. **0b**, once K's branch is known.
3. **2b**, after 2, K and 0b. It amends what 2 merged and does not edit 2's open branch.
4. **Setup step 4**, by the branch K chose, **then 3**.
5. **4**, after 2b. Slices 1, 2 and 4 each touch `ci.yml` and run in sequence.
6. **5**, which changes no script in this repository, after 3 and 4.
7. **E and F**, the rehearsal.

G waits for #374 and the v0.7.1 tag (P376b). M waits for its trigger (P376c).
