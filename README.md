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
| `declare_ledger` | `LedgerDefinition` → `DeclareLedgerResult` | Declares a ledger: conserved fields that only pairs of adds change (N75). |
| `get_ledger` | `LedgerQuery` → `Ledger` | A ledger by id, or, when `id` is zero, the `slot`th declared (from 1), to list them (N80). |
| `pulse` | — | Sent by the cluster to itself while a view or an index is building: adds a bounded number of existing rows or records to it (N52, P123c). |
| `commit_wide` | `WideEntry` → `EntryResult` | `commit` for transactions that write records as well as rows (below), under the same rules (P123b). |
| `lookup_records`, `get_record_changes`, `get_record_history` | `RecordKey` → `RecordValue`; `ChangesFilter`, `RecordHistoryFilter` → `RecordChange[]` | Records' point reads, change feed and history, as rows' (P123b). |
| `declare_index` | `IndexDefinition` → `DeclareIndexResult` | Declares an index over a record table, maintained from then on by every commit (P123c). |
| `scan_index` | `IndexQuery` → `IndexRecord[]` | A page of an index's records for one `eq` key, by order, with the records themselves (P123c). |
| `get_index` | `IndexGet` → `Index` | An index's declaration, state and count of records. |

Commits execute serially in op order, so validating each read's version at commit time gives
serializable transactions over point reads.

A **commit key** makes a transaction safe to send again when its reply is lost (P123). A
transaction may start with a `key` entry naming a 128-bit key the client chose. When it commits,
the state machine also writes the key's row (in the reserved table `0xFFFF0003`), in the same
op. Any later transaction under that key commits nothing: sent again with the same entries, it
reports `committed_before` with the op it committed at; with other entries, `key_reused`. So a
client that lost a reply resends the same transaction, under the same key, until it gets an
answer, and it applies once. A transaction that did not commit (a conflict, a bound) writes no
key, and its resend executes again. A resend's reply has no adds' amounts: read the rows as of
its op. Keys are kept forever, one 80-byte row each; their row ids are 64-bit hashes, so two
keys may collide (about 3 in 10,000 among 10⁸ keys), and the second is refused with
`key_collision`, which proves nothing committed under it: pick another key.

**Records** are rows for facts (P123b): tables from `0x80000000` to `0xFFFEFFFF` hold records,
identified by `(table, id)` with a 128-bit id (a UUID, say), each a fixed 448-byte value. A
transaction (`commit_wide`) may read, put and delete records and rows together, so a fact
commits in the op that moves its money (G1). Records are written whole: they take no adds.
Their changes form a feed of their own, ordered with rows' by timestamp. A record's key keeps
96 bits of a hash of its id: two ids of one table that collide are refused (`id_collision`, about
one in 10¹³ among 10⁸ records), never merged.

