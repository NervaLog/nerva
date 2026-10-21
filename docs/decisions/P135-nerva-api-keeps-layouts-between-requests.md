---
id: P135
date: 2026-10-21
area: "Milestone 3: positioned reads and the first views"
amends: N34
---

# `nerva api` keeps table layouts between requests, and a kept layout never makes an answer wrong

A Botpike submit is a `POST /v1/lookup` then a `POST /v1/commit` with `fields` on three tables.
Each request read every table's layout document from the log, 8 of a submit's ~9 log ops (#134),
about 0.7 ms each and more under load.

- **The gateway keeps layouts** (`src/nerva/api/layout_cache.zig`): at most 64 tables, plain data
  allocated with the gateway, the oldest replaced when full, each with the version (the op of
  chunk 0) of its catalog document. Every write of a document rewrites all its chunks together
  (N48), so the version identifies the content. Only present layouts are kept. The cache is cleared
  when the cluster client is replaced and a table's entry is dropped when this gateway writes its
  layout. A request copies what it uses into its arena.
- **A write is exact without any check.** A layout only grows by appending fields
  (`layout_extends`), and `fields_encode` and `add_parse` use a named field's offset, size and type
  alone: absent fields are zero, unknown fields are refused. The bytes a put or add produces under
  a layout that is behind the log are the ones the log's layout produces, or the request is
  refused. A 400 raised after a kept layout was used is answered only after the request runs again
  with every layout read from the log (which also refreshes the cache), so a field another gateway
  added is never refused. The commit's entries, indices and the key's checksum are unchanged.
- **A read is checked.** A lookup of rows adds the kept layouts' catalog rows to its own
  `lookup_rows`, so they are read at the same op, and compares their ops with the kept versions; a
  layout that moved is read again before rendering. If the extra rows do not fit the batch
  (`TooManyEvents`), or the lookup is of records (which cannot mix with rows, P123b), they are read
  by a `lookup_rows` that follows, which is as exact: the layouts were kept before the request
  began, and the gateway serves one request at a time, so an unchanged version later is unchanged
  at the lookup's op.
- **Not kept**: `changes`, `history`, `row`, `index_scan` (they render fields; no hot path) and
  views, ledgers and indexes keep reading the log for each request.

Considered and rejected: gateway-owned `read` entries on the layout rows inside the commit. They
change the entries a key's checksum covers, so a resend after another gateway extended the layout
would answer `key_reused` instead of `committed_before`; and they are not needed (see "A write is
exact").

Cost: a gateway keeps up to 64 layouts (about 50 KiB); a lookup reads one more catalog row per
kept layout it names, in the same op; an invalid request that used a kept layout reads the layouts
once more before it is refused. A submit's log ops drop from 8 to 2 in a three-table test.
