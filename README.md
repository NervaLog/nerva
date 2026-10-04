# Nerva

A database where **derived state is declared, not hand-built**.

Today, keeping caches, search indexes, aggregates, embeddings, client sync feeds and audit
history consistent with source data means CDC pipelines, queues, consumers and backfill scripts.
Nerva's bet: one ordered, replicated, hash-chained log; base data and every derived view are
deterministic functions of it, and every read says which log position it reflects.

> Status: **toy / research.** Only the foundation exists so far — see [Roadmap](#roadmap).

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

Nerva's own code lives in `src/nerva.zig` (public types) and `src/nerva/` (state machine).

## Building

```bash
./zig/download.sh             # Pinned Zig 0.14.1 (falls back to PyPI if ziglang.org is blocked)
./zig/zig build check         # Typecheck
./zig/zig build test:unit     # Unit tests
./zig/zig build test          # Unit tests + format check
./zig/zig build vopr -- 42    # Simulate a cluster under faults with seed 42
./zig/zig build fuzz -- smoke # Quick pass over all fuzzers
```

Linux (io_uring) or macOS; x86_64 with AES or aarch64.

## Roadmap

1. **Foundation** — vendored consensus + storage + simulator, placeholder state machine. ✅
2. **Commit core** — row model, optimistic read-set validation, versioned base rows; VOPR
   workload with a linearizability checker.
3. **Server and client protocol** — `nerva format` / `nerva start`, a minimal client.
4. **First derived view** — one incremental view, a watermark, and reads at a position.
5. **Snapshots and subscriptions** — reads as of op `N`; change cursors.
6. **Object storage tiering**, external operators, effect sinks.

## License

Apache 2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
