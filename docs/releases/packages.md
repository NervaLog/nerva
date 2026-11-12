# The domain, and the apt and dnf repositories: spec, setup, slices

Status: spec, 2026-11-12 (P365, which amends P360 point 10 and P148), reworked the same day after
its adversarial review. Nothing here is built yet. It is the last change before the v0.7.1 tag:
the owner moved the repositories from v0.7.2 to v0.7.1 on 2026-11-12, and named the domain,
`nerva.pro` (owner, 2026-11-12).

The freeze holds. Nothing here touches `src/` or `build.zig`. The change is workflows, scripts,
documents, two key files under `packaging/keys/`, a few lines in the site repository, and
Cloudflare and GitHub settings. No new dependency enters the Zig build.

## Goal

1. Nerva's site is served at `https://nerva.pro/`. It is still the one page `index.html` in
   `NervaLog/nervalog.github.io`, still served by GitHub Pages from that repository's `main`, and
   a merge to `main` is still a deploy. `https://nervalog.github.io/` sends visitors to the new
   address. The release pull request flow (the App, `site-check`, the ruleset, P364's merge)
   does not change.
2. `https://packages.nerva.pro/` serves signed apt and dnf repositories of every release from
   v0.7.1 on. A user installs with `apt install nerva` or `dnf install nerva`, and later upgrades
   with `apt upgrade` or `dnf upgrade`.
3. The release is still one approval: the owner approves `mac` in `apple-signing`, and
   everything after it, the repositories included, runs without anyone. Nothing is published by
   hand afterwards.
4. **Everything the packages' trust depends on lives in `NervaLog/nerva`,** under the same guard
   as the release workflows and the signing environments: the public key, the pinned
   fingerprints, the code that writes and checks the repositories. The site repository holds only
   static pages and can change none of it.

## Architecture

### The hosts

```
https://nerva.pro/                 index.html: GitHub Pages, from the site repository's main (custom domain)
https://www.nerva.pro/             GitHub Pages sends it to https://nerva.pro/
https://nervalog.github.io/        GitHub Pages sends it to https://nerva.pro/ (301, path kept)
https://packages.nerva.pro/        the R2 bucket nerva-packages, public, read-only (R2 custom domain)
https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc
                                   the repositories' public key: a file in Nerva's repository
```

`nerva.pro`'s DNS is a Cloudflare zone, because an R2 custom domain must be a hostname in a zone
of the bucket's account. The apex and `www` records point at GitHub Pages and are **DNS only**
(not proxied), so GitHub serves them and issues their certificate. `packages.nerva.pro` is the
bucket's custom domain: Cloudflare creates its record and serves it.

**Why the site stays on GitHub Pages** (the first draft moved it to Cloudflare Pages, with a Pages
Function serving the packages). A Pages project built from the site repository runs whatever
`functions/` or `_worker.js` that repository's `main` holds, and takes bindings from a
`wrangler.toml` in it (Cloudflare's Pages configuration docs), so one merge to the site could bind
any bucket of the account and write to it. There is no read-only R2 binding: a binding has
`put` and `delete` whatever the code does with it. Keeping the site on GitHub Pages leaves the
site repository no path to the Cloudflare account at all. The custom domain also gives the old
URL a real 301 for free, which the orphan redirect branch of the first draft could not.

### The bucket, served read-only by construction

The bucket's **public access through a custom domain** is the only reader. It serves GET and HEAD
of an object's exact key and nothing else: no listing, no writes, no code. Whoever holds no R2
token can change nothing in it, whatever they merge anywhere.

| | R2 custom domain, public (chosen) | A Worker deployed from Nerva (considered) |
|---|---|---|
| Write access in the serving path | none: public access is read-only | the Worker's binding has `put` and `delete`; its deploy token (Workers Scripts: Edit) covers every Worker of the account |
| Code in the request path | none | a Worker, its tests, and a deploy workflow with a Cloudflare API token |
| Headers | `Content-Type` and `Cache-Control` stored on each object by `r2.py put`, served as stored | set by code |
| `Range`, `If-None-Match`, `ETag` | served by R2 | by code, with R2's `range` and `onlyIf` |
| Request limit | none of Workers' kind; reads are R2 Class B operations, 10 M a month free, then $0.36 a million; cached reads are free | Workers' 100,000 a day free, then error 1027 until Workers Paid |
| What it cannot do | map one key to two paths, refuse a path by rule | — |

The two things a Worker could add are handled in the layout instead. Each dnf channel has its own
copy of its rpms (below), so no path is mapped. And what a channel may hold is enforced by the
job that writes it, which is checked on every run (step 3 of `repos`), not by the server.

The owner's answer to the Workers Paid question (owner, 2026-11-12: only if the free quota is
hit) stands, and with this design there is no Worker quota to hit.

The bucket is public, so `manifest/pool.asc` and `lock/` are readable by anyone. Both hold only
hashes, names, run ids and times, which the public releases and runs already show.

### The bucket's layout

```
nerva-packages/
  apt/pool/main/n/nerva/nerva_<filever>-1_<amd64|arm64>.deb                  immutable, the release's own file
  apt/dists/<stable|rc>/InRelease, Release, Release.gpg                      replaced by each write run (signed)
  apt/dists/<stable|rc>/main/binary-<amd64|arm64>/Packages, Packages.gz      replaced by each write run
  apt/dists/<stable|rc>/main/binary-<amd64|arm64>/by-hash/SHA256/<hex>       immutable (Acquire-By-Hash)
  rpm/<stable|rc>/packages/nerva-<filever>-1.<x86_64|aarch64>.rpm            immutable, signed copy of the release's file
  rpm/<stable|rc>/repodata/<hex>-<primary|filelists|other>.xml.gz            immutable (unique names)
  rpm/<stable|rc>/repodata/repomd.xml, repomd.xml.asc                        replaced by each write run (signed)
  manifest/pool.asc                                                          replaced by each write run (clearsigned)
  lock/<generation, ten digits>                                              immutable, the write lock (below)
```

`<filever>` is the version in the release's file names (`0.7.1`, or `0.7.1.rc.2` for a candidate,
P311). The version inside each package keeps `~` (`0.7.1~rc.2`), so a candidate sorts before its
release in both apt and dnf.

