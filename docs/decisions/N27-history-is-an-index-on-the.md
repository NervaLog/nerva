---
id: N27
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# History is an index on the change feed: `get_history`.

G6 asks for any row as of any op. The change feed already keeps every write with its op and
value, so history needs no second copy of the data: a derived index `row_key(table, id)` on
`Change` (tree id 4) orders each row's writes by timestamp, and timestamps increase with op.
`get_history` scans one row's changes newest first from a cursor (`timestamp_max`) and returns
those with `op <= op_max`. Changes after `op_max` are skipped, but they count toward `limit`,
so every call is bounded and pages on. The cursor counts down, and `end.op` is the query's op
once the history is exhausted (as for `get_changes`). `op_max = 0` is invalid rather than
meaning "no bound", because "as of op 0" must not quietly read the latest (caught by the first
unit test); clients pass `maxInt(u64)` for the latest. Cost: 32 bytes of index per write. History
is kept forever: pruning is not a 1.0 goal. Changed now because no Nerva data has been deployed.
