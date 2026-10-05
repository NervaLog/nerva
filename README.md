# Nerva

A database where **derived state is declared, not hand-built**.

Today, keeping caches, search indexes, aggregates, embeddings, client sync feeds and audit
history consistent with source data means CDC pipelines, queues, consumers and backfill scripts.
Nerva's bet: one ordered, replicated, hash-chained log; base data and every derived view are
deterministic functions of it, and every read says which log position it reflects.

> Status: **toy / research.** The foundation and the commit core exist — see [Roadmap](#roadmap).

New here? [docs/TUTORIAL.md](./docs/TUTORIAL.md) walks through a running cluster, every API
and the code, step by step.

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
stay exact. The operations:

| Operation | Event → result | Semantics |
|---|---|---|
| `lookup_rows` | `RowKey` → `RowValue` | Point reads: value, `exists`, and version. |
| `commit` | `Entry` → `EntryResult` | One batch is one transaction of `read` (asserts `op_seen`), `put`, `delete` and `add` entries. If any read is stale (`conflict`), any add cannot apply, or any entry is invalid, nothing applies and the other entries report `aborted`; otherwise every entry reports `ok` with the commit op, and each add what it applied and the field's new value. |
| `get_changes` | `ChangesFilter` → `Change[]` | Committed writes in op order from a timestamp cursor, ending with an `end` record that carries the next cursor and, when complete, the op the feed reflects. |
| `get_history` | `HistoryFilter` → `Change[]` | One row's writes, newest first, through an index on the change feed. With `op_max = N`, the first change returned is the row as of op `N` (`Client.row_as_of`). |
| `declare_view` | `ViewDefinition` → `DeclareResult` | Declares a view maintained from then on by every commit, with its fields resolved to offsets (N52). |
| `get_view` | `ViewQuery` → `ViewRecord[]` | A maintained view's state, hash and group count, and a page of its groups (N52). |
| `pulse` | — | Sent by the cluster to itself while a view is building: adds a bounded number of existing rows to it (N52). |

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

CI (`.github/workflows/ci.yml`) runs on every push and pull request to `main` that changes more
than Markdown (N68): typecheck, format,
unit, integration, API, view, mixed-release and demo tests, every fuzzer at its smoke size, and the VOPR on seeds 1,
2, 5 and one random seed (printed, so a failure replays), as parallel jobs (N57). A commit to `main` that changes `VERSION` runs CI on that commit, then
publishes binaries for Linux and macOS (x86_64, aarch64) as GitHub release `v<VERSION>`
(`release.yml`), with that version's section of [CHANGELOG.md](./CHANGELOG.md) as the release
notes; releasing a version twice, or without notes, fails. Each release also carries its bill of
materials, `nerva-v<VERSION>.cdx.json` (CycloneDX 1.5, N63): Nerva, the vendored TigerBeetle
commit, and the Zig standard library and compiler, read from the repository's pins and covered
by `SHA256SUMS`. A separate workflow,
`fuzz.yml`, runs every fuzzer and the VOPR on random seeds for a time budget; it is started by hand
on runners brought up for it.

Binaries report `<protocol>+<commit>`. The protocol release (`0.0.4` since views' `min`, `max`
and `as_of`, N62) is what data files and clients check: a replica refuses a data file of another
release, so upgrading means reformatting, and accepts clients of its own release only (a v0.3.0
`nerva api` is refused at registration). A replica ignores peers that
run another release (N61): in a cluster mixing releases, only replicas of one release count
toward each other's quorums, and each logs the others it ignores. Upgrade by stopping every
replica, reformatting, and starting them all on the new release. `zig build test:release` runs a
cluster of two releases.

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

### Metrics and traces

`nerva start --statsd=<host:port>` sends the replica's metrics over UDP every 10 seconds, in
statsd format with DogStatsD tags (`|#cluster:…,replica:N`). `--trace=<path>` writes a JSON span
trace for [Perfetto](https://ui.perfetto.dev) or `chrome://tracing` to a new file (it refuses
an existing one); tracing slows the replica, so use it to diagnose, not to time. The trace is
written 64 KiB at a time and stops at `--trace-size-max` (default 1 GiB), or if writing it fails,
with a warning in the log; the replica runs on (N71). The metrics most useful for performance work:

| Metric | What it measures |
|---|---|
| `tb.replica_request_us.*` (tag `operation:Operation.<op>`) | From the primary first seeing a request to this replica committing it (`min`, `max`, `avg`, `sum`, `count`) |
| `tb.replica_request_local_us.*` (tag `operation`) | This replica's own commit of the request |
| `tb.replica_request_execute_us.*` (tag `operation`) | Executing the request in the state machine |
| `tb.replica_commit_us.*` (tag `stage`) | Each commit stage: `prefetch`, `stall`, `execute`, `compact`, `checkpoint_*` and others |
| `tb.replica_prepare_ok_quorum_us.*` | From prepare to a replication quorum |
| `tb.compact_beat_us.*`, `tb.compact_mutable_us.*` (tag `tree`) | Compaction work per LSM tree |
| `tb.lookup_us.*`, `tb.scan_tree_us.*` (tag `tree`) | Point lookups and scans per tree |
| `tb.storage_read_us.*`, `tb.storage_write_us.*` (tag `zone`) | Disk IO by data file zone |
| `tb.grid_cache_hits`, `tb.grid_cache_misses` | Block cache effectiveness (gauges) |
| `tb.replica_commit_min`, `tb.replica_commit_max`, `tb.replica_pipeline_queue_length` | Progress and backlog (gauges) |

Timings are aggregated over each 10-second window. The `tb.` prefix and tag spellings come from
TigerBeetle's tracer (UPSTREAM.md).

### Caches

`--cache-grid` sizes the block cache. `--cache-rows=<size>` sizes the row cache (128 bytes a row,
rounded down to whole cache sets); it defaults to its minimum, one set of a few hundred rows.

### Benchmarks

```bash
./zig/zig build bench                         # every `benchmark:` test, ReleaseSafe
./zig/zig build bench -- "benchmark: documents"
./zig/zig build -Drelease bench:load -- --local --workload=c7 --clients=4 --seconds=30
./zig/zig build -Drelease bench:load -- --addresses=<addresses> --workload=c4 --batch=64 \
    --rate=2000 --output=c4.json
```

`zig build bench` prints each result for people and, from `Bench.metric`, one
`bench-json: {"name":…,"value":…,"unit":…}` line for machines. `bench:load` drives a cluster
with one thread and one client per `--clients` (`--local` starts a three-replica `--development`
cluster, at most 6 clients) and prints one JSON object: operations and entries per second,
conflicts and retries, and latency percentiles in µs. Workloads: `c1` puts, `c2`
read-modify-write, `c3` hot rows with retries, `c3_adds` hot rows with adds, `c4` lookups, `c5`
change feed, `c7` mixed. `--rate=0` (default) is a closed loop; `--rate=<n>` an open loop whose
latencies count from each request's due time. Use `-Drelease` so the `nerva` it starts is a
release build.

### Nightly performance

`.github/workflows/perf-nightly.yml` runs every night at 06:47 UTC (and by hand, with any
candidate and baseline). It builds the candidate (`main`) and the baseline (the last night that
passed), then `perf/nightly/fly-run.sh` creates one Fly Machine for the night, runs both builds
there in alternating rounds (`perf/nightly/run.sh`: every benchmark, then the `bench:load`
workloads against three production-config replicas), and destroys it. `perf/nightly/compare.py`
compares the rounds pairwise: a metric that is worse than its threshold in every round fails the
night and files a `perf-regression` issue; it never blocks a release. Results go to the
`perf-results` branch. The job needs the repository secret `FLY_API_TOKEN_PERF`.

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

Both gateways (`nerva api`, `nerva view`) execute one request at a time but read up to 16
connections at once, so a slow client holds up nobody; with all 16 busy, a new connection
displaces the oldest one still sending its request. A request must arrive whole within 10 s
of connecting and carries one request per connection (`Connection: close`). If a gateway
loses its cluster session (a request times out after 30 s, or the session is evicted), it
answers `503` and `/healthz` answers `503`, and it reconnects on its own, trying at most every
5 s whether or not requests arrive (N64); `nerva view` then reads the feed on from where it
stopped. Heads are parsed
strictly: lines end in CRLF, bodies have a `Content-Length` (no `Transfer-Encoding`), and
anything malformed answers `400`. A body is at most 4 MiB, and a `nerva api` request may
allocate at most 128 MiB: a body that would take more once parsed (deeply nested or very long
JSON arrays) answers `413 {"error":"request too complex"}`. What a request took is given back as
soon as its reply is written; the gateway keeps at most 8 MiB between requests (N69).

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
through `nerva api`, and read it there, latest or as of any op since it was declared:

```bash
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/views/revenue -d '{
  "table": 5, "where": [{"field": "sold", "op": "eq", "value": true}],
  "group_by": ["section"], "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"}]}'
curl -H 'X-Nerva-Key: secret' 'http://127.0.0.1:8080/v1/views/revenue?as_of=1234'
# {"view":"revenue","op":"1234","hash":"…","view_hash":"…","declared_op":"812",
#  "groups":[{"section":1,"count":"12","sum_price":"5400"},…]}
```

`where` ANDs comparisons (`eq`, `ne`, `lt`, `le`, `gt`, `ge`) on numeric and bool fields;
`group_by` takes up to three fields; aggregates are `count`, `sum`, `min` and `max`.

**Maintained by the replicas** (N52, N62, N66). The state machine keeps every view inside every
commit, like the rows: each write updates its row's groups, and every replica holds the same
groups at every op. Reading a view reads its groups, not the rows, and nothing is lost when a
process restarts.

- `GET /v1/views/<name>` answers with the whole view, groups sorted by key, read at one op.
  `hash` is the SHA-256 of the `groups` JSON exactly as served; `view_hash` is the replicated
  hash, the sum modulo 2^256 of the groups' digests, the same at every replica. `as_of=<op>`
  reads the view as that op left it (`404` before it was declared); `min_op=<n|latest>` asks for
  at least op `n`. Either answers `504` for an op not yet committed, and a view still building
  answers `503`. A view of more than 10,000 groups is read in pages instead:
- `GET /v1/views/<name>/groups?cursor=&limit=&as_of=` pages through the groups in storage order,
  with the view's state, `view_hash` and group count.
- `GET /v1/views` lists the views (name, id, state, `declared_op`, group count);
  `GET /v1/views/<name>/definition` is the declaration.
- A view declared over rows that already exist is `building` until pulses (which the cluster
  runs by itself) have added them, a bounded number per op; then `ready`.
- An `add` to a field a view filters or groups by is refused (`409 view_key_field`); adds to
  summed fields are what views are for.
- One op touches at most about 4,000 distinct groups and 8,000 `min` and `max` members (a write
  takes one in each such slot of its table), however many writes it has: a transaction writes
  at most about 4,000 rows of a table with two such slots, 2,000 with four. A transaction that
  exceeds them on its own is refused whole (`413 views_too_large`): it never fits, so split it.
  `503 views_busy` is only for a request that packs several transactions (Nerva's clients send
  one each), when earlier ones filled the op: nothing applied, retry it.
- `min` and `max` stay exact when the row holding them is deleted, moved or changed: the state
  machine keeps each group's values in order (N62). A table's views have at most four `min` and
  `max` aggregates between them (a fifth is refused: `"maintained": false`).
- Every op that changes a view keeps a version of it and of each group it changed, so history
  grows with writes, as rows' does. A read as of an op scans only for the groups changed since.

**Recomputed by `nerva view`** (N35). `nerva view` follows the change feed, keeps tables and
their changes in memory (at most two million changes), and computes a view when it is read, the
same `GET /v1/views/<name>` with the same answer: the same groups and the same `hash`, byte for
byte. It answers for any op, including ops before a view was declared, and `min_op=<n>` waits
until it has applied op `n`. It is the independent check on the replicas: the demos show the
two hashes side by side.

`zig build test:views` checks `nerva view` against a model on two view processes, and the
maintained views (latest and as of past ops, with `min` and `max`, whole and in pages) against
`nerva view`, byte for byte.

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