A release's rpm is stored twice, under `rpm/stable/packages/` and `rpm/rc/packages/`, as the same
signed bytes; a candidate's only under `rc`. That costs about 14 MB a release and keeps every dnf
path physical. The job refuses to write a candidate's name (one holding `.rc.`) under
`rpm/stable/`, and refuses a bucket that holds one there (NRV-E1142). apt's pool path carries no
channel, so for apt the channel is only what each channel's signed `Packages` lists.

The objects carry `Cache-Control: public, max-age=31536000, immutable` for immutable names and
`Cache-Control: no-cache` for the names a run replaces, and a `Content-Type` per kind
(`application/vnd.debian.binary-package`, `application/x-rpm`, `text/plain`, `application/gzip`,
`application/xml`, `application/pgp-signature`).

### The manifest

`manifest/pool.asc` is a clearsigned text file, the authority over what the bucket may hold:

```
nerva-packages manifest 1
<state> <sha256> <size> <key> <source-sha256> <tag> <commit>
...
```

One line per package object, sorted by key. `<state>` is `pending` or `published`. `<sha256>` and
`<size>` are the stored object's (for an rpm, the signed copy). `<source-sha256>` is the release
asset's, as the approved run read it from the draft. `<tag>` and `<commit>` are the release's tag
and the commit `publish-ready` checked.

**It is verified only against the pinned fingerprints.** `packaging/keys/fingerprints` in this
repository lists the fingerprints the job trusts, each with a role:

```
current <40 hex>
next <40 hex>        (only during a rotation)
previous <40 hex>    (only while rpms it signed are in the bucket)
```

`packaging/keys/nerva-release.asc` holds exactly those keys, armored. The job builds a keyring
from that file, verifies with `gpgv --status-fd`, and accepts a signature only when its
`VALIDSIG` primary-key fingerprint is one of the listed fingerprints. A key file that holds a key
the list does not name, or misses one it names, is NRV-E1139. Nothing the job reads from the
bucket, the site or the network is ever a source of trusted keys.

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
  packages are Nerva's own signed candidates, not foreign code, and the next write run (at most a
  week later, see "Valid-Until") writes `stable` back. Slice 2's container test performs the copy
  and asserts apt's refusal.

The cost: a candidate's packages stay in the bucket even after its GitHub release is deleted
(P343 7b). They are real builds of `main`'s code (P343). A later candidate takes the next number.
Publishing a used tag again with other files is refused (NRV-E1141).

### Failure modes, and what each does

- **R2 or `packages.nerva.pro` is down:** `apt update` and `dnf` fail on that host. The site is
  unaffected, and the GitHub release still carries every package, so INSTALL.md's
  download-and-install path keeps working.
- **Cloudflare's bot protections challenge apt or dnf:** a challenge page is HTML, so apt says
  "Clearsigned file isn't valid" and dnf says "repomd.xml parser error". The setup turns off Bot
  Fight Mode, and the rehearsal's install checks would show the problem.
- **A dnf client that reads during a run:** dnf fetches `repomd.xml` and then `repomd.xml.asc` in
  two requests. The job writes them back to back, last of all, but a client whose two requests fall
  on either side of that write gets a signature error once, and its next try succeeds. apt has no
  such window: it reads one signed `InRelease`, then fetches the indexes by hash.
- **The R2 token leaks.** Its holder can add, replace or delete any object. It cannot sign.
  - **A planted package** is not installed: apt and dnf refuse metadata not signed by the key, and
    dnf refuses an rpm not signed by it. The next write run refuses the bucket (NRV-E1142),
    because every package object must be in the manifest, and the manifest must be signed by a
    pinned fingerprint.
  - **Freeze and replay.** The holder can put back an older signed `InRelease` or `repomd.xml`
    with its signature, so users stay on an old version. apt refuses an `InRelease` past its
    `Valid-Until` (at most 21 days old, below). dnf has no signed expiry and accepts a replayed
    `repomd.xml` for as long as it is served. The next write run, at most a week later, writes
    fresh indexes over it.
  - **Channel swap:** as in "Channels" above. The next write run writes `stable` back.
  - **Deletion** is a denial of service; the next write run refuses with NRV-E1142 (a listed
    object is missing), and rebuilding is the owner's decision.
  - **The key file** is not in the bucket, so the token cannot change it.
- **The signing key leaks:** the one compromise that reaches users. See "Rotation and
  compromise".

### The old URL

The site repository's GitHub Pages settings get the custom domain `nerva.pro` (setup step 5).
GitHub then answers `https://nervalog.github.io/<path>` with a 301 to `https://nerva.pro/<path>`,
and the browser keeps the `#section`. The repository keeps its name, which the redirect needs.
The domain is verified for the `NervaLog` organisation first, so no other GitHub account can claim
`nerva.pro` if the setting is ever cleared.

### What someone who can merge to the site's `main` can do, afterwards

- **Can:** change the page, which is a deploy: deface it, or put misleading text on it. The page
  therefore carries no key, no fingerprint and no repository line of its own: it links to
  INSTALL.md in this repository for them (slice 5). They could also delete the `CNAME` file that
  GitHub Pages keeps in the branch, which drops the custom domain until the owner sets it again;
  the domain verification stops anyone else taking it meanwhile.
