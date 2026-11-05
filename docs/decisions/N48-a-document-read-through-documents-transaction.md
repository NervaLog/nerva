---
id: N48
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# A document read through `documents.Transaction` is read whole at chunk 0's version.

`Transaction.get` read chunk 0, then the tail chunks, in two lookups that can execute at
different ops. A rewrite committed between them made the read decode chunk 0 of one version
with tails of the next: a spurious `Corrupt`, or a value stitched from both (#7). A transaction
that went on to commit got `conflict`, so no write was ever based on it; but read-only callers
(the API reading table layouts and view declarations through `catalog_store.zig`) could see the
mix. Amends N41, whose public route already read this way:
- Every write rewrites every chunk of a document in one transaction, so in a consistent read
  every tail has chunk 0's op. A tail at a later op is read from its history at chunk 0's
  version (`Client.row_as_of`), as `documents_routes.zig` does; a tail at an earlier op cannot
  happen, and is `Corrupt`. A read without a race costs nothing more: still two lookups.
- Every chunk is recorded as read at chunk 0's version, not at the version its row holds now,
  so a transaction that commits after such a read conflicts, as it should.
- `Transaction` is now `TransactionType(Client)`, so a test can give it a stub client and land
  a rewrite between the two lookups. Callers are unchanged.
Tests (`documents.zig`): the rewrite between the lookups returns the old document whole, with
every chunk recorded at the old version (with the previous code the same test returns a value
stitched from both versions, differing from byte 49, where the first tail starts); a read
without a race reads no history; a tail older than chunk 0 is `Corrupt`.
