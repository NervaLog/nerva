---
id: N69
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# A `nerva api` request may allocate at most 128 MiB, and is given back when it answers.

Request bodies are parsed into `std.json.Value` in a per-request arena, which costs many times
the body for nested or long arrays, and the arena was reset with `.retain_capacity`, so one
4 MiB body pinned its peak for the gateway's life (#31; measured at `825355c`: 91 to 788 MiB for
nested arrays, 527 MiB for a long one). A request now allocates through `MemoryBudget`
(`src/nerva/api/memory_budget.zig`), over the arena: it counts the bytes the request asks for,
refuses an allocation past 128 MiB, and records it, so the gateway answers
`413 {"error":"request too complex"}` instead of 500 and serves on. The arena is reset as soon as
the reply is written (`respond` writes it before returning), keeping at most 8 MiB. A budget,
rather than limits on JSON depth or array length, bounds every shape of body at once.
- **Above the arena, not below** (#60). #57 first put the budget below the arena, at 64 MiB.
  But `ArenaAllocator` sizes each new block from the last one plus the request, so below it the
  budget counted several times what the request asked for: the largest valid request, a
  `documents/get` of 256 documents of 64 KiB, asks for about 100 MB (rows, chunks, values, hex
  reply) yet counted 330 MiB, and was refused. Above the arena the budget counts requests, and
  128 MiB holds that `get`. The cost is that the memory the arena touches can reach two to three
  times the budget for a moment (about 290 MiB for the nested-array body, from 788 MiB), and it
  is given back at once. The `get` reply is also sized up front, so it is not copied as it grows.
Tests: unit tests of the budget (refusal, frees, a request over an arena failing on nested JSON,
then the next fitting); `test:api` sends both bodies (413) and checks the gateway's RSS returns
within 100 MiB of where it was (93 MiB, then 101 MiB), and that the largest valid
`documents/get` answers 200.