- **Cannot:** read or write the bucket (the site has no Cloudflare credential and no Cloudflare
  integration), change the key, the fingerprints or the scripts (all in this repository), get
  anything signed, or change what `packages.nerva.pro` serves.

That holds for every holder of a site merge: a session acting as `topwombat`, and the release
App, whose token can open and merge site pull requests.

## The release graph

`release-finish.yml` (P360, P362, P364) gains three jobs:

```
guard ── mac (apple-signing: THE ONE APPROVAL) ── mac-verify ─┬─ repos-ready (package-repos) ─┐
                                                               └───────────────────────────────┴─ publish (release-publish)
                                                                                                    ├─ verify        (brew; unchanged)
                                                                                                    └─ repos (package-repos)
                                                                                                         └─ repos-verify (no environment)
```

A new workflow, `package-repos-refresh.yml`, runs the same writer weekly without a tag (see
"Valid-Until").

- `publish` gains `repos-ready` in its `needs` and its `if`. Everything that can refuse without
  writing still runs before the draft is published (P362 point 8), so a setup mistake leaves a
  draft, not a published release with no packages.
- `verify` does not wait for `repos`, and `repos` does not wait for `verify`.
- A failure in `repos` or `repos-verify` happens after the release is public. Its fix is **"Re-run
  failed jobs" of the same run**, which keeps the digests `repos-ready` read from the draft (see
  "What the key signs, and who can make it sign").

### What the key signs, and who can make it sign

Release assets stay mutable after publishing, and `SHA256SUMS` is one of them, so a check against
it proves nothing after the fact. A dispatch for a published release skips `mac` (P362 point 10)
and needs no approval. The design therefore binds **new** package content to the approved run
itself:

1. **`repos-ready` reads the four packages from the draft,** in a run where `guard` found a draft
   and `mac` succeeded, so after the owner's approval and before `publish`. It checks them
   against the draft's `SHA256SUMS` (NRV-E1140) and sets the job output `bound`: the four file
   names, their SHA-256 and the commit `publish-ready` checked. Where `guard` found the release
   already published, `bound` is empty.
2. **`repos` signs and lists a package only if its bytes equal `bound`.** It downloads them from
   the now-public release, compares (NRV-E1148), and its first write is the manifest with those
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
| A new rpm, or a new manifest entry | only the run whose `mac` the owner approved, and re-runs of its failed jobs (anyone with write access can press the button) | `bound`, read from the draft after the approval, fixed for the run |
| An rpm again, for a `pending` entry whose object never landed | any write run | the entry's `<source-sha256>`, in a manifest signed by a pinned key |
| `InRelease`, `Release.gpg`, `repomd.xml.asc`, the manifest | any write run: a release run, a dispatch, a re-run, the weekly refresh | a deterministic function of the signed manifest, after the bucket is checked against it |

What the draft held when the approved run read it is what gets signed. Anyone who can change a
draft's assets before the approval can already change what the release ships (the Mac zip apart,
which `mac` signs). That is the existing risk of the release, and this spec does not widen it.
Anyone who can merge to `main` here can change the workflows and scripts, and with them all of
the above; that is the guard the release already relies on (automation.md, "Security notes"), and
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
  3. Install the pinned tools (see "Tools").
  4. `package_repos.sh ready "$TAG" "$PUBLISHED"`. The environment's secrets and variables reach
     this step only, through `env:`. It writes nothing. It refuses with a code:
     - an environment that lacks a secret or a variable, a key that does not import, a key whose
       fingerprint is not the `current` one in `packaging/keys/fingerprints`, or a key file that
       does not hold exactly the listed keys (NRV-E1139);
     - a draft without exactly its four packages, or a package that does not match `SHA256SUMS`
       (NRV-E1140);
     - a package name the manifest already lists with another `<source-sha256>` (NRV-E1141);
     - a manifest not signed by a pinned fingerprint, a package object the manifest does not list,
       a listed `published` object that is missing or differs, a candidate under `rpm/stable/`, or
       a bucket over its bound (NRV-E1142). `pending` entries of any tag are accepted: the next
       write run finishes them;
     - a bucket that cannot be listed or read with the token (NRV-E1143);
     - `https://packages.nerva.pro/manifest/pool.asc` that differs from the bucket's object, or a
       404 there while the bucket holds a manifest (NRV-E1145).
  5. Under `if: always()`: `package_repos.sh cleanup`. It runs `gpgconf --kill all` and removes
     the temporary `GNUPGHOME`.

### `repos`

