---
id: N83
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# A benchmark's size is fixed, not a limit's; the documents benchmark measures 64 KiB.

The nightly of 2026-10-06 (#88) failed `documents.encode_ns_per_document` and
`decode_ns_per_document` by about 8x, and `declared_views.latest_ns` by 39%, at `4a8aef3` against
`ef2eaad`. Bisected (a 4-CPU sandbox, ReleaseSafe, one value size throughout): at 64 KiB,
`ef2eaad`, `b64f7a0~1` (before #85), `b64f7a0` (#85) and `4a8aef3` all encode a document in
630–670 µs and decode it in 18–19 µs. Nothing slowed down: the benchmark took
`documents.value_size_max` as its size, so when N76 raised that from 64 KiB to 512 KiB the
benchmark started timing documents 8 times larger, and encoding and decoding are linear in the
size. The benchmark is back at 64 KiB, the size its metrics reported from its start (88cc5e6) to
#85; `value_size=524288` times the largest. The decode series stays comparable across the change;
the encode series drops about 2.8 times from the old baseline, for the change below. A benchmark's default size is now chosen
for itself, never derived from a limit that may move.
- **Encoding hashed the key once per chunk.** `nerva api`'s documents commit, the Zig
  transaction's `get` and `put`, and `nerva import`'s catalog reads called `chunk_id(namespace,
  key, chunk)` for each chunk, and each call hashes the key (up to 1 KiB) before the tail's own
  SHA-256. Now they take `row_id` once per document and name each chunk with
  `chunk_id_from(id0, chunk)` (or `tail_id`): the same ids, which a unit test pins as fixed
  vectors computed outside this code, and encoding about 2.8 times faster (64 KiB: 635 µs to
  225 µs; 512 KiB: 5.47 ms to 1.96 ms). Tests, fuzzers and the view benchmark still call
  `chunk_id` per chunk: harmless there.
- **`declared_views.latest_ns`: the documents benchmark before it, in the same process.** On
  Fly the candidate's `latest` was about 141 ms in all three rounds against about 100 ms, while
  `as_of_middle_ns` did not move. `latest` walks a map of a million rows built on the process's
  heap after the documents benchmark has run in it; `as_of` builds its own in a fresh arena. A
  reviewer reproduced it on another machine (transparent huge pages `madvise`): with the
  documents benchmark first, `latest` took 74.6, 81.3 and 79.6 ms after 64 KiB documents and
  108.8, 98.4 and 124.7 ms after 512 KiB (+37%), and `4a8aef3` the same (about 75 ms and
  108–110 ms). In this session's 4-CPU sandbox it does not reproduce (interleaved, four rounds:
  137–152 ms after either), so it depends on the machine, not on huge pages. The only change to
  that path in the range, sorting `Group`s instead of the hash map's entries (N66), is the same
  speed. The 64 KiB benchmark restores the process `latest` ran in before; #91 is the cause
  (benchmarks share one process), left for later. The next night confirms the fix.
