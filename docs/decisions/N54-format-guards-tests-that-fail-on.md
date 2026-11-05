---
id: N54
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Format guards: tests that fail on any change to what Nerva puts on the wire or on disk.

Only struct sizes (comptime asserts), one document id vector and an empty formatted data file
were pinned. Reordering fields of equal size, renumbering an enum value or tree id, or changing a
derived key, the catalog's stored JSON, a layout's packing or what a commit stores would all
have passed every test. Three guards, all tests, no production code:
- `format_test.zig`, "wire and storage layouts": every wire and storage type (rows, entries and
  results, add parameters, keys, values, changes, both filters, the document header) rendered by
  reflection with its size and each field's offset, size and type (bits, for flags), every
  persisted enum's values, and `tree_ids`, compared to a snapshot.
- `format_test.zig`, "persisted derivations": golden values for `row_key`, documents' `tail_id`
  (computed apart from the code, in Python, as `row_id`'s was), and the catalog's canonical
  layout and view JSON and its packing of a layout's fields into a row (checked by hand against
  N34's rules). The canonical view stores `true` as `"1"`; the guard records it as it is.
- `state_machine_tests.zig`, "what a fixed script commits": puts, a delete and re-create, a read
  at the version seen and a stale one, unsigned and signed adds, a clamped reservation moved by
  `delta_from`; every result, row, change and history record, summarized (checked by hand) and
  checksummed.
A meant change updates the snapshots with `SNAP_UPDATE=1` and says why (CLAUDE.md); one that
changes the protocol or the data file also moves the release string (N32). Not guarded here: the
data file's own encoding (grid, LSM, superblock). That is the vendored code's, pinned upstream
and by the formatted-file checksum (`replica_format.zig`); a populated golden data file would
need checkpointing the harness does not do, and would test TigerBeetle's encoding more than
Nerva's. The script guard sees what a client can observe: a stored byte no reply exposes (a
deleted row's old value) is not covered.
Written before views (N52) and merged after them: the layouts guard also covers views' wire and
storage types (definitions, views, groups, queries, records, their enums and flags), the new
operations and tree ids 5 to 8. The script guard's first run on the merged code failed, as it
should: N52 reserves 5 timestamps per entry, so change timestamps step by 5. N52 records that
change; the snapshot was updated for it. (The release string stayed `0.0.2` through N52's new
trees, operations and timestamps: whether that needed a bump under N32 is the owner's call.)
Proven by planted changes, each failing exactly its guard: two `HistoryFilter` fields swapped,
`EntryStatus.conflict` renumbered, a tree id renumbered (layouts); `row_key`'s halves swapped,
one character of `layout_render`'s output (derivations); change timestamps shifted (script).
