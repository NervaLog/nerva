# Nerva

A database where **derived state is declared, not hand-built**.

Today, keeping caches, search indexes, aggregates, embeddings, client sync feeds and audit
history consistent with source data means CDC pipelines, queues, consumers and backfill scripts.
Nerva's bet: one ordered, replicated, hash-chained log; base data and every derived view are
deterministic functions of it, and every read says which log position it reflects.

> Status: **toy / research.** The foundation and the commit core exist — see [Roadmap](#roadmap).

## Design in one picture

```
 clients ──writes──▶  ┌──────────────────────────┐
   │                  │  CORE  (3–6 nodes, NVMe) │   VSR consensus,
   │                  │  validate + append       │   deterministic, single-threaded
   │                  │  base rows (MVCC by op)  │
   │                  └────────────┬─────────────┘
   │                               │ log tail (op, delta)
   │                  ┌────────────▼─────────────┐
   │   reads @op ◀────│  VIEW WORKERS (elastic)  │   incremental dataflow per view
   │   subscribe ◀────│                          │
   │                  └────────────┬─────────────┘
   │                               │ sealed segments, view snapshots
   │                  ┌────────────▼─────────────┐
   └──backfill/history│  OBJECT STORAGE          │
                      └──────────────────────────┘
```

- **Core.** Interactive transactions execute against a snapshot at op `N`, holding no locks.
  Commit submits the read set and write set; the core validates that nothing read has changed
  since `N` (optimistic concurrency), appends to the log and returns op `M`. That small operation
  is the only thing that goes through consensus.
- **Views.** Each view is a dataflow over the log, maintained incrementally by workers, with a
  watermark ("applied through op `N`"). Synchronous views (indexes, uniqueness) are maintained
  inside the commit; everything else is asynchronous with a measurable lag.
- **Reads carry positions.** Writes return their op; reads ask for "at least op `M`"
  (read-your-writes on asynchronous views) or "as of op `N`" (time travel). Subscriptions are
  cursors over a view's changes: device sync, CDC and cache invalidation are the same mechanism.
- **Verifiable derived state.** Deterministic views are byte-identical functions of the log, so
  replicas can compare hashes of view state at op `N`.
- **Recorded non-determinism.** External operators (embedding models, classifiers) record their
  outputs in a side log keyed by input hash and model version; replays read the recording.
- **Effects are views.** A view whose sink sends email or calls an API gets an idempotency key of
  `(view, row key, op)`: exactly-once side effects after commit.

## Foundation

Consensus (Viewstamped Replication with flexible quorums and protocol-aware recovery), storage
(LSM forest on a checksummed block grid with physical repair), io_uring IO and the VOPR
deterministic simulator are vendored from [TigerBeetle](https://github.com/tigerbeetle/tigerbeetle).
See [UPSTREAM.md](./UPSTREAM.md) for exactly what was taken and changed.

Nerva's own code lives in `src/nerva.zig` (public types) and `src/nerva/` (state machine,
simulator workload and tests).

## Commit core

Rows are identified by `(table, id)` and hold a fixed 80-byte value. A row's **version** is the
op of its last write; zero means it has never existed, and deletes leave a tombstone so versions
stay exact. Four operations:

| Operation | Event → result | Semantics |
|---|---|---|
| `lookup_rows` | `RowKey` → `RowValue` | Point reads: value, `exists`, and version. |
| `commit` | `Entry` → `EntryResult` | One batch is one transaction of `read` (asserts `op_seen`), `put`, `delete` and `add` entries. If any read is stale (`conflict`), any add cannot apply, or any entry is invalid, nothing applies and the other entries report `aborted`; otherwise every entry reports `ok` with the commit op, and each add what it applied and the field's new value. |
| `get_changes` | `ChangesFilter` → `Change[]` | Committed writes in op order from a timestamp cursor, ending with an `end` record that carries the next cursor and, when complete, the op the feed reflects. |
| `get_history` | `HistoryFilter` → `Change[]` | One row's writes, newest first, through an index on the change feed. With `op_max = N`, the first change returned is the row as of op `N` (`Client.row_as_of`). |

Commits execute serially in op order, so validating each read's version at commit time gives
serializable transactions over point reads.

An **add** changes one 64-bit field (`u64` or `i64`, at a byte offset) inside the commit, with
no read: adds to one row never conflict, they apply in log order. An add never moves a field
past a bound (`min`, `max`, or the type's range) in the direction it moves: it fails the
transaction with `out_of_bounds`, or with `clamp` adds as much as fits. `delta_from` moves what
an earlier add of the transaction applied, so "reserve up to 30, and hold what was taken" is two
adds that can never overdraw and never retry. A row that does not exist is `row_absent` unless
the add has `create`. Each add is an ordinary change in the feed (the whole new row), so
history, as-of reads and views see it like a put. The VOPR workload checks every reply against an
in-memory model replayed in op order.

## Building

```bash
./zig/download.sh             # Pinned Zig 0.14.1 (falls back to PyPI if ziglang.org is blocked)
./zig/zig build check         # Typecheck
./zig/zig build test:unit     # Unit tests
./zig/zig build test          # Unit tests + format check
./zig/zig build vopr -- 42    # Simulate a cluster under faults with seed 42
./zig/zig build fuzz -- smoke # Quick pass over all fuzzers
./zig/zig build test:integration  # Three real replicas + the client (~3.5 GiB disk, 3 GiB RAM)
./zig/zig build               # Builds zig-out/bin/nerva
```

Linux (io_uring) or macOS; x86_64 with AES or aarch64.

CI (`.github/workflows/ci.yml`) runs on every push and pull request to `main`: typecheck, format,
unit, integration, API, view and demo tests, and the VOPR on seeds 1, 2, 5 and one random seed (printed,
so a failure replays). A commit to `main` that changes `VERSION` runs CI on that commit, then
publishes binaries for Linux and macOS (x86_64, aarch64) as GitHub release `v<VERSION>`
(`release.yml`), with that version's section of [CHANGELOG.md](./CHANGELOG.md) as the release
notes; releasing a version twice, or without notes, fails.

Binaries report `<protocol>+<commit>`. The protocol release (`0.0.2` since adds, N43) is what
replicas, clients and data files check: binaries of different protocol releases do not mix in
one cluster, and data files formatted by v0.1.0 (protocol `0.0.1`) must be reformatted.

## Running a cluster

```bash
# One data file per replica (cluster id 0 is reserved for test builds).
./zig-out/bin/nerva format --cluster=0 --replica=0 --replica-count=3 0_0.nerva
./zig-out/bin/nerva format --cluster=0 --replica=1 --replica-count=3 0_1.nerva
./zig-out/bin/nerva format --cluster=0 --replica=2 --replica-count=3 0_2.nerva

# Every replica gets every address, in replica order.
./zig-out/bin/nerva start --addresses=3001,3002,3003 0_0.nerva   # and 0_1, 0_2
```

`--development` relaxes Direct IO and uses small caches. Clients use `src/nerva/client.zig`:
`lookup_rows`, `commit` and `get_changes`, blocking, one request in flight per client.

## JSON API

`nerva api` serves the core operations as JSON over HTTP, for any language:

```bash
NERVA_KEY=secret ./zig-out/bin/nerva api --cluster=1 --addresses=3001,3002,3003 \
    --listen=127.0.0.1:8080
curl -H 'X-Nerva-Key: secret' -d '{"entries":[{"kind":"put","table":1,"id":"5","value_hex":"c0ffee"}]}' \
    http://127.0.0.1:8080/v1/commit        # {"status":"committed","op":"42"}
```

| Route | Does |
|---|---|
| `POST /v1/lookup` `{"rows":[{"table","id"}]}` | Point reads: `exists`, version `op`, `value_hex`, and the `op` read at. |
| `POST /v1/commit` `{"entries":[…]}` | One transaction of `read` (with `op_seen`), `put` (with `value_hex`), `delete` and `add` (`field`, or `offset` and `type`; `delta` or `delta_from`; optional `min`, `max`, `clamp`, `create`). `200` committed with its `op` and each add's `applied` and `value`; `409` conflict with the stale entry's `index` and the row's current `op`, or `out_of_bounds` (with the field's `value`) or `row_absent` for an add; `400` invalid. |
| `GET /v1/changes?cursor=&limit=` | The change feed, paged. |
| `GET /v1/history?table=&id=&op_max=&cursor=&limit=` | One row's writes, newest first, up to `op_max`. |
| `GET /v1/row?table=&id=&as_of=` | One row as it was at an op (refused for an op not yet committed). |
| `PUT /v1/tables/<t>` `{"name","fields":[{"name","type"}]}` | Declare a table's layout (u8, u16, u32, u64, i64, bool, bytes), or extend it by appending fields. Then puts may send `fields` instead of `value_hex`, and reads return `fields`. |
| `GET /v1/tables/<t>` | The table's layout. |

64-bit numbers (ids, ops, cursors) are decimal strings; values are the 80 bytes as hex. Layouts
live in the log, in a reserved catalog table; the core still stores bytes and never reads them.

**Documents** hold values larger than a row: up to 64 KiB under a string key (up to 1024 bytes
of UTF-8) in a namespace (a `u64`, as a decimal string). Nerva chunks them over rows of a
reserved table:

| Route | Does |
|---|---|
| `POST /v1/documents/get` `{"namespace","keys":[…],"as_of"?}` | Up to 256 keys as of one op (the latest, or `as_of` a committed op): `exists`, `version` (the op of the last write, `"0"` if never written), `value_hex`. |
| `POST /v1/documents/commit` `{"namespace","reads":[{"key","version"}],"writes":[{"key","value_hex"} or {"key","delete":true}]}` | One transaction. `200` committed with its `op`; `409` with the stale read's `key` and current `version`; `400` invalid. About 600 KB of keys and values per commit. |
| `GET /v1/documents/changes?namespace=&cursor=&limit=` | The namespace's document writes in commit order (`key`, `op`, `kind` put or delete, `value_hex`), paged like `/v1/changes`. |

`zig build test:api` checks every route against a model (documents included), races eight
writers on one row and on one document, and races fifty reservations on one budget with adds
(none retried).

## Declared views

A view is a declaration in the log, not code. Declare a table's layout, then a view over it,
through `nerva api`; read it from `nerva view`, latest or as of any op:

```bash
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/views/revenue -d '{
  "table": 5, "where": [{"field": "sold", "op": "eq", "value": true}],
  "group_by": ["section"], "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"}]}'
curl -H 'X-Nerva-Key: secret' 'http://127.0.0.1:8091/v1/views/revenue?as_of=1234'
# {"view":"revenue","op":"1234","hash":"…","groups":[{"section":1,"count":"12","sum_price":"5400"},…]}
```

`where` ANDs comparisons (`eq`, `ne`, `lt`, `le`, `gt`, `ge`) on numeric and bool fields;
`group_by` takes up to three fields; aggregates are `count`, `sum`, `min` and `max`. A view
answers for any op, including ops before it was declared, and every answer carries the SHA-256
of its groups, so two view processes can show they agree. v0 keeps tables and their changes in
`nerva view`'s memory (at most two million changes) and computes a view when it is read.
`min_op=<n>` waits until the view process has applied op `n` (read-your-writes); views are
rebuilt from the feed when the process restarts. `zig build test:views` checks views against a
model on two view processes.

## Demos

[demo/](./demo/README.md) holds public demos built only on the pieces above: a seat race (512
seats, simulated buyers; buy, rewind the show to any op, crash any process, declare views) and
a shared canvas (paint, play the timelapse, crash, declare). `zig build test:demo` runs both
under random crashes.

Decisions and their reasons: [docs/DECISIONS.md](./docs/DECISIONS.md).

## Roadmap

The 1.0 target is in [docs/GOALS-1.0.md](./docs/GOALS-1.0.md).

1. **Foundation** — vendored consensus + storage + simulator, placeholder state machine. ✅
2. **Commit core** — row model, optimistic read-set validation, versioned base rows; VOPR
   workload with a model checker. ✅
3. **Server and client protocol** — `nerva format` / `nerva start`, a Zig client, and
   `nerva api` (JSON over HTTP). ✅
4. **Declared views** — layouts and views as data in the log, a watermark, reads at a position,
   a hash per answer. ✅ (v0 computes on read; incremental maintenance next.)
5. **Snapshots and subscriptions** — reads as of op `N` ✅ (`get_history`, `row?as_of=`, views
   `as_of`); change cursors ✅ (`get_changes`); view snapshots.
6. **Object storage tiering**, external operators, effect sinks.

## License

Apache 2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
