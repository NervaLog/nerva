# The domain, and the apt and dnf repositories: spec, setup, slices

Status: spec, 2026-11-12 (P365, which amends P360 point 10, P364 and P148). Reworked twice the
same day after adversarial reviews, and after the owner's decision that Cloudflare deploys the
site. Nothing here is built yet. It is the last change before the v0.7.1 tag: the owner moved the
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
   only a static page, and a merge there can change none of it.

## Architecture

### The hosts

```
https://nerva.pro/                 index.html: Cloudflare Pages project nerva-site, built from the site repository's main
https://www.nerva.pro/             a Cloudflare redirect rule: 301 to https://nerva.pro/<path>
https://nervalog.github.io/        GitHub Pages is off: GitHub's 404 (accepted, see "The old URL")
https://packages.nerva.pro/        the R2 bucket nerva-packages, public, read-only (R2 custom domain)
https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc
                                   the repositories' public key: a file in Nerva's repository
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
holds any of those names, then copies `index.html` alone into an empty `dist/`, the output
directory:

```
set -eu; for p in wrangler.toml wrangler.json wrangler.jsonc functions _worker.js _routes.json; do if [ -e "$p" ]; then echo "error[NRV-E1152]: site build: $p is not allowed in the site repository; nothing is deployed" >&2; exit 1; fi; done; rm -rf dist; mkdir dist; cp index.html dist/
```

A failed build deploys nothing, so the last good deployment keeps serving. A pull request in the
site repository cannot change the build command: only a member of the Cloudflare account can.
The site's `site_check.mjs` refuses the same names too (slice 5), so a pull request fails before
it merges, but that check is the pull request's own code. The build command is what holds.
If the site gains a second file, the owner extends the build command's `cp`.

**Preview deployments: on, for pull requests (recommended).** Cloudflare builds every
non-production branch of the site repository with the same build command and posts its preview
URL on the pull request. Why on:

- The gate can be tested without a merge. The rehearsal opens a pull request that adds a
  `wrangler.toml` binding the bucket and a `functions/` file, and its preview build must fail
  with NRV-E1152.
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
  carries no key, no fingerprint and no repository line of its own. It links to INSTALL.md in this
  repository for them (slice 5).
- **Cannot:** run code on Cloudflare, or bind the bucket (the build command refuses it, and the
  repository cannot change the build command). Cannot read or write the bucket (no credential).
  Cannot change the key, the fingerprints or the scripts (all in this repository). Cannot get
  anything signed, or change what `packages.nerva.pro` serves (R2 serves it, not the Pages
  project).
- **If the gate ever failed** (for example, Cloudflare starts reading a config file under a new
  name), a site merge would gain the bucket token's power and nothing more. "The R2 token leaks"
  below bounds that: it cannot sign, the bucket locks stop it from deleting or replacing a package
  or a manifest, and the next write run reports any tampering.

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
that writes it, which is checked on every run (step 3 of `repos`), not by the server.

The owner's answer to the Workers Paid question (owner, 2026-11-12: only if the free quota is
hit) stands, and with this design there is no Worker quota to hit.

The bucket is public, so its manifests and its lock objects are readable by anyone. They hold only
hashes, names, run ids and times, which the public releases and runs already show.

**Bucket locks.** The bucket has five R2 bucket lock rules, each with indefinite retention, on the
prefixes `apt/pool/`, `rpm/stable/packages/`, `rpm/rc/packages/`, `manifest/` and `lock/` (setup
step 5). R2 then refuses to delete or overwrite any object under them, whoever asks. The bucket
token is "Object Read & Write" and cannot change lock rules, which needs an admin permission. So
the token can add objects there, but cannot remove or replace a package, a manifest or a lock
object. Every write run checks that the locks are in force (step 3 of `repos`, NRV-E1149). The
names a run replaces (the indexes) cannot be locked, and the manifest records their hashes instead
(below).

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
  lock/<generation, ten digits>                                              locked, the write lock (below)
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
`manifest/<generation>.asc`, written only if absent, and locked. The current manifest is the one
with the highest generation. Nothing can roll it back: an older manifest cannot be put back over a
newer one (locked), and the newer one cannot be deleted (locked). It is clearsigned text:

```
nerva-packages manifest 2
generation <n>
package <state> <sha256> <size> <key> <source-sha256> <tag> <commit>
...
index <sha256> <key>
...
index-was <sha256> <key>
...
```

- **`generation`** must equal the number in the object's name. A copy of an older signed manifest
  under a new, higher name therefore fails (NRV-E1142).
- **`package` lines,** one per package object, sorted by key. `<state>` is `pending` or
  `published`. `<sha256>` and `<size>` are the stored object's (for an rpm, the signed copy).
  `<source-sha256>` is the release asset's, as the approved run read it from the draft. `<tag>`
  and `<commit>` are the release's tag and the commit `publish-ready` checked.
- **`index` lines** give the SHA-256 of every name a run replaces (`InRelease`, `Release`,
  `Release.gpg`, `Packages`, `Packages.gz`, `repomd.xml`, `repomd.xml.asc`, for each channel and
  architecture), as this run uploads them. **`index-was` lines** give what the run found in the
  bucket for those names, and accepted, before it uploaded. A run that stops between writing the
  manifest and finishing the upload leaves each name either at its `index` or its `index-was`
  hash, and the next run accepts both. Anything else is tampering (see "The R2 token leaks").
- **Bound:** at most 100,000 generations. Above that the job refuses (NRV-E1142). A release run
  writes two or three, a refresh one, so that is far beyond any foreseeable use.

**It is verified only against the pinned fingerprints.** `packaging/keys/fingerprints` in this
repository lists the fingerprints the job trusts, each with a role:

```
current <40 hex>
next <40 hex>        (only during a rotation)
previous <40 hex>    (while rpms it signed are in the bucket, which with the locks is for good)
```

`packaging/keys/nerva-release.asc` holds exactly those keys, armored. The job builds a keyring
from that file and verifies with `gpgv --status-fd 3 --output -`. A key file that holds a key the
list does not name, or misses one it names, is NRV-E1139. Nothing the job reads from the bucket,
the site or the network is ever a source of trusted keys.

**Parsing is strict** (the clearsign pitfalls). The job refuses the manifest (NRV-E1142) unless:

- the file starts with `-----BEGIN PGP SIGNED MESSAGE-----` on its first line, holds that line
  and `-----BEGIN PGP SIGNATURE-----` exactly once each, and ends with
  `-----END PGP SIGNATURE-----` and one newline. Nothing comes before or after the one signed
  block;
- `gpgv`'s status holds exactly one `VALIDSIG`, whose primary-key fingerprint is listed, and no
  `BADSIG`, `ERRSIG`, `EXPSIG`, `EXPKEYSIG` or `REVKEYSIG`.

It then parses **only what `gpgv --output -` printed**, which is the signed text with the
dash-escaping removed, never the file itself. Slice 2 tests unsigned lines appended or prepended,
a second signed block, a dash-escaped line, and a signature by a key that is in the key file but
not listed.

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
    dnf refuses an rpm not signed by it. The next write run refuses the bucket (NRV-E1142),
    because every package object must be in the current manifest.
  - **Deleting or replacing a package or a manifest** is refused by the bucket locks.
  - **Rolling the manifest back** is impossible: the current manifest is the highest generation,
    and none can be deleted. Copying an old manifest to a higher name fails its `generation` line.
  - **Freeze and replay.** The holder can put back an older signed `InRelease` or `repomd.xml`
    with its signature, so users stay on an old version. apt refuses an `InRelease` past its
    `Valid-Until` (at most 21 days old, below). dnf has no signed expiry. The next write run, at
    most a week later, finds a hash that is neither `index` nor `index-was`, **writes fresh indexes
    anyway, then ends red with NRV-E1142.** So users are healed and the owner is alarmed; a
    refusal that left the old indexes in place would let the holder break `apt update` for
    everyone once `Valid-Until` passed. The one replay it cannot see is the set of the run just
    before (`index-was`), which is at most one write run old.
  - **Channel swap:** as in "Channels" above, detected and repaired the same way.
  - **Deleting an index file** is a denial of service until the next write run, which rewrites it
    and reports it the same way.
  - **Adding a lock object** of a higher generation makes the next run wait until it is stale (60
    minutes), then take it over.
  - **The key file** is not in the bucket, so the token cannot change it.
- **The signing key leaks:** the one compromise that reaches users. See "Rotation and
  compromise".

## The release graph

`release-finish.yml` (P360, P362, P364) gains four jobs and one output:

```
guard ── mac (apple-signing: THE ONE APPROVAL) ── mac-verify ─┬─ repos-ready (package-repos) ─┐
                                                               └───────────────────────────────┴─ publish (release-publish; output public)
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
- A failure in `repos` or `repos-verify` happens after the release is public. Its fix is **"Re-run
  failed jobs" of the same run**, which keeps the digests `repos-ready` read from the draft (see
  "What the key signs, and who can make it sign"). GitHub allows a re-run for 30 days after the
  run. After that, only a dispatch is left, and a dispatch binds nothing new (see "Recovery").

