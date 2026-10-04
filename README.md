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
| `commit` | `Entry` → `EntryResult` | One batch is one transaction of `read` (asserts `op_seen`), `put` and `delete` entries. If any read is stale (`conflict`) or any entry invalid, nothing applies and the other entries report `aborted`; otherwise every entry reports `ok` with the commit op. |
| `get_changes` | `ChangesFilter` → `Change[]` | Committed writes in op order from a timestamp cursor, ending with an `end` record that carries the next cursor and, when complete, the op the feed reflects. |
| `get_history` | `HistoryFilter` → `Change[]` | One row's writes, newest first, through an index on the change feed. With `op_max = N`, the first change returned is the row as of op `N` (`Client.row_as_of`). |

Commits execute serially in op order, so validating each read's version at commit time gives
serializable transactions over point reads. The VOPR workload checks every reply against an
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

## The Botpike runtime's ledger

`nerva ledgerd` serves the [Botpike runtime](https://github.com/Botpike/runtime)'s ledger
protocol (`POST` `key=value` lines, `X-Ledger-Key`) from a Nerva cluster: a drop-in for the
runtime's reference `ledgerd.py`, with every route one Nerva transaction.

```bash
LEDGER_KEY=secret ./zig-out/bin/nerva ledgerd --cluster=0 --addresses=3001,3002,3003 \
    --ledger=1 --listen=127.0.0.1:8090
./brt backend http://127.0.0.1:8090 secret   # in Botpike/runtime
```

`zig build test:ledgerd` checks it against `ledgerd.py` request by request (byte-identical
replies, scripted scenarios plus a seeded fuzzer), races two gateways on one ledger, and checks
the views below against `ledgerd.py`'s own files.

How to run the runtime on Nerva, phase by phase: [docs/BOTPIKE-INTEGRATION.md](./docs/BOTPIKE-INTEGRATION.md).

`/v1/store/get` and `/v1/store/put` (`name_hex`, `value_hex`) serve the runtime's `Store`
ability, the agent state its daemon otherwise keeps as files in a state directory:
continuations, code and receipts. They live outside the ledger's generations, so
`/v1/admin/init` keeps them. `ledgerd.py` has no such routes; `tests/ledgerd/store.py` checks
them against a model.

## Views

`nerva view` follows the change feed and serves derived views of every ledgerd ledger, each
reply stamped with the op it reflects:

```bash
LEDGER_KEY=secret ./zig-out/bin/nerva view --cluster=0 --addresses=3001,3002,3003 \
    --listen=127.0.0.1:8091
curl -H 'X-Ledger-Key: secret' 'http://127.0.0.1:8091/v1/views/1/spend?min_op=latest'
```

- `journal`: the ledger's journal lines in commit order, each with the op that wrote it.
- `spend`: Botpike's agent spend rollup (own and subtree spend, settled and denied counts,
  depth) over the agent tree in the runtime's request ids.

`min_op=<n>` waits until the view has applied op `n` (read-your-writes); `min_op=latest` first
reads the feed to its end. Views live in memory and are rebuilt from the feed on restart.

Any ledger key can be read as it was at any op, such as the op of a journal line, to see what
an agent's allowance was when it decided:

```bash
curl -H 'X-Ledger-Key: secret' \
    'http://127.0.0.1:8091/v1/ledgers/1/as_of?op=1234&key_hex=617661696c61626c65'
```

Decisions and their reasons: [docs/DECISIONS.md](./docs/DECISIONS.md).

## Roadmap

The 1.0 target, with Botpike as first customer, is in [docs/GOALS-1.0.md](./docs/GOALS-1.0.md).

1. **Foundation** — vendored consensus + storage + simulator, placeholder state machine. ✅
2. **Commit core** — row model, optimistic read-set validation, versioned base rows; VOPR
   workload with a model checker. ✅
3. **Server and client protocol** — `nerva format` / `nerva start`, a Zig client, and
   `nerva ledgerd` serving the Botpike runtime's ledger protocol. ✅
4. **First derived view** — one incremental view, a watermark, and reads at a position. ✅
   (`nerva view`: `journal` and `spend` over ledgerd ledgers.)
5. **Snapshots and subscriptions** — reads as of op `N` ✅ (`get_history`, `as_of`); change
   cursors ✅ (`get_changes`); view snapshots.
6. **Object storage tiering**, external operators, effect sinks.

## License

Apache 2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
