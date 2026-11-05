---
id: N41
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Documents in the generic API: values up to 64 KiB by key, as one more reserved table.

Every application with state larger than an 80-byte row was chunking it by hand (the catalog
did; so did the dog-fooding application). `nerva api` now serves `documents.zig` documents in a
reserved table, `catalog.table_documents` (`0xFFFF0002`), under a `u64` namespace and a string
key (1–1024 bytes of UTF-8), with values up to 64 KiB:
- `POST /v1/documents/get` reads up to 256 keys as of one op, the latest or `as_of` a committed
  op (folded into `get` rather than a separate route, so several keys share one position).
  Each document's `version` is chunk 0's op. A tail chunk whose op differs from its chunk 0's
  (a later write landed between the two lookups, or the read is `as_of`) is read from its
  history at that version, so a read is consistent without retries.
- `POST /v1/documents/commit` is one transaction: reads assert chunk 0 at the version seen (every
  write rewrites chunk 0, so that covers the document); writes put every chunk. `409` names the
  stale key and its current version.
- **A delete is a tombstone document**: chunk 0 (and any tails the key needs) written with a new
  `deleted` header flag (the header's formerly reserved `u16`; old documents read the same) and
  the key, but no value. A row delete would carry no value, so the feed could not name the key
  deleted; and the version still advances, so a read at it still conflicts correctly.
- `GET /v1/documents/changes?namespace=` decodes the feed into document writes. An op's chunks
  are grouped by op (pages always end at an op boundary, reading on while one op fills a page),
  and each document an op wrote is reported once, as the op left it. Chunk 0 is recognised by
  decoding: only a real chunk 0 decodes to a key that hashes back to its id.
- Accepted costs: a write that shrinks a document, and a delete, leave its old trailing chunks
  in place, unread (deleting them would need a read first); `as_of` reads of documents
  rewritten since cost one history read per chunk.
Found on the way: `Client` refused an oversized request (`TooManyEvents`) after marking itself
busy, so the next request on that client panicked. It now checks before; `tests/api/
documents.py` sends an oversized commit and then reads.
