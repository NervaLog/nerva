# Changelog

What changed in each release, for people running Nerva or building on it. The release workflow
publishes a version's section as its GitHub release notes, and refuses to release a version
without one. Design reasons are in [docs/DECISIONS.md](./docs/DECISIONS.md); the full log of
work is [WORKLOG.md](./WORKLOG.md).

## v0.5.0 — 2026-10-07

Replicas now prove to each other that they hold a cluster key, and refuse replicas imported
from a different export. Gateways rotate their key without downtime and listen on IPv6. Several
crashes are now refusals that name their cause. **A replica no longer starts without
`NERVA_CLUSTER_KEY`, its data files must be imported again, and its replicas must never run in
one cluster with v0.4.0 replicas:** see "Upgrading from v0.4.0" below. v0.4.0 clients and
gateways keep working.

### New: replicas authenticate each other

Before any replica message flows on a connection between two replicas, each proves that it holds
the cluster key, `NERVA_CLUSTER_KEY`: an HMAC-SHA256 over fresh nonces from both sides. A
process without the key cannot join the cluster, pose as a replica or vote. Clients and gateways
don't hold the key and aren't affected. (P102)

```bash
export NERVA_CLUSTER_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"  # the same on every replica
nerva start --addresses=3001,3002,3003 1_0.nerva
```

- **The key:** at least 32 bytes and secret. `nerva start` refuses to run without it and never
  prints it. With `--development`, a public development key is used, with a warning, but only
  when every address is a loopback address.
- **Rotating it, with no downtime:**
  1. restart every replica with the new key as `NERVA_CLUSTER_KEY_NEXT`;
  2. restart every replica with the new key as `NERVA_CLUSTER_KEY` and the old one as
     `NERVA_CLUSTER_KEY_NEXT`;
  3. restart every replica without `NERVA_CLUSTER_KEY_NEXT`.
