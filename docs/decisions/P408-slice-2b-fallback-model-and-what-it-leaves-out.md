---
id: P408
date: 2026-11-13
area: Releases
amends: P376
---

# Slice 2b implements P376's checks under P392's single key; the subkey roles are not implemented

**Decision.** `package_repos.sh` takes P376's pinned checks and the rpm exclusion as P392 narrowed them
(setup step 4B: one RSA 4096 key, no expiry; `packaging/keys/fingerprints` roles `current`, `next`,
`previous`), and P398. What the slice does:

- Every rpm is checked (`rpmkeys -K` in a scratch rpm database holding the listed keys, `RSA/SHA512`
  and a Key ID that is current's or previous's) before it is recorded and before it is put, and again
  in step 5b over every rpm staged. A failure is NRV-E1161 and names the Key ID that signed the rpm.
- Each index signature (`InRelease`, `Release.gpg`, `repomd.xml.asc`) is checked before upload against
  the key file alone, by the 12-field `VALIDSIG` pin (primary equals signing key, listed, RSA, SHA-512).
- `refresh` takes `rpm_key` as `exclude <Key ID>` or `restore <Key ID>` (owner only, NRV-E1139 for any
  other actor or shape). Exclusion marks every published rpm of that Key ID `excluded` in one manifest
  generation; excluded rpms are left out of both channels' repodata and stay excluded on later runs.
  It refuses the Key ID of `current` or `next`, and a Key ID no published rpm has.
- After the pipeline writes, everything it put is fetched back from `packages.nerva.pro` and hashed;
  a difference is retried every 10 s for 2 minutes, then NRV-E1145 (`PACKAGE_REPOS_SERVED_WAIT` is the
  test override). `fresh` is the daily watch's check: stable's served `InRelease` verifies and has at
  least 10 days of `Valid-Until`.
- Every failing step writes `code=<NRV-...>` to `$GITHUB_OUTPUT` for `repos_alarm.sh`.

**Not implemented, because P392 removed their premise:** the subkey roles (`primary`, `retired`,
`revoked`, `anchor`), the `sec#` check of the CI secret and NRV-E1160 (retired). **Not implemented,
for another reason:** the skipped-run count; P392 did not remove its premise, so the alarm keeps its
24-hour deduplication per (workflow, job, code) and nothing counts skipped runs.

**Choices the task left open.**

- `restore` refuses the Key ID of a revoked key (a published revocation is final) and one that is neither
  current's nor previous's (5b would refuse its rpms), and nothing else; a
  revoked key may still be listed as `previous`, so its rpms can be excluded and the key file kept.
- The key file may hold a revoked `previous`; `current` and `next` must be neither revoked nor expired.
- `PACKAGE_REPOS_SERVED_WAIT=<interval>:<total>` and `PACKAGE_REPOS_CLOCK` are refused on a runner, like the other overrides.

**Cost.** The rotation to a new key needs `previous` in `fingerprints` for as long as rpms signed by the
old key stay published, or an exclusion; there is no subkey rotation that needs neither (P392).
