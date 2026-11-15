---
id: P417d
date: 2026-11-14
area: Releases
amends: P417b
---

# A `.debug` file is signed by being listed in the signed `SHA256SUMS`

**Decision** (owner, 2026-11-14). P417b's "signed like the other release files" means: each
`nerva-<tag>-<target>.debug` has its checksum in `SHA256SUMS`, and `SHA256SUMS` carries the release
key's signature (P417c). A `.debug` file gets no `.asc` of its own.

- `release.yml` writes `SHA256SUMS` over `*.debug` among the other files, expects eleven lines, and
  also checks that each `.debug` file in `dist/` has its own line.
- No document says otherwise: P417b's "covered by `SHA256SUMS`" was the first half of this reading,
  and P417c made the sums signed.

**Reason.** One signature covers every file the sums list, so a verifier makes one check and the asset
list does not grow with each file. **Cost.** A `.debug` file alone is not verifiable without the sums.