- **What it doesn't cover:** the key authenticates who opened a connection, not the traffic
  after it. Replicas still need a private network that encrypts (WireGuard; Fly.io's 6PN).

### New: replicas imported from different exports refuse each other

A data file now records the export it was imported from: the export's SHA-256. `nerva export`
prints it, and `nerva import` and `nerva start` log it. Replicas announce it to each other. A
replica that can never reach a quorum with replicas of its own export exits with **status 8**
(`origin_mismatch`), naming both exports and telling you to import it again. The others log
that they ignore it and keep running. Before, replicas imported from two exports that reached
the same checkpoint crashed in the journal. (P90, #81)

- **Replacing a lost replica is a whole-cluster operation:** export the cluster again and import
  every replica. Importing one replica alone joins and catches up, but it has forgotten the
  prepares the lost replica acknowledged, so a later failure could lose a committed op. A safe
  single-replica replacement is future work (#94).

### New: gateways rotate their key, and listen on IPv6

- **`NERVA_KEY_NEXT`:** `nerva api` and `nerva view` also accept `X-Nerva-Key` equal to
  `NERVA_KEY_NEXT` when it is set. Rotate in three restarts:
  1. give every gateway the new key as `NERVA_KEY_NEXT`;
  2. move callers to the new key;
  3. make it `NERVA_KEY` and unset `NERVA_KEY_NEXT`.

  A gateway refuses to start with an empty `NERVA_KEY_NEXT`, or one equal to `NERVA_KEY`. Both
  keys are compared in constant time on every request. (P96)
- **`--listen=[<ipv6>]:<port>`**, as `--addresses` already took, for example `--listen=[::]:8080`
  on an IPv6-only network such as Fly.io's. Zone ids (`[fe80::1%2]`) are refused. On Linux,
  `[::]` also accepts IPv4 unless `net.ipv6.bindv6only` is set. (#99, #104)
- **README "Limits"** gathers every limit a caller can hit, each checked against the code. (#96,
  #110)

### Fixed

- Replicas imported from different exports crashed instead of refusing each other. They now
  exit with status 8. (#81)
- **A client older than its replicas couldn't commit to a cluster of more than one replica:**
  backups dropped every prepare that carried an older accepted client's release, including its
  registration. This has been so since v0.3.0, which accepted v0.2.x clients that then timed
  out. It now works, so v0.4.0 clients and gateways work against v0.5.0 clusters. (#93)
- A gateway, the Zig client or a replica given an address its kernel can't open a socket for
  (`[::1]` without IPv6) aborted on an assertion. It now logs the error once and keeps retrying.
  (#92)
- The nightly benchmark reported documents encoding and decoding 8 times slower. The benchmark
  had grown with the document limit; the code hadn't changed. Writing a document now computes
  its chunk ids' prefix once, and encoding takes about a third of the time it did. (#88)
- A `413` reply had no reason phrase in its status line. It now reads `413 Content Too Large`.
  (#110)

### Release review

Before this release, a bot that did none of its work reviewed it adversarially (P105).
- **Fixed:** #108 (the nightly benchmark couldn't start its cluster without the key), #110 (the
  README Limits wording) and #111 (P115: a v0.4.0 replica dialed by a v0.5.0 one exits with
  `unknown_vsr_command`, status 7; it doesn't just close the connection).
- **Answered by these notes:** #109 (the key is now mandatory).
- **Carried to 0.6.0:** #112.

### Known issues, carried to 0.6.0

- **#112:** gateways listen with `SO_REUSEPORT`, so two gateways can silently share a port.
- **#95:** a replica given another release's data file stops on a panic (`multiversion
  unsupported`) rather than a message.
- **#94:** no safe way yet to replace one lost replica. Replace by exporting and importing the
  whole cluster.
- **#116:** the nightly showed contended (`c3`) p99 latency 39% above v0.4.0's. Throughput and
  p50 held, and the baseline's own spread is nearly as wide. Being watched.
- **#109, downstream:** deployments must set `NERVA_CLUSTER_KEY` before starting a v0.5.0
  replica. Botpike's own deploy tracks this in Botpike/app#93.
- **CI and benchmarks:** #107 (the Jepsen suite doesn't fit the CI runner's memory; it passes
  where it has room), #101 (CI runners short of disk), and #91 (benchmarks in one process move
  each other's numbers).
- Divergence alerts (replica metrics and a view check) move to 0.6.0.

### Upgrading from v0.4.0

1. **Choose a cluster key and give it to every replica**, as `NERVA_CLUSTER_KEY`: at least 32
   bytes, the same everywhere, secret (for example a Fly secret). A v0.5.0 replica refuses to
   start without it. `--development` falls back to its public key only when every address is a
   loopback address. (#109)
2. **Export with v0.4.0, then stop every replica.** Run
   `nerva export --cluster=<id> --addresses=<…> --output=cluster.nerva-export`.
3. **Import every replica with v0.5.0**, from that one export, before any of them starts:
   `nerva import --cluster=<id> --replica=<i> --replica-count=<n> --input=cluster.nerva-export <file>`.
   Then `nerva start` each replica with the key set. Binaries report `0.0.5+<commit>`. A v0.5.0
   replica refuses a v0.4.0 data file.
4. **Never run v0.4.0 and v0.5.0 replicas in one cluster.** They can't authenticate each other,
   and a v0.4.0 replica that a v0.5.0 one dials exits at once (status 7, P115).
5. Clients and gateways may stay on v0.4.0 for now: v0.5.0 replicas accept clients from v0.4.0
   on.
6. **Going back** to v0.4.0 means exporting with v0.5.0 and importing with v0.4.0, which reads
   v0.5.0's exports. A v0.4.0 replica given a v0.5.0 data file stops without writing to it.

## v0.4.0 — 2026-10-06

Declared ledgers, so that the cluster itself conserves balances; views with `min` and `max`,
read as of any op and served whole by `nerva api`; and a round of fixes that keep replicas and
gateways up. **This release is not compatible with v0.3.0's data files, its replicas must never
run in one cluster with v0.3.0 replicas, and it refuses v0.3.0 clients:** see "Upgrading" below.

### New: declared ledgers

A ledger is a declared set of conserved `i64` fields, each with an optional floor. Its fields
then change only by a **pair** of adds that moves one amount from one field to another, never
below a floor, whoever sends the request. Value is neither created nor destroyed, a floored
field is never overdrawn, and puts and deletes cannot overwrite a balance.

```bash
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/ledgers/1 -d '{"fields": [
  {"table": 7, "field": "available", "floor": "0"}, {"table": 7, "field": "held", "floor": "0"},
  {"table": 8, "field": "balance", "floor": null}]}'
# Reserve up to 30: the first half may clamp at its floor; the partner moves what it took.
curl -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/commit -d '{"entries": [
  {"kind": "add", "table": 7, "id": "1", "field": "available", "delta": "-30", "pair": true,
   "clamp": true},
  {"kind": "add", "table": 7, "id": "1", "field": "held", "delta_from": 0}]}'
```

- An add to a conserved field outside a pair answers `409 {"status": "unpaired", "index"}`; a
  put, delete or overlapping add that would change one, `409 {"status": "conserved_write"}`.
- A partner stopped by its floor fails the whole transaction `out_of_bounds`.
- `GET /v1/ledgers/<id>` reads a declaration back. Declarations are immutable
  (`409 ledger_immutable`), a field is in one ledger at most (`409 ledger_field_taken`), and a
  view may sum a conserved field but not filter or group by it.
- At most 64 ledgers of 2 to 16 fields. See README, "Ledgers".

### New: views, complete in the cluster

- `min` and `max` are maintained by the state machine too, and stay exact when the row holding
  them is deleted, moved or changed. A table's views have at most four of them.
- A view reads as of any op since its declaration: `?as_of=<op>`.
- `GET /v1/views/<name>` on `nerva api` is now the whole view, groups sorted by key, read at
  one op, byte for byte what `nerva view` answers, with `hash`, the replicated `view_hash` and
  `declared_op`. **It used to return the declaration, which moved to
  `GET /v1/views/<name>/definition`.** `GET /v1/views` lists the views. A view of more than
  10,000 groups is read in pages from `/groups`.
- A view that filters or groups by a ledger's field is refused with `409`, and nothing is
  written.
- **`GET /v1/views/<name>/groups` names its replicated hash `view_hash`, as the whole view
  does; it was `hash`** (#66). `hash` on `nerva api` now always means `nerva view`'s.

### New: upgrades keep the data

From this release on, a cluster moves to the next release with its data. The old release's
`nerva export` writes the cluster's changes, views, ledgers and checks to a file; the new
release's `nerva import` builds each replica's data file from it, recomputing views and
everything else derived with its own code, and refuses a damaged export or a state that does
not match the checks.

```bash
nerva export --cluster=1 --addresses=3001,3002,3003 --output=cluster.nerva-export
# Stop the replicas; with the new release, once per replica:
nerva import --cluster=1 --replica=0 --replica-count=3 --input=cluster.nerva-export 1_0.nerva
nerva start --addresses=3001,3002,3003 1_0.nerva
```

- Rows, versions, history, `row?as_of`, the change feed and its cursors, documents, layouts,
  ledgers and every view's answer carry over. A view declared over rows that already existed is
  rebuilt after the new cluster starts, and its as-of history starts again; client sessions
  start again.
- Op numbers jump: the new cluster goes on from the first checkpoint at or after the export's
  op. Versions (`op_seen`) and feed cursors from before stay valid.
- Export and import work between two releases that both have them: from v0.4.0 on, the old
  release's `nerva export` and the new release's `nerva import`.
- A view declared only through the Zig client, without a catalog document, cannot be imported:
  `nerva import` refuses it. Declare views through `nerva api`.
- `nerva export` refuses an export that `nerva import` would refuse, before anything is
  stopped. `nerva import` writes `<path>.importing` and names it `<path>` only once its checks
  pass, so a failed or interrupted import leaves no data file to start.
- `--as-of=<op>` exports the cluster as of an op; by default, as of the export's start.
- See README, "Upgrading a cluster".

### New: releases carry a bill of materials

Each release has a CycloneDX 1.5 software bill of materials next to its binaries.

### New: larger documents

A document holds up to 512 KiB (it was 64 KiB), the most one commit writes atomically. Larger
values belong outside Nerva, stored by their hash. One `documents/get` reads at most as many
chunks as 256 documents of 64 KiB, and answers `413` past that: ask for fewer keys. (#25)

### Fixed

- One request with the raw operation value 134 (`pulse`) from any client crashed every replica,
  for good. Clients can no longer send it. (#33)
- Any eviction (more than 64 client sessions over a cluster's life, a client release too old)
  aborted `nerva api`, `nerva view` and Zig clients. They now report `error.Evicted` and
  reconnect. (#48, #52)
- A reply arriving after its request timed out could abort a gateway, and `nerva view` exited
  on one timeout. Both recover on their own now. (#42, #44)
- A transaction that touched more view groups than any op allows got `503 views_busy`, and
  retrying never helped. It now gets `413 views_too_large`: split it. (#32)
- A large JSON body kept up to 0.8 GB allocated in `nerva api`. A request may use at most
  128 MiB (`413 request too complex` past that), and the gateway keeps at most 8 MiB between
  requests. (#31, #60)
- With `--trace`, a full or failing trace disk panicked the replica, and the trace grew
  without bound. Trace writes are buffered and bounded now, and a write error stops tracing,
  not the replica. (#30)
- A bad view name was refused with a message about field names. It now says "a view name".
  (#77)

### Upgrading from v0.3.0

- **Stop every replica, then start them all on v0.4.0, on newly formatted data files.**
  Binaries report `0.0.4+<commit>`. A cluster cannot run two releases, and a v0.4.0 replica
  stops on a v0.3.0 data file. Load your data again.
- **Upgrade clients and gateways too.** v0.4.0 replicas refuse clients older than v0.4.0.
- `GET /v1/views/<name>` now answers the view; read the declaration at `/definition`.
- `GET /v1/views/<name>/groups` sends the replicated hash as `view_hash`; it was `hash`.
- v0.3.0 has no `nerva export`: this upgrade still means loading your data again. From
  v0.4.0 on, run the old release's `nerva export` and the new release's `nerva import`.
- Zig client users: new operations `declare_ledger` and `get_ledger` (by id, or by `slot` to
  list them: `Client.get_ledger_slot`), `AddFlags.pair`, new
  statuses `views_too_large` (15), `unpaired` (16) and `conserved_write` (17),
  `DeclareStatus.ledger_field` (10) and `table_extremes_full` (9), `DeclareLedgerStatus`,
  `min` and `max` in `AggregateFunction`, and `ViewQuery.as_of`. Existing values keep their
  numbers.

## v0.3.0 — 2026-10-05

Views that the cluster keeps itself, metrics and traces from replicas, a faster client, and a
round of gateway fixes. **This release is not compatible with v0.2.0's data files, and its
replicas must never run in one cluster with v0.2.0 replicas:** see "Upgrading" below.

### New: maintained views

A view whose aggregates are `count` and `sum` is now kept by the state machine inside every
commit, like the rows. Every replica holds the same groups and the same hash at every op, and
nothing is rebuilt when a process restarts. Declare it as before; read its groups from
`nerva api`:

```bash
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/views/revenue -d '{
  "table": 5, "where": [{"field": "sold", "op": "eq", "value": true}],
  "group_by": ["section"], "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"}]}'
curl -H 'X-Nerva-Key: secret' 'http://127.0.0.1:8080/v1/views/revenue/groups?limit=100'
# {"view":"revenue","id":1,"state":"ready","op":"1240","hash":"…","group_count":"8",
#  "groups":[{"section":4,"count":"369","sum_price":"184590"},…],"more":false,"cursor":null}
```

- A view declared over existing rows says `"state":"building"` until the cluster has added
  them, a bounded number per op; then `"ready"`.
- Groups come a page at a time (`cursor`, `limit`), in storage order.
- An `add` to a field a maintained view filters or groups by answers `409 view_key_field`.
- One op touches at most about 4,000 distinct groups; a transaction past that answers
  `503 views_busy`.
- `min`, `max` and as-of answers are still served by `nerva view`.

### New: metrics and traces

- `nerva start --statsd=<host:port>` sends the replica's metrics (requests, commits, caches,
  client round trips) over UDP every 10 seconds, in statsd format with DogStatsD tags.
- `nerva start --trace=<path>` writes a JSON span trace. The path must be a new file: an
  existing one is refused (#29).
- `nerva start --cache-rows=<size>` sizes the row cache.
- `zig build bench` and `zig build bench:load` measure Nerva's parts and a running cluster.

### Faster

The Zig client, and so `nerva api`, returns as soon as its reply arrives instead of at the end
of a 10 ms tick. Through `nerva api` on a local three-replica cluster, lookup p50 went from
10.60 ms to 1.05 ms and commit p50 from 10.53 ms to 0.92 ms.

### Fixed

- A request head ending in a bare LF crashed `nerva api` and `nerva view` before the key was
  checked. (#8)
- A slow client stalled a gateway: the timeout was per read, not per request. Gateways now read
  up to 16 connections at once, with a 10 s deadline per request. (#9)
- The `X-Nerva-Key` check took time that depended on the key. It is constant-time now. (#10)
- When all 16 slots were taken by idle connections, a gateway shut everyone else out for
  minutes, with no key needed. A new connection now displaces the oldest one that is still
  sending its request. (#28)
- `GET /v1/views/groups` crashed `nerva api`. It is now `404`, and a view named `groups` reads
  at `/v1/views/groups/groups`. (#26)
- After one cluster timeout, `nerva api` answered `503` to every later request, while
  `/healthz` still said `200`. It now reconnects, and `/healthz` answers `503` until the
  cluster is reachable again. (#27, #37)
- `nerva start --trace=<path>` truncated whatever file it named, a data file included. (#29)
- A replica of another release could join a cluster: it counted toward quorums while running
  the log with different code, and panicked with `checkpoint diverged` at the first checkpoint
  (about 960 ops). Replicas now ignore peers that run another release, and log it:
  `replica 2 runs release 0.0.2, this replica runs 0.0.3: ignoring it`. (#34)
- A JSON body with newlines (`curl -d` with a multi-line body, as in the examples above) was
  refused with `400 malformed request` when it arrived in the same read as its head. (#36)
- `documents.Transaction` (Zig) could read a value stitched from two versions when a rewrite
  landed between its reads. (#7)

### Known issues

- With `--trace`, a trace write error panics the replica, and the trace grows without bound.
  (#30)
- A 4 MiB JSON body keeps about 0.8 GB allocated in `nerva api` for the rest of its life. (#31)
- A transaction touching more view groups than one op allows gets `503 views_busy`, and
  retrying will never make it succeed. (#32)
- Any client can send `pulse`, the cluster's internal backfill operation. (#33)

### Upgrading from v0.2.0

- **Stop every replica, then start them all on v0.3.0.** A cluster cannot run two releases. A
  v0.3.0 replica ignores v0.2.0 peers, so during a one-at-a-time upgrade it never counts toward
  their quorums, nor they toward its own. A v0.2.0 replica facing a v0.3.0 majority stops with
  `panic: attempt to use null value` at the first operation it does not know.
- **Reformat data files.** Binaries now report `0.0.3+<commit>`. A v0.3.0 replica stops on a
  v0.2.0 data file with `panic: multiversion unsupported`. Format new files and load your data
  again.
- **Clients and gateways can follow.** v0.3.0 replicas still accept v0.2.0 clients, so a v0.2.0
  `nerva api` keeps committing and reading against a v0.3.0 cluster. It does not have the new
  routes (`/v1/views/<name>/groups`).
- Zig client users: new operations `declare_view`, `get_view` (`pulse` is internal), new
  statuses `view_key_field` and `views_busy`, and `Client.reconnect`. Existing values keep their
  numbers.

## v0.2.0 — 2026-10-04

Two new capabilities for applications on `nerva api`, values larger than a row and counters
that many clients can change at once, plus two crash fixes. **This release is not compatible
with v0.1.0's data files or clients:** see "Upgrading" below.

### New: documents (larger values by key)

Store values of up to 64 KiB under string keys (up to 1024 bytes of UTF-8), grouped by a
namespace, without chunking them yourself. Reads and writes are optimistic transactions, like
rows.

```bash
curl -H 'X-Nerva-Key: secret' -d '{"namespace":"7",
  "reads":[{"key":"cart/1","version":"0"}],
  "writes":[{"key":"cart/1","value_hex":"7b7d"}]}' http://127.0.0.1:8080/v1/documents/commit
