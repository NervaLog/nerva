---
id: P392
date: 2026-11-13
area: Releases
amends: P376
---

# The key-model test: rpm 4.16, rpm 4.18 and dnf5 do not follow a subkey rotation, so setup step 4 takes 4B

**Decision.** P376 point 1 asked whether a certify-only primary with CI-held signing subkeys
can sign both repositories and rotate a subkey with no command on any host. The test
(`tests/packaging/subkeys.py`, `.github/workflows/key-model.yml`) was run on
`72d1b312c8e705086c60eb313ada3b2e88cb1e77`, as run 43438971430
(<https://github.com/NervaLog/nerva/actions/runs/43438971430>): 16 jobs, all green (a job is green
when every FAIL is a finding below, with its symptom), on host, Debian 12 and 13, Ubuntu 22.04 and
24.04, Rocky 9, Fedora 43 and Fedora 44, each on amd64 and arm64, with the images pinned by digest.
The two architectures agree on every cell. The dnf cells behave like a host: one fixed `baseurl`
for the whole scenario (the repository's contents are swapped at it), the `gpgkey=` URL's contents
swapped, no `dnf clean all` between stages, and the repo file INSTALL.md ships (no
`metadata_expire`, so dnf's default applies). A user then runs `dnf upgrade`: within the default
metadata expiry that sees nothing (recorded as INFO, `.../plain-dnf-upgrade`), so the judged run
is `dnf upgrade --refresh`, which keeps the cache and the repository keyring and re-fetches the
metadata. (Earlier runs are not evidence: 43429062850 never gave the host the new key file; 43433615878
and 43435465660 gave each stage a new `baseurl` and cleaned the cache, so a fresh host measured
what a long-lived host does not. Run 43437979486 on `6020e56` is the first with the kept cache; it
differs from the run above only in a diagnosis cell and in the findings table, which did not yet
list the dnf5 rotation.)
The answer is **apt yes; rpm 4.18, dnf4 (rpm 4.16) and dnf5 (rpm 6): no.**
P376's rule is "if any cell fails, Rocky 9 included, the model falls back to the single key", and
three rpm cells fail, so setup step 4 takes **4B**, which is also what the earlier runs said. The
subkey model is not adopted. 4A and 4A with `never` are not used. Setup step 4B and P365 point 12
do not change.

**What 4B is** (P365 point 12 and setup step 4B, unchanged). One OpenPGP key, RSA 4096, sign-only,
SHA-512, **no expiry** (`Expire-Date: 0`), no subkeys. The one key signs the apt repository
(`InRelease`, `Release.gpg`) and the rpm repository (`repomd.xml.asc`, every rpm); it is the trust
anchor in `fingerprints`, with `$3` equal to `$12` (P376 point 2, fallback). Its secret part and
passphrase are the secret `REPO_SIGNING_KEY` in `package-repos` only, and its revocation
certificate is saved with it, in the password manager, as a file. Rotation is P365's, every two
years, with an overlap in which apt's metadata is signed by both keys.

**What the test found**, from run 43438971430:

- **apt: every cell passes on every Debian and Ubuntu image, both architectures** (gpgv on Debian
  12 and Ubuntu, sqv on Debian 13). A subkey signature validates against the primary's key file;
  an `InRelease` or `Release.gpg` signed by S1 and S2 verifies with only the old key file; S2
  alone verifies once the key file carries S2 (INSTALL.md's `curl` line alone); a revoked subkey
  is refused. The certify-only primary cannot sign, and every signature names a subkey.
- **rpm 4.18 (the host cells): rotation fails.** A database that imported `{P, S1}` and then the
  key file `{P, S1, S2}` exits 0 from `rpmkeys --import`, still holds one `gpg-pubkey` entry, and
  the S2-signed rpm is `SIGNATURES NOT OK`. It verifies after `rpm -e gpg-pubkey-<id>` and a second
  import, which is the extra command P376 forbids.
- **dnf4 on Rocky 9 (rpm 4.16): rotation fails.** The key file at the `gpgkey=` URL becomes
  `{P, S1, S2}`, nothing else is done, and `dnf upgrade nervak` exits 1: "Public key for
  nervak-2.0-1.noarch.rpm is not installed ... GPG check FAILED". Only `rpm -e gpg-pubkey-*` and
  a re-import make it work.
- **dnf5 on Fedora 43 and 44 (rpm 6.0.2): rotation fails.** Install 1.0 under `{P, S1}`; the key
  file at `gpgkey=` becomes `{P, S1, S2}`; the repository (same `baseurl`) now holds the S2-signed
  2.0. `dnf upgrade` (plain, then `--refresh`) exits 0, prints "repomd.xml GPG signature
  verification error: Signing key not found", skips the repository and leaves 1.0. `rpm --import`
  of the new file, `rpm -e` of every `gpg-pubkey` and a re-import, and `dnf clean all` do not clear
  it in the run (`rotation/diagnosis-*` cells, all still "absent"). The cause is not established.
  This is a host that silently stops getting updates (exit 0). What a Fedora host would have to
  run to recover is not found by this test.
- **dnf5 skips a repository it cannot verify and exits 0.** With the key file still `{P, S1}`
  (nobody changed it), `dnf upgrade` on Fedora 43 and 44 prints "repomd.xml GPG signature
  verification error: Signing key not found", then "Nothing to do", exits 0, and nervak stays at
  1.0. A host whose key file lacks the new key stops getting updates silently, and any monitor
  that reads the exit status stays green. The test records the refusal as its own cell
  (`.../exit-status`, FAIL). This was measured with the 4A keys only; it probably also follows any
  key change a host has not received, 4B's included, but no cell serves a K2-signed repomd to a
  host whose key file is `{K1}` (not tested). dnf4 and rpm 4.18 refuse loudly there (exit 1).
- **Revocation.** rpm 4.18 and dnf4 refuse a key file that carries a subkey revocation (rpm 4.18:
  "key 1 import failed", rc 1; dnf4: "Key import failed (code 2)"), so S1 does not verify either.
  The cells that expect the revoked S4 to be refused are therefore recorded as FAIL, "not tested":
  a refusal where nothing verifies says nothing about the revocation (an earlier version of the
  test counted them as passes). On dnf5 the revoked subkey's rpm is refused, and a repomd signed
  by the revoked subkey is **accepted** (installed, exit 0): dnf5 does not enforce a subkey
  revocation on `repomd.xml`. Both bear on 4A under a compromise, not on 4B.
- An rpm signed by an expired subkey still verifies on rpm 4.18 and dnf on every image. apt's
  answer on an `InRelease` of an expired subkey is INFO in the run.
- Setup step 4A's own commands, including the real `--passwd` change from the primary's passphrase
  to the CI passphrase, run non-interactively with a fake pinentry: `sec#` and one `ssb` in the CI
  export, unlocked by the CI passphrase only. The ceremony is sound; the model fails on the rpm
  side.

**4B's own key swap is tested** (`rotation4b/...`, K1 and K2 two whole keys with no expiry, the
key file at `gpgkey=` `{K1}` becoming `{K1, K2}`, the repository at its fixed `baseurl` changing to
the one holding the rpm signed by K2, the host's cache kept, no `dnf clean all`). With
`dnf upgrade --refresh` and no other command it passes on rpm 4.18 (`rpmkeys --import` adds K2 as a
second `gpg-pubkey`), on dnf4 (Rocky 9) and on dnf5 (Fedora 43 and 44, which hold both keys
afterwards), on both architectures. K2 has a key ID the host has never imported, which is the difference
from 4A's S2 (a new subkey of a key ID the host already holds); the test does not show why those
differ inside rpm or dnf. A plain `dnf upgrade` inside the metadata expiry sees nothing new in any
of them, as for any release. So 4B's rpm and dnf key swap passes with `dnf upgrade --refresh` and no
other command, provided the file at `gpgkey=` carries `{K1, K2}` before the first K2-signed rpm is
published (P365's overlap). apt under 4B was not tested here.

**Why.** A key model that is safe for apt and breaks every rpm 4.16, rpm 4.18 and Fedora host at the
first rotation (the last one silently) is worse than one key, because the first rotation would be the incident. With 4B the
rotation is P365's: a new key, announced, with INSTALL.md's line; the test shows the hosts take it.

**Costs.**

- 4B puts the trust anchor, the one key, in `REPO_SIGNING_KEY` on CI, which P376 wanted to avoid.
  A leak then means rotating the key itself, with a new fingerprint for every user, and a manual
  re-key on rpm hosts that miss the announcement (the same manual step rejected for 4A, but once
  per leak and not once a year). The compensation stays P365's: the passphrase in an environment
  gated by the owner's approval, and the revocation certificate in the password manager.
- **No expiry** is the spec's choice and it stays: the test checked an rpm signed by an expired
  *subkey*, never one signed by an expired *primary*, and the locks forbid re-signing, so an expiry
  on the single key could stop every rpm in the bucket verifying on rpm 6 at that date.
- Under 4A a compromise would also meet the revocation finding (rpm 4.16 and 4.18 refuse a key
  file that carries a revoked subkey), which 4B does not have.
- The test stays and is not a required check: it runs on a pull request that changes it, by hand
  and weekly. Its findings table is by image and cell with the symptom each must show; any other
  FAIL is red, an expected finding that starts to pass is red too (XPASS), and so is one that is no
  longer reported (MISSING). A red weekly run opens one issue, or comments on it if it is open
  (job `alarm`, `issues: write` and the workflow's `GITHUB_TOKEN` only, nothing checked out), so a
  later rpm that merges subkeys is noticed. The alarm job is skipped on every other event and has
  not run yet: it is untested until the first red scheduled run.

**Not tested.** Unattended dnf upgrades (dnf-automatic) at the 4B swap (every dnf cell confirms
the key import with `-y`), real signing hosts (the keys are throwaway), WKD (nerva.pro), `zypper` and
openSUSE, dnf on an rpm 4.18 host (the rpm 4.18 cells use `rpmkeys`), apt in the 4B swap, an rpm
signed by an expired primary, what recovers a Fedora host from the 4A finding, dnf's behaviour
under a `metadata_expire` other than the default, and Docker Hub images other than the digests in `PINS` (dnf5 is
upgraded from the distribution inside the container, and its version is in the log).