- `needs: [guard, repos-ready, publish]`, `runs-on: ubuntu-24.04`, `timeout-minutes: 120`,
  `environment: package-repos`, `permissions: contents: read` (the release is public now).
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
  2. **The lock.** It lists `lock/` and reads the highest generation `g`. If there is none, or its
     body is `free <epoch>`, or it is `held <run>/<attempt> <epoch>` with that epoch more than 60
     minutes old (stale: no holder lives that long, see below), it puts `lock/<g+1>` with
     `held <run id>/<attempt> <now>`, write-if-absent. A 412 means another run won; it lists
     again. Otherwise it waits 30 seconds and tries again, for at most 70 minutes, then stops
     with NRV-E1147 (nothing was written; re-run). The holder gives itself 45 minutes from its
     acquisition; before each replaceable write it checks that `lock/<g+2>` does not exist (no one
     took the lock over), and stops with NRV-E1147 otherwise. At the end, and under `if: always()`
     in `cleanup`, it puts `lock/<g+2>` with `free <now>`, write-if-absent. This needs only the
     write-if-absent put; the job never deletes a lock object. Lock objects are about 60 bytes,
     two a run; past 20,000 generations the job refuses (NRV-E1147) and the owner decides on
     pruning.
  3. **Check the bucket.** It reads `manifest/pool.asc` and verifies it against the pinned
     fingerprints. It lists `apt/pool/` and `rpm/*/packages/` and checks every rule `ready` checks
     (NRV-E1142), downloading each `published` object and comparing its SHA-256 with the
     manifest's. With no manifest and no package object, it starts from an empty manifest. Package
     objects but no manifest is NRV-E1142.
     - **Bound:** at most 2,000 package objects and 8 GiB. Above that the job refuses
       (NRV-E1142), and a decision is needed: a pruning policy, or indexes built from the manifest
       instead of the files. At about 38 MB a release (the rpms twice), that is about 200 releases
       away.
  4. **Bind.** If the tag has no entries yet: with `BOUND` empty, it stops (NRV-E1148). Otherwise
     it downloads the four packages from the published release and compares each with `BOUND`
     (NRV-E1148). It signs each rpm (see "Signing"), checks that the signed copy has the release
     file's NEVRA and payload digest (NRV-E1144), and writes the manifest with the new entries as
     `pending`: each deb once, each rpm under `rpm/rc/packages/`, and for a release also under
     `rpm/stable/packages/`. **This manifest is the run's first write to the bucket,** so every
     package object the job ever writes is listed in a signed manifest before it exists. If the
     tag has entries already (a re-run), their `<source-sha256>` must equal `BOUND` where `BOUND`
     is set (NRV-E1141), and nothing is re-bound.
  5. **Put.** For every `pending` entry, of any tag:
     - the object exists with the entry's SHA-256: nothing to do (an earlier run put it);
     - it exists with other content: NRV-E1142;
     - it is absent, and it is a deb: download it from the entry's release, check its SHA-256
       against `<source-sha256>` (NRV-E1148), put it write-if-absent;
     - it is absent, and it is an rpm: if another copy of the same file (the other channel) exists
       with the entry's SHA-256, put those bytes. Otherwise this run's signed copy from step 4 if
       it has one; otherwise download the release's rpm, check `<source-sha256>` (NRV-E1148), and
       sign it again. A new signature differs, so the run **first** rewrites the entry's
       `<sha256>` and `<size>` in the manifest (signed), **then** puts the object
       write-if-absent.
  6. **Promote.** It writes the manifest with every entry whose objects are all present as
     `published`.
  7. **Indexes.** It regenerates both channels of both formats from the `published` entries:
     `stable` from the releases, `rc` from everything.
     - **apt:** for each channel it makes a staging tree of hard links to that channel's debs and
       runs `apt-ftparchive -a <arch> packages pool/main/n/nerva` for `amd64` and `arm64`, writing
       `Packages` and `Packages.gz`. With only those files under `dists/<channel>/`, it runs
       `apt-ftparchive release` with the channel's Origin, Label, Suite and Codename (above),
       Architectures `amd64 arm64`, Components `main`, `Acquire-By-Hash: yes`, and `Valid-Until`
       21 days after `Date`. Only then does it make the `by-hash/SHA256/<hex>` copies and sign
       `InRelease` (clearsign) and `Release.gpg` (detached), so `Release` never lists `by-hash/`
       or an old signature.
     - **dnf:** for each channel it makes a staging tree whose `packages/` holds that channel's
       rpms, then runs `createrepo_c --general-compress-type=gz --checksum=sha256 --no-database
       --revision <now, epoch seconds>`, which gives unique names for everything but
       `repomd.xml`, and signs `repomd.xml.asc` (detached, armored).
  8. **Upload the indexes.** First every immutable name (`by-hash/...`, the hashed `repodata`
     files), each write-if-absent. Then the names a run replaces: apt's `Packages`, `Packages.gz`,
     `Release` and `Release.gpg` for each channel, with `InRelease` last; then for each channel
     `repomd.xml.asc` and `repomd.xml`, back to back, last of all. `r2.py put` refuses to replace
     any name outside the replaceable set (the `no-cache` names and `manifest/pool.asc`), so a bug
     cannot overwrite a package.
  9. **Unlock** (step 2).
- `package_repos.sh served "$TAG"` (no secrets) fetches over `https://packages.nerva.pro`: each
  channel's `InRelease` and `repomd.xml`, and `manifest/pool.asc`, must equal the bytes just
  uploaded, and the tag's packages must be served with their SHA-256 (NRV-E1145).
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
| step 5 or 6 | all objects, entries pending or published | promotes, then indexes |
| part of step 8 | new immutable index files, some old replaceable names | rewrites every replaceable name |

A second run of a finished release writes no package object; it writes the manifest and the
indexes again, with the same content but new dates and signatures. The job never replaces or
deletes a package object or a lock object.

### `Valid-Until`, and the weekly refresh

apt's `Release` carries `Valid-Until`, 21 days after `Date`, so a replayed `InRelease` stops
working at most 21 days after it was signed. Something must therefore re-sign within 21 days even
when no release happens: `package-repos-refresh.yml` runs `package_repos.sh refresh` every Monday
at 05:17 UTC (and by `workflow_dispatch`), from `main`, in `package-repos`, under
`concurrency: { group: package-repos-refresh, cancel-in-progress: false }` (a newer pending refresh
replacing an older one loses nothing). `refresh` is `publish` without step 4: it takes the lock,
checks the bucket, finishes `pending` entries, promotes, and re-signs both channels. Every release
run does the same. Two refreshes can fail in a row before users see "Release file … is expired";
a failed scheduled run e-mails the owner, and its fix is a re-run. dnf has no signed expiry: the
cost stays as P365 lists it.

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
- Each cell runs `.github/scripts/repo_install_check.sh <apt|dnf> <channel> <base-url>
  <fingerprint> <version>` in the container, with the channel the tag belongs to: `rc` for a
  candidate, `stable` for a release. The script runs **INSTALL.md's own commands** (the same text,
  kept in step by slice 2's test). It fetches the key and checks its fingerprint. For apt it
  writes the `.sources` file and runs `apt-get update` and `apt-get install -y nerva=<package
  version>`. For dnf it writes the `.repo` file with `gpgcheck=1` and `repo_gpgcheck=1`, runs
  `rpm --import` after the fingerprint check, then `dnf install -y nerva-<package version>`. Then
  `nerva version`'s last line must be `version <V>`.