# {"status":"committed","op":"42"}
curl -H 'X-Nerva-Key: secret' -d '{"namespace":"7","keys":["cart/1"]}' \
    http://127.0.0.1:8080/v1/documents/get
# {"op":"43","documents":[{"key":"cart/1","exists":true,"version":"42","value_hex":"7b7d"}]}
```

- `POST /v1/documents/get` reads up to 256 keys at one op: the latest, or `"as_of"` any
  committed op. Each document has a `version` (the op of its last write; `"0"` if never
  written).
- `POST /v1/documents/commit` is one transaction of reads at the version seen, puts and
  deletes. A stale read answers `409` with the key and its current version; nothing applies.
- `GET /v1/documents/changes?namespace=&cursor=&limit=` lists a namespace's document writes in
  commit order, including deletes (each with its key).
- Up to about 600 KB of keys and values per commit.

### New: adds (counters and budgets without conflicts)

An `add` changes one 64-bit field of a row inside the commit, without reading it first. Adds to
the same row never conflict, so many clients can draw on one budget or stock count at once with
no retries.

```bash
# Reserve up to 30 from `available` and hold exactly what was taken, in one transaction.
curl -H 'X-Nerva-Key: secret' -d '{"entries":[
  {"kind":"add","table":5,"id":"1","field":"available","delta":"-30","min":"0","clamp":true},
  {"kind":"add","table":5,"id":"1","field":"held","delta_from":0}]}' \
    http://127.0.0.1:8080/v1/commit
