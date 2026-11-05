---
id: N77
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# A table's `min`/`max` slots also fit one op's member budget.

A pulse backfills at most `member_writes_limit / extremes` rows of a view (N62), and every write
to its table takes a member in each of the table's `min`/`max` slots. With a member budget below a
view's slots, the view could never backfill a row and no write to its table could ever be
admitted; `backfill_rows_max` asserted. Production's budget is 8,189, but the VOPR draws its batch
size at random, and its lanes on `main` (N74) hit this on four of four lanes across two pushes
(#68; seed 17320319949900435868 at `28cbd79`). Declaration now allows a table's views at most
`min(view_extremes_per_table_max, member_writes_limit)` slots (`table_extremes_max`) and refuses
more with `table_extremes_full`, as the VOPR's model does. Production is unchanged. Verified: the
failing seeds now pass (the first refuses one declaration `table_extremes_full`), as do seeds 1,
2, 5 and 30 random ones in ReleaseSafe.