- **A candidate also checks `stable`:** with `stable` configured, `apt-cache policy nerva` and
  `dnf list --showduplicates nerva` must not list the candidate.
- A failure is NRV-E1146. The release is already public, so the message says that, and that the
  GitHub release's files still install by hand (INSTALL.md).

### Recovery

| What stopped | Do |
|---|---|
| `repos-ready` refused | Fix the setup it names, then "Re-run failed jobs". Nothing was published or written |
| `repos` stopped part way, or failed with NRV-E1143 or NRV-E1147 | "Re-run failed jobs" of the **same** run. It converges (the table above). A dispatch or the weekly refresh also finishes whatever the manifest already lists |
| `repos` refused NRV-E1148 for a release whose run never wrote its entries | The bytes on the release differ from what the approved run read, or nothing was bound (a dispatch, or "Re-run all jobs"). Stop: the owner decides (a new patch release, normally). The release's files still install by hand |
| `repos` refused NRV-E1141 or NRV-E1142 | Stop. The bucket holds something no signed manifest lists, a listed object is missing or changed, or a published name has other content. A crash of this pipeline never causes these (every object is listed before it is written), so suspect the R2 token: the owner rotates it and decides |
| `repos-verify` failed | Read which image failed. If it is the environment (a mirror is down), re-run. Otherwise it is a finding: file it |
| The weekly refresh failed | Re-run it. apt users have at least a week before `Valid-Until` |

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
| apt `InRelease`, `Release.gpg` | `gpg --clearsign`, `gpg --detach-sign --armor` of `Release` |
| dnf `repomd.xml.asc` | `gpg --detach-sign --armor repomd.xml` |
| each rpm | `rpmsign --addsign`, with `--define "_gpg_name <fingerprint>"`, `--define "_gpg_path $GNUPGHOME"` and `--define "_gpg_sign_cmd_extra_args --pinentry-mode loopback --passphrase-file $GNUPGHOME/passphrase"`. The path to the passphrase file is in the argv; the passphrase is not |
| `manifest/pool.asc` | `gpg --clearsign` |

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

**Rotation (every two years).**

1. The owner makes a new key with setup step 2.
2. A pull request here adds it to `nerva-release.asc` and lists it as `next` in `fingerprints`.
   INSTALL.md and the CHANGELOG say so. The job now accepts manifests signed by either.
3. One release later, the owner replaces `REPO_SIGNING_KEY` and `REPO_SIGNING_PASSPHRASE`, and a
   pull request makes the new key `current` and the old one `previous`. From then on, metadata
   and new rpms are signed with the new key. The rpms signed earlier keep the old signatures, so
   the old key stays in the file while they are in the bucket. A user who never refreshed the key
   file sees `NO_PUBKEY <new id>` and follows INSTALL.md again.

**Compromise.** The owner publishes the revocation certificate, makes a new key and removes the
old one from `packaging/keys/`. Old rpms cannot be re-signed without replacing package objects,
which this spec forbids, so a compromise is a new decision, recorded then.

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
install `gnupg` first. `Architectures` keeps apt from asking for i386 on hosts with multiarch.)

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

- **Upgrades:** `sudo apt update && sudo apt upgrade`, or `sudo dnf upgrade nerva`. A package
  upgrade replaces the binary and never restarts a replica (P295b). Restart them as OPERATING.md
  says.
- **Candidates:** use `Suites: rc`, or `baseurl=https://packages.nerva.pro/rpm/rc`. That channel
  also has every release.
- **Switching from a downloaded package:** add the repository. The package installed from the file
  is the same package, and the next upgrade comes from the repository.

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
the names a run replaces. Every put sends `x-amz-content-sha256` (a signed payload),
`x-amz-meta-sha256`, `Content-Type` and `Cache-Control` for the key's kind. It retries a 5xx or a
broken connection three times with backoff, and fails on any 4xx but 412 with NRV-E1143. Its
message names the operation, the key and the HTTP status, never a header or a credential.

## Error codes (reserved here; slice 0 registers them)

