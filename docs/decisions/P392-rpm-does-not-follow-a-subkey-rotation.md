---
id: P392
date: 2026-11-13
area: Releases
amends: P376
---

# The key-model test: rpm and dnf do not follow a subkey rotation, so setup step 4 takes 4B

**Decision.** P376 point 1 asked whether a certify-only primary with CI-held signing subkeys
can sign both repositories and rotate a subkey with no command on any host. The test
(`tests/packaging/subkeys.py`, `.github/workflows/key-model.yml`, run 43425142574 on
`f39e9fc`, 16 jobs: host, Debian 12 and 13, Ubuntu 22.04 and 24.04, Rocky 9, Fedora 43 and 44,
on amd64 and arm64) answers: **apt yes, rpm and dnf no.** P365's single-key fallback therefore
applies to the rpm repository, and setup step 4 takes **4B**, the signing key as one key whose
primary signs. The subkey model is not adopted. 4A and 4A with `never` are not used.

**What the test found.**

- apt: every cell passes on every Debian and Ubuntu image, both architectures (gpgv on Debian 12
  and Ubuntu, sqv on Debian 13). A subkey signature validates against the primary's key file;
  an `InRelease` or `Release.gpg` signed by S1 and S2 verifies with only the old key file; S2
  alone verifies once the key file carries S2 (the INSTALL.md `curl` line alone); a revoked
  subkey is refused. The certify-only primary cannot sign, and every signature names a subkey.
- rpm 4.18 (runner) and `dnf upgrade` on Rocky 9 (rpm 4.16), Fedora 43 and 44 (rpm 6, dnf5): a
  host that imported `{P, S1}` does not take S2 from the new key file `{P, S1, S2}`. rpm keeps
  the first certificate it was given for a primary; the import succeeds and S2's signature is
  still "NOT OK" (rpm 4.18), and dnf's repomd check says "Signing key not found" (dnf5) or the
  upgrade fails (dnf4). Rotation would need `rpm -e gpg-pubkey-*` and a re-import on every
  host, which P376 forbids ("without a single extra command").
- rpm 4.18 and dnf4 refuse a key file that carries a subkey revocation (`key 1 import failed`),
  so a revoked subkey would break installs for new hosts rather than only S4's packages.
- dnf5 on Fedora 43 and 44 accepted a repomd signed by S2 with the old key file (stale) and by a
  revoked subkey. It does not enforce repo_gpgcheck the way dnf4 does, which makes a subkey
  revocation unenforceable there; it is not a reason by itself, the two points above are.
- An rpm signed by an expired subkey still verifies on rpm 4.18 and dnf on every image, so an
  expiry on subkeys would not by itself break old packages. apt's answer on an `InRelease` of
  an expired subkey is recorded as INFO in the run.
- Setup step 4A's own commands, including the real `--passwd` change from the primary's
  passphrase to the CI passphrase, run non-interactively with a fake pinentry: `sec#` and one
  `ssb` in the CI export, unlocked by the CI passphrase only. The ceremony is sound; the model
  fails on the rpm side, not on the ceremony.

**Why.** A key model that is safe for apt and breaks every existing rpm host at the first
rotation is worse than one key, because the first rotation would be the incident. With 4B the
rotation is the P365 one, a new key, announced, with the INSTALL.md line.

**Costs.** The signing key's primary is on CI (4B), which P376 wanted to avoid. Its compensation
stays P365's: the key's passphrase in the environment gated by the owner's approval, a long
expiry with a calendar reminder, and a revocation certificate kept offline. The test stays,
non-blocking in its FINDINGS cells, so a later rpm or dnf that merges subkeys shows up as a
cell that now passes (a reason to revisit). The key-file import failure on revocation is
unaffected by 4B.

**Not tested.** Real signing hosts (the keys are throwaway), WKD (nerva.pin), `zypper` and
openSUSE, and dnf on an rpm 4.18 host (the rpm 4.18 cells use `rpmkeys`).
