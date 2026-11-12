---
id: P376
date: 2026-11-12
area: Releases
amends: P365, P368
---

# Package signing: an offline primary with a CI subkey, tested first; pinned checks, verification before upload, served bytes, alarms and WKD

**Order.** #368, which carries P368 and slice 2's `package_repos.sh`, has merged. The
amendment of P368 is to slice 2's `verify_manifest` (the `$NF` check) and its signing setup,
and slice 2b makes it.

**The owner's decisions (owner, 2026-11-12, on the Zigbox team's review of the pipeline).** The
key model is "test, then subkey". Every signature is checked against the pinned primary. The run
verifies its output before uploading it, and checks that the served bytes equal the bytes it
signed. A failed refresh raises an issue. The primary key is published through WKD on
`nerva.pro` as a second channel. `docs/releases/packages.md` gives the full design. P376c (the
Intel Mac runner) is a separate decision. The review's point on recording the release gates is
left to slice G, after v0.7.1, which proposes its own decision in its own pull request.

**Decision.**

1. **The key model (amends P365 point 12), adopted only if slice K passes.**
   - **Primary.** An RSA 4096 primary key, certify-only, with no expiry. It is kept offline, on
     two encrypted media held apart, with its revocation certificate, which never stays on the
     ceremony's Mac. Its passphrase is in the owner's password manager. `packaging/keys/fingerprints` pins the primary's fingerprint, and
     that pin never changes.
   - **CI subkey.** CI holds one RSA 4096 signing subkey, or two during a rotation's overlap
     (`current` and `next`), never the primary. A subkey expires one year after it is made. The secret export holds the subkey and a stub of the primary
     (`--export-secret-subkeys <fpr>!`). It is re-protected with a CI passphrase of its own.
   - **Rotation, once a year.** At least 120 days before the subkey expires, the owner certifies
     the next subkey offline. The pull request that adds it lists it as `next` and replaces the
     key file. From the next write run, `InRelease` and `Release.gpg` carry two signatures.
     14 days before expiry, the owner swaps the secrets, `next` becomes `current`, and the old
     subkey becomes `retired`. NRV-E1160 is the alarm: a write run, or `repos-fresh`, ends red
     after it has re-signed when fewer than 120 days remain and no `next` is listed, or when
     fewer than 30 days remain and the swap has not happened.
   - **What users do.** Users never compare a fingerprint again. Each apt host does need the new
     key file once a year, because `gpgv` and `sqv` verify only against the subkeys in the file
     that `Signed-By` names. To get it without a keyring package, the user runs INSTALL.md's
     `curl` line again, and the CHANGELOG announces it in the overlap. Whether to ship a keyring
     package after v0.7.1 is the owner's question, and it must be answered before the first
     `next` (about 2027-07). On dnf, slice K tests what rpm 4.16 and rpm 6 do with a new
     subkey of a primary already imported, against the criterion under "Which branch is taken":
     a step the user must take is a failure, not a documentation item.
   - **A leaked subkey.** The owner revokes it offline and certifies a new one. The key file
     ships the revocation, and the pinned primary stays the same. If the current manifest was
     signed by the revoked subkey, an `anchor <generation> <sha256>` line in `fingerprints`
     restarts the chain from a manifest the owner names by its hash. rpms signed by the revoked
     subkey cannot be re-signed, because of the locks. The owner leaves them out of the indexes
     with a dispatch of the refresh that names the subkey's Key ID (point 3). Their releases get
     a decision at the time, normally a patch release.
   - **Slice K tests the model first.** It runs before slice 3 and before the owner makes the
     key. It signs test repositories and rpms with a subkey of a throwaway primary, then installs
     from them on Debian 12 (gpgv), Debian 13 (sqv), Ubuntu 22.04 and 24.04, Rocky 9 (rpm 4.16),
     Fedora 43 and 44 (rpm 6) and the runner's rpm 4.18, on amd64 and arm64. It also tests:
     - a rotation, where a host that holds {primary, S1} meets a dual-signed `InRelease` and
       rpms signed by S2;
     - an rpm whose subkey expired after it signed;
     - a revoked subkey;
     - a signature by the primary itself, which the job's check must refuse.
   - **Which branch is taken.** The subkey model is adopted if every cell installs, and across
     a rotation `dnf upgrade nerva` succeeds, and `apt update` succeeds after INSTALL.md's own
     `curl` line, with no other command. A step that can be documented but is a command (for
     example `rpm -e gpg-pubkey-<id>`) is a failure. Slice K runs exactly this on rpm 4.16, 4.18
     and 6. If any cell fails, Rocky 9 included, the model falls back to the single key of P365
     point 12. That fallback keeps every other point of this decision.
   - **What the fallback means.** "Only the subkey is in GitHub, and the primary is offline"
     holds under the subkey model only. Under the fallback, the one key, which is also the
     trust anchor, is the secret `REPO_SIGNING_KEY` in GitHub, as P365 has it today. A leak
     then means rotating the key itself, with a new fingerprint for every user. If an rpm whose subkey has since expired no longer
     verifies on some cell, the subkeys are made without expiry instead: rotation becomes a
     policy, and revocation is the bound. Slice K's pull request records the branch taken as a
     decision that amends this one.
