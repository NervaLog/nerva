---
id: N33
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# A general JSON API: `nerva api`.

The public demos (seat booking, then a shared canvas) and any non-Zig user need Nerva's
operations without an application-specific protocol. `nerva api` is a thin translation: five routes
(`lookup`, `commit`, `changes`, `history`, `row`), each one Nerva request, and no application
concepts. Choices:
- 64-bit numbers are decimal strings, because JavaScript loses precision past 2^53. `table` and
  `limit` are numbers.
- A value is hex: up to 80 bytes, zero-padded on write; reads always return all 80 bytes, so
  what comes back is exactly what is stored.
- One commit request is one transaction. The answer is `200` committed, `409` conflict (with the
  stale entry's index and the row's current version, so the caller can retry from it), or `400`
  for a row written twice or an invalid entry. Entries are validated before they reach the
  cluster, so the core's other entry statuses cannot occur.
- Unknown fields, unknown or repeated query parameters, and non-decimal numbers are refused,
  not ignored.
- `row?as_of=` first checks that the op is committed (a lookup's own op is newer than every
  committed op). The end-to-end test caught the first version answering for a future op.
- Keyed by `X-Nerva-Key` from `NERVA_KEY`. Sequential; run more gateways for throughput.