### What the key signs, and who can make it sign

Release assets stay mutable after publishing, and `SHA256SUMS` is one of them, so a check against
it proves nothing after the fact. A dispatch for a published release skips `mac` (P362 point 10)
and needs no approval. The design therefore binds **new** package content to the approved run
itself, and only while the release is still a draft:

1. **`repos-ready` reads the four packages from the draft,** in a run where `guard` found a draft
   and `mac` succeeded, so after the owner's approval and before `publish`. **It binds only if the
   release reads `draft: true` at that moment,** from its own `gh api` call, made before it
   downloads the packages and again after it has hashed them. It never trusts `guard`'s output for
   this. It checks the packages against the draft's `SHA256SUMS` (NRV-E1140) and sets the job
   output `bound`: the four file names, their SHA-256 and the commit `publish-ready` checked.
   - Where `guard` found the release already published (a dispatch), `bound` is empty.
   - Where `guard` found a draft but the release now reads published, `ready` refuses with
     NRV-E1148 and binds nothing. That is a "Re-run this job" of `repos-ready` from a run whose
     `publish` already succeeded: GitHub keeps `guard`'s old output, so without this check the
     re-run would read the now-mutable published assets and bind them with no approval.
     "Re-run failed jobs" never re-runs a `repos-ready` that succeeded, so the normal recovery
     keeps the original `bound`.
2. **`repos` signs and lists a package only if its bytes equal `bound`.** It downloads them from
   the now-public release, compares (NRV-E1148), and its first write is a manifest with those
   packages as `pending` entries, signed. From then on the signed manifest carries the binding,
   so any later write run can finish those entries from the release's assets, but only with bytes
   whose SHA-256 equals the entry's `<source-sha256>` (NRV-E1148 otherwise).
3. **A run with nothing bound adds nothing.** A dispatch for a published release, a "Re-run all
   jobs" (which re-runs `guard`, now seeing a published release), or the weekly refresh: each
   finishes `pending` entries, re-signs the indexes from the manifest, and stops with NRV-E1148
   for a tag that has neither `bound` digests nor manifest entries. A release published before
   the repositories existed is therefore not backfilled; its files install by hand.

So the key signs:

| What | Who can cause it | Bounded by |
|---|---|---|
| A new rpm, or a new manifest entry | only the run whose `mac` the owner approved, while the release is a draft, and re-runs of its failed jobs (anyone with write access can press the button) | `bound`, read from the draft after the approval, fixed for the run |
| An rpm again, for a `pending` entry whose object never landed | any write run | the entry's `<source-sha256>`, in a manifest signed by a pinned key |
| `InRelease`, `Release.gpg`, `repomd.xml.asc`, a manifest | any write run: a release run, a dispatch, a re-run, the weekly refresh | a deterministic function of the signed manifest, after the bucket is checked against it |

What the draft held when the approved run read it is what gets signed. Anyone who can change a
draft's assets before the approval can already change what the release ships (the Mac zip apart,
which `mac` signs). That is the existing risk of the release, and this spec does not widen it.
Anyone who can merge to `main` here can change the workflows and scripts, and with them all of
the above. That is the guard the release already relies on (automation.md, "Security notes"), and
this design puts the packages' trust in that one place instead of adding a second.

Not chosen: GitHub's immutable releases (published assets cannot change). Its effect on P343 7b's
cleanup of a candidate, which deletes the release and its tag, was not checked, and the binding
above does not need it. It can be added later as a second layer.

### `repos-ready`

- `needs: [guard, mac, mac-verify]`, with the same `if` as `publish`. It runs after the approval,
  because `publish-ready` checks the draft's target (P343), and the twelve assets exist only after
  `mac` (P361).