2. **Pin and check (amends P365 point 6, and P368 for slice 2's `verify_manifest`).**
   - **Every signature.** Each `VALIDSIG` line has 12 fields. `$12`, the primary fingerprint,
     equals `primary`. `$3`, the signing key, is a subkey listed for that kind of file and
     differs from `$12`. The public-key algorithm is RSA (`1`), the hash algorithm SHA-512
     (`10`), and the class matches the file (`01` for a clearsigned file, `00` for a detached
     signature). The output has no `BADSIG`, `ERRSIG`, `EXPSIG`, `EXPKEYSIG` or `REVKEYSIG`, and
     exactly one `VALIDSIG`, or two for a dual-signed `InRelease` or `Release.gpg`. In the
     fallback, `$3` equals `$12`, and both are listed.
   - **rpms.** The issuer Key ID and digest, from `rpm -qp --qf '%{RSAHEADER:pgpsig}'`, must be
     `SHA512` and the low 64 bits of `current`, never the primary's.
3. **Verify before upload (adds a step to `repos`, NRV-E1161).** Before anything is written to a
   locked or immutable prefix, and before the run writes the promoted manifest, it checks its
   own output. An rpm is checked in step 4, before its hash is recorded and before it is put,
   because the locks make a bad object permanent. Any failure in step 5b, of an index or of an
   rpm already in the bucket, stops the run and writes nothing (no manifest generation, no index
   upload). The job never leaves an rpm out on its own, so a fault of the run, such as a bad
   `fingerprints` edit, cannot drop packages. A lasting fault stops every run until a person
   acts; the alarm and `Valid-Until`'s 10-day margin (point 5) bound the damage. When the cause
   is a key (a revoked subkey, or in the fallback a key that left `fingerprints`), the owner
   dispatches the refresh with the input `rpm_key` set to `exclude <Key ID>`. That run marks
   every rpm signed by it `excluded` in the manifest, with no count bound because a person
   started it, and later runs keep it so. `restore <Key ID>` reverses a mistaken exclusion, and
   is refused for a subkey that is revoked. The rest is
   checked in step 5b:
   - `gpgv` checks `InRelease`, `Release.gpg` and `repomd.xml.asc`, under an empty `GNUPGHOME`,
     against a keyring made only from `packaging/keys/`.
   - The text `gpgv` prints from `InRelease` must equal `Release` byte for byte.
   - `rpmkeys --dbpath <scratch> --import` loads the pinned key file into a scratch rpm
     database, then `rpmkeys --dbpath <scratch> -K` checks each rpm before step 4 records it,
     and again every rpm the indexes list. It runs on the runner's rpm 4.18, so it checks
     signatures and the Key ID, not rpm 6's policy or an expired subkey; slice K and
     `repos-verify` check those. That
     database holds no other key. Fedora's rpm 6 refuses a key it has not imported, so the
     import is part of the check.
   - The manifests already verify before they are put, and the NEVRA and payload checks
     (NRV-E1144) stay as they are.
4. **Served bytes equal signed bytes (extends NRV-E1145).** After its last write, each job
   fetches back from `https://packages.nerva.pro`, without cache busting, every object it wrote
   in the run and compares each byte for byte:
   - the manifests, the binding one of `repos-ready` included, and the `complete` one;
   - the packages;
   - the content-named index files;
   - every replaceable name.

   The bound is 32 index names for two channels, at most 4 manifests, and the package objects
   the run wrote. That is about 40 MB a release; the manifest's 4 GiB bound applies in the worst
   case. The cost is about a minute. R2 egress is free.
5. **Refresh alarms (amends P365 point 10's threshold).** When `repos`, `repos-verify`, the
   refresh or `repos-fresh` fails, an `alarm` job runs. A cancelled `repos-ready` or `repos` in
   `release-finish.yml` alarms too: nothing supersedes them (`cancel-in-progress: false`), and a
   cancelled `repos-ready` is a release with no packages that no clock sees. No other cancelled
   job alarms (`ci.yml` cancels a superseded run on `main`). It uses the
   `GITHUB_TOKEN` with `permissions: issues: write` only, and no environment or secret.
   - If an open issue labelled `package-repos` exists, the job comments on it, at most once a
     day per (workflow, job, code). Otherwise it opens one, assigned to the owner, so there is
     at most one open alarm.
   - The comment quotes the code and the run's link.
   - A failure of the alarm itself is warning NRV-W1103 and never changes the run's verdict.
   - The refresh also comments when the `InRelease` it finds was signed more than 8 days
     earlier, which means a refresh was missed.
   - A daily `package-repos-watch.yml`, a file of its own, runs the same check as `repos-fresh`,
     so a refresh that never starts is seen within a day even when `main` is quiet.
   - `repos-fresh` fails at under **10** days left, not 7. A healthy `InRelease` has 14 to 21
     days left, so under 10 means at least one refresh did not happen.
   - The 60-day rule stays. It catches only a schedule that GitHub disabled.
6. **WKD on `nerva.pro` (amends P365 point 3: the site now carries the key, as a second channel).**
   - The site repository serves the key by WKD's direct method, with a `404.html` and a
     `_headers` rule (`Access-Control-Allow-Origin: *`), and it is adopted only if the
     rehearsal shows Pages serves the dot-directory and answers an unknown hash with 404:
     - `.well-known/openpgpkey/policy`, an empty file;
     - `.well-known/openpgpkey/hu/ndqm47zydhyqyzabecddtdk1q3bponab`, the hash of `nerva`. It
       holds the binary form of `packaging/keys/nerva-release.asc`.
   - The build command copies exactly those two files and refuses a symlink.
   - Both checks use one reference, taken from Nerva and never from the pull request checked:
     the key file at the tag of Nerva's newest published release, prereleases included (so a
     site pull request cannot roll the WKD file back, and a candidate's pull request passes).
     `site_check.mjs` runs on every site pull request and does not read `RELEASES`;
     `release_finish.sh site-live` runs after a release. A difference is NRV-E1162.
     `release-finish.yml`'s `site` job writes the WKD file into the site pull request it opens,
     for a release and for a candidate.
   - INSTALL.md tells users to check that the primary fingerprints from GitHub and from WKD
     agree.
   - The job never reads the site's key.
   - The Pages build gate still refuses functions, workers, bindings and dependency files.
7. **`Date` (P365 point 10).** `Release`'s `Date` is the clock of the signing run. It is not a
   reproducible fixed date, and the run refuses `SOURCE_DATE_EPOCH` (NRV-E1139). `Valid-Until`
   is `Date` plus 21 days.

**Reason.**
- The primary never touches CI, and a leaked CI subkey costs users no new fingerprint. The
  expiry bounds a leaked subkey to one year, even for a host that never fetches the revocation.
- Rocky 9's rpm 4.16 is the oldest verifier in scope, and its handling of subkeys is the one
  known risk. So the model is adopted on a test, and the fallback is written beforehand.
- The Zigbox review found four gaps:
  - Slice 2's check accepted any key whose primary was listed.
  - Nothing verified the output before upload.
  - Only part of what was served was checked.
  - A failed refresh e-mailed one inbox.
- WKD lets a user notice a swapped key file, which GitHub alone cannot show.

**Cost.**
- One more slice (K) before slice 3, and the owner's key ceremony waits for it.
- A yearly rotation for the owner.
- A yearly key-file fetch for apt users until a keyring package exists. A user who misses it gets
  `NO_PUBKEY` at the swap.
- About a minute more per write run.
- A lasting rpm fault stops every write run until the owner acts, by hand.
- The WKD file changes with a release, not with a key change on `main`.
- Four codes (NRV-E1160 to NRV-E1162, and the warning NRV-W1103).
- Under the fallback, the primary key itself is in GitHub, and a leak means rotating it.
- WKD does not protect against a merge to Nerva's `main`. That merge already reaches the CI
  subkey through the workflows, but it cannot make a new subkey without the offline primary.
