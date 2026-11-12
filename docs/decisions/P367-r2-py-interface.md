---
id: P367
date: 2026-11-12
area: Releases
---

# r2.py's output formats, exit codes and refusals

**Decision.** `r2.py` (slice 1 of `docs/releases/packages.md`) fixes what the spec leaves open:

- `list <prefix>` prints `<key><TAB><size>` per object, in listing order. At the 100-page bound it
  still prints what it read, then exits 5 with an NRV-E1143 line.
- `head <key>` prints `<size><TAB><x-amz-meta-sha256>`, with `-` when the object has none.
- `get` fails with NRV-E1143 (exit 1) when the stored `x-amz-meta-sha256` does not match the bytes,
  and leaves no file. An absent object is exit 2.
- Any other failure is exit 1 with `error[NRV-E1143]: r2 <op> <key>: <what>`. Usage errors, a
  missing environment variable and a name `put` refuses are exit 64. The refusal of a name has no
  code: it is a bug in the calling script, which no operator input can cause.
- `probe-locked` exit 4 prints no code; `package_repos.sh` reports NRV-E1149.
- `Cache-Control` is `immutable` for every name not in the replaceable set (packages, manifests,
  by-hash and hashed repodata files). `by-hash` objects are `application/octet-stream`, because a
  hash does not say whether it names text or gzip; manifests are `text/plain`.
- The lock refusal is pinned as HTTP 409 with `ObjectLockedByBucketPolicy`, from Cloudflare's
  documentation. Only that exact pair counts; the rehearsal confirms it.

**Reason.** Closest to the spec's text; `package_repos.sh` (slice 2) parses these forms.

**Cost.** A wrong pin makes `probe-locked` fail closed until it is corrected.