The highest code on `origin/main` is NRV-E1138 (#363 and #364 merged and added none above it).
This spec takes **NRV-E1139 to NRV-E1148**. Each is printed as
`error[NRV-E11xx]: <script or host>: <what>`, with a `cause` and a `fix` line, and exits 1, like
the other release codes.

| Code | Summary | Printed by | Blame |
|---|---|---|---|
| NRV-E1139 | The package-repos environment is incomplete, its key is not the `current` pinned key, or `packaging/keys/` does not hold exactly the listed keys | `package_repos.sh ready`, `publish`, `refresh` | release maintainer |
| NRV-E1140 | The release's packages are missing, extra, or do not match `SHA256SUMS` | `package_repos.sh ready` | release maintainer |
| NRV-E1141 | A package of the same name is already listed with other content (published packages are never replaced) | `package_repos.sh ready`, `publish` | release maintainer |
| NRV-E1142 | The bucket does not match its manifest (unlisted, missing or changed object, a candidate under `stable`), the manifest is not signed by a pinned key, or the bucket is over its bound | `package_repos.sh ready`, `publish`, `refresh` | the bucket token's holder (a crash of the job never causes it) |
| NRV-E1143 | The bucket refused or failed an operation | `r2.py` | release maintainer / Cloudflare |
| NRV-E1144 | Signing failed, or a signed rpm differs from the release's file in NEVRA or payload | `package_repos.sh publish`, `refresh` | release maintainer |
| NRV-E1145 | `packages.nerva.pro` does not serve what is in the bucket | `package_repos.sh ready`, `served` | release maintainer / Cloudflare |
| NRV-E1146 | Installing from the repository failed on a supported distribution | `repo_install_check.sh` (`repos-verify`) | release maintainer |
| NRV-E1147 | The bucket's write lock was not acquired in time, was lost, or has run out of generations | `package_repos.sh publish`, `refresh` | release maintainer (another write run, or a dead one) |
| NRV-E1148 | A package is not what the approved run bound: its bytes differ from the draft's or the manifest's, or nothing was bound for the tag | `package_repos.sh publish`, `refresh` | release maintainer (or whoever changed a release asset) |

## Setup (owner, once)

Each command works in zsh and in bash. Secrets go in through `gh`'s own prompt or standard input,
never on the command line. Run these on your Mac, signed in to `gh` as `topwombat`. The session
proxy cannot reach these settings.

**1. `nerva.pro` on Cloudflare.** In the Cloudflare dashboard: **Add a domain**, enter `nerva.pro`,
take the Free plan, and set the registrar's nameservers to the two Cloudflare names it shows (or
transfer the domain to Cloudflare Registrar). Wait until the zone says **Active**. Then, in the
zone:

- **DNS**, add these records, each with **Proxy status: DNS only** (grey cloud), so that GitHub
  serves the site:
  - `A` `nerva.pro` to `185.199.108.153`, `185.199.109.153`, `185.199.110.153` and
    `185.199.111.153` (four records);
  - `AAAA` `nerva.pro` to `2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153` and
    `2606:50c0:8003::153`;
  - `CNAME` `www` to `nervalog.github.io`.
- **Security:** Bots, turn **Bot Fight Mode off**. It challenges apt and dnf on the proxied
  `packages` host, and they cannot answer a challenge.
- **SSL/TLS:** Edge Certificates, set **Minimum TLS Version** to 1.2.

**2. The signing key.** On your Mac, with GnuPG (`brew install gnupg`, which brings pinentry), in a
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

Run step 4's two environment commands before the next two, so the environment exists with its
branch rule. GnuPG asks for the passphrase again for the export.

```bash
gpg --armor --export-secret-keys "$fpr" | gh secret set REPO_SIGNING_KEY --env package-repos --repo NervaLog/nerva
```

```bash
gh secret set REPO_SIGNING_PASSPHRASE --env package-repos --repo NervaLog/nerva
```

Then save the key, its passphrase and its revocation certificate in the password manager, as
files, not through the clipboard (Universal Clipboard would copy them to your other devices):

```bash
gpg --armor --export-secret-keys "$fpr" > "$HOME/nerva-release-secret.asc" && cp "$GNUPGHOME/openpgp-revocs.d/$fpr.rev" "$HOME/nerva-release.rev"
```

Attach `~/nerva-release-secret.asc` and `~/nerva-release.rev` to one password manager item, then
delete them and the throwaway keyring:

```bash
rm -P "$HOME/nerva-release-secret.asc" "$HOME/nerva-release.rev" && gpgconf --kill all && rm -rf "$GNUPGHOME" && unset GNUPGHOME GPG_TTY
```

Give the supervisor `~/nerva-release.asc` and the fingerprint (`echo "$fpr"`). Both are public;
slice 3 commits them to `packaging/keys/`.

**3. The bucket, its public host and its token.**

- In the dashboard, open **R2 Object Storage**. If R2 is not enabled on the account, enable it;
  Cloudflare asks for a payment method even for the free tier.
- **Create bucket:** name `nerva-packages`, location Automatic, storage class Standard.
- In the bucket's **Settings**, **Public access**: under **Custom Domains**, **Connect Domain**,
  enter `packages.nerva.pro`, and confirm the DNS record Cloudflare proposes. Leave the
  **R2.dev subdomain** disabled.
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
gh variable set PACKAGES_BASE_URL --env package-repos --repo NervaLog/nerva --body 'https://packages.nerva.pro'
```

Then run step 2's two `gh secret set` commands for the key. The fingerprint is not a variable: it
is pinned in `packaging/keys/fingerprints`.

**5. The site: its domain, its ruleset, its CODEOWNERS.**

- **Verify the domain for the organisation:** GitHub, **NervaLog** organisation **Settings**,
  **Pages**, **Add a domain**, `nerva.pro`. Add the `TXT` record it shows in the Cloudflare zone,
  then **Verify**.
- **Set the custom domain**, then, once GitHub has issued the certificate (a few minutes; the
  second command fails until then, so repeat it), enforce HTTPS:

```bash
gh api -X PUT repos/NervaLog/nervalog.github.io/pages -f cname=nerva.pro
```

```bash
gh api -X PUT repos/NervaLog/nervalog.github.io/pages -F https_enforced=true
```

- **The ruleset.** The site holds nothing the packages depend on, so it needs no code owner. A
  code-owner rule could not be met anyway: the App cannot approve its own release pull request,
  `topwombat` cannot approve its own, and the ruleset has no bypass. Today's CODEOWNERS (the bare
  line `topwombat`) owns nothing, so `require_code_owner_review` has never applied. Set the rule
  to what is enforced, keeping everything else as it is live (`site-check` from GitHub Actions
  required, no approvals, no bypass, no deletion, no force push):

```bash
printf '%s' '{"name":"main","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"do_not_enforce_on_create":false,"required_status_checks":[{"context":"site-check","integration_id":15368}]}},{"type":"pull_request","parameters":{"required_approving_review_count":0,"dismiss_stale_reviews_on_push":true,"require_code_owner_review":false,"require_last_push_approval":false,"required_review_thread_resolution":false,"allowed_merge_methods":["merge","squash","rebase"]}}]}' | gh api -X PUT repos/NervaLog/nervalog.github.io/rulesets/27139365 --input -
```

- **CODEOWNERS** is deleted by slice 5's site pull request, which merges on `site-check` alone,
  as every site pull request does.

**6. Homepages.**

```bash
gh repo edit NervaLog/nervalog.github.io --homepage 'https://nerva.pro/' && gh repo edit NervaLog/nerva --homepage 'https://nerva.pro/'
```

**7. Check it.**

```bash
curl -sI 'https://nerva.pro/' | head -n1 && curl -sI 'https://nervalog.github.io/' | grep -i -e '^HTTP' -e '^location'
```

```bash
curl -sI 'https://packages.nerva.pro/nothing' | head -n1
```

```bash
gh secret list --env package-repos --repo NervaLog/nerva && gh variable list --env package-repos --repo NervaLog/nerva
```

```bash
gh api repos/NervaLog/nerva/environments --jq '.environments[] | [.name, (.protection_rules | map(.type) | join(","))] | @tsv'
```

```bash
gh api repos/NervaLog/nervalog.github.io/rulesets/27139365 --jq '.rules[] | select(.type == "pull_request") | .parameters.require_code_owner_review'
```

Expect a 200 from `nerva.pro`; a 301 from `nervalog.github.io` to `https://nerva.pro/`; a 404 from
`packages.nerva.pro` (served by R2: the bucket is empty); four secrets (`R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY`, `REPO_SIGNING_KEY`, `REPO_SIGNING_PASSPHRASE`) and three variables
(`R2_ENDPOINT`, `R2_BUCKET`, `PACKAGES_BASE_URL`); `package-repos` with `branch_policy` only; and
`false`. Then tell the supervisor.

