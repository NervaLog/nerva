# Changelog

What changed in each release, for people running Nerva or building on it. The release workflow
publishes a version's section as its GitHub release notes, and refuses to release a version
without one. Design reasons are in [docs/DECISIONS.md](./docs/DECISIONS.md); the full log of
work is [WORKLOG.md](./WORKLOG.md).

## v0.2.0 — 2026-10-04

Two new capabilities for applications on `nerva api`, values larger than a row and counters
that many clients can change at once, plus two crash fixes. **This release is not compatible
with v0.1.0's data files or clients:** see "Upgrading" below.

### New: documents (larger values by key)

Store values of up to 64 KiB under string keys (up to 1024 bytes of UTF-8), grouped by a
namespace, without chunking them yourself. Reads and writes are optimistic transactions, like
rows.

```bash
curl -H 'X-Nerva-Key: secret' -d '{"namespace":"7",
  "reads":[{"key":"cart/1","version":"0"}],
  "writes":[{"key":"cart/1","value_hex":"7b7d"}]}' http://127.0.0.1:8080/v1/documents/commit
# {"status":"committed","op":"42"}
curl -H 'X-Nerva-Key: secret' -d '{"namespace":"7","keys":["cart/1"]}' \
    http://127.0.0.1:8080/v1/documents/get
# {"op":"43","documents":[{"key":"cart/1","exists":true,"version":"42","value_hex":"7b7d"}]}
```

- `POST /v1/documents/get` reads up to 256 keys at one op: the latest, or `"as_of"` any
  committed op. Each document has a `version` (the op of its last write; `"0"` if never
  written).
- `POST /v1/documents/commit` is one transaction of reads at the version seen, puts and
  deletes. A stale read answers `409` with the key and its current version; nothing applies.
- `GET /v1/documents/changes?namespace=&cursor=&limit=` lists a namespace's document writes in
  commit order, including deletes (each with its key).
- Up to about 600 KB of keys and values per commit.

### New: adds (counters and budgets without conflicts)

An `add` changes one 64-bit field of a row inside the commit, without reading it first. Adds to
the same row never conflict, so many clients can draw on one budget or stock count at once with
no retries.

```bash
# Reserve up to 30 from `available` and hold exactly what was taken, in one transaction.
curl -H 'X-Nerva-Key: secret' -d '{"entries":[
  {"kind":"add","table":5,"id":"1","field":"available","delta":"-30","min":"0","clamp":true},
  {"kind":"add","table":5,"id":"1","field":"held","delta_from":0}]}' \
    http://127.0.0.1:8080/v1/commit
# {"status":"committed","op":"44","adds":[{"index":0,"applied":"-20","value":"0"},
#                                         {"index":1,"applied":"20","value":"20"}]}
```

- Fields are `u64` or `i64`, named by the table's layout or given by `offset` and `type`.
- `min` and `max` bound the result. Crossing a bound fails the transaction with `409
  out_of_bounds` (with the field's current value), or with `clamp` the add takes what fits.
- `delta_from` moves exactly what an earlier add of the same transaction applied, so a
  reservation can never overdraw.
- An add to a row that does not exist answers `409 row_absent`, unless `create` starts it at
  zero.
- Adds appear in the change feed, history, as-of reads and declared views like any other write.

### Fixed

- A cluster could crash when one request carried two writes that left a row unchanged (for
  example two identical puts). Every replica failed on the same op. Nerva's own client never
  sent such requests, but the protocol allows them. (#4)
- One oversized request (too many rows or entries) made the next request to the same
  `nerva api` gateway crash it. Oversized requests now just answer `400`. (#5)

### Upgrading from v0.1.0

- **Reformat data files.** v0.2.0 refuses data files formatted by v0.1.0 ("found incompatible
  superblock version 0"). Nothing carries over: format new files and load your data again.
- **Upgrade every process together.** Replicas refuse clients from v0.1.0, and the two releases
  cannot run in one cluster. Binaries now report `0.0.2+<commit>` (the protocol release, then
  the commit).
- Zig client users: `EntryResult` is now 32 bytes (with `applied` and `value`), and
  `EntryKind`, `EntryStatus` gained values. Existing values keep their numbers.
- JSON API users: nothing changes for existing requests and replies; a commit reply carries
  `adds` only when the commit had adds.

## v0.1.0 — 2026-10-04

The first release.

- **Commit core:** rows of 80 bytes keyed by `(table, id)`, optimistic transactions (reads at
  the version seen, puts and deletes), a change feed, and every row's history as of any op.
- **`nerva api`:** the core operations as JSON over HTTP, table layouts (named, typed fields).
- **`nerva view`:** declared views (where, group by, count, sum, min, max) over a table, latest
  or as of any op, each answer with a hash.
- Replication, storage and the simulator from TigerBeetle; binaries for Linux and macOS
  (x86_64, aarch64). Binaries report `0.0.1+<commit>`.