# {"status":"committed","op":"44","adds":[{"index":0,"applied":"-20","value":"0"},
#                                         {"index":1,"applied":"20","value":"20"}]}
```

- Fields are `u64` or `i64`, named by the table's layout or given by `offset` and `type`.
- `min` and `max` bound the result. Crossing a bound fails the transaction with `409
  out_of_bounds` (with the field's current value), or with `clamp` the add takes what fits.
- `delta_from` moves exactly what an earlier add of the same transaction applied, so a
  reservation can never overdraw.
- An add to a row that does not exist answers `409 row_absent`, unless `create` starts it at
  zero.
- Adds appear in the change feed, history, as-of reads and declared views like any other write.

### Fixed

- A cluster could crash when one request carried two writes that left a row unchanged (for
  example two identical puts). Every replica failed on the same op. Nerva's own client never
  sent such requests, but the protocol allows them. (#4)
- One oversized request (too many rows or entries) made the next request to the same
  `nerva api` gateway crash it. Oversized requests now just answer `400`. (#5)

### Upgrading from v0.1.0

- **Reformat data files.** v0.2.0 refuses data files formatted by v0.1.0 ("found incompatible
  superblock version 0"). Nothing carries over: format new files and load your data again.
- **Upgrade every process together.** Replicas refuse clients from v0.1.0, and the two releases
  cannot run in one cluster. Binaries now report `0.0.2+<commit>` (the protocol release, then
  the commit).
- Zig client users: `EntryResult` is now 32 bytes (with `applied` and `value`), and
  `EntryKind`, `EntryStatus` gained values. Existing values keep their numbers.
- JSON API users: nothing changes for existing requests and replies; a commit reply carries
  `adds` only when the commit had adds.

## v0.1.0 — 2026-10-04

The first release.

- **Commit core:** rows of 80 bytes keyed by `(table, id)`, optimistic transactions (reads at
  the version seen, puts and deletes), a change feed, and every row's history as of any op.
- **`nerva api`:** the core operations as JSON over HTTP, table layouts (named, typed fields).
- **`nerva view`:** declared views (where, group by, count, sum, min, max) over a table, latest
  or as of any op, each answer with a hash.
- Replication, storage and the simulator from TigerBeetle; binaries for Linux and macOS
  (x86_64, aarch64). Binaries report `0.0.1+<commit>`.