**Rotating the R2 token** (yearly, or if it may have leaked): create a new token as in step 3, set
both secrets again as in step 4, then delete the old token in the dashboard. A run in progress
fails with NRV-E1143 and is re-run.

**Least privilege, in summary:**

- **The R2 token** can write one bucket. It sits in one environment that only `main` can deploy,
  and it reaches the `package_repos.sh` steps only. Nothing else in GitHub or the site holds any
  Cloudflare credential.
- **The bucket's public host** is read-only by construction: R2 public access has no write path.
- **The signing key** sits in the same environment, reaches the same steps, and signs new package
  content only as bound by the approved run.
- **The trust anchor** (the public key and the pinned fingerprints) is in this repository.
- **The site repository and the release App** hold nothing the packages depend on.
- `package-repos` has no reviewer, as `release-publish` has none, so the release is still one
  approval. The same accepted risk applies (automation.md, "Security notes"): any workflow merged
  to `main` can name the environment, and merging is the guard.

## What changes elsewhere

- **P148:** the site is still GitHub Pages from the site repository's `main`, now at
  `https://nerva.pro/`; `https://nervalog.github.io/` redirects there. The decision file says
  this. P148 itself is not edited.
- **P360 point 10:** the repositories come in v0.7.1, not v0.7.2, as three jobs (not one) plus a
  weekly refresh, in the environment `package-repos`. `verify` does not wait for them, and
  `publish` waits for `repos-ready`.
- **Nerva's CLAUDE.md:**
  - "README and site status": "served by GitHub Pages from that repository's `main` at
    <https://nervalog.github.io/>" becomes "served by GitHub Pages from that repository's `main`
    at <https://nerva.pro/> (P365); <https://nervalog.github.io/> redirects there".
  - The release paragraph adds that the release also publishes the apt and dnf repositories.
  - "Environment facts" notes that the session proxy cannot reach Cloudflare.
- **The site's CLAUDE.md and README:** the served-by line, as in Nerva's CLAUDE.md, and that the
  page carries no key, fingerprint or repository line: it links to INSTALL.md.
- **Nerva's README** has no link to the site; nothing changes there.
- **docs/releases/automation.md**, the section "`apt` and `dnf` repositories (v0.7.2): the hook",
  becomes a pointer to this document (slice 5). The rest of it stands.
- **The site's `NEXT`:** the v0.7.2 line "apt and dnf repositories with signed packages" moves to
  v0.7.1 in the supervisor's status pull request, and is marked delivered only after
  `repos-verify` is green on the v0.7.1 run.
- **CHANGELOG.md's v0.7.1 section** gains the repositories, with the install lines, in the
  `VERSION` pull request.

## The rehearsal

The owner's decision (owner, 2026-11-12): v0.7.1's other gates wait for this rehearsal to pass.

Prerequisites: setup steps 1 to 7 are done, and slices 0 to 4 have merged.

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
  because no release has packages yet; that exercises the channel rule. `served` is green.
- `repos-verify` is green in all ten cells, on amd64 and arm64: `nerva version` ends with
  `version 0.7.1-rc.N`, and `stable` offers no candidate.
- **"Re-run failed jobs"** is not forced, but **a dispatch** of the same tag (no approval) writes
  no package object, stops nowhere, and re-signs the indexes; it is green. It shows that a run
  with nothing bound finishes without adding.
- **The refresh:** one `workflow_dispatch` of `package-repos-refresh.yml` is green, and
  `InRelease`'s `Valid-Until` moves.
- `https://nerva.pro/` answers 200, and `https://nervalog.github.io/` answers 301 to it.

**Afterwards:** the cleanup in automation.md stays as it is. The candidate stays in the `rc`
channel. Nothing is deleted from the bucket. The run link goes in the worklog note of the pull
request that records the result.

**Not verified until the rehearsal** (slices 1 and 2 test the rest locally, with stand-ins, and in
containers):

