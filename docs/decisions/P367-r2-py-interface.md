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
- A failure prints the registered form: `error[NRV-E1143]: r2.py: <op> <key>: <what>`, then a
  `cause` and a `fix` line, exit 1. A missing or malformed `R2_*` variable (an endpoint with a
  path, or `http` on a host that is not loopback) is NRV-E1139, exit 1. A usage error is exit 64
  with a usage line and no code.
- `put` refuses a name a run never replaces with `bug[NRV-B0005]: r2.py: ...` (registered in this
  PR), exit 70, before any request.
- `list` refuses with NRV-E1143: a key with a control character (TAB and newline would forge
  lines), a missing or non-decimal `<Size>`, and a truncated page that gives no continuation
  token. It prints nothing in those cases.
- `put-new` answers "exists" (exit 3) on a 412 or the pinned lock refusal. When that answer comes
  after a retry, it HEADs the key: the object's `x-amz-meta-sha256` and size equal what was sent,
  and the run's own write, whose answer was lost, is done (exit 0). Anything else is exit 3. A
  first-attempt "exists" is not HEADed: the caller decides, as the spec says.
- `probe-locked` exit 4 prints a plain note, no code; `package_repos.sh` reports NRV-E1149.
- `Cache-Control` is `immutable` for every name not in the replaceable set (packages, manifests,
  by-hash and hashed repodata files). `by-hash` objects are `application/octet-stream`, because a
  hash does not say whether it names text or gzip; manifests are `text/plain`.
- The lock refusal is pinned as HTTP 409 with `ObjectLockedByBucketPolicy`, from Cloudflare's
  documentation. Only that exact pair counts; the rehearsal confirms it.

**Reason.** Closest to the spec's text; `package_repos.sh` (slice 2) parses these forms.

**Cost.** A wrong pin makes `probe-locked` fail closed until it is corrected.