- `runs-on: ubuntu-24.04`, `timeout-minutes: 15`, `environment: package-repos`,
  `permissions: contents: write` (reading a draft's assets needs it, P311). **No `concurrency`:**
  it writes nothing and takes no lock.
- `outputs: bound` (see above).
- Steps:
  1. Check out the workflow's own ref, with `persist-credentials: false`.
  2. `release_check.sh publish-ready "$TAG"`. It is unchanged.
  3. Install the pinned tools (see "Tools"). A tool that does not install or does not report its
     pinned version is NRV-E1139.
  4. `package_repos.sh ready "$TAG" "$PUBLISHED"`. The environment's secrets and variables reach
     this step only, through `env:`. It writes nothing. It refuses with a code:
     - an environment that lacks a secret, a variable or a pinned tool, a key that does not
       import, a key whose fingerprint is not the `current` one in `packaging/keys/fingerprints`,
       or a key file that does not hold exactly the listed keys (NRV-E1139);
     - a draft without exactly its four packages, or a package that does not match `SHA256SUMS`
       (NRV-E1140);
     - a package name the manifest already lists with another `<source-sha256>` (NRV-E1141);
     - every bucket rule of step 3 of `repos` but the lock probe, which writes (NRV-E1142);
     - a bucket that cannot be listed or read with the token (NRV-E1143);
     - the current manifest served at `https://packages.nerva.pro/manifest/<generation>.asc` that
       differs from the bucket's object (NRV-E1145);
     - `PUBLISHED` false while the release reads published (NRV-E1148, above).
  5. Under `if: always()`: `package_repos.sh cleanup`. It runs `gpgconf --kill all` and removes
     the temporary `GNUPGHOME`.

**It blocks the release on a bucket fault, on purpose.** With R2 down, or an object planted in the
bucket, `repos-ready` refuses, and the GitHub release, the tap and the site wait with it, though
none of them depend on the repositories. This keeps P362 point 8 (refuse before publishing): a
release is never published while its packages cannot follow. The recovery is in the table below,
and P365 lists it as a cost.

### `repos`

- `needs: [guard, repos-ready, publish]`, with the `if` above, `runs-on: ubuntu-24.04`,
  `timeout-minutes: 120`, `environment: package-repos`, `permissions: contents: read` (the release
  is public now).
- **No `concurrency` group.** GitHub's concurrency keeps one pending job per group and cancels the
  older pending one, which would leave a public release with no packages and a "cancelled" job
  that pages nobody. Write runs queue on the bucket's own lock instead (step 2), and are never
  cancelled. (The workflow's own group, `release-finish-<tag>`, can still replace a pending run of
  the **same** tag by a newer one, which does the same work.)
- Steps 1 and 3 as in `repos-ready`. Then `package_repos.sh publish "$TAG"`, with
  `BOUND: ${{ needs.repos-ready.outputs.bound }}` and the same `env:` as before. In this order:
  1. **Keys.** It imports the key into a fresh `GNUPGHOME` under `$RUNNER_TEMP` (mode 0700). It
     writes the passphrase from the environment with `printf`, a shell builtin, so it is never in
     an argv, to `$GNUPGHOME/passphrase` (mode 0600). `gpg.conf` gets `pinentry-mode loopback` and
     `passphrase-file`. It checks the key against `packaging/keys/` as `ready` does (NRV-E1139).
  2. **The lock.** It lists `lock/` (every page, see `r2.py`) and reads the highest generation `g`.
     If there is none, or its body is `free <epoch>`, or it is `held <run>/<attempt> <epoch>` with
     that epoch more than 60 minutes old (stale: no holder lives that long, see below), it puts
     `lock/<g+1>` with `held <run id>/<attempt> <now>`, write-if-absent. A 412 means another run
     won; it lists again. Otherwise it waits 30 seconds and tries again, for at most 70 minutes,
     then stops with NRV-E1147 (nothing was written; re-run). The holder gives itself 45 minutes
     from its acquisition; before each replaceable write it checks that `lock/<g+2>` does not
     exist (no one took the lock over), and stops with NRV-E1147 otherwise. At the end, and under
     `if: always()` in `cleanup`, it puts `lock/<g+2>` with `free <now>`, write-if-absent. A
     takeover is itself a write-if-absent, so two runs cannot both take a stale lock; the
     15 minutes between the holder's deadline and staleness cover the seconds between the
     holder's check and its write. The job never deletes a lock object (they are locked anyway).
     Lock objects are about 60 bytes, two a run; past 20,000 generations the job refuses
     (NRV-E1147) and the owner decides on pruning.
  3. **Check the bucket.** It lists `manifest/` and reads the highest generation, then verifies it
     as "The manifest" says (NRV-E1142 for any failure). With no manifest and no package object,
     it starts from an empty manifest, generation 0. Package objects but no manifest is
     NRV-E1142. Then:
     - **Packages.** It lists `apt/pool/` and `rpm/*/packages/`. Every package object must be in
       the manifest; every `published` entry's object must exist, and it downloads each one and
       compares its SHA-256; no candidate under `rpm/stable/`. Any failure is NRV-E1142.
     - **Bound:** at most 2,000 package objects and 8 GiB. Above that the job refuses
       (NRV-E1142), and a decision is needed: a pruning policy, or indexes built from the
       manifest instead of the files. At about 38 MB a release (the rpms twice), that is about
       200 releases away.
     - **The locks.** It re-puts the current manifest's own bytes over it, unconditionally,
       with `r2.py probe-locked`. A lock rule refuses that. If R2 accepts it (the bytes are
       identical, so nothing changes), the lock rule on `manifest/` is gone: NRV-E1149. The same
       probe runs on one existing object under each other locked prefix that has one.
     - **The indexes.** It reads each replaceable name and compares its SHA-256 with the
       manifest's `index` and `index-was` lines. A name that matches neither, or that is missing
       while the manifest lists it, is **noted, not refused**: the run carries on, rewrites every
       index in step 8, and ends with NRV-E1142 after `served` (see "The R2 token leaks"). It
       records each name's found hash for the `index-was` lines it will write.
  4. **Bind.** If the tag has no entries yet: with `BOUND` empty, it stops (NRV-E1148). Otherwise
     it downloads the four packages from the published release and compares each with `BOUND`
     (NRV-E1148). It signs each rpm (see "Signing"), checks that the signed copy has the release
     file's NEVRA and payload digest (NRV-E1144), and writes the next manifest generation with
     the new entries as `pending`: each deb once, each rpm under `rpm/rc/packages/`, and for a
     release also under `rpm/stable/packages/`. Its `index` and `index-was` lines are the
     previous manifest's `index` lines and what step 3 found. **This manifest is the run's first
     write to the bucket,** so every package object the job ever writes is listed in a signed
     manifest before it exists. If the tag has entries already (a re-run), their
     `<source-sha256>` must equal `BOUND` where `BOUND` is set (NRV-E1141), and nothing is
     re-bound.
  5. **Put.** For every `pending` entry, of any tag:
     - the object exists with the entry's SHA-256: nothing to do (an earlier run put it);
     - it exists with other content: NRV-E1142;
     - it is absent, and it is a deb: download it from the entry's release, check its SHA-256
       against `<source-sha256>` (NRV-E1148), put it write-if-absent;
     - it is absent, and it is an rpm: if another copy of the same file (the other channel) exists
       with the entry's SHA-256, put those bytes. Otherwise this run's signed copy from step 4 if
       it has one; otherwise download the release's rpm, check `<source-sha256>` (NRV-E1148), and
       sign it again. A new signature differs, so the run **first** writes a manifest generation
       with the entry's new `<sha256>` and `<size>`, **then** puts the object write-if-absent.
  6. **Indexes.** It regenerates both channels of both formats from the entries whose objects are
     all present (they are about to be `published`): `stable` from the releases, `rc` from
     everything.
     - **apt:** for each channel it makes a staging tree of hard links to that channel's debs and
       runs `apt-ftparchive -a <arch> packages pool/main/n/nerva` for `amd64` and `arm64`, writing
       `Packages` and `Packages.gz`. With only those files under `dists/<channel>/`, it runs
       `apt-ftparchive release` with the channel's Origin, Label, Suite and Codename (above),
       Architectures `amd64 arm64`, Components `main`, `Acquire-By-Hash: yes`, and `Valid-Until`
       21 days after `Date`. Only then does it make the `by-hash/SHA256/<hex>` copies and sign
       `InRelease` (clearsign) and `Release.gpg` (detached), so `Release` never lists `by-hash/`
       or an old signature. During a key rotation it signs both with `current` and `next` (see
       "Rotation").
     - **dnf:** for each channel it makes a staging tree whose `packages/` holds that channel's
       rpms, then runs `createrepo_c --general-compress-type=gz --checksum=sha256 --no-database
       --revision <now, epoch seconds>`, which gives unique names for everything but
       `repomd.xml`, and signs `repomd.xml.asc` (detached, armored).
  7. **Promote and record.** It writes the next manifest generation: those entries as
     `published`, `index` lines with the SHA-256 of every replaceable file from step 6, and
     `index-was` lines with what step 3 found.
  8. **Upload the indexes.** First every name written once (`by-hash/...`, the hashed `repodata`
     files), each write-if-absent. Then the names a run replaces: apt's `Packages`, `Packages.gz`,
     `Release` and `Release.gpg` for each channel, with `InRelease` last; then for each channel
     `repomd.xml.asc` and `repomd.xml`, back to back, last of all. `r2.py put` refuses to replace
     any name outside the replaceable set, so a bug cannot overwrite a package, and the locks
     refuse it too.
  9. **Unlock** (step 2).
- `package_repos.sh served "$TAG"` (no secrets) fetches over `https://packages.nerva.pro`: each
  channel's `InRelease` and `repomd.xml`, and the current manifest, must equal the bytes just
  uploaded, and the tag's packages must be served with their SHA-256 (NRV-E1145). Then, if step 3
  noted tampered indexes, it ends with NRV-E1142, naming each name and its found hash.
- `package_repos.sh cleanup` runs under `if: always()`; it also frees the lock if this run holds
  it.

**Idempotence.** Every write is a signed manifest that lists what will exist before it exists, a
write-if-absent put of content the job compares first, or indexes regenerated from the manifest.
A run stopped at any step leaves the bucket in a state the next write run accepts and finishes:

| Stopped after | The bucket holds | The next write run |
|---|---|---|
| step 2 (lock taken) | a held lock | waits until it is stale (60 minutes), then takes it over |
| step 4 (pending manifest) | entries, no objects | puts them (step 5), re-signing absent rpms |
| part of step 5 | some objects of pending entries | puts the rest; adopts what is there with the entry's SHA-256 |
| step 5 | all objects, entries pending | indexes, then promotes |
| step 7 | the promoted manifest, the old indexes (`index-was`) | accepts them, rewrites every index |
| part of step 8 | new names written once, each replaceable name at `index` or `index-was` | accepts them, rewrites every index |

A second run of a finished release writes no package object; it writes a manifest and the indexes
again, with the same content but new dates and signatures. The job never replaces or deletes a
package object, a manifest or a lock object.

### `Valid-Until`, and the weekly refresh

apt's `Release` carries `Valid-Until`, 21 days after `Date`, so a replayed `InRelease` stops
working at most 21 days after it was signed. Something must therefore re-sign within 21 days even
when no release happens: `package-repos-refresh.yml` runs `package_repos.sh refresh` every Monday
at 05:17 UTC (and by `workflow_dispatch`), from `main`, in `package-repos`, under
`concurrency: { group: package-repos-refresh, cancel-in-progress: false }` (a newer pending refresh
replacing an older one loses nothing). `refresh` is `publish` without step 4: it takes the lock,
checks the bucket, finishes `pending` entries, promotes, and re-signs both channels. Every release
run does the same. Two refreshes can fail in a row before users see "Release file … is expired".
A failed scheduled run e-mails the account that last changed the workflow's `schedule` line, which
is `topwombat`, and its fix is a re-run. dnf has no signed expiry: the cost stays as P365 lists it.

### The 60-day rule

GitHub disables a public repository's scheduled workflows after 60 days with no commit, without a
failed run to e-mail about. Then `Valid-Until` lapses about 21 days later, and every `apt update`
fails with "Release file … is expired" while dnf keeps working. Two alarms come before that:

1. **The refresh warns from day 45.** After it has re-signed, `refresh` reads the date of the
   newest commit on `main` (`gh api repos/$GITHUB_REPOSITORY/commits/main --jq
   .commit.committer.date`). If it is more than 45 days old, the run ends with NRV-E1150: "the
   repository has had no commit for N days; GitHub disables this schedule at 60". The failed
   scheduled run e-mails the owner every Monday from day 45 to day 60. The fix is any commit to
   `main`, such as a worklog note. The refresh never commits by itself: `main` is protected, and
   a bot that keeps a repository looking active would hide the real state.
2. **CI checks the expiry on every push to `main`.** `ci.yml` gains a job, `repos-fresh`, on
   `push` to `main` only, never on pull requests, and not a required check, so a Cloudflare
   outage never blocks a pull request. It fetches `stable`'s `InRelease` from
   `https://packages.nerva.pro`, verifies it against `packaging/keys/` with `gpgv`, and fails
   with NRV-E1150 if its `Valid-Until` is less than 7 days away. Until the rehearsal has written
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
  | `ubuntu-24.04` (amd64) | `debian:12` (gpgv), `debian:13` (sqv), `ubuntu:24.04`, `rockylinux:9` (rpm 4.16), `fedora:43` (rpm 6, dnf 5) |
  | `ubuntu-24.04-arm` (arm64) | the same five |

  Fedora 43 is the first Fedora with rpm 6 and its enforcing signature policy; Debian 13 is the
  first with apt verifying through `sqv`. Slice 4 also adds the newest Fedora of the day if it is
  later than 43, pinned the same way.
- **dnf 5.** The `fedora:43` image is pinned at a digest whose dnf5 is at least
  `5.2.18.0-4.fc43` (the fix for RHBZ 2458182, a five-minute hang on importing a repository key),
  and the check asserts `rpm -q dnf5` against that version before it starts.
- Each cell runs `.github/scripts/repo_install_check.sh <apt|dnf> <channel> <base-url>
  <fingerprint> <version>` in the container, with the channel the tag belongs to: `rc` for a
  candidate, `stable` for a release. The script runs **INSTALL.md's own commands** (the same text,
  kept in step by slice 2's test), with `-y` added where they prompt. It fetches the key and checks
  its fingerprint. For apt it writes the `.sources` file and runs `apt-get update` and
  `apt-get install -y nerva=<package version>`. For dnf it writes the `.repo` file with
  `gpgcheck=1`, `repo_gpgcheck=1` and `gpgkey=`, and runs `dnf install -y nerva-<package
  version>`. It does **not** run `rpm --import`. dnf 5 verifies `repomd.xml` with its own
  repository keyring, which it fills from `gpgkey=` on first use. A key only in the rpm database
  gives "repomd.xml GPG signature verification error: Signing key not found" (Fedora 41 reports),
  and a user following INSTALL.md never runs `rpm --import` either. Then `nerva version`'s last
  line must be `version <V>`.
- **A candidate also checks `stable`:** with `stable` configured, `apt-cache policy nerva` and
  `dnf list --showduplicates nerva` must not list the candidate.
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
- `publish`'s meaning of "published" (P364) changes in one word: the site pull request is merged
  after `site-check` passes, exactly as now, and the page is published when **Cloudflare** has
  deployed that merge, which `site-verify` checks.

### Recovery

| What stopped | Do |
|---|---|
| `repos-ready` refused NRV-E1139, NRV-E1140 or NRV-E1145 | Fix the setup it names, then "Re-run failed jobs". Nothing was published or written |
| `repos-ready` refused NRV-E1143 (R2 unreachable) | The draft waits. Re-run failed jobs when R2 answers. To ship without packages instead, the owner decides; that is a new decision, and the tag is then never bound |
| `repos-ready` refused NRV-E1141 or NRV-E1142 | Stop. The bucket holds something no signed manifest allows. The owner rotates the R2 token and decides. The draft waits |
| `repos-ready` refused NRV-E1148 (the release was already public) | Someone re-ran `repos-ready` alone after publication. Use "Re-run failed jobs" of that run instead; if `repos` already bound the tag, nothing is needed |
| `publish` failed after the release went public (NRV-E1135, E1136, E1138) | `repos` runs anyway (`public` is `true`). Recover the tap or the site as P362 and P364 say |
| `repos` stopped part way, or failed with NRV-E1143 or NRV-E1147 | "Re-run failed jobs" of the **same** run, within GitHub's 30 days. It converges (the table above). A dispatch or the weekly refresh also finishes whatever the manifest already lists |
| `repos` refused NRV-E1148 for a release whose run never wrote its entries | The bytes on the release differ from what the approved run read, or nothing was bound (a dispatch, "Re-run all jobs", or a re-run after 30 days). Stop: the owner decides (a new patch release, normally). The release's files still install by hand |
| `repos` refused NRV-E1141 or NRV-E1142 before writing | Stop. The bucket holds something no signed manifest lists, a listed object is missing or changed, or a manifest fails its checks. A crash of this pipeline never causes these (every object is listed before it is written), so suspect the R2 token: the owner rotates it and decides |
| `repos` or the refresh ended NRV-E1142 after rewriting the indexes | An index file was replaced or deleted outside a run. Users are already healed. The owner rotates the R2 token |
| NRV-E1149 | A bucket lock rule is gone. The owner restores it as setup step 5 says, and checks the account's audit log for who removed it |
| `repos-verify` failed | Read which image failed. If it is the environment (a mirror is down), re-run. Otherwise it is a finding: file it |
| `site-verify` failed NRV-E1151 | As in "`site-verify`" above |
| The weekly refresh failed | Re-run it. apt users have at least a week before `Valid-Until` |
| The refresh or `repos-fresh` failed NRV-E1150 | As in "The 60-day rule" |

## Signing

**One OpenPGP key, RSA 4096, sign-only, with no expiry and no subkeys.**

- **RSA 4096, not Ed25519:** apt (`gpgv` on Debian 12 and Ubuntu, `sqv` on Debian 13), Rocky 9's
  rpm 4.16 and Fedora's rpm 6 (Sequoia) all verify RSA with SHA-512. rpm 4.16's support for
  EdDSA and for subkeys is the weak point of older RPM distributions, and one primary key avoids
  both. The key's self-signatures use SHA-512 (`--cert-digest-algo SHA512`), which `sqv`'s policy
  accepts.
- **No expiry:** apt refuses a signature by an expired key, and a key file in
  `/etc/apt/keyrings/nerva.asc` does not refresh itself, so an expiry date would break every user
  on that day. Rotation is a policy instead: every two years, and at once on a compromise.
- **Digest:** `--digest-algo SHA512` for every signature, and `%_gpg_digest_algo sha512` for rpm.

It signs:

| What | How |
|---|---|
| apt `InRelease`, `Release.gpg` | `gpg --clearsign`, `gpg --detach-sign --armor` of `Release` (with `-u current -u next` during a rotation) |
| dnf `repomd.xml.asc` | `gpg --detach-sign --armor repomd.xml` |
| each rpm | `rpmsign --addsign`, with `--define "_gpg_name <fingerprint>"`, `--define "_gpg_path $GNUPGHOME"` and `--define "_gpg_sign_cmd_extra_args --pinentry-mode loopback --passphrase-file $GNUPGHOME/passphrase"`. The path to the passphrase file is in the argv; the passphrase is not |
| each manifest | `gpg --clearsign`, with `current` only |

**The release's assets stay as P295 left them: unsigned, and covered by `SHA256SUMS`.** The
repository's rpm is a signed copy: `rpmsign` adds a signature header and changes neither the main
header nor the payload, and the job checks this (NRV-E1144). Debs are not signed one by one,
because apt's trust comes from the signed `InRelease` and its hashes, so the repository's deb is
the release's file, byte for byte.

**Custody.** The armored secret key is the secret `REPO_SIGNING_KEY` of the environment
`package-repos`, and its passphrase is `REPO_SIGNING_PASSPHRASE` in the same environment. They
reach only the `package_repos.sh` steps (`ready`, `publish`, `refresh`), through `env:`, and never
an argv, a URL or the log. GitHub masks both, and the scripts never echo them. A backup of the
key, its passphrase and its revocation certificate is in the owner's password manager, and
nowhere else.

**Publication, and the trust anchor.** The public key is `packaging/keys/nerva-release.asc` in
this repository, next to `packaging/keys/fingerprints`; both change only by a pull request merged
to `main` here. Users fetch it from
`https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc`, and
INSTALL.md prints the fingerprint to compare. Neither the site nor the bucket holds a copy, so
neither a site merge nor the R2 token can change what a new user trusts.

**Rotation (every two years).** apt users hold the key in a file they wrote once, so a rotation
must reach them. The overlap does it for those who re-fetch the key; the rest are a cost.

1. The owner makes a new key with setup step 4, and adds it to `package-repos` as
   `REPO_SIGNING_KEY_NEXT` and `REPO_SIGNING_PASSPHRASE_NEXT`.
2. A pull request here adds it to `nerva-release.asc` and lists it as `next` in `fingerprints`.
   From the next write run, `InRelease` and `Release.gpg` carry **two signatures**, by `current`
   and by `next`. apt accepts a file when one signature verifies with a key in `Signed-By`, and
   ignores a signature whose key it lacks, as Debian's own archive does with its several keys, so
   both old and new key files work. dnf reads `gpgkey=`, which now holds both keys, and imports
   the new one when it first meets it. INSTALL.md and the CHANGELOG ask apt users to fetch the key
   file again. Slice 2 tests a dual-signed `InRelease` on hosts that hold only one of the two keys,
   with `gpgv` and with `sqv`.
3. At least six months later, the owner swaps the secrets (the new key becomes
   `REPO_SIGNING_KEY`), and a pull request makes the new key `current` and the old one `previous`.
   Do both on the same day: between them, `ready` and the refresh fail with NRV-E1139, which is
   expected. From then on, metadata and new rpms are signed with the new key only. The rpms signed
   earlier keep the old signatures, so the old key stays in the file as `previous`.
4. An apt user who never re-fetched the key now sees `NO_PUBKEY <new id>` and follows INSTALL.md
   again. Shipping the key inside a package (a `nerva-archive-keyring`, as Debian does), so that
   upgrades carry the next key, is the way to remove that cost. It changes the packages, so it is
   a decision for before the first rotation (2028), not part of v0.7.1.

**Compromise.** The owner publishes the revocation certificate, makes a new key and removes the
old one from `packaging/keys/`. Old rpms cannot be re-signed without replacing package objects,
which the locks forbid, so a compromise is a new decision, recorded then.

## Install instructions (what INSTALL.md gains)

Slice 5 writes this in INSTALL.md's Linux section, before the download-and-install text, which
stays as the path that needs no repository. The recorded output comes from the rehearsal, and is
marked "not run" until then. `<FINGERPRINT>` is the `current` line of `packaging/keys/fingerprints`.

**Debian 12 and 13, Ubuntu 22.04 and 24.04** (apt 2.4 or later reads an armored key file):

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc | sudo tee /etc/apt/keyrings/nerva.asc > /dev/null
gpg --show-keys /etc/apt/keyrings/nerva.asc     # the fingerprint must be <FINGERPRINT>
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

(`gpg` is not on a minimal Debian. In that case, compare the fingerprint on another machine, or
install `gnupg` first. `Architectures` keeps apt from asking for i386 on hosts with multiarch. To
pin Nerva, pin by Origin, `o=Nerva`: the Suite name `stable` is also Debian's.)

**Fedora, Rocky Linux and RHEL 9:**

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
sudo dnf install nerva      # dnf shows the key's fingerprint and asks: it must be <FINGERPRINT>
```

- **dnf 5 (Fedora 41 and later)** fetches the key from `gpgkey=` and asks once; answering yes
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
- **A new key** (every two years): fetch the key file again with the `curl` line above. The
  CHANGELOG says when.

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
  and refuses past 100 pages (NRV-E1143), an assert well above every bound above;
- `get <key> <file>` checks `x-amz-meta-sha256` when present;
- `put-new <key> <file>` sends `If-None-Match: *` (exit 0 written, 3 exists);
- `put <key> <file>` is allowed only on the names a run replaces;
- `probe-locked <key> <file>` sends an unconditional put of bytes the caller has just read from
  that key and checked (exit 0 when R2 refuses it, 4 when R2 accepts it).

Every put sends `x-amz-content-sha256` (a signed payload), `x-amz-meta-sha256`, `Content-Type` and
`Cache-Control` for the key's kind. It retries a 5xx or a broken connection three times with
backoff, and fails on any other 4xx than 412 (and than the lock's refusal in `probe-locked`) with
NRV-E1143. Its message names the operation, the key and the HTTP status, never a header or a
credential.

## Error codes (reserved here; slice 0 registers them)

The highest code on `origin/main` is NRV-E1138. This spec first took **NRV-E1139 to NRV-E1148**.
The second review and the move of the site to Cloudflare need four more, so it now takes
**NRV-E1139 to NRV-E1152** (E1149 to E1152 are free on `main`). Each is printed as
`error[NRV-E11xx]: <script or host>: <what>`, with a `cause` and a `fix` line, and exits 1, like
the other release codes.

| Code | Summary | Printed by | Blame |
|---|---|---|---|
| NRV-E1139 | The package-repos environment is incomplete (a secret, a variable, a pinned tool), its key is not the `current` pinned key, or `packaging/keys/` does not hold exactly the listed keys | `package_repos.sh ready`, `publish`, `refresh` | release maintainer |
| NRV-E1140 | The release's packages are missing, extra, or do not match `SHA256SUMS` | `package_repos.sh ready` | release maintainer |
| NRV-E1141 | A package of the same name is already listed with other content (published packages are never replaced) | `package_repos.sh ready`, `publish` | release maintainer |
| NRV-E1142 | The bucket does not match its manifest (an unlisted, missing or changed package, a candidate under `stable`, an index file that is neither `index` nor `index-was`), a manifest fails its signature, parsing or `generation` checks, or the bucket is over its bound | `package_repos.sh ready`, `publish`, `refresh`, `served` | the bucket token's holder (a crash of the job never causes it) |
| NRV-E1143 | The bucket refused or failed an operation, or a listing ran past 100 pages | `r2.py` | release maintainer / Cloudflare |
| NRV-E1144 | Signing failed, or a signed rpm differs from the release's file in NEVRA or payload | `package_repos.sh publish`, `refresh` | release maintainer |
| NRV-E1145 | `packages.nerva.pro` does not serve what is in the bucket | `package_repos.sh ready`, `served` | release maintainer / Cloudflare |
| NRV-E1146 | Installing from the repository failed on a supported distribution | `repo_install_check.sh` (`repos-verify`) | release maintainer |
| NRV-E1147 | The bucket's write lock was not acquired in time, was lost, or has run out of generations | `package_repos.sh publish`, `refresh` | release maintainer (another write run, or a dead one) |
| NRV-E1148 | A package is not what the approved run bound: its bytes differ from the draft's or the manifest's, nothing was bound for the tag, or `repos-ready` ran after the release was published | `package_repos.sh ready`, `publish`, `refresh` | release maintainer (or whoever changed a release asset) |
| NRV-E1149 | A bucket lock rule is missing: R2 accepted an overwrite under a locked prefix | `package_repos.sh publish`, `refresh` | the Cloudflare account's admin |
| NRV-E1150 | The repositories' signatures expire within 7 days, or this repository has had no commit for 45 days and GitHub will disable the refresh at 60 | `package_repos.sh refresh`, `ci.yml`'s `repos-fresh` | release maintainer |
| NRV-E1151 | `nerva.pro` does not show the release 15 minutes after the site's pull request merged | `release_finish.sh site-live` (`site-verify`) | release maintainer / Cloudflare |
| NRV-E1152 | The site's build refused a file that would run code or bind resources on Cloudflare (`functions/`, `_worker.js`, `_routes.json`, `wrangler.*`) | the `nerva-site` build command (Cloudflare), and the site's `site_check.mjs` | whoever added the file to the site repository |

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
  - **Environment variables:** none.
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

**4. The signing key.** On your Mac, with GnuPG (`brew install gnupg`, which brings pinentry), in a
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
slice 3 commits them to `packaging/keys/`.

**5. The bucket, its public host, its locks and its token.**

- In the dashboard, open **R2 Object Storage**. If R2 is not enabled on the account, enable it;
  Cloudflare asks for a payment method even for the free tier.
- **Create bucket:** name `nerva-packages`, location Automatic, storage class Standard.
- In the bucket's **Settings**, **Public access**: under **Custom Domains**, **Connect Domain**,
  enter `packages.nerva.pro`, and confirm the DNS record Cloudflare proposes. Leave the
  **R2.dev subdomain** disabled.
- In the bucket's **Settings**, **Bucket lock rules**, **Add rule**, five times, each with
  retention **Indefinite**:

  | Rule name | Prefix |
  |---|---|
  | `apt-pool` | `apt/pool/` |
  | `rpm-stable-packages` | `rpm/stable/packages/` |
  | `rpm-rc-packages` | `rpm/rc/packages/` |
  | `manifests` | `manifest/` |
  | `locks` | `lock/` |

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

Then, in step 4's terminal (GnuPG asks for the passphrase again for the export):

```bash
gpg --armor --export-secret-keys "$fpr" | gh secret set REPO_SIGNING_KEY --env package-repos --repo NervaLog/nerva
```

```bash
gh secret set REPO_SIGNING_PASSPHRASE --env package-repos --repo NervaLog/nerva
```

Now delete the files and the throwaway keyring:

```bash
rm -P "$HOME/nerva-release-secret.asc" "$HOME/nerva-release.rev" && gpgconf --kill all && rm -rf "$GNUPGHOME" && unset GNUPGHOME GPG_TTY
```

The fingerprint is not a variable: it is pinned in `packaging/keys/fingerprints`.

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

Read `~/site-ruleset.json`: it must differ from the live ruleset only in
`require_code_owner_review`. Then:

```bash
gh api -X PUT repos/NervaLog/nervalog.github.io/rulesets/27139365 --input "$HOME/site-ruleset.json" && rm "$HOME/site-ruleset.json"
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

Expect: a 200 from `nerva.pro`; a 404 from `nervalog.github.io`; a 404 from `packages.nerva.pro`
(served by R2: the bucket is empty); four secrets (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
`REPO_SIGNING_KEY`, `REPO_SIGNING_PASSPHRASE`) and three variables (`R2_ENDPOINT`, `R2_BUCKET`,
`PACKAGES_BASE_URL`); `false`, `true` and `branch_policy`; `false`; and `pages exit 1` (Pages is
off). Then tell the supervisor.

**Rotating the R2 token** (yearly, or if it may have leaked): create a new token as in step 5, set
both secrets again as in step 6, then delete the old token in the dashboard. A run in progress
fails with NRV-E1143 and is re-run.

**Least privilege, in summary:**

- **The R2 token** can write one bucket, and cannot remove its locks. It sits in one environment
  that only `main` can deploy and admins cannot bypass, and it reaches the `package_repos.sh`
  steps only. Nothing else in GitHub holds any Cloudflare credential.
- **The bucket's public host** is read-only by construction: R2 public access has no write path.
- **The signing key** sits in the same environment, reaches the same steps, and signs new package
  content only as bound by the approved run, while the release is a draft.
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
  line (it links to INSTALL.md); and that `functions/`, `_worker.js`, `_routes.json` and
  `wrangler.*` are refused (NRV-E1152).
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
- `repos` writes the pending manifest first, then two debs and two rpms (under `rpm/rc/` only),
  then the promoted manifest and both channels of both formats. `stable` is signed and empty,
  because no release has packages yet; that exercises the channel rule. The lock probe passes
  (no NRV-E1149). `served` is green.
- `repos-verify` is green in all ten cells, on amd64 and arm64: `nerva version` ends with
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
  `nerva-packages` and a `functions/x.js` gets a failed preview build with NRV-E1152 in its log,
  and the project's **Bindings** stay empty. The pull request is closed unmerged. (With previews
  off, this needs a merge; skip it and record it as not verified.)
- `https://nerva.pro/` answers 200, `https://www.nerva.pro/` answers 301 to it, and
  `https://nervalog.github.io/` answers 404.

**Afterwards:** the cleanup in automation.md stays as it is. The candidate stays in the `rc`
channel. Nothing is deleted from the bucket. The run link goes in the worklog note of the pull
request that records the result, and that pull request's author runs
`gh variable set REPOS_LIVE --repo NervaLog/nerva --body true`, which switches on `repos-fresh`.

**Not verified until the rehearsal** (slices 1 and 2 test the rest locally, with stand-ins, and in
containers):

- `r2.py` against real R2: SigV4 with region `auto`, `If-None-Match: *` answering 412, listing
  pages, and the `x-amz-meta-sha256`, `Content-Type` and `Cache-Control` round trip through the
  public host.
- R2's bucket locks: that an unconditional put under a locked prefix is refused, and with which
  HTTP status (`probe-locked` accepts any 4xx for now; slice 1 narrows it once the rehearsal
  records it); and that an "Object Read & Write" token cannot change lock rules.
- R2's custom-domain public access: `Range`, `ETag`, `If-None-Match`, and Cloudflare's cache
  honouring each object's `Cache-Control`.
- Cloudflare's security features against apt's and dnf's user agents, from GitHub's runners.
- The environment `package-repos`, its secrets, and the key's import with the passphrase file on
  the runner.
- That "Re-run failed jobs" keeps `repos-ready`'s `bound` output (GitHub keeps the outputs of jobs
  that are not re-run), and that a failed `publish` job's `public` output reaches `repos`.