- `r2.py` against real R2: SigV4 with region `auto`, `If-None-Match: *` answering 412, and the
  `x-amz-meta-sha256`, `Content-Type` and `Cache-Control` round trip through the public host.
- R2's custom-domain public access: `Range`, `ETag`, `If-None-Match`, and Cloudflare's cache
  honouring each object's `Cache-Control`.
- Cloudflare's security features against apt's and dnf's user agents, from GitHub's runners.
- The environment `package-repos`, its secrets, and the key's import with the passphrase file on
  the runner.
- That "Re-run failed jobs" keeps `repos-ready`'s `bound` output (GitHub keeps the outputs of jobs
  that are not re-run). If it does not, the re-run stops with NRV-E1148 unless step 4 already
  wrote the entries, and the recovery row for NRV-E1148 applies.
- `ubuntu-24.04-arm` running the arm64 cells.
- The custom domain's redirect of `nervalog.github.io`.

**Not verified until v0.7.1** (the same code with another filter): the first release package in
`stable`, its rpm under `rpm/stable/`, and `repos-verify` installing from `stable`.

The fallback is the same as for the tap and the site in automation.md: the release is already
public, its files install by hand, and a re-run finishes the repositories.

## Slices

Concurrent slices touch different files (P250). Each gets a fresh agent and is reviewed
adversarially by a fresh reviewer, who posts the findings on its pull request. Tiers as in
CLAUDE.md (P148b).

| Slice | What | Files | Tier | Order |
|---|---|---|---|---|
| 0 | Register NRV-E1139 to NRV-E1148 from the table above: entries with surface, blame, cause and fix, plus the intro paragraph of the 11xx section naming the scripts that print them | `docs/ERRORS.md` | mechanical; supervisor checks the diff | first; small, merges before 1 and 2 |
| 1 | `r2.py` and its tests. The tests run a fake S3 server (`http.server`, in the test file), check the SigV4 signature against AWS's published test vectors, and cover `If-None-Match` and 412, the replaceable-name refusal, the stored `Content-Type` and `Cache-Control`, retries, NRV-E1143's text, and that no credential appears in argv or any message. One line in `ci.yml`'s release-scripts step | `.github/scripts/r2.py`, `.github/scripts/test_r2.py`, `.github/workflows/ci.yml` (one line) | implementation; review | after 0 |
| 2 | `package_repos.sh` (`ready`, `publish`, `refresh`, `served`, `cleanup`) and `repo_install_check.sh`. Tests with real `gpg`, `apt-ftparchive`, `createrepo_c` and `rpmsign`, throwaway keys and a throwaway `packaging/keys/` directory, a stand-in `gh`, and `r2.py` against slice 1's fake server. They cover every code from NRV-E1139 to NRV-E1148 but E1143 and E1146; a manifest signed by a key in the key file but not in `fingerprints` (refused); a kill after each step of `publish` (each row of the idempotence table), including between the put of a package and the promoted manifest; the lock's wait, takeover of a stale lock, and loss; a run with nothing bound; the bound; and that `stable` holds no candidate. `tests/packaging/repos.py` serves the generated trees over local HTTP to the debian 12 and 13, ubuntu, rocky and fedora 43 containers in `packages.yml` through `repo_install_check.sh` (NRV-E1146 included), checks apt's refusal of a copied channel on a host that read `stable` before, and checks that its commands equal this spec's install block (slice 5 switches the source to INSTALL.md). `ci.yml` installs the pinned tools for the scripts step | `.github/scripts/package_repos.sh`, `.github/scripts/repo_install_check.sh`, `.github/scripts/test_package_repos.py`, `tests/packaging/repos.py`, `.github/workflows/ci.yml` (the tools and one line), `.github/workflows/packages.yml` (one step) | implementation; review (security focus: secrets, argv, refusals, the binding) | after 1 |
| 3 | `packaging/keys/nerva-release.asc` and `packaging/keys/fingerprints` (`current <fpr>`), from setup step 2 | `packaging/keys/*` | mechanical; supervisor checks the fingerprint against the owner's | after setup step 2; parallel with 1 and 2 |
| 4 | `release-finish.yml`: jobs `repos-ready` (with output `bound`), `repos`, `repos-verify`; `publish`'s `needs` and `if`; the header comment (which still says "the site's auto-merge"; P364 merges directly); images pinned by digest. `package-repos-refresh.yml`: the weekly schedule and dispatch. Tried with a dispatch on a published candidate before review where possible: `repos-ready` then refuses NRV-E1139 cleanly while the environment is not set up | `.github/workflows/release-finish.yml`, `.github/workflows/package-repos-refresh.yml` | implementation; review (security focus: environments, `needs`/`if`, outputs, no concurrency group on `repos`) | after 2 |
| 5 | The fingerprint in INSTALL.md's new section (and the signing sentence), CLAUDE.md (the site line, the release line, the environment fact), automation.md's hook section as a pointer here, the source of slice 2's install-block test switched from this spec to INSTALL.md (one line), and the worklog. In the site repository, one pull request: CLAUDE.md and README's served-by line and "no key on the page", `.github/CODEOWNERS` deleted | `docs/INSTALL.md`, `CLAUDE.md`, `docs/releases/automation.md`, `tests/packaging/repos.py` (one line); the site's `CLAUDE.md`, `README.md`, `.github/CODEOWNERS` | mechanical; supervisor checks | after 2 and 3, and after setup step 5 (the ruleset) |
| E | Setup steps 1 to 7 | Cloudflare, GitHub | owner | step 2 before 3; step 5 before slice 5's site pull request |
| F | The rehearsal, and its run link recorded | worklog | supervisor | after 0 to 5 and E |

Slices 1 and 3 can run at once, and 0 with either. Slice 2 needs slice 1's fake server. Slice 4
needs slice 2's script interface. Slice 5 changes no script and goes last.
