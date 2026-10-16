# Phase B storage: what Nerva needs so facts can leave Postgres

Status: **proposal, for the owner to decide** (2026-10-16, pull request #123). Nothing here is
built or decided. Each part becomes its own pull request and decision once agreed, and each
changes a persisted format, so each needs the owner's yes (CLAUDE.md, "Stop" 1).

## Why

GOALS-1.0 G1 ("one log, no dual truth") is what the first application moves to Nerva for, and
Phase A does not deliver it: balances move to Nerva, and every fact (executions, receipts, runs,
leases, acts, obligations, deposits) stays in Postgres. The application's Phase B moves those
facts into the same Nerva transactions as the money they record (Botpike/app,
`docs/specs/nerva-ledger/README.md`, "Phase B"). Three things in Nerva stop that today:

1. **Rows are 80 bytes, keyed by a 64-bit id.** The facts are wider and keyed by 128-bit ids.
2. **Nothing finds a row except by its id.** The application reads facts by foreign key, by
   status and age, and by unique attributes.
3. **Views group only by numeric fields** of one table, so the reports need help.

Commit keys (P123) were the fourth: a lost reply left the client unsure whether a commit applied.
That is built in this pull request.

## What the facts need (inventory of Botpike/app, 2026-10-16)

Sizes are fixed-width estimates; text that is an enum or a short code counts as its code.

| Fact (Postgres table) | Id | Size | Read by (besides id) |
|---|---|---|---|
| execution (`tollbooth.executions`) | UUIDv7, or client-chosen v4 | ≈120 B (+64 B of transfer ids, derivable) | agent, status `reserved` by age (reaper) |
| attempt (`tollbooth.attempts`) | UUIDv7 | ≈100 B | execution, ordered by sequence |
| receipt (`tollbooth.receipts`) | UUIDv7 | 64-byte hash + 0.6–1 KB JCS JSON | execution; hash (unique) |
| proxy execution (`proxy.executions`) | = execution id | ≈260 B | org, lease, rate; status `reserved`/`settling` by age (reaper); claim CAS |
| authorization decision | UUIDv4 | ≈100 B | org by time, decision, deny reason (reports only) |
| run, record half (`runs.runs`) | UUIDv4 | ≈200 B + source (KBs) | org; status queued/running; `ledger_key_hash` (unique, every runtime call) |
| request (`runs.requests`) | (run, request_id text) | ≈110 B + memo | run; run and `held`; `held` anywhere (repair) |
| result, funding | (run, request_id); derived UUIDv3 | value bytes; ≈65 B | run |
| lease, act, obligation | UUIDv7 | ≈150–200 B (text arrays as bitsets) | org, agent, lease, parent lease, source act; status; act idempotency key (unique) |
| deposit (credited) | UUIDv4 | ≈150 B | org; Stripe payment intent (unique) |
| agent and run sequences | agent; (run, agent) | 24 B | id only (CAS) |

What the inventory shows:
- **Every id is 16 bytes.** UUIDv7, v4 and v3, and TigerBeetle-style SHA-256 prefixes.
- **Most facts are 100–260 bytes.** Two are larger and opaque: a run's source and a receipt's
  JSON. Both already fit documents (up to 512 KiB, N76).
- **No query uses SQL `ORDER BY` or `LIMIT`.** Every PostgREST read is an equality filter, or
  `status = X and created_at < cutoff`, and the application sorts in memory. Range scans and
  aggregates live only in SQL functions: the reports and the ops watches.
- **Rows are updated in place.** Status transitions, the claim CAS, and requests going
  null → held → done all rewrite a row. In Nerva that is fine as it is: every put keeps the
  version before it (G6). The Phase B outline's "appended facts" are not needed for history.
- **Unique attributes** (receipt hash, act idempotency key, run key hash, payment intent) need
  no engine feature. A row whose id derives from the attribute, read with `op_seen` 0, is
  compare-and-set (G3). Commit keys are built the same way.

## Proposal

### 1. Records: 128-bit ids, 448-byte values

A second kind of row beside today's, in trees of its own. Today's rows stay as they are:
ledgers, adds and their views use them unchanged.

- **Stored record, 512 bytes:** `key: u128`, `id: u128`, `table: u32`, `flags: u32`, `op: u64`,
  `timestamp: u64`, 8 bytes reserved, then `value: [448]u8`.
  - `key` is the first 16 bytes of SHA-256 of `("nerva.record.v1", table, id)`.
  - Two `(table, id)` pairs sharing a key are refused with `id_collision`, never merged. That is
    about 10⁻²³ for 10⁸ records.
  - The 448 bytes hold the largest fact above with room to grow. Anything larger goes in a
    document, and its hash goes in the record.
- **A wide entry, 512 bytes:** `id: u128`, `table: u32`, `kind: u8`, then `op_seen`, then
  reserved bytes, then a 448-byte value.
  - It carries reads, puts and deletes of records, and every kind today's `Entry` carries for
    rows (a row is a record whose `id` fits 64 bits and whose value is its first 80 bytes).
  - One new operation, `commit_wide`, takes these entries, so a transaction can move money in
    rows and write the facts in records together (G1).
  - `commit` stays, and keeps its number.
- **A wide change** in a tree of its own, and wide `lookup`, `get_changes` and `get_history`.
  The feed of records is ordered by timestamp with rows' feed, so one cursor reads both.
- **Layouts** (N34) extend to records unchanged: a layout packs fields into 448 bytes instead
  of 80. `nerva api` takes `"id"` as 32 hex digits for a record table.
- **Cost:**
  - new `tree_ids` (records 18–19, wide changes 20–21);
  - new operations;
  - a new export-file format version;
  - six times the bytes per write for the tables that use records.

**The alternative not proposed: multi-row records** (several 80-byte rows per fact, as
documents chunk values).
- It needs no new trees, but every reader reassembles records.
- Views and indexes would read fields across rows.
- Ids would stay 64-bit hashes with collisions to handle in the client, as `NervaLedger` does
  today.
- It moves the engine work into every client, which is the opposite of N39's generic surface.

### 2. Declared indexes

An index is a declaration in the log, like a view (N52). The state machine maintains it inside
every commit, under the same per-op budget and admission as view groups.

- **Declaration:**
  - `table`;
  - up to three `eq` fields (any type up to 32 bytes);
  - one `order` field (a `u64`, `i64` or timestamp field, or the row's `op` when none is named);
  - an optional `where` (as views', N52), which makes the index partial. "Executions with
    status `reserved`, by `created_at`" is the reaper's index.
- **Entries:** an index-entries tree keyed by
  `hash64(index id, eq values) << 64 | order value`, composite with the timestamp as LSM
  derived indexes already are, so equal keys coexist. The value names the row.
  - A put that changes an indexed field or the `where` moves its entry.
  - A delete removes it.
  - The `members` tree (N62) works the same way for `min` and `max`, and is the template.
- **Query, `scan_index`:**
  - takes the index, the `eq` values, an `order` range, a limit and a cursor;
  - returns the rows themselves, at the op it executed (G2);
  - drops rows whose `eq` fields only share the hash prefix (false positives) before
    replying.
- **The inventory needs about fifteen indexes:**
  - executions by agent;
  - proxy executions by org, by lease, and by `reserved`/`settling` age;
  - attempts by execution;
  - requests by run, and `held` by run and anywhere;
  - leases by org, agent and parent;
  - acts by lease and by org and time;
  - obligations by org and status;
  - deposits by org.

  The unique attributes need none: they are derived-id rows.
- **As of an op:** not in the first version. The application reads the latest state through
  indexes, and reads the past through views (`as_of`, N62) and history (G6). Index versions can
  come later, as group versions did.
- **Cost:**
  - new `tree_ids`;
  - `declare_index` and `scan_index` operations;
  - an index's backfill by pulses (as views', N52);
  - one entry, of 64 bytes, per indexed row per index.

### 3. Views for the reports

The weekly report and the ops watches group by deny reason, provider and model, agent, and a
time window.

- **`group_by` on `bytes` fields of up to 32 bytes** (provider and model names), alongside
  numeric ones. The group key is already 64 bytes (`group_key_size_max`).
- **Views over records**, as over rows.
- **Time windows are fields the application writes**, such as a `week` or `day` number set
  when the fact is written. A past week is read `as_of` the week's last op, so it is
  reproducible. Nerva interprets no time.
- **Joins stay out.** The report's left join of executions to proxy executions (for provider and
  model) becomes fields copied into the execution when it is written, in the same transaction.

### 4. Retention

None of this deletes. Facts, commit keys (P123) and index entries are kept forever, like
TigerBeetle's transfers. Retention (archive to object storage, README "Object storage tiering")
is a later decision. Nothing above makes it harder: records and index entries carry their op.

## Order of work, and what each unblocks

| Step | Unblocks (Phase B step) | Formats |
|---|---|---|
| Commit keys (P123), **this pull request** | exactly-once commits; deletes most of `NervaLedger`'s P99 machinery | `EntryKind`, `EntryStatus`, reserved table, release `0.0.6` |
| 1. Records and `commit_wide` | facts commit with their money (step 1 onward), with lookups by id | trees, operations, export format |
| 2. Declared indexes | reapers, run repair, consoles, leases (steps 1–3) | trees, operations |
| 3. Views: bytes `group_by`, over records | weekly report, spend rollups, watches (step 6) | view definition |

Steps 1 and 2 are each larger than anything merged so far (comparable to N52's maintained
views). Each would start with a design at the top of its pull request, and a VOPR workload
extended with the model of the new trees, as N52 and N75 were.

## Questions for the owner

1. **Records as proposed (448-byte values, 128-bit ids, `commit_wide`)**, rather than
   multi-row records? Recommended: yes. It keeps clients simple and ids exact.
2. **Indexes without `as_of` at first?** Recommended: yes. Nothing in the inventory reads an
   index in the past.
3. **Is "Nerva holds money only" (Botpike/app P95, 2026-10-07) for now or for good?** This
   design assumes for now. If it is for good, step 1 shrinks to wide ledger rows, and steps 2–3
   are not needed.