An **index** finds a record table's records other than by id (P123c): a declaration of up to
three `eq` fields, then an `order` field (or the op of the record's last write), and optional
`where` clauses that make it partial ("executions with status `reserved`, by `created_at`").
The state machine keeps it exact in the commit that writes each record. Scanned for one `eq` key,
it lists records by order, then in the order they were first written, a page at a time from a
cursor. An index declared over records that exist builds by pulses, like a view, and answers no
scan until it is ready. Indexes read the latest state; read the past through history.

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
unit, integration, API, view, mixed-release and demo tests, every fuzzer at its smoke size, and the VOPR,
as parallel jobs (N57). On a pull request the VOPR runs seeds 1, 2, 5 and one random seed in Debug
(printed, so a failure replays); on `main` it runs in ReleaseSafe, seeds 1, 2 and 5 and then four
lanes of random seeds for 6 minutes each, about 300 seeds a push (N74). A commit to `main` that changes `VERSION` runs CI on that commit, then
publishes binaries for Linux and macOS (x86_64, aarch64) as GitHub release `v<VERSION>`
(`release.yml`), with that version's section of [CHANGELOG.md](./CHANGELOG.md) as the release
notes; releasing a version twice, or without notes, fails. Each release also carries its bill of
materials, `nerva-v<VERSION>.cdx.json` (CycloneDX 1.5, N63): Nerva, the vendored TigerBeetle
commit, and the Zig standard library and compiler, read from the repository's pins and covered
by `SHA256SUMS`. A separate workflow,
`fuzz.yml`, runs every fuzzer and the VOPR on random seeds for a time budget; it is started by hand
on runners brought up for it. The simulation fleet ([ops/sim-fleet](./ops/sim-fleet/README.md))
runs the VOPR and the fuzzers on fresh seeds on one host around the clock, at the tip of `main`,
and files each distinct failure as an issue labelled `sim-fleet` (P147h). [tests/jepsen](./tests/jepsen/README.md) is a Jepsen suite: five
real nodes, clients through `nerva api`, kills, pauses and partitions, and a history checked
against what Nerva promises (a declared ledger's conservation, so far); it runs by hand (N82).

Binaries report `<protocol>+<commit>`. The protocol release (`0.0.5` since data files record
the export they were imported from, P90) is what data files and clients check: a replica refuses
a data file of another release, so upgrading means new data files, and accepts clients from
`0.0.4` on (v0.4.0's; a v0.3.0 `nerva api` is refused at registration). A replica ignores peers that
run another release (N61): in a cluster mixing releases, only replicas of one release count
toward each other's quorums, and each logs the others it ignores. From `0.0.5`, replicas also
authenticate each other before anything else (P102, below), which `0.0.4` replicas cannot do: a
`0.0.5` replica closes a connection from a `0.0.4` one, and a `0.0.4` replica that a `0.0.5` one
dials exits at once (`unknown_vsr_command`, status 7, on the handshake's first message), so
**never run them in one cluster**. A cluster moves to a new
release with its data by export and import (below, N80). `zig build test:release` runs a cluster
of two releases, an upgrade from this build to another release, and replicas imported from
different exports.

## Running a cluster

```bash
# One data file per replica (cluster id 0 is reserved for test builds).
./zig-out/bin/nerva format --cluster=0 --replica=0 --replica-count=3 0_0.nerva
./zig-out/bin/nerva format --cluster=0 --replica=1 --replica-count=3 0_1.nerva
./zig-out/bin/nerva format --cluster=0 --replica=2 --replica-count=3 0_2.nerva

# Every replica gets every address, in replica order, and the same cluster key.
export NERVA_CLUSTER_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
./zig-out/bin/nerva start --addresses=3001,3002,3003 0_0.nerva   # and 0_1, 0_2
```

`--development` relaxes Direct IO and uses small caches. Clients use `src/nerva/client.zig`:
`lookup_rows`, `commit`, `get_changes`, `get_history`, views and ledgers, blocking, one
request in flight per client.

### Replicas authenticate each other

Before any replica message flows on a connection between two replicas, each proves that it
holds the cluster key, `NERVA_CLUSTER_KEY` (P102). A process without it cannot join the cluster,
pose as a replica, or send a replica message: the connection is closed first. Clients and
gateways do not hold the key and are not affected.

- **The key**: at least 32 bytes, the same on every replica, and secret. `nerva start` refuses
  to run without it, and never prints it. With `--development` and every address a loopback
  address (`127.0.0.1`, `::1`, or bare ports), an unset key falls back to a public development
  key, with a warning; that key authenticates nothing, so it is never used elsewhere.
- **Rotating it**, one replica restart at a time, with no downtime:
  1. restart every replica with the new key as `NERVA_CLUSTER_KEY_NEXT`;
  2. restart every replica with the new key as `NERVA_CLUSTER_KEY` and the old one as
     `NERVA_CLUSTER_KEY_NEXT`;
  3. restart every replica without `NERVA_CLUSTER_KEY_NEXT`.

  A replica proves with `NERVA_CLUSTER_KEY` and accepts proofs under either key.
- **The handshake**: the replica that dials (the lower index) sends a fresh nonce; the other
  answers with its own nonce and an HMAC-SHA256 under the key of both nonces, both replicas, the
  cluster and both data files' origins (P90); the dialing replica checks it and answers with its
  own. A replica's pings must then announce the origin its proof covered. A connection still
  handshaking after 5 seconds is closed, and a replica refused with a wrong key is redialed with
  backoff (it logs `wrong cluster key`).
- **What it does not cover**: the key proves who opened a connection, but what follows is not
  encrypted or signed. Someone on the network path between two replicas could still read or
  alter it. Run replicas on a private network that encrypts: WireGuard, or Fly.io's private
  network (6PN), which is WireGuard. Put gateways (`nerva api`, `nerva view`) behind TLS for any
  caller off that network.

### Upgrading a cluster

From v0.4.0 on (v0.3.0 has no `nerva export`), a new release keeps the data: the old release's
`nerva export` writes what a client can read,
and the new release's `nerva import` rebuilds each replica's data file from it, recomputing
everything derived (views, versions, ledger indexes) with its own code (N80).

```bash
# 1. With the old release, while the cluster runs (stop writers first, or pass --as-of=<op>):
nerva export --cluster=0 --addresses=3001,3002,3003 --output=cluster.nerva-export
# 2. Stop every replica. With the new release, once per replica, on the same export:
nerva import --cluster=0 --replica=0 --replica-count=3 --input=cluster.nerva-export 0_0.nerva
nerva import --cluster=0 --replica=1 --replica-count=3 --input=cluster.nerva-export 0_1.nerva
nerva import --cluster=0 --replica=2 --replica-count=3 --input=cluster.nerva-export 0_2.nerva
# 3. Start the replicas on the new release (with NERVA_CLUSTER_KEY from 0.0.5 on), then
#    clients and gateways of the new release.
nerva start --addresses=3001,3002,3003 0_0.nerva   # and 0_1, 0_2
```

- The export holds every change up to its op (`--as-of`, by default the op it starts at), with
  its op and timestamp, the views' names and ops, the ledgers' definitions and ops, and checks:
  each view's hash, each ledger's total, and a hash of each table's rows. It is versioned,
  checksummed record by record (CRC-32) and as a whole (SHA-256); `export` never overwrites a
  file. It refuses an export `import` would refuse, such as one taken while a gateway was
  between declaring a view and writing its catalog document (export again, or PUT the view
  again if that gateway stopped), so nothing is stopped for an export that cannot be used (N81).
- `import` checks the whole export before it creates the data file, restores every op at its
  number, then compares its state with the checks. It writes `<path>.importing` and gives it its
  name only once the checks pass: on a damaged export, a mismatch or a crash, no data file is
  left to start (a killed import leaves `<path>.importing`; remove it and import again). Every
  replica's file is identical.
- What carries over: rows, versions (a client's `op_seen` still holds), history, `row?as_of`,
  the change feed with its timestamps (a cursor from before continues), documents, layouts,
  ledgers, commit keys, records and their history, and every view's answer and hash. Indexes
  are declared again at their ops and rebuilt by the new cluster's pulses; a scan's order and
  cursors are the same as before (P123c). A view declared over rows that already existed is
  rebuilt by the new cluster after it starts (`"state": "building"` until then), and its as-of
  history starts there; client sessions do not carry over.
- Op numbers jump: the new cluster goes on from the first checkpoint at or after the export's
  op. Versions and feed cursors from before stay valid.
- **Every replica from one export** (P90). An export is named by its SHA-256 (`export` prints
  it; `import` and `start` log it), and every data file records the export it was imported from
  (none, for `nerva format`). Replicas handle a peer only once it has announced their export. A
  replica whose peers of other exports leave it no quorum exits with status 8 (`NRV-E0711`), naming
  both exports, and nothing from them reaches its data file: import it again from the cluster's
  export. The others log that they ignore it and run on. A replica imported from the cluster's
  export that has not started yet may start later and catch up.
- **Replacing a lost replica** of a cluster that was formatted, with the cluster open: stop the
  lost replica and destroy its data file (it must never start again), then, on its host,
  `nerva recover --cluster=<id> --replica=<i> --replica-count=<n> --addresses=<every replica, in
  order> --origin=none <path>`, then `nerva start` on the new file. It registers a session with
  the running cluster, commits a pipeline's worth of no-op requests, and writes a data file whose
  view is two past the cluster's, so that the new replica never contradicts what its
  predecessor promised (`src/vsr/replica_reformat.zig`, upstream's recovery). The data file is
  written as `<path>.recovering` and renamed once complete. It needs at least three replicas,
  refuses with `NRV-E0713` while anything answers at the replica's address, with `NRV-E0712` when
  the others have no quorum, and recovers one replica at a time, each caught up before the next.
  A cluster that was imported is recovered the same way with `--origin=<export>`, the SHA-256 that
  `nerva export` prints and `nerva import` and `nerva start` log: the new data file records that
  export, so its peers handle it (P90). `--origin` has no default. With the wrong one the
  replica exits with status 8 and `NRV-E0711` when it starts, naming the export its peers
  announce, and they ignore it and run on; recover it again with the right one. Importing only
  the lost replica instead is not safe: its replacement forgets the prepares the lost replica
  acknowledged, and with one more failure a committed op could be lost (P90).
- A view declared only through the Zig client, with no catalog document, cannot be imported:
  `import` refuses it. Declare views through `nerva api`.
- **Format versions.** An export of a cluster with records or indexes is version 2 (P123b);
  any other is version 1, which every release since v0.4.0 reads. A release reads both. From
  v0.5.0 to v0.6.0, rows in tables from `2147483648` up must move below it first: those tables
  now hold records, and `import` refuses such rows by name (P123e).
- **Memory.** v0.6.0's replica takes about 0.5 GiB more than v0.5.0's (3.0 GB at startup with
  the defaults, from 2.5 GB); `--cache-grid=512MiB` brings it back, at the cost of more reads
  from disk (#127).
- Measured (`perf/upgrade.py`, a 4-CPU sandbox, `--development`): a million changes over
  970,000 rows exported in 5.8 s (365 MiB at most) and imported in 14 s (1.2 GiB, the state
  machine's fixed allocation, as a replica's); the export file is 121 bytes a change.

### When a command refuses

A `nerva` command that refuses prints one block and exits (R5, [docs/ERRORS.md](./docs/ERRORS.md)):

```
error[NRV-E0004]: export: cluster.export exists
  cause  An output file already exists
  fix    give a new path: nerva never overwrites a file
```

The exit status says who is to blame: 1 the operator's input, 2 the environment (disk, kernel,
file system), 70 a bug in Nerva (`bug[NRV-B…]`, with the error's name on a `detail` line under
`--log-debug`). `nerva start`'s runtime exits keep their statuses (2 to 8). The flag parser's own
messages (an unknown or repeated flag) are not coded yet.

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

### Commit stall

The primary pauses a commit for one tick (10 ms) with some probability, when no backup is lagging
and another prepare is already acknowledged by every replica, to give backups breathing room
(vendored from TigerBeetle, default 2/5). `nerva start --commit-stall-probability=<n>/<d>` sets
it (a ratio from 0 to 1, `0` never pauses; ratios above 1 and zero denominators are refused). It
trades latency against backup lag: the pause is most of an op's time under a few clients. The
longer pause the primary takes while a backup lags is not configurable (P136).

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
change feed, `c7` mixed, and `botpike`: submits like Botpike's app sends (a lookup, then a commit
with a key, a transfer row and a clamped add pair, reserves and settles alternating) through one
`nerva api` gateway over HTTP, with `--clients` concurrent callers (up to 64; `--keys` accounts;
`--nerva=<path>` the binary to start the gateway from), so that it measures what an application
behind one gateway gets (P132). `--rate=0` (default) is a closed loop; `--rate=<n>` an open loop whose
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

One regression is one issue, however many nights it lasts (`perf/nightly/file_issue.py`, P121,
P122). Each failing metric has a fingerprint, `<metric>:<baseline commit>` (for example
`load-c4-b1-ops-s:4a8aef30a882`), which the issue carries as
`<!-- nerva-perf:fingerprint=... -->`. A failing night that shares a metric with an open issue,
or a fingerprint with a closed one, adds a comment with its numbers, reopening the issue if it
was closed; otherwise it opens one. The next night that passes comments "recovered" on every
open issue with a fingerprint and closes it (hand-filed `perf-regression` issues are left
alone); a night that only warns changes no issue. The baseline moves to the candidate after a
night that passes, or one that only warns while no fingerprinted issue is open: a warn night in
the middle of a regression does not absorb it. To try the issue step, run the workflow by hand with
`force_verdict` set to `fail` or `pass`; to see what it would do without changing anything:

```bash
python3 perf/nightly/file_issue.py --verdict verdict.json --summary summary.md \
    --run-id 1 --run-url <url> --repo NervaLog/nerva --dry-run
python3 perf/nightly/test_file_issue.py   # its tests, offline (CI runs them)
```

## JSON API

`nerva api` serves the core operations as JSON over HTTP, for any language:

```bash
NERVA_KEY=secret ./zig-out/bin/nerva api --cluster=1 --addresses=3001,3002,3003 \
    --listen=127.0.0.1:8080
curl -H 'X-Nerva-Key: secret' -d '{"entries":[{"kind":"put","table":1,"id":"5","value_hex":"c0ffee"}]}' \
    http://127.0.0.1:8080/v1/commit        # {"status":"committed","op":"42"}
```

`--listen` (for `nerva api` and `nerva view`) takes `<ipv4>:<port>` or `[<ipv6>]:<port>`, as
`--addresses` does: `--listen=[::]:8080` serves every IPv6 address, as on an IPv6-only network.
On Linux, `[::]` accepts IPv4 connections too unless `net.ipv6.bindv6only` is set (it is not by
default). Zone ids (`[fe80::1%2]`) are refused.

| Route | Does |
|---|---|
| `POST /v1/lookup` `{"rows":[{"table","id"}]}` | Point reads: `exists`, version `op`, `value_hex`, and the `op` read at. |
| `POST /v1/commit` `{"key"?,"entries":[…]}` | One transaction of `read` (with `op_seen`), `put` (with `value_hex`), `delete` and `add` (`field`, or `offset` and `type`; `delta` or `delta_from`; optional `min`, `max`, `clamp`, `create`, `pair`). `200` committed with its `op` and each add's `applied` and `value`; `409` conflict with the stale entry's `index` and the row's current `op`, or `out_of_bounds` (with the field's `value`) or `row_absent` for an add, or `unpaired` or `conserved_write` for a ledger's field (below); `400` invalid. Under a `key` (16 bytes as 32 hex digits, not zero; P123): the same request again answers `200` with the original `op` and `"replayed": true`, and applies nothing; other entries under the key, `409 key_reused` (or `key_collision`) with the op that holds it. Indices are the request's. |
| `GET /v1/changes?cursor=&limit=` | The change feed, paged. |
| `GET /v1/history?table=&id=&op_max=&cursor=&limit=` | One row's writes, newest first, up to `op_max`. |
| `GET /v1/row?table=&id=&as_of=` | One row as it was at an op (refused for an op not yet committed). |
| `PUT /v1/tables/<t>` `{"name","fields":[{"name","type"}]}` | Declare a table's layout (u8, u16, u32, u64, i64, bool, bytes), or extend it by appending fields. Then puts may send `fields` instead of `value_hex`, and reads return `fields`. |
| `GET /v1/tables/<t>` | The table's layout. |
| `PUT /v1/ledgers/<id>` `{"fields":[{"table","field" or "offset","floor"}]}` | Declare a ledger: 2 to 16 conserved `i64` fields (below). `200` created or exists, with its `op`; `409` `ledger_immutable`, `ledger_field_taken`, `field_viewed` or `ledgers_full`; `400` invalid. |
| `GET /v1/ledgers/<id>` | The ledger's fields, floors and the op it was declared at. |
| `PUT /v1/indexes/<name>` `{"table","eq":[…],"order"?,"where"?}` | Declare an index over a record table, by its layout's field names (P123c). `200` created or exists, with its `op`; `409` different (indexes are immutable) or full; `400` invalid. |
| `GET /v1/indexes`, `GET /v1/indexes/<name>` | The indexes: name, id, table, fields, state, records, `declared_op`. |
| `POST /v1/indexes/<name>/scan` `{"eq":{…},"min"?,"max"?,"descending"?,"limit"?,"after"?}` | A page of the records with these `eq` values, by order from `min` to `max`, each with its `id`, `op`, `order`, `value_hex` and `fields`; `next` is the next page's `after`, or null. `503` while the index builds. |

64-bit numbers (ids, ops, cursors) are decimal strings; values are the 80 bytes as hex. A
record table's ids are 16 bytes as 32 hex digits, given back as sent, and its values 448 bytes;
`/v1/lookup` reads rows or records, not both in one request, and `/v1/changes`, `/v1/history`
and `/v1/row` serve both. Layouts live in the log, in a reserved catalog table; the core still
stores bytes and never reads them. A record table's layout packs up to 448 bytes, a bytes field
up to 255. A gateway keeps up to 64 layouts between requests (P135), so a lookup or commit does not
read them from the log; one that another gateway extended is never used for an answer it would
get wrong (`api.zig`, "Layouts").

```bash
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/tables/2147483649 -d '{"name":"executions",
  "fields":[{"name":"agent","type":"bytes","size":16},{"name":"status","type":"u8"},
            {"name":"created","type":"u64"},{"name":"amount","type":"u64"}]}'
# A balance (row) and the fact of its move (record) in one transaction:
curl -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/commit -d '{"key":"<32 hex digits>","entries":[
  {"kind":"add","table":7,"id":"1","field":"available","delta":"-30","min":"0"},
  {"kind":"put","table":2147483649,"id":"0190f1c2a7e47b3c9d2e5f6a7b8c9d0e",
   "fields":{"agent":"…","status":1,"created":"1760600000","amount":"30"}}]}'
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/indexes/reserved -d '{"table":2147483649,
  "order":"created","where":[{"field":"status","op":"eq","value":1}]}'
curl -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/indexes/reserved/scan -d '{"max":"1760599000","limit":100}'
```

Both gateways (`nerva api`, `nerva view`) execute one cluster request at a time but read up to 16
connections at once, so a slow client holds up nobody. `nerva api` answers the `POST /v1/commit`
and `POST /v1/lookup` requests that are waiting together when it turns to them with one cluster
request, one transaction or read each (at most 16; it never waits for more), and each reply is
the one the request would have had alone; if the cluster does not answer, each gets the `503`
it would have had alone (P143). With all 16 connections busy, a new connection
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

**Documents** hold values larger than a row: up to 512 KiB under a string key (up to 1024 bytes
of UTF-8) in a namespace (a `u64`, as a decimal string). Nerva chunks them over rows of a
reserved table; a document is written in one commit, so 512 KiB is the most that stays atomic.
Keep larger values (files, model outputs) outside Nerva, content-addressed, and store their hash
in a document: Nerva then orders and versions the reference, and the blob store never needs to
be transactional (N76). A `get` reads at most as many chunks as 256 documents of 64 KiB (about
16 MiB of values); more answers `413`:

| Route | Does |
|---|---|
| `POST /v1/documents/get` `{"namespace","keys":[…],"as_of"?}` | Up to 256 keys as of one op (the latest, or `as_of` a committed op): `exists`, `version` (the op of the last write, `"0"` if never written), `value_hex`. |
| `POST /v1/documents/commit` `{"namespace","reads":[{"key","version"}],"writes":[{"key","value_hex"} or {"key","delete":true}]}` | One transaction. `200` committed with its `op`; `409` with the stale read's `key` and current `version`; `400` invalid. About 600 KB of keys and values per commit. |
| `GET /v1/documents/changes?namespace=&cursor=&limit=` | The namespace's document writes in commit order (`key`, `op`, `kind` put or delete, `value_hex`), paged like `/v1/changes`. |

`zig build test:api` checks every route against a model (documents, records and indexes included), races eight
writers on one row and on one document, races fifty reservations on one budget with adds
(none retried), and races fifty clamped reservations on one ledger account (below).

## Ledgers

A **ledger** is a declared set of conserved `i64` fields, each with an optional floor (N75). Once
a field is in a ledger, the state machine changes it in one way only: a **pair** of adds that
moves one amount from one field of the ledger to another, never below either field's floor. A
client cannot create or destroy value, overdraw a floored field, or overwrite a balance, however
it builds its requests: the cluster refuses the transaction.

```bash
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/tables/7 -d '{"name": "accounts",
  "fields": [{"name": "available", "type": "i64"}, {"name": "held", "type": "i64"}]}'
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/tables/8 -d '{"name": "sources",
  "fields": [{"name": "balance", "type": "i64"}]}'
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/ledgers/1 -d '{"fields": [
  {"table": 7, "field": "available", "floor": "0"}, {"table": 7, "field": "held", "floor": "0"},
  {"table": 8, "field": "balance", "floor": null}]}'
# {"ledger":1,"declared":"created","op":"57"}

# Reserve up to 30: the first half (pair) may clamp at its floor; its partner, the next entry,
# names it in delta_from and moves exactly what it took.
curl -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/commit -d '{"entries": [
  {"kind": "add", "table": 7, "id": "1", "field": "available", "delta": "-30", "pair": true,
   "clamp": true},
  {"kind": "add", "table": 7, "id": "1", "field": "held", "delta_from": 0}]}'
```

- **Pairs.** A pair is an add with `"pair": true` at index `i` and its partner at `i + 1`: an add
  to another field of the same ledger (another row, or another field of the same row) whose
  `delta_from` is `i`, without `min`, `max`, `clamp` or `pair`. Each move of the example is one
  pair: fund (`balance` to `available`), reserve (`available` to `held`), post (`held` to
  another account's `available`), void (`held` back to `available`). A transaction may hold
  several pairs, and other entries. Any other add to a conserved field, a partner breaking a
  rule, or a third add naming a first half is `409 {"status": "unpaired", "index"}`.
- **Floors.** A conserved add never moves its field down past its floor: the first half
  clamps there with `clamp`, or the transaction is `409 out_of_bounds`; the partner never
  clamps, so if its floor (or the `i64` range) stops it, the whole transaction is
  `out_of_bounds`. A field with no floor may go negative: a source of funds. A field below its
  floor (declared over existing rows) may still move back up.
- **No other writes.** A put that would change a conserved field's bytes, a delete of a row
  whose conserved fields are not all zero, and an add that overlaps a conserved field without
  matching it as an `i64` are `409 {"status": "conserved_write", "index"}`. A put that leaves
  them alone, or creates a row with them zero, commits; so does an add with `create`.
- **Declarations** are immutable: the same one again is a no-op (`exists`, with its op); another
  under the same id is `409 ledger_immutable`. A field belongs to one ledger at most
  (`ledger_field_taken`). A view may sum a conserved field, or take its `min` or `max`, but not
  filter or group by it, whichever is declared first (`field_viewed`, or `409` for the view).
  At most 64 ledgers, of 2 to 16 fields. A ledger may be declared over rows that already
  exist: its total is then whatever it was at the declaration's op.
- **The invariant:** for every ledger, the sum of its fields over all rows is what it was at its
  declaration, at every op, and no field moves down past its floor. The VOPR checks it after
  every commit under crashes and faults, independently of its model of the rows.

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
`group_by` takes up to three fields; aggregates are `count`, `sum`, `min` and `max`. A view over
a record table takes `count` and `sum` only, and is served by `nerva api`, not `nerva view`
(P123d).

**Maintained by the replicas** (N52, N62, N66). The state machine keeps every view inside every
commit, like the rows: each write updates its row's groups, and every replica holds the same
groups at every op. Reading a view reads its groups, not the rows, and nothing is lost when a
process restarts.

- `GET /v1/views/<name>` answers with the whole view, groups sorted by key, read at one op.
  `hash` is the SHA-256 of the `groups` JSON exactly as served; `view_hash` is the replicated
  hash, the sum modulo 2^256 of the groups' digests, the same at every replica. `as_of=<op>`
  reads the view as that op left it (`404` before it was declared); `min_op=<n|latest>` asks for
  at least op `n`. Either answers `504` for an op not yet committed, and a view still building
  answers `503`. A view of more than 10,000 groups answers `400`; read it in pages instead:
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

## Limits

Every limit a caller can hit, in one place. Each is a constant in the code, asserted where it is
used; the sections above say why.

**Gateways** (`nerva api`, `nerva view`):
- A `nerva api` request body is at most 4 MiB; a larger `Content-Length` answers
  `400 {"error":"body too large"}` before the body is read. `nerva view` takes no body: it answers
  `GET` only, and any body answers that same `400`.
- A `nerva api` request may allocate at most 128 MiB once parsed; more answers
  `413 {"error":"request too complex"}`. Between requests the gateway keeps at most 8 MiB.
- 16 connections are read at once. With all 16 busy, a new connection displaces the oldest one
  still sending its request.
- A request must arrive whole within 10 s of connecting, and its reply is written within another
  10 s. One request per connection (`Connection: close`).
- Every request but `GET /healthz` needs `X-Nerva-Key`, equal to `NERVA_KEY` or, during a
  rotation, `NERVA_KEY_NEXT`; a missing or other key answers `401`. A method the gateway never
  takes (for `nerva api` anything but `GET`, `POST` and `PUT`; for `nerva view` anything but `GET`)
  answers `405` before the key is checked.
- A gateway's cluster session times out a request after 30 s; the gateway then answers `503`
  until it has reconnected.

**Documents:** a value is at most 512 KiB, under a key of at most 1024 bytes of UTF-8. A commit
carries about 600 KB of keys and values. A `get` takes at most 256 keys (more answers `400`), and
reads at most as many chunks as 256 documents of 64 KiB (more answers `413`: ask for fewer keys).

**Views:** one op touches at most about 4,000 distinct groups and 8,000 `min` and `max` members.
A transaction that exceeds them alone answers `413 views_too_large` (split it); one that only
fails to fit after earlier transactions of the same request answers `503 views_busy` (retry).
A view of more than 10,000 groups is read in pages. A table's views have at most four `min` and
`max` aggregates between them.

**Records and indexes:** a record's value is 448 bytes; a layout's bytes field in it at most
255. A lookup reads at most about 2,000 records, and a page of the feed or a history about
2,000 changes. At most 64 indexes, 4 per table; an index has up to three `eq` fields of 64
bytes between them, and four `where` clauses. A scan returns at most about 2,000 records (1,024
through `nerva api`). A view over records takes `count` and `sum` only.

**Client sessions:** a cluster holds 64 client sessions. Every gateway, `nerva view` and Zig
client takes one; a 65th evicts the session that committed least recently, whose next request
fails (gateways reconnect on their own).

**Network.** Gateways authenticate their callers with `X-Nerva-Key`, but send it, and every
reply, in plain HTTP: put them behind TLS (a load balancer or proxy) when callers are not on a
private network. Replicas authenticate each other with the cluster key (P102, "Replicas
authenticate each other" above), but their traffic is neither encrypted nor signed after the
handshake, and anyone who can reach a replica's port can still act as a client. Run replicas on a
private network that encrypts (WireGuard, or Fly.io's 6PN) and that only the cluster and its
gateways can reach.

To rotate a gateway key without downtime: restart every gateway with the new key as
`NERVA_KEY_NEXT` (it accepts both); move every caller to the new key; then restart every gateway
with the new key as `NERVA_KEY` and no `NERVA_KEY_NEXT`. Each set key must be non-empty, and the
two must differ; a gateway refuses to start otherwise, without printing either key (P96).

## Demos

[demo/](./demo/README.md) holds public demos built only on the pieces above: a seat race (512
seats, simulated buyers; buy, rewind the show to any op, crash any process, declare views) and
a shared canvas (paint, play the timelapse, crash, declare). `zig build test:demo` runs both
under random crashes.

Decisions and their reasons: [docs/DECISIONS.md](./docs/DECISIONS.md).

## Production

Nerva holds its first client's money on the R milestones' terms, in
[docs/PRODUCTION.md](./docs/PRODUCTION.md). Each ends in a demo that runs in CI; a milestone is
**delivered** only when that demo is green. The gate for strangers' money is R1 to R5.

| Milestone | What it adds | Status |
| --- | --- | --- |
| R1 · Proven | Jepsen nightly on a dedicated host: commit keys under unknown outcomes, the gateway killed and cut off | Not started (bank suite exists; nightly is draft #106) |
| R2 · Fleet | An always-on VOPR and fuzzer fleet on Hetzner that files every new failure | In progress |
| R3 · Measured | Sizing and latency on three machines; the Fly p99 explained | Not started |
| R4 · Gateway | Beside its client: a gateway per client process on loopback, no ambiguous 503, metrics | Not started |
| R5 · Recover | Replace a lost replica, and restore a backup, with the cluster open | In progress: slices 1 to 4 and 6 of 7 merged (#150 diagnostics, #152 pre-flight, #151 and #157 `nerva recover`, #154 `nerva backup` and `nerva restore`); slice 5 and `demo-r5` to come; brief [docs/briefs/r5.md](./docs/briefs/r5.md) |
| R6 · Upgrade | Rolling upgrades between releases with the same data format | Not started |
| R7 · Retention | Keys, history and view versions trimmed below a horizon | Not started |
| R8 · Native client | The client library from the JVM over a C ABI: no gateway, no JSON, batched ops | Not started |

## Roadmap

The 1.0 target is in [docs/GOALS-1.0.md](./docs/GOALS-1.0.md).

1. **Foundation** — vendored consensus + storage + simulator, placeholder state machine. ✅
2. **Commit core** — row model, optimistic read-set validation, versioned base rows; VOPR
   workload with a model checker. ✅
3. **Server and client protocol** — `nerva format` / `nerva start`, a Zig client, and
   `nerva api` (JSON over HTTP). ✅
4. **Declared views** — layouts and views as data in the log, a watermark, reads at a position,
   a hash per answer. ✅ (Maintained by the replicas in every commit, N52; `nerva view`
   recomputes them as a check.)
5. **Snapshots and subscriptions** — reads as of op `N` ✅ (`get_history`, `row?as_of=`, views
   `as_of`); change cursors ✅ (`get_changes`); view snapshots.
6. **Facts beside money** — commit keys, records with 128-bit ids and declared indexes, written
   in the transaction that moves the money (P123, P123b, P123c). ✅ Index reads as of a past op,
   and retention of keys and facts, are next.
7. **Object storage tiering**, external operators, effect sinks.

## License

Apache 2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
