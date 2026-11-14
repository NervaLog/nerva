---
id: P417c
date: 2026-11-14
area: Releases
amends: P417b
---

# `SHA256SUMS` is signed with the release key

**Decision** (owner, 2026-11-14, answering the question left by P417b's reading of "signed"). Each
release's `SHA256SUMS` carries a detached, armored OpenPGP signature, `SHA256SUMS.asc`, made with the
release key (P392: `packaging/keys/nerva-release.asc`; its secret is `REPO_SIGNING_KEY`, with
`REPO_SIGNING_PASSPHRASE`). P417b's reading ("covered by `SHA256SUMS`") stands for the files the sums
list, `.debug` files included; the sums themselves are now signed.

- `repos-ready` signs. It already holds the key and the passphrase, and it has read the draft's
  assets twice (NRV-E1148) before it signs. No workflow, job or secret is added. A signature already
  on the draft must verify against its sums (kept), or the run refuses (NRV-E1165): a signature is
  never replaced.
- The check is the pinned one for `Release.gpg` (the current or next key, RSA, SHA-512, class 00),
  against `packaging/keys/` alone. `repos-ready` makes it right after signing; the `publish` job
  makes it again (`package_repos.sh sums-verify`, no secret), and `release_check.sh publish-ready
  <tag> signed` requires the file. The draft `release` builds still has twelve assets (P417b);
  `SHA256SUMS.asc` is the thirteenth, added by `repos-ready`, and the published release has fifteen with the
  Mac zip and its checksum (P417b said fourteen).
- The release notes say how to check it: `gpg --verify SHA256SUMS.asc SHA256SUMS`.
- The Mac zip stays covered by its own `.zip.sha256`, as before.

**Reason.** A download is checked against the sums, so the sums need a root: the release key is the
one the packages' signatures already lead to. **Cost.** One more release asset and one more write to
the draft, made by a job that already writes to the release's package repositories.