- `ubuntu-24.04-arm` running the arm64 cells.
- Cloudflare Pages: that it reads `wrangler.toml` and `functions/` only for a deployment whose
  build passed, so the gate holds; and that it builds no pull request from a fork.

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
| 0 | Register NRV-E1139 to NRV-E1152 from the table above: entries with surface, blame, cause and fix, plus the intro paragraph of the 11xx section naming the scripts and the Cloudflare build that print them | `docs/ERRORS.md` | mechanical; supervisor checks the diff | first; small, merges before 1 and 2 |
| 1 | `r2.py` and its tests. The tests run a fake S3 server (`http.server`, in the test file) that also enforces lock prefixes, check the SigV4 signature against AWS's published test vectors, and cover `If-None-Match` and 412, listing across pages and the 100-page assert, `probe-locked` both ways, the replaceable-name refusal, the stored `Content-Type` and `Cache-Control`, retries, NRV-E1143's text, and that no credential appears in argv or any message. One line in `ci.yml`'s release-scripts step | `.github/scripts/r2.py`, `.github/scripts/test_r2.py`, `.github/workflows/ci.yml` (one line) | implementation; review | after 0 |
| 2 | `package_repos.sh` (`ready`, `publish`, `refresh`, `served`, `cleanup`) and `repo_install_check.sh`. Tests with real `gpg`, `gpgv`, `apt-ftparchive`, `createrepo_c` and `rpmsign`, throwaway keys and a throwaway `packaging/keys/` directory, a stand-in `gh`, and `r2.py` against slice 1's fake server. They cover every code from NRV-E1139 to NRV-E1150 but E1143 and E1146; the strict manifest parsing (appended and prepended text, two blocks, dash-escaping, a listed-key-file key that is not in `fingerprints`); a manifest copied to a higher generation; an index replaced, deleted, or copied across channels (healed, then NRV-E1142); `ready` on a release that reads published while `PUBLISHED` is false (NRV-E1148); a missing lock rule (NRV-E1149); the quiet-repository check (NRV-E1150); a kill after each step of `publish` (each row of the idempotence table), including between the manifest of step 7 and the upload; the lock's wait, takeover of a stale lock, and loss; a run with nothing bound; the bound; that `stable` holds no candidate; and a dual-signed `InRelease`. `tests/packaging/repos.py` serves the generated trees over local HTTP to the debian 12 and 13, ubuntu, rocky and fedora 43 containers in `packages.yml` through `repo_install_check.sh` (NRV-E1146 included, and dnf 5 without `rpm --import`), checks apt's refusal of a copied channel on a host that read `stable` before, checks a dual-signed `InRelease` with only one key on the host (gpgv and sqv), and checks that its commands equal this spec's install block (slice 5 switches the source to INSTALL.md). `ci.yml` installs the pinned tools for the scripts step | `.github/scripts/package_repos.sh`, `.github/scripts/repo_install_check.sh`, `.github/scripts/test_package_repos.py`, `tests/packaging/repos.py`, `.github/workflows/ci.yml` (the tools and one line), `.github/workflows/packages.yml` (one step) | implementation; review (security focus: secrets, argv, refusals, the binding, the manifest parser) | after 1 |
| 3 | `packaging/keys/nerva-release.asc` and `packaging/keys/fingerprints` (`current <fpr>`), from setup step 4 | `packaging/keys/*` | mechanical; supervisor checks the fingerprint against the owner's | after setup step 4; parallel with 1 and 2 |
| 4 | `release-finish.yml`: jobs `repos-ready` (with output `bound`), `repos` (gated on `public`), `repos-verify`, `site-verify`; `publish`'s `needs`, `if`, last step and output `public`; the header comment (which still says "the site's auto-merge"; P364 merges directly); images pinned by digest. `release_finish.sh site-live` and its test. `package-repos-refresh.yml`: the weekly schedule and dispatch. `ci.yml`'s `repos-fresh` job, behind `REPOS_LIVE`. Tried with a dispatch on a published candidate before review where possible: `repos-ready` then refuses NRV-E1139 cleanly while the environment is not set up | `.github/workflows/release-finish.yml`, `.github/workflows/package-repos-refresh.yml`, `.github/workflows/ci.yml` (one job), `.github/scripts/release_finish.sh` (`site-live`), `.github/scripts/test_release_finish.py` | implementation; review (security focus: environments, `needs`/`if`, outputs, `!cancelled()`, no concurrency group on `repos`) | after 2 |
| 5 | The fingerprint in INSTALL.md's new section (the dnf 5 notes, pinning by Origin, the signing sentence), CLAUDE.md (the site line, the release line, the environment fact), automation.md's hook section as a pointer here, the source of slice 2's install-block test switched from this spec to INSTALL.md (one line), and the worklog. In the site repository, one pull request: CLAUDE.md and README (Cloudflare Pages, "no key on the page", the refused names), `.github/CODEOWNERS` deleted, and `site_check.mjs` refusing `functions/`, `_worker.js`, `_routes.json` and `wrangler.*` (NRV-E1152) with its test | `docs/INSTALL.md`, `CLAUDE.md`, `docs/releases/automation.md`, `tests/packaging/repos.py` (one line); the site's `CLAUDE.md`, `README.md`, `.github/CODEOWNERS`, `site_check.mjs` and its test | mechanical, except the `site_check.mjs` change (implementation); supervisor checks | after 2 and 3, and after setup steps 2 and 8 |
| E | Setup steps 1 to 10 | Cloudflare, GitHub | owner | in order; step 4 before slice 3; step 7 only after step 3's check |
| F | The rehearsal, its run link recorded, and `REPOS_LIVE` set | worklog, a repository variable | supervisor | after 0 to 5 and E |

Slices 1 and 3 can run at once, and 0 with either. Slice 2 needs slice 1's fake server. Slice 4
needs slice 2's script interface. Slices 1, 2 and 4 each touch `ci.yml` and run in sequence.
Slice 5 changes no script in this repository and goes last.
