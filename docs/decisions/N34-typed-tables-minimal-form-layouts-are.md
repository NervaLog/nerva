---
id: N34
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Typed tables, minimal form: layouts are metadata in the log.

Declared views need to read named fields (`price`, `color`) out of 80-byte values, and demo
clients want to write fields rather than hex. A table may have a layout: up to 16 fields
(`u8`, `u16`, `u32`, `u64`, `i64`, `bool`, fixed-size `bytes`), packed in declaration order,
each aligned to its size, little-endian, within 80 bytes. Choices:
- The core does not know layouts. It stores bytes and validates nothing about them; layouts are
  read by the API (to encode and decode `fields`) and, next, by views. This keeps the state
  machine unchanged and the choice reversible. The cost: a client writing `value_hex` can write
  bytes its layout does not describe well, which is accepted.
- Layouts live in the log, in a reserved catalog table (`0xFFFF0001`), chunked as documents
  (`documents.zig`) and keyed `table.<id>`, so declarations are committed facts with ops. Tables from
  `0xFFFF0000` up are reserved: the API refuses them, and leaves their rows out of `changes`.
- A layout may only grow by appending fields: data written earlier reads the same later, and a
  reader holding an older layout decodes a correct prefix. Anything else answers 409.
- A declaration is a transaction that reads the current layout, so two gateways declaring at
  once cannot both "create": the loser retries and finds it unchanged (tested).
- 64-bit fields render as decimal strings, as elsewhere (N33).
- The API reads layouts from the log on each request that needs them (at most once per table
  per request); no cache yet. Measure before adding one.
