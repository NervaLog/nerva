---
id: N76
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Documents hold up to 512 KiB, the most one commit writes atomically; larger values live outside, by hash.

Documents held at most 64 KiB (N39, N41), and applications storing model outputs, files or
program state needed more (#25). A document is written in one commit request, so atomicity caps
it: a request carries 8,190 entries in production, one per 80-byte chunk. `value_size_max` is
now 512 KiB: with the longest key that is 6,567 chunks, leaving over 1,600 entries for the rest
of the transaction (asserted at compile time against the production message size). Not larger:
a document split across requests would no longer be written atomically, and a design for that
(staged chunks, a commit record) is a 1.0-sized change. The chunk format and ids are unchanged, so
existing documents read as before; a client older than this change refuses a larger document as
corrupt, but v0.3.0 clients are refused by 0.0.4 clusters anyway (N62).
- **A `get` reads at most as many chunks as 256 documents of 64 KiB** (about 16 MiB of values),
  and answers `413` past that, before reading any tail chunk. Every `get` that answered before
  still does, and a reply stays inside the request's 128 MiB budget (N69): 256 documents of
  512 KiB would be 128 MiB of values alone.
- **Larger values**: the documented pattern is content-addressed blobs outside Nerva, with their
  hash in a document (README, TUTORIAL Part 8).
Tests: `tests/api/documents.py` writes a 512 KiB value under a 1024-byte key in one transaction
and reads it back, refuses one byte more, and checks the `get` cap at its edge (33 documents of
512 KiB answer 413, 32 answer 200); the documents fuzzer draws values up to the new limit.
