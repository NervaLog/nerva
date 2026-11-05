# Nerva tutorial

This tutorial takes you from an empty directory to a running Nerva cluster, then through every
capability it has today: rows and versions, transactions, the change feed and time travel, typed
layouts, conflict-free counters, conserved ledgers, declared views, documents, commit keys,
records and indexes, and surviving a crash. It ends with a
tour of the code for people who want to change Nerva itself.

It assumes you are comfortable with a shell, `curl` and JSON, and know roughly what a database
transaction is. You do not need to know Zig until the last two parts.

Every reply shown below is real output from a run of these exact commands: Part 9 and the
version in Part 1 against v0.6.0, the rest against v0.5.0 (nothing they show changed since).
**Your op numbers will differ**: see "Ops move on their own" in Part 2.

> Nerva is a research database (see the [README](../README.md)). Do not put data in it that you
> cannot lose.

## Contents

- [Part 0: The idea in five minutes](#part-0-the-idea-in-five-minutes)
- [Part 1: Build and start a cluster](#part-1-build-and-start-a-cluster)
- [Part 2: Rows and versions](#part-2-rows-and-versions)
- [Part 3: Transactions](#part-3-transactions)
- [Part 4: The log: changes, history, time travel](#part-4-the-log-changes-history-time-travel)
- [Part 5: Layouts: typed fields instead of hex](#part-5-layouts-typed-fields-instead-of-hex)
- [Part 6: Adds and ledgers: counters and balances](#part-6-adds-and-ledgers-counters-and-balances)
- [Part 7: Declared views](#part-7-declared-views)
- [Part 8: Documents: larger values by key](#part-8-documents-larger-values-by-key)
- [Part 9: Facts beside money: commit keys, records and indexes](#part-9-facts-beside-money-commit-keys-records-and-indexes)
- [Part 10: Crashes, retries and upgrades](#part-10-crashes-retries-and-upgrades)
- [Part 11: The Zig client](#part-11-the-zig-client)
- [Part 12: Inside Nerva, for contributors](#part-12-inside-nerva-for-contributors)
- [Cheat sheet](#cheat-sheet)

---

## Part 0: The idea in five minutes

Most applications keep one copy of the truth and many derived copies: a cache, a search index,
a "total sales by section" table, a sync feed for mobile clients, an audit history. Keeping them
consistent means change-data-capture pipelines, queues and backfill scripts, and every one of
them can drift.

Nerva's bet is that there should be **one ordered, replicated log**, and that every piece of
state, base rows and derived views alike, is a deterministic function of that log. Four ideas
follow from it, and they run through the whole tutorial:

1. **Every request has a position, its op.** The log is numbered: op 1, op 2, op 3… A write
   tells you the op it committed at. A read tells you the op it reflects. "Is this current?"
   becomes a comparison of two numbers.
2. **A row's version is the op of its last write.** No separate version counter: if a row says
   `"op":"10"`, op 10 was the last thing to write it. Version `0` means "never existed".
3. **Transactions are optimistic.** You read rows (noting their versions), decide what to
   write, and send the reads and writes together. If any row you read has changed since,
   nothing applies and you get a `conflict`. No locks are held while you think.
4. **Derived state is declared, not hand-built.** You tell Nerva "keep count and sum of price
   by section for sold seats", and from then on every commit maintains it, with a hash that two
   copies can compare.

### What Nerva is for

Nerva is meant to be a **system of record for autonomous agency**. When software agents act on
someone's behalf (spending from a budget, claiming a job, asking for and acting on an approval),
the questions that follow are an auditor's: what ran, who authorized it, and was what it relied
on current? A system of record answers them from its own guarantees, without depending on the
care of every application around it. Here is how Nerva's guarantees answer them. Each
authorization, receipt and balance change is a position in one log. A claim is a compare-and-set
that exactly one agent wins (Part 3). A budget is a ledger that no request can overdraw or
inflate (Part 6). What an agent knew when it decided is a read as of the op of its decision
(Part 4), and a report is a view whose hash anyone can check (Part 7). Nerva itself stays
general: it knows nothing about agents, and each application's own rules live in that
application. Two parts of this picture are still to come: exactly-once effects on outside
systems, and approvals tied to an identity ([docs/GOALS-1.0.md](./GOALS-1.0.md), G5 and G7).

The machinery underneath (Viewstamped Replication consensus, an LSM storage engine, io_uring
IO and a deterministic simulator) is vendored from [TigerBeetle](https://github.com/tigerbeetle/tigerbeetle).
Nerva's own code is the state machine on top, plus the gateways and tools around it.

### The processes you will run

```
             curl / your app (JSON over HTTP)
                 │                       │
     writes, reads, views        independent check
                 ▼                       ▼
         ┌──────────────┐        ┌──────────────┐
         │  nerva api   │        │  nerva view  │   gateways: stateless, restartable
         │  :8080       │        │  :8091       │
         └──────┬───────┘        └──────┬───────┘
                │  binary VSR protocol  │ (follows the change feed)
                ▼                       ▼
         ┌──────────────────────────────────────┐
         │  nerva start  ×1 (or ×3, ×5, …)      │   replicas: the log and all state
         │  :3001 …                             │
         └──────────────────────────────────────┘
```

- **`nerva start`** runs a replica: one data file, one member of the consensus group.
- **`nerva api`** is a gateway that turns JSON over HTTP into Nerva requests. It holds no
  data of its own.
- **`nerva view`** follows the change feed and recomputes declared views on its own, as an
  independent check on the views the replicas maintain. It is optional.

---

## Part 1: Build and start a cluster

### Build

You need Linux (io_uring) or macOS, on x86_64 with AES or on aarch64. The repository pins its
own Zig compiler:

```bash
git clone https://github.com/Botpike/nerva-ledger.git
cd nerva-ledger
./zig/download.sh      # installs Zig 0.14.1 into ./zig
./zig/zig build        # builds zig-out/bin/nerva (a few minutes the first time)
./zig-out/bin/nerva version
# Nerva version 0.0.6+0d8d13a
```

The version is `<protocol release>+<commit>`: `0.0.6` is the protocol release of v0.6.0. It
decides which replicas, data files and clients work together (see "One release per cluster"
below).

Or skip the build: v0.6.0 binaries for Linux and macOS (x86_64, aarch64) are on the
[releases page](https://github.com/Botpike/nerva-ledger/releases), each with a bill of
materials (`nerva-v0.6.0.cdx.json`) listing exactly what went into it. This tutorial matches
v0.6.0; [CHANGELOG.md](../CHANGELOG.md) lists what each release changed, and the README's
[Limits](../README.md#limits) section lists every limit a caller can hit.

### Start one replica

A production cluster has three or more replicas, which is what makes it survive failures. For
learning, one replica behaves the same way through the API and needs a third of the disk and
memory. Use a scratch directory:

```bash
mkdir -p /tmp/nerva-tutorial && cd /tmp/nerva-tutorial
NERVA=~/nerva-ledger/zig-out/bin/nerva     # adjust to where you built it

$NERVA format --cluster=1 --replica=0 --replica-count=1 --development 1_0.nerva
# info(main): 0: formatted: cluster=1 replica_count=1

$NERVA start --addresses=3001 --development 1_0.nerva > replica.log 2>&1 &
```

- `format` creates the data file (about 1.1 GiB). `--cluster` is the cluster's id, which every
  client must name; `0` is reserved for tests.
- `start` runs the replica. `--addresses` lists every replica's address in replica order;
  a bare port means `127.0.0.1`.
- `--development` lets the replica run without Direct IO (which some filesystems, like tmpfs,
  lack) and with small caches. Use it on a laptop, never in production.

A replica takes 10–15 seconds to open its data file. `replica.log` says
`listening on … port = 3001` when it is ready. It also starts with a warning:

```
warning(main): NERVA_CLUSTER_KEY is unset: replicas authenticate each other with the public development key (--development, loopback addresses only)
```

Replicas prove to each other that they hold a shared secret, the **cluster key** (see "The
cluster key" below). On a laptop, with `--development` and only loopback addresses, a missing
key falls back to a public development key, which is fine for this tutorial and protects
nothing. Without `--development`, or with any other address, `nerva start` refuses to run
without a key.

### Start the JSON gateway

```bash
export NERVA_KEY=secret
$NERVA api --cluster=1 --addresses=3001 --listen=127.0.0.1:8080 > api.log 2>&1 &

curl http://127.0.0.1:8080/healthz
# {"ok":true}
```

The gateway reads its shared secret from `NERVA_KEY`, and every request must carry it in
`X-Nerva-Key`. To change the secret without refusing anyone, restart the gateway with the new
one in `NERVA_KEY_NEXT` as well (it then accepts either), move clients to it, and restart again
with it as `NERVA_KEY` alone. Define a short helper for the rest of the tutorial:

```bash
n() { curl -s -H 'X-Nerva-Key: secret' "$@"; echo; }
A=http://127.0.0.1:8080
```

Bodies may span several lines, as the longer examples below do. (Before v0.3.0, a body with
a newline could be refused with `400 malformed request`: if you see that, upgrade.)

### A three-replica cluster

When you want the real thing, format one file per replica, choose a cluster key, and give
every replica every address and the same key:

```bash
export NERVA_CLUSTER_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
for i in 0 1 2; do
  $NERVA format --cluster=1 --replica=$i --replica-count=3 --development 1_$i.nerva
done
for i in 0 1 2; do
  $NERVA start --addresses=3001,3002,3003 --development 1_$i.nerva > replica_$i.log 2>&1 &
done
$NERVA api --cluster=1 --addresses=3001,3002,3003 --listen=127.0.0.1:8080 &
```

Everything below works identically against it. With three replicas, any one can crash and the
cluster keeps committing.

### The cluster key

Before any replica message flows between two replicas, each proves that it holds
`NERVA_CLUSTER_KEY`: an HMAC-SHA256 over fresh nonces from both sides. A process without the key
cannot join the cluster, pose as a replica or vote. Clients and gateways don't need the key.

- The key is at least 32 bytes, the same on every replica, and secret (a deployment secret, not
  a file in the repository). `nerva start` never prints it.
- To rotate it with no downtime, restart every replica three times: first with the new key as
  `NERVA_CLUSTER_KEY_NEXT`; then with the new key as `NERVA_CLUSTER_KEY` and the old one as
  `NERVA_CLUSTER_KEY_NEXT`; then without `NERVA_CLUSTER_KEY_NEXT`.
- The key proves who opened a connection, but the traffic after that is neither encrypted nor
  signed. Run replicas on a private network that encrypts (WireGuard, or Fly.io's 6PN), and put
  the gateways behind TLS for any caller off that network. The README's
  [Limits](../README.md#limits) section says what is and isn't protected.

### One release per cluster

Every replica of a cluster must run the same release (the part of `nerva version` before the
`+`). A replica ignores peers that run another release and says so in its log (`replica 2 runs
release …, this replica runs 0.0.6: ignoring it (a cluster must run one release)`). Ignored
peers count toward nobody's quorum, so a cluster with mixed releases may stop committing. A
v0.4.0 replica can't even take part in the v0.5.0 handshake: when a v0.5.0 replica dials it, it
exits with status 7.

Data files are tied to a release too: a replica refuses a file formatted by another one. So a
cluster moves to a new release all at once, with its data carried over by `nerva export` and
`nerva import` ("Moving to a new release" in Part 10).

Clients may trail: v0.6.0 replicas accept clients from v0.4.0 on, so you can upgrade the
cluster first and `nerva api`, `nerva view` and any Zig client after it. (An older client
cannot write records: `commit` refuses an entry in a record table.)

---

## Part 2: Rows and versions

A **row** is identified by `(table, id)`: `table` is a 32-bit number other than zero, and `id`
is a 64-bit number. A row holds a fixed **80-byte value**. Nerva stores bytes; it never
interprets them (Part 5 adds names and types on top).

There is no "create table": every table exists, empty, from the start.

### Read a row that does not exist

```bash
n -d '{"rows":[{"table":1,"id":"42"}]}' $A/v1/lookup
```
```json
{"op":"4","rows":[{"table":1,"id":"42","exists":false,"op":"0","value_hex":"0000…0000"}]}
```

Two different `op`s appear here, and the difference matters:

- The outer `"op":"4"` is **the op the read executed at**. The answer reflects every commit
  before it.
- The row's `"op":"0"` is **the row's version**: zero, because it has never been written.

The `value_hex` is always the full 80 bytes (160 hex digits). It is shortened to `0000…0000`
here and below.

> **Why are 64-bit numbers strings?** JavaScript's numbers lose precision past 2^53, so ids,
> ops and cursors travel as decimal strings. `table` (32-bit) and `limit` are plain numbers.

### Write it

```bash
n -d '{"entries":[{"kind":"put","table":1,"id":"42","value_hex":"68656c6c6f"}]}' $A/v1/commit
```
```json
{"status":"committed","op":"5"}
```

`68656c6c6f` is "hello" in ASCII. Shorter values are zero-padded to 80 bytes. The commit went
into the log at op 5.

```bash
n -d '{"rows":[{"table":1,"id":"42"}]}' $A/v1/lookup
```
```json
{"op":"6","rows":[{"table":1,"id":"42","exists":true,"op":"5","value_hex":"68656c6c6f0000…"}]}
```

The row's version is now `5`, the op that wrote it.

### Ops move on their own

Notice that the lookup itself took an op (6). **Every request goes through the log**, reads
included, because that is what makes "this read reflects op 6" exact: the read is ordered
against every write. One HTTP call can also take more than one op (the first time a gateway needs a table's
layout, Part 5, it reads it from the log, and keeps it after that), and other processes make
requests of their own:
`nerva view` polls the feed, and the cluster sends itself requests while a view is building
(Part 7). So op numbers climb between your commands, and the
numbers in your terminal will not match this page. Wherever a later step uses a number from an
earlier reply, **use the one from your own reply**.

---

## Part 3: Transactions

A commit is a list of **entries**, and the whole list is **one transaction**: every entry
applies, or none does. There are four kinds:

| Kind | Fields | Meaning |
|---|---|---|
| `read` | `table`, `id`, `op_seen` | "This row's version must still be `op_seen`." Writes nothing. |
| `put` | `table`, `id`, `value_hex` (or `fields`) | Set the row's value. |
| `delete` | `table`, `id` | Remove the row (it leaves a tombstone, so its version stays exact). |
| `add` | `table`, `id`, `field`, `delta`, … | Change a 64-bit field in place (Part 6). |

### Compare-and-set

The row above is at version 5. "Change it, but only if nobody else did since I read it" is a
`read` at that version plus a `put`:

```bash
n -d '{"entries":[
  {"kind":"read","table":1,"id":"42","op_seen":"5"},
  {"kind":"put","table":1,"id":"42","value_hex":"776f726c64"}]}' $A/v1/commit
```
```json
{"status":"committed","op":"10"}
```

Now send the same thing again. The read says "version 5", but the row is at version 10:

```bash
n -d '{"entries":[{"kind":"read","table":1,"id":"42","op_seen":"5"},{"kind":"put","table":1,"id":"42","value_hex":"6c617465"}]}' $A/v1/commit
```
```json
{"status":"conflict","index":0,"op":"10"}
```

HTTP status 409. `index` is the stale entry (0, the read) and `op` is the row's current
version. Nothing was written. The usual response to a conflict is: look the row up again,
re-decide, and retry with the new version.

This is how Nerva gives you **serializable transactions without locks**. Commits execute one at
a time in op order, so checking each read's version at commit time is enough to guarantee that
no transaction acted on stale data.

### Claim something exactly once

`op_seen: "0"` means "this row must not exist". That makes exclusive claims (a receipt, a
lease, a job) a single request. Two workers race to claim receipt 1001:

```bash
# Worker A
n -d '{"entries":[{"kind":"read","table":2,"id":"1001","op_seen":"0"},{"kind":"put","table":2,"id":"1001","value_hex":"0a"}]}' $A/v1/commit
# {"status":"committed","op":"12"}

# Worker B, same claim
n -d '{"entries":[{"kind":"read","table":2,"id":"1001","op_seen":"0"},{"kind":"put","table":2,"id":"1001","value_hex":"0b"}]}' $A/v1/commit
# {"status":"conflict","index":0,"op":"12"}
```

Exactly one wins, however the two requests interleave, through crashes and network faults.
This "receipt race" is the scenario Nerva's simulator checks on every CI run (Part 12).

### All or nothing

A transaction that puts row 43 and also asserts something false:

```bash
n -d '{"entries":[{"kind":"put","table":1,"id":"43","value_hex":"01"},{"kind":"read","table":2,"id":"1001","op_seen":"0"}]}' $A/v1/commit
# {"status":"conflict","index":1,"op":"12"}

n -d '{"rows":[{"table":1,"id":"43"}]}' $A/v1/lookup
# {"op":"15","rows":[{"table":1,"id":"43","exists":false,"op":"0",…}]}
```

The read at index 1 failed, so the put at index 0 did not apply either.

### Deletes

```bash
n -d '{"entries":[{"kind":"delete","table":2,"id":"1001"}]}' $A/v1/commit
# {"status":"committed","op":"16"}

n -d '{"rows":[{"table":2,"id":"1001"}]}' $A/v1/lookup
# {"op":"17","rows":[{"table":2,"id":"1001","exists":false,"op":"16",…}]}
```

A deleted row does not exist, but its version is the delete's op (16), not zero. So a
compare-and-set against a row that was created and then deleted still conflicts correctly:
`op_seen: "0"` would be stale here.

### Invalid requests

A malformed entry answers `400` and nothing applies:

```bash
n -d '{"entries":[{"kind":"put","table":0,"id":"1","value_hex":"01"}]}' $A/v1/commit
# {"error":"table must not be zero"}
```

The rules: one transaction may write each row once (except several `add`s to one row), `read`
and `delete` carry no value, `put` and `delete` carry no `op_seen`. One commit holds up to a
few thousand entries; the exact limit comes from the message size.

---

## Part 4: The log: changes, history, time travel

Every applied write is also appended to a **change feed**. It is the same log the replicas
agree on, readable by anyone.

### The change feed

```bash
n "$A/v1/changes?limit=2"
```
```json
{"changes":[
  {"kind":"put","table":1,"id":"42","op":"5","value_hex":"68656c6c6f…"},
  {"kind":"put","table":1,"id":"42","op":"10","value_hex":"776f726c64…"}],
 "more":true,"cursor":"1791217283381577635","op":null}
```

(Reformatted across lines for reading; the gateway answers on one line.)

Changes come in commit order. `more: true` says there are more; pass `cursor` to continue:

```bash
n "$A/v1/changes?cursor=1791217283381577635&limit=100"
```
```json
{"changes":[
  {"kind":"put","table":2,"id":"1001","op":"12","value_hex":"0a…"},
  {"kind":"delete","table":2,"id":"1001","op":"16"}],
 "more":false,"cursor":"1791217283447260485","op":"22"}
```

When `more` is false, the page reached the end of the feed, and `op` says **the feed is
complete through op 22**. Store the cursor and call again later to get only what is new. That
loop is all a consumer needs to keep a cache, a search index or a mobile client in sync, with
no message queue in between. A cursor is opaque (it is a timestamp inside Nerva): store it, do
not compute with it. Pages hold at most 1024 changes.

### A row's history

```bash
n "$A/v1/history?table=1&id=42&op_max=latest&limit=10"
```
```json
{"changes":[
  {"kind":"put","table":1,"id":"42","op":"10","value_hex":"776f726c64…"},
  {"kind":"put","table":1,"id":"42","op":"5","value_hex":"68656c6c6f…"}],
 "more":false,"cursor":null,"op":"24"}
```

One row's writes, newest first, served from an index on the feed.

### Time travel

"What was this row at op N?" is a first-class read:

```bash
n "$A/v1/row?table=1&id=42&as_of=5"
# {"table":1,"id":"42","as_of":"5","exists":true,"op":"5","value_hex":"68656c6c6f…"}

n "$A/v1/row?table=1&id=42&as_of=4"
# {"table":1,"id":"42","as_of":"4","exists":false,"op":"0",…}

n "$A/v1/row?table=1&id=42&as_of=999999999"
# {"error":"as_of is not yet committed"}
```

Asking about the future is refused rather than answered with today's value, so an `as_of`
answer is always final: it can never change later. This is what lets an application answer an
auditor's "what did the system know when it decided?": record the op of a decision, and read
every input as of that op.

---

## Part 5: Layouts: typed fields instead of hex

Hex is fine for the core, but tedious for people. A **layout** names and types the fields
packed into a table's 80 bytes:

```bash
n -X PUT $A/v1/tables/5 -d '{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},{"name":"sold","type":"bool"}]}'
# {"table":5,"layout":"created"}

n $A/v1/tables/5
# {"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},{"name":"sold","type":"bool"}]}
```

Types are `u8`, `u16`, `u32`, `u64`, `i64`, `bool` and `bytes` (with a size). Now puts can send
`fields` instead of `value_hex`, and reads return both:

```bash
n -d '{"entries":[
  {"kind":"put","table":5,"id":"1","fields":{"section":1,"price":"100","sold":true}},
  {"kind":"put","table":5,"id":"2","fields":{"section":1,"price":"100","sold":false}},
  {"kind":"put","table":5,"id":"3","fields":{"section":2,"price":"250","sold":true}},
  {"kind":"put","table":5,"id":"4","fields":{"section":2,"price":"250","sold":true}}]}' $A/v1/commit
# {"status":"committed","op":"38"}

n -d '{"rows":[{"table":5,"id":"3"}]}' $A/v1/lookup
```
```json
{"op":"39","rows":[{"table":5,"id":"3","exists":true,"op":"38",
  "value_hex":"0200000000000000fa0000000000000001…",
  "fields":{"section":2,"price":"250","sold":true}}]}
```

Look at `value_hex` to see how fields are packed: in declaration order, each aligned to its own
size, little-endian. `section` (u8) is byte 0, `price` (u64) is padded to byte 8 (`fa` = 250),
and `sold` is byte 16. (`u64` and `i64` values are strings in JSON, like ids.)

Some things to know about layouts:

- **Layouts live in the log** too, in a reserved catalog table. The replicas still store
  bytes; only the gateways use layouts. A layout changes nothing about data already written.
- **A layout can only grow**, by sending the whole layout again with fields appended (the
  reply says `"layout":"extended"`). Rows written earlier read the new fields as zero.
  Renaming, reordering or retyping answers `409` ("a layout may only be extended by appending
  fields"), because old rows would be misread.
- Tables from `4294901760` (`0xFFFF0000`) up are Nerva's own and are refused by the API.

---

## Part 6: Adds and ledgers: counters and balances

Compare-and-set is the right tool for claims, but the wrong one for a **hot counter**. If fifty
clients decrement one budget at once with read-then-write, forty-nine of them conflict and
retry, and that repeats. An **add** changes a 64-bit field inside the commit, without reading
it first. Adds to one row never conflict; they just apply in log order.

A budget with two fields:

```bash
n -X PUT $A/v1/tables/6 -d '{"name":"budgets","fields":[{"name":"available","type":"u64"},{"name":"held","type":"u64"}]}'
# {"table":6,"layout":"created"}
```

Fund it with 50. `create: true` starts the row at all zeros if it does not exist:

```bash
n -d '{"entries":[{"kind":"add","table":6,"id":"1","field":"available","delta":"50","create":true}]}' $A/v1/commit
# {"status":"committed","op":"46","adds":[{"index":0,"applied":"50","value":"50"}]}
```

Each add reports what it `applied` and the field's new `value`.

### A reservation that can never overdraw

"Take up to 30 from `available`, and put exactly what was taken into `held`" is two adds in
one transaction:

```bash
n -d '{"entries":[
  {"kind":"add","table":6,"id":"1","field":"available","delta":"-30","min":"0","clamp":true},
  {"kind":"add","table":6,"id":"1","field":"held","delta_from":0}]}' $A/v1/commit
```

Run it three times:

```json
{"status":"committed","op":"49","adds":[{"index":0,"applied":"-30","value":"20"},{"index":1,"applied":"30","value":"30"}]}
{"status":"committed","op":"52","adds":[{"index":0,"applied":"-20","value":"0"},{"index":1,"applied":"20","value":"50"}]}
{"status":"committed","op":"55","adds":[{"index":0,"applied":"0","value":"0"},{"index":1,"applied":"0","value":"50"}]}
```

- `min: "0"` is a floor. With `clamp: true`, an add that would cross it applies as much as
  fits: the second reservation got 20, the third got 0.
- `delta_from: 0` means "move the negation of whatever entry 0 applied". So `held` always
  rises by exactly what `available` lost, and `available + held` stays 50, however many clients
  reserve at once.

### Strict bounds and absent rows

Without `clamp`, crossing a bound fails the whole transaction:

```bash
n -d '{"entries":[{"kind":"add","table":6,"id":"1","field":"available","delta":"-1"}]}' $A/v1/commit
# {"status":"out_of_bounds","index":0,"value":"0"}        (409; value is the field now)

n -d '{"entries":[{"kind":"add","table":6,"id":"2","field":"available","delta":"5"}]}' $A/v1/commit
# {"status":"row_absent","index":0}                       (409; no create)
```

A `u64` field without `min` has an implicit floor of 0 (its type's range), so you cannot
underflow a counter by accident. `max` works the same way upwards.

Adds are ordinary writes everywhere else: they appear in the change feed (as the whole new row),
in history and in as-of reads. Without a layout, name the field by byte `offset` and `type`
(`u64` or `i64`) instead of `field`.

### Ledgers: balances the cluster conserves

The budget above is only as safe as the requests your application sends. A bug that sends a
lone `+50`, or a `put` of the whole row, creates money. A **ledger** moves that rule into the
cluster: you declare a set of `i64` fields as **conserved**, and from then on the state machine
changes them in one way only, by a **pair** of adds that moves one amount from one field of the
ledger to another. No request, however it is built, can create or destroy value, overdraw a
field with a floor, or overwrite a balance.

Two tables: accounts, with money `available` and `held`, and a source of funds outside the
system (the bank, say). Then the ledger over their three fields:

```bash
n -X PUT $A/v1/tables/7 -d '{"name":"accounts","fields":[{"name":"available","type":"i64"},{"name":"held","type":"i64"}]}'
# {"table":7,"layout":"created"}
n -X PUT $A/v1/tables/8 -d '{"name":"sources","fields":[{"name":"balance","type":"i64"}]}'
# {"table":8,"layout":"created"}

n -X PUT $A/v1/ledgers/1 -d '{"fields":[
  {"table":7,"field":"available","floor":"0"},
  {"table":7,"field":"held","floor":"0"},
  {"table":8,"field":"balance","floor":null}]}'
# {"ledger":1,"declared":"created","op":"75"}
```

`available` and `held` may never go below 0. `balance` has no floor, so it can go negative: that
is how money enters the system, and its negative balance is what was paid in.

**Fund** account 1 with 100. The first entry is the pair's first half (`"pair": true`); the
next entry is its partner, which names it in `delta_from` and moves exactly what it took:

```bash
n -d '{"entries":[
  {"kind":"add","table":8,"id":"1","field":"balance","delta":"-100","pair":true,"create":true},
  {"kind":"add","table":7,"id":"1","field":"available","delta_from":0,"create":true}]}' $A/v1/commit
# {"status":"committed","op":"94","adds":[{"index":0,"applied":"-100","value":"-100"},{"index":1,"applied":"100","value":"100"}]}
```

**Reserve** up to 30 at a time, as in the budget, but now as a pair. The first half may
`clamp` at its floor; the partner never clamps. Run four times:

```bash
n -d '{"entries":[
  {"kind":"add","table":7,"id":"1","field":"available","delta":"-30","pair":true,"clamp":true},
  {"kind":"add","table":7,"id":"1","field":"held","delta_from":0}]}' $A/v1/commit
```
```json
{"status":"committed","op":"97","adds":[{"index":0,"applied":"-30","value":"70"},{"index":1,"applied":"30","value":"30"}]}
{"status":"committed","op":"100","adds":[{"index":0,"applied":"-30","value":"40"},{"index":1,"applied":"30","value":"60"}]}
{"status":"committed","op":"103","adds":[{"index":0,"applied":"-30","value":"10"},{"index":1,"applied":"30","value":"90"}]}
{"status":"committed","op":"106","adds":[{"index":0,"applied":"-10","value":"0"},{"index":1,"applied":"10","value":"100"}]}
```

**Post** 25 of what is held to account 2, another row:

```bash
n -d '{"entries":[
  {"kind":"add","table":7,"id":"1","field":"held","delta":"-25","pair":true},
  {"kind":"add","table":7,"id":"2","field":"available","delta_from":0,"create":true}]}' $A/v1/commit
# {"status":"committed","op":"109","adds":[{"index":0,"applied":"-25","value":"75"},{"index":1,"applied":"25","value":"25"}]}
```

Now try to break it:

```bash
# A lone add to a conserved field: it would create money.
n -d '{"entries":[{"kind":"add","table":7,"id":"1","field":"available","delta":"5"}]}' $A/v1/commit
# {"status":"unpaired","index":0}                          (409)

# A put that overwrites a balance.
n -d '{"entries":[{"kind":"put","table":7,"id":"1","fields":{"available":"1000","held":"0"}}]}' $A/v1/commit
# {"status":"conserved_write","index":0}                   (409)

# Pay out 26 from an account holding 25: the floor stops it.
n -d '{"entries":[
  {"kind":"add","table":7,"id":"2","field":"available","delta":"-26","pair":true},
  {"kind":"add","table":8,"id":"1","field":"balance","delta_from":0}]}' $A/v1/commit
# {"status":"out_of_bounds","index":0,"value":"25"}        (409)
```

And check the books:

```bash
n -d '{"rows":[{"table":8,"id":"1"},{"table":7,"id":"1"},{"table":7,"id":"2"}]}' $A/v1/lookup
# … "fields":{"balance":"-100"} … "fields":{"available":"0","held":"75"} … "fields":{"available":"25","held":"0"} …
```

−100 + 0 + 75 + 25 = 0, as it was when the ledger was declared, and as it is at every op.

The rules, in full:

- **A pair** is an add with `"pair": true` at index `i` and its partner at `i + 1`: an add to
  another field of the same ledger (another row, or another field of the same row) whose
  `delta_from` is `i`, without `min`, `max`, `clamp` or `pair`. A transaction may hold several
  pairs and other entries. Anything else that adds to a conserved field is `unpaired`.
- **Floors.** The first half clamps at its floor with `clamp`, or fails `out_of_bounds`. The
  partner never clamps: if its floor stops it, the whole transaction is `out_of_bounds`.
- **Other writes.** A put may write a row's other fields, or create a row with its conserved
  fields at zero. Changing a conserved field's bytes, or deleting a row whose conserved fields
  are not all zero, is `conserved_write`.
- **Declarations** are immutable: sending the same one again answers `"declared":"exists"`
  with its original op, and a different one under the same id is `409 ledger_immutable`. A
  field belongs to one ledger at most (`ledger_field_taken`), and a view may not filter or
  group by a conserved field (Part 7). There can be at most 64 ledgers, of 2 to 16 fields each.
  `GET /v1/ledgers/1` reads a declaration back.

The simulator checks this invariant after every commit, under crashes and disk faults: every
ledger's total stays what it was when it was declared, and no field ever moves past its floor.

---

## Part 7: Declared views

A **view** is a declaration stored in the log, not code you run. Declare "count and total
price of sold seats, by section":

```bash
n -X PUT $A/v1/views/revenue -d '{
  "table": 5,
  "where": [{"field": "sold", "op": "eq", "value": true}],
  "group_by": ["section"],
  "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"}]}'
# {"view":"revenue","declared":"created","maintained":true}
```

- `where` ANDs up to four comparisons (`eq`, `ne`, `lt`, `le`, `gt`, `ge`) on numeric and
  bool fields.
- `group_by` takes up to three fields.
- `aggregates` are `count`, `sum`, `min` and `max`.
- Names are lowercase letters, digits and `_`.

A view is immutable. Declaring the same name with the same definition again answers
`"declared":"unchanged"`, so declarations are safe to run at every application start. With a
different definition, it answers `409` ("declared differently; views are immutable"): pick a new
name instead.

The state machine maintains every view **inside every commit**, alongside the rows: each
write updates its row's groups, and every replica holds the same groups at every op. Reading a
view reads its groups, not the rows, and nothing has to be rebuilt when a process restarts.

### Read a view

```bash
n $A/v1/views/revenue
```
```json
{"view":"revenue","op":"142",
 "hash":"aa945a74f02106ab0fd8759a5c46e31be48aff918a4f737b0638215c6d10026a",
 "view_hash":"0c8ceeee30d22fcca2f2a5b97e80be1cf94912ed80cfc7218ff1225874c29739",
 "declared_op":"129",
 "groups":[{"section":1,"count":"1","sum_price":"100"},
           {"section":2,"count":"2","sum_price":"500"}]}
```

Seat 2 (section 1) is not sold, so section 1 counts one seat. The view was declared after the
seats were written, and it still counts them: a view declared over existing rows is
`building` while the cluster backfills them, a bounded number per op, and reads answer `503`
until it is `ready`. With four rows, that was instant.

The answer is the whole view, read at one op (`op`), with groups sorted by key. It carries two
hashes:

- **`hash`** is the SHA-256 of the `groups` JSON exactly as served. Two answers with the same
  groups have the same `hash`, whoever computed them (see "Check it independently" below).
- **`view_hash`** is the replicas' own hash of the view's state (a sum of per-group digests,
  cheap to update on every write). Every replica holds the same `view_hash` at every op.

`GET /v1/views` lists the views, and `/definition` reads a declaration back:

```bash
n $A/v1/views
# {"views":[{"name":"revenue","id":1,"state":"ready","declared_op":"129","group_count":"2"}]}
n $A/v1/views/revenue/definition
# {"table":5,"where":[{"field":"sold","op":"eq","value":"1"}],"group_by":["section"],"aggregates":[{"fn":"count"},{"fn":"sum","field":"price"}]}
```

### Read the past, and your own writes

Sell seat 2 and note the op:

```bash
n -d '{"entries":[{"kind":"put","table":5,"id":"2","fields":{"section":1,"price":"100","sold":true}}]}' $A/v1/commit
# {"status":"committed","op":"160"}
```

`min_op` asks for a view that reflects at least that op. Use it when the write went through
another gateway, or when you pass an op between services:

```bash
n "$A/v1/views/revenue?min_op=160"
# {"view":"revenue","op":"165","hash":"2560a945…","view_hash":"3ab4f4c8…","declared_op":"129","groups":[{"section":1,"count":"2","sum_price":"200"},{"section":2,"count":"2","sum_price":"500"}]}
```

`as_of` reads the view exactly as an op left it. Here it is just before the sale:

```bash
n "$A/v1/views/revenue?as_of=159"
# {"view":"revenue","op":"159","hash":"aa945a74…","view_hash":"0c8ceeee…","declared_op":"129","groups":[{"section":1,"count":"1","sum_price":"100"},{"section":2,"count":"2","sum_price":"500"}]}

n "$A/v1/views/revenue?as_of=128"
# {"error":"the view was declared after as_of"}            (404)
n "$A/v1/views/revenue?as_of=999999999"
# {"error":"as_of is not yet committed"}                   (504)
```

Op 159 has the same groups as op 142, so it has the same `hash`. **A hash is a function of the
groups only**: two gateways, two clusters fed the same writes, or `nerva view` all agree on it
exactly, so checking that two copies of a report agree means comparing 64 hex digits. (Every run
of this tutorial so far, on fresh clusters of three different releases, hashed the groups above
to `2560a945…`.)

### Large views: pages

A view of more than 10,000 groups is too big to answer whole. Read it a page at a time from
`/groups` instead, following `cursor` while `more` is true:

```bash
n "$A/v1/views/revenue/groups?limit=1"
# {"view":"revenue","id":1,"state":"ready","op":"185","declared_op":"129","view_hash":"3ab4f4c8…","group_count":"2","groups":[{"section":1,"count":"2","sum_price":"200"}],"more":true,"cursor":"17233920722255747274"}
n "$A/v1/views/revenue/groups?limit=1&cursor=17233920722255747274"
# {… "groups":[{"section":2,"count":"2","sum_price":"500"}],"more":false,"cursor":null}
```

Pages come in storage order (by group hash, not by key), each read at its own op; `as_of` pins
them all to one. Each page carries the replicated `view_hash`, the same on every page while
the view does not change. Reading a view of more than 10,000 groups whole answers `400`.

### `min` and `max`

`min` and `max` stay exact even when the row holding them changes or disappears, because the
replicas keep each group's values in order. Declare a second view:

```bash
n -X PUT $A/v1/views/cheapest -d '{"table":5,"group_by":["section"],"aggregates":[{"fn":"count"},{"fn":"min","field":"price"},{"fn":"max","field":"price"}]}'
# {"view":"cheapest","declared":"created","maintained":true}
```

Add a cheap seat to section 2, read the view, delete the seat, and read it again:

```bash
n -d '{"entries":[{"kind":"put","table":5,"id":"5","fields":{"section":2,"price":"90","sold":false}}]}' $A/v1/commit
n $A/v1/views/cheapest
# {… "groups":[{"section":1,"count":"2","min_price":"100","max_price":"100"},{"section":2,"count":"3","min_price":"90","max_price":"250"}]}

n -d '{"entries":[{"kind":"delete","table":5,"id":"5"}]}' $A/v1/commit
n $A/v1/views/cheapest
# {… "groups":[{"section":1,"count":"2","min_price":"100","max_price":"100"},{"section":2,"count":"2","min_price":"250","max_price":"250"}]}
```

A table has at most four views, and its views may have at most four `min` and `max`
aggregates between them (64 views in the whole cluster). A view that
would add a fifth is still declared, but answers `"maintained": false` with a `reason` ("the
table's views have too many min and max aggregates (at most 4)"). `nerva api` answers `404` for
it, and only `nerva view` (below) serves it.

### Check it independently: `nerva view`

`nerva view` is a separate process that follows the change feed, keeps the rows in memory, and
computes views from them when asked: none of the replicas' view code is involved. It serves the
same route with the same answer, so it is the independent check on the replicas:

```bash
$NERVA view --cluster=1 --addresses=3001 --listen=127.0.0.1:8091 > view.log 2>&1 &
V=http://127.0.0.1:8091

n "$A/v1/views/revenue?as_of=229"
# {"view":"revenue","op":"229","hash":"2560a945…","view_hash":"3ab4f4c8…","declared_op":"129","groups":[…]}
n "$V/v1/views/revenue?as_of=229"
# {"view":"revenue","op":"229","hash":"2560a945…","groups":[…]}
```

The groups are byte for byte the same, so `hash` is the same. `nerva view` can also answer for
ops before a view was declared (`as_of=128` works there), and its `min_op` waits until it has
read that far into the feed. It holds at most two million changes in memory and rebuilds from
the feed when it restarts, so treat it as a checker and a tool, not as the place to serve
views from.

### Adds and views

Adds to a summed field are what maintained views are for, and they work as expected:

```bash
n -d '{"entries":[{"kind":"add","table":5,"id":"3","field":"price","delta":"-50"}]}' $A/v1/commit
# {"status":"committed","op":"238","adds":[{"index":0,"applied":"-50","value":"200"}]}
```

An add to a field that a view **filters or groups by** is refused, because an add must never
move a row from one group to another. Here an add over the first 8 bytes, which include
`section`:

```bash
n -d '{"entries":[{"kind":"add","table":5,"id":"3","offset":0,"type":"u64","delta":"1"}]}' $A/v1/commit
# {"status":"view_key_field","index":0}      (409)
```

Change such fields with a `put`.

Ledgers (Part 6) have a matching rule. A view may sum a conserved field, or take its `min` or
`max`, but may not filter or group by one, since only pairs of adds may change it:

```bash
n -X PUT $A/v1/views/by_available -d '{"table":7,"group_by":["available"],"aggregates":[{"fn":"count"}]}'
# {"error":"the view filters or groups by a field of a ledger"}       (409)
n -X PUT $A/v1/views/total_held -d '{"table":7,"group_by":[],"aggregates":[{"fn":"sum","field":"held"}]}'
# {"view":"total_held","declared":"created","maintained":true}
n $A/v1/views/total_held
# {"view":"total_held","op":"256",…,"declared_op":"247","groups":[{"sum_held":"75"}]}
```

### Large transactions: `views_too_large`

Maintaining views costs work inside the commit, so one op may touch at most about 4,000
distinct view groups, counted across all of a table's views. A row that moves between groups
touches both. A transaction past that answers `413 {"status":"views_too_large","index":…}` and
applies nothing.

**Split the transaction**: no retry of it can succeed. It happens with bulk loads into a view
grouped by a high-cardinality field. For example, with a view `by_price` grouping seats by
price, one commit of 5,000 seats at 5,000 different prices:

```bash
n -X PUT $A/v1/views/by_price -d '{"table":5,"group_by":["price"],"aggregates":[{"fn":"count"}]}'
n -d @bulk.json $A/v1/commit        # 5,000 puts, each a new price
# {"status":"views_too_large","index":0}                   (413)
```

Send such loads in transactions of a few hundred rows. `min` and `max` add a second limit:
each write takes one of about 8,000 member slots per op for every `min` or `max` on its table,
so a table with four of them takes about 2,000 rows per transaction.
(`503 views_busy` means something else, which `nerva api` and the Zig client never meet: in a
request that packs several transactions, earlier ones filled the op. Nothing applied, and a
retry fits.)

Groups are counted once however many writes land in them: a transaction of thousands of puts
into the same few sections is fine.

---

## Part 8: Documents: larger values by key

Rows are 80 bytes with numeric ids. **Documents** hold up to 512 KiB under a string key (up to
1024 bytes of UTF-8), in a numeric `namespace`. Nerva splits them over rows of a reserved table
for you. They follow the same optimistic model: a read names the `version` you saw, and `"0"`
means "must not exist".

```bash
# {"items":[]} as hex
n -d '{"namespace":"7","reads":[{"key":"cart/alice","version":"0"}],"writes":[{"key":"cart/alice","value_hex":"7b226974656d73223a5b5d7d"}]}' $A/v1/documents/commit
# {"status":"committed","op":"270"}

n -d '{"namespace":"7","keys":["cart/alice","cart/bob"]}' $A/v1/documents/get
# {"op":"271","documents":[{"key":"cart/alice","exists":true,"version":"270","value_hex":"7b226974656d73223a5b5d7d"},{"key":"cart/bob","exists":false,"version":"0","value_hex":""}]}
```

A stale read conflicts and names the key:

```bash
n -d '{"namespace":"7","reads":[{"key":"cart/alice","version":"0"}],"writes":[{"key":"cart/alice","delete":true}]}' $A/v1/documents/commit
# {"status":"conflict","key":"cart/alice","version":"270"}     (409)
```

`documents/get` takes up to 256 keys and an optional `"as_of"`, and reads at most about 16 MiB of
documents at once (more answers `413`: ask for fewer keys). A commit carries up to about 600 KB
of keys and values, so one 512 KiB document is written atomically with room to spare.

**Values larger than 512 KiB** (uploaded files, long model outputs) belong outside Nerva: put the
bytes in a blob store under their SHA-256, then commit a small document holding the hash (and
size, type, whatever you read it by). The document is ordered, versioned and conflict-checked
like any other; the blob store only ever adds immutable objects, so it needs no transactions, and
a blob with no document pointing at it is garbage you can collect later.

Each namespace has its own feed:

```bash
n "$A/v1/documents/changes?namespace=7&limit=1000"
# {"documents":[{"key":"cart/alice","op":"270","kind":"put","value_hex":"7b2269…"}],"more":false,"cursor":"…","op":"273"}
```

This feed is filtered from the shared change feed, `limit` records at a time, so a page can come
back **empty with `more: true`**. That means "nothing for this namespace in that stretch, keep
going", not "done". Always loop until `more` is false.

---

## Part 9: Facts beside money: commit keys, records and indexes

Parts 6 and 7 moved money and summed it. A real application also keeps **facts** about each
move: which agent reserved it, for what, and whether it settled. Nerva keeps those in the same
log as the money, written in the same transaction, so there is nothing to reconcile (goal G1 in
[GOALS-1.0](GOALS-1.0.md)). Three pieces make that work: commit keys, records and indexes.

These examples ran on a fresh cluster, with Part 6's budget layout and 100 deposited into budget
`1` (`{"kind":"add","table":6,"id":"1","field":"available","delta":"100","create":true}`).
Continuing from Part 8, your amounts will differ as well as your ops.

### Commit keys: send it again, it commits once

A commit whose reply never arrived may or may not have applied ("The one rule about retries" in
Part 10). A **commit key** makes the answer certain. Start the transaction with `"key"`, 16
bytes as 32 hex digits, one per logical operation (a UUID is fine). This reserves 30 under a
key, then sends exactly the same request again:

```bash
R='{"key":"0190f1c2a7e47b3c9d2e5f6a7b8c9d0e","entries":[
  {"kind":"add","table":6,"id":"1","field":"available","delta":"-30","min":"0","clamp":true},
  {"kind":"add","table":6,"id":"1","field":"held","delta_from":0}]}'
n -d "$R" $A/v1/commit
# {"status":"committed","op":"10","adds":[{"index":0,"applied":"-30","value":"70"},{"index":1,"applied":"30","value":"30"}]}
n -d "$R" $A/v1/commit
# {"status":"committed","op":"10","replayed":true}
```

The second reply names the op the first committed at, and nothing moved twice. Other entries
under the same key are refused, because a key names one operation:

```bash
n -d '{"key":"0190f1c2a7e47b3c9d2e5f6a7b8c9d0e","entries":[…"delta":"-31"…]}' $A/v1/commit
# {"status":"key_reused","op":"10"}                        (409)
```

A transaction that did *not* commit (a conflict, a bound) keeps no key, so its resend runs
again. A replayed reply carries no `adds`: read the rows as of its op if you need the amounts.

### Records: facts with 128-bit ids

Tables from `2147483648` (`0x80000000`) up hold **records**: a 128-bit id (32 hex digits, a UUID
say) and a 448-byte value, room for most facts. Layouts work as for rows, with bytes fields of up
to 255:

```bash
n -X PUT $A/v1/tables/2147483649 -d '{"name":"executions","fields":[{"name":"agent","type":"bytes","size":16},{"name":"status","type":"u8"},{"name":"created","type":"u64"},{"name":"amount","type":"u64"}]}'
# {"table":2147483649,"layout":"created"}
```

One transaction reserves the money and writes the fact, under a key:

```bash
n -d '{"key":"0190f1c2a7e47b3c9d2e5f6a7b8c9d11","entries":[
  {"kind":"add","table":6,"id":"1","field":"available","delta":"-10","min":"0"},
  {"kind":"add","table":6,"id":"1","field":"held","delta_from":0},
  {"kind":"put","table":2147483649,"id":"0190f1c2a7e47b3c9d2e5f6a7b8c9e01",
   "fields":{"agent":"a6e70000000000000000000000000001","status":1,"created":"1001","amount":"10"}}]}' $A/v1/commit
# {"status":"committed","op":"26","adds":[{"index":0,"applied":"-10","value":"60"},{"index":1,"applied":"10","value":"40"}]}
```

(We ran it twice more, for executions `…e02` and `…e03`, created at 1002 and 1003.) If the money
cannot move, the fact is not written either:

```bash
n -d '{"entries":[{"kind":"add",…"delta":"-1000","min":"0"},{…"delta_from":0},
  {"kind":"put","table":2147483649,"id":"0190f1c2a7e47b3c9d2e5f6a7b8c9e09",…}]}' $A/v1/commit
# {"status":"out_of_bounds","index":0,"value":"40"}        (409)
n -d '{"rows":[{"table":2147483649,"id":"0190f1c2a7e47b3c9d2e5f6a7b8c9e09"}]}' $A/v1/lookup
# {"op":"45","rows":[{"table":2147483649,"id":"0190f1c2a7e47b3c9d2e5f6a7b8c9e09","exists":false,"op":"0",…}]}
```

Reading a record is a lookup, as for rows; one lookup reads rows or records, not both:

```bash
n -d '{"rows":[{"table":2147483649,"id":"0190f1c2a7e47b3c9d2e5f6a7b8c9e01"}]}' $A/v1/lookup
# {"op":"37","rows":[{"table":2147483649,"id":"0190f1c2a7e47b3c9d2e5f6a7b8c9e01","exists":true,"op":"26","value_hex":"…","fields":{"agent":"a6e70000000000000000000000000001","status":1,"created":"1001","amount":"10"}}]}
```

Records are written whole: an add to one answers `{"error":"records take no adds"}`. Keep
counters and balances in rows, beside them. Their writes join the same change feed
(`/v1/changes`), and `/v1/history` and `/v1/row?as_of` read them as they read rows.

### Indexes: find facts by their fields

A record is found by its id. To find "every reserved execution, oldest first" (what a reaper
asks every minute), declare an **index**: a table, up to three `eq` fields, an `order` field
(or, without one, the op of the last write), and an optional `where`:

```bash
n -X PUT $A/v1/indexes/reserved -d '{"table":2147483649,"order":"created","where":[{"field":"status","op":"eq","value":1}]}'
# {"index":"reserved","id":1,"declared":"created","op":"48"}
n -d '{"limit":2}' $A/v1/indexes/reserved/scan
# {"index":"reserved","op":"53","records":[{"id":"…e01","op":"26","order":"1001",…},{"id":"…e02","op":"31","order":"1002",…}],"next":"1002.1792177367900271537"}
```

A scan returns the records themselves, read at the op it names, a page at a time: send `next`
back as `"after"` for the page after. The index was declared over records that already existed;
Nerva added them in the background, and until it is done a scan answers `503`. From then on,
every commit keeps it exact. Settle the first execution (release what it held, mark it settled),
and it leaves the index in the same op:

```bash
n -d '{"entries":[
  {"kind":"add","table":6,"id":"1","field":"held","delta":"-10","min":"0"},
  {"kind":"put","table":2147483649,"id":"0190f1c2a7e47b3c9d2e5f6a7b8c9e01",
   "fields":{"agent":"a6e70000000000000000000000000001","status":2,"created":"1001","amount":"10"}}]}' $A/v1/commit
# {"status":"committed","op":"58","adds":[{"index":0,"applied":"-10","value":"50"}]}
n -d '{"max":"1002"}' $A/v1/indexes/reserved/scan
# {"index":"reserved","op":"62","records":[{"id":"…e02","op":"31","order":"1002",…}],"next":null}
```

`eq` fields pick one key's records; `min`, `max` and `descending` bound and turn the order:

```bash
n -X PUT $A/v1/indexes/by_agent -d '{"table":2147483649,"eq":["agent"],"order":"created"}'
n -d '{"eq":{"agent":"a6e70000000000000000000000000001"},"descending":true,"limit":5}' $A/v1/indexes/by_agent/scan
# {"index":"by_agent","op":"71","records":[{"id":"…e03","order":"1003",…},{"id":"…e02","order":"1002",…},{"id":"…e01","op":"58","order":"1001",…,"status":2,…}],"next":null}
n $A/v1/indexes
# {"indexes":[{"name":"reserved","id":1,"table":2147483649,"state":"ready","declared_op":"48","record_count":"2"},{"name":"by_agent","id":2,"table":2147483649,"state":"ready","declared_op":"65","record_count":"3"}]}
```

Records that tie on the order (two executions created at the same moment) come back in the
order they were first written. An index reads the latest state; to read the past, use history.

### Views over records

Part 7's views work over records too, with `count` and `sum`:

```bash
n -X PUT $A/v1/views/spend -d '{"table":2147483649,"group_by":["status"],"aggregates":[{"fn":"count"},{"fn":"sum","field":"amount"}]}'
n $A/v1/views/spend
# {"view":"spend","op":"86",…,"groups":[{"status":1,"count":"2","sum_amount":"20"},{"status":2,"count":"1","sum_amount":"10"}]}
```

`min` and `max` over records are refused (`{"error":"a view over records takes count and sum
only"}`), and `nerva view` does not compute views over records: read them from `nerva api`.

---

## Part 10: Crashes, retries and upgrades

Kill the replica the hard way, as in a power cut:

```bash
kill -9 %1        # or: kill -9 <pid of nerva start>
```

While the cluster is unreachable, `nerva api` holds each request for up to 30 seconds (`--request-timeout`), then
answers `503 {"error":"cluster unavailable"}`. If the cluster comes back within those 30
seconds, held requests simply complete. Leave it down longer and watch the gateway notice:

```bash
n -d '{"rows":[{"table":6,"id":"1"}]}' $A/v1/lookup     # waits, then:
# {"error":"cluster unavailable"}                        (503)
curl -s $A/healthz
# {"ok":false,"error":"cluster unavailable"}             (503)
```

From then on, requests answer `503` at once instead of each waiting 30 seconds, and
`/healthz` reports the gateway as unhealthy. Restart the replica from the same data file:

```bash
$NERVA start --addresses=3001 --development 1_0.nerva >> replica.log 2>&1 &
# …about ten seconds later:
n -d '{"rows":[{"table":6,"id":"1"}]}' $A/v1/lookup
# {"op":"275","rows":[{"table":6,"id":"1","exists":true,"op":"55",…,"fields":{"available":"0","held":"50"}}]}
curl -s $A/healthz
# {"ok":true}
```

`api.log` says `reconnected to the cluster`. The gateway replaces its broken connection by
itself, at most once every 5 seconds, whether or not requests arrive, so a request or two may
still see `503` while the replica opens. Then everything committed is there: a commit is acknowledged
only once it is durable on a quorum of replicas. With three replicas you can kill any one and
the other two keep committing (if it was the primary, after a short election); the restarted
one catches up by itself.

> **Behind a load balancer**, `/healthz` is enough: a gateway taken out of rotation while the
> cluster was down reconnects on its own and reports `200` again once it has. `nerva view`
> does the same, and reads on from where it stopped in the feed.

### The one rule about retries

If a commit answers 503, or the connection drops, **you do not know whether it committed**. It
may have reached the log just before the failure. Never blindly resend a write. Instead, make
writes safe to retry:

- **Commit keys** (Part 9) are the direct answer: send the same request, under the same key,
  until you get a reply. It commits at most once, and a resend of one that did commit answers
  `"replayed": true` with its op. The rest of this list is how it was done before keys, and
  still works.

- **Compare-and-set** writes are naturally idempotent: if the first attempt committed, the
  retry's `read` is stale and answers `conflict`. Then look the row up to see whether it holds
  your value.
- **Claims** with `op_seen: "0"` behave the same way.
- **Adds** are *not* idempotent: a retried `-30` takes 30 again. Pair an add with a claim on
  a request-id row in the same transaction, so a retry conflicts instead of applying twice.
  Here request 9001 claims row `(9, 9001)` and settles 10 of what is held, and is sent twice:

  ```bash
  n -d '{"entries":[
    {"kind":"read","table":9,"id":"9001","op_seen":"0"},
    {"kind":"put","table":9,"id":"9001","value_hex":"01"},
    {"kind":"add","table":6,"id":"1","field":"held","delta":"-10","min":"0"}]}' $A/v1/commit
  # first:  {"status":"committed","op":"283","adds":[{"index":2,"applied":"-10","value":"40"}]}
  # again:  {"status":"conflict","index":0,"op":"283"}     ← already applied, at op 283
  ```

  The conflict's `op` even tells you which op the first attempt committed at. Ledger pairs
  are adds too: make them safe to retry the same way.

The demos' client (`demo/nerva_http.py`) never retries a commit for this reason; with a key, it
could.

### Moving to a new release

A new release runs on new data files (see "One release per cluster" in Part 1), and from
v0.4.0 on your data comes along. The **old** release's `nerva export` reads everything a client
can read from the running cluster into one file. The **new** release's `nerva import` builds
each replica's data file from that file, recomputing everything derived (views, versions,
ledger indexes) with its own code, and checks the result against the export before it gives you
a file to start.

You can rehearse the whole procedure with one release. Note a feed cursor first, so you can
check that it survives:

```bash
n "$A/v1/changes?limit=1000"          # … "more":false,"cursor":"1791379930311661242" …

$NERVA export --cluster=1 --addresses=3001 --output=cluster.nerva-export
# info(export_): exporting as of op 314 (the cluster is at op 314)
# info(main): exported to cluster.nerva-export: op 314, 52 changes, 4 views, 1 ledgers, 8 tables, export 6059f66084f7206ba2107db035fdd0f48facb69f3b1e9398c74c18bb3e8a4933
```

The export is taken while the cluster runs, as of the op it started at (`--as-of=<op>` picks
another). Stop writers first, or everything committed after that op is not in it. It never
overwrites a file (`export: cluster.nerva-export exists; give a new file`), and it refuses up
front an export that `import` would refuse, before you have stopped anything. The long hex
string at the end is the export's SHA-256: its identity, which follows the data from here on.

Now stop every replica, and with the new binary import once per replica, each into a **new**
data file. Keep the replicas' `NERVA_CLUSTER_KEY` set as before:

```bash
kill <pid of nerva start>            # every replica
$NERVA import --cluster=1 --replica=0 --replica-count=1 --input=cluster.nerva-export \
    --development 1_0.new.nerva
# info(import_): view 4: building here, ready in the export: not compared
# info(import_): checks passed: 4 views, 1 ledgers, 8 tables
# warning(main): 0: start this replica only with every replica imported from cluster.nerva-export, before the cluster runs; to replace a replica of a running cluster, export it again and import every replica
# info(main): 0: imported cluster.nerva-export: cluster=1 replica_count=1 op=314 export=6059f660…4933

$NERVA start --addresses=3001 --development 1_0.new.nerva >> replica.log 2>&1 &
# replica.log: … listening on … port = 3001 }; data file from export 6059f660…4933
```

`import` writes `1_0.new.nerva.importing` and renames it only once every check has passed, so
a damaged export, a mismatch or a crash never leaves a data file you could start by mistake.
Like `export`, it never overwrites a file. The gateways reconnect by themselves (in a real
upgrade, restart them on the new release when you choose). What came across:

```bash
n -d '{"rows":[{"table":1,"id":"42"},{"table":6,"id":"1"}]}' $A/v1/lookup
# {"op":"1041","rows":[{"table":1,"id":"42","exists":true,"op":"10",…},{"table":6,"id":"1","exists":true,"op":"283",…,"fields":{"available":"0","held":"40"}}]}
n $A/v1/views/revenue
# {"view":"revenue","op":"1050","hash":"590cfdb8…",…,"declared_op":"129","groups":[{"section":1,"count":"2","sum_price":"200"},{"section":2,"count":"2","sum_price":"450"}]}
n "$A/v1/changes?cursor=1791379930311661242&limit=10"
# {"changes":[],"more":false,"cursor":"1791379930311661242","op":"1056"}
```

- **Versions survive.** Row 42 still says version `10`, so a client holding `op_seen: "10"`
  can still compare-and-set against it.
- **Op numbers jump.** The new cluster continues from the first checkpoint at or after the
  export's op (op 314 became op 1041 here). Never assume ops are consecutive.
- **Cursors survive.** The cursor taken before the export reads on: nothing new yet, and after
  one more write, exactly that write.
- **Views, ledgers, documents and layouts survive**, with each view's answer and both of its
  hashes. A view that the new cluster still has to rebuild from rows that existed before it
  was declared (view 4 above) isn't compared at import. It reports `building` until it is
  `ready`, and its as-of history starts again from there. Client sessions start again too.
- A view declared only through the Zig client has no catalog document, and `import` refuses
  it. Declare views through `nerva api`.

**Every replica comes from the same export.** Each data file records the export it was
imported from, and replicas compare it when they connect. A replica that can never reach a
quorum with replicas of its own export exits with **status 8** (`origin_mismatch`), naming both
exports. The others log that they ignore it and keep running. This has a consequence for
repairs: **replacing one lost replica is a whole-cluster operation.** Export the cluster again
and import every replica. Importing one replica alone would join and catch up, but it would
have forgotten the prepares the lost replica had acknowledged, so a later failure could lose a
committed op. A safe single-replica replacement is future work
([#94](https://github.com/Botpike/nerva-ledger/issues/94)).

From v0.4.0 on, every upgrade works as above: the old release's `export`, the new release's
`import`. (v0.3.0 had no `nerva export`.) Two things to know for v0.6.0, which the
[CHANGELOG](../CHANGELOG.md)'s upgrade steps cover:

- v0.6.0 made tables from `2147483648` up record tables. `nerva import` refuses an export with
  rows there, naming the table: move them to lower tables with the old release first.
- An export of a cluster that holds records or indexes is format version 2, which v0.5.0
  cannot read. To go back to v0.5.0, export before the first record or index; once there are
  any, there is no way back.

### Watching a replica

Three `nerva start` flags help when you run Nerva for real:

- `--statsd=<host:port>` sends the replica's metrics over UDP every 10 seconds, in statsd
  format with DogStatsD tags (`cluster`, `replica`, and per-metric tags such as `operation`).
  Useful ones: `tb.replica_request_us` (time from the primary seeing a request to this replica
  committing it), `tb.replica_commit_us` by stage, and the grid cache's hits and misses. The
  `tb.` prefix comes from TigerBeetle. The README's "Metrics and traces" section lists more.
- `--trace=<path>` writes a span trace you can open in [Perfetto](https://ui.perfetto.dev). It
  slows the replica, so use it to diagnose, not to measure, and give it a **new** file: an
  existing one is refused (`--trace: existing.json exists; give a new file`), so a typo cannot
  overwrite your data file. Tracing stops, with `warning(trace_file): tracing stopped: …` in the
  log, at `--trace-size-max` (default `1GiB`) or if writing fails (a full disk, say); the
  replica runs on.
- `--cache-grid=<size>` and `--cache-rows=<size>` size the block cache and the row cache (128
  bytes a row). The row cache defaults to its minimum, a few hundred rows.

### Cleaning up

```bash
kill %1 %2 %3                 # replica, api, view (check with `jobs`)
rm -rf /tmp/nerva-tutorial    # the data file is about 1.1 GiB
```

### See it at scale

The demos run all of this with three replicas, two view processes and a supervisor that
crashes them on demand: a 512-seat ticket race you can rewind to any op, and a shared pixel
canvas with a timelapse. Each needs about 3.5 GiB of disk.

```bash
./zig/zig build -Drelease
python3 demo/seats/server.py --nerva zig-out/bin/nerva --data /tmp/seats --port 8000
# open http://127.0.0.1:8000
```

See [demo/README.md](../demo/README.md).

---

## Part 11: The Zig client

`nerva api` exists so any language can use Nerva. Zig programs can talk to the replicas
directly with the blocking client in `src/nerva/client.zig`, which speaks the binary protocol
and skips JSON. The wire types are `extern struct`s in `src/nerva.zig`. These excerpts are from
`src/integration_tests.zig`, which runs them against three real replicas:

```zig
const nerva = @import("nerva.zig");
const Client = @import("nerva/client.zig").Client;

// Connect and register a session (blocks). One request in flight per client.
var client: Client = undefined;
try client.init(gpa, .{
    .cluster = 1,
    .addresses = addresses, // []const stdx.SocketAddress, in replica order
    .timeout = stdx.Duration.seconds(30),
});
defer client.deinit();

// A compare-and-set: the same two entries as in Part 3.
const entries = [_]nerva.Entry{
    .{ .id = 42, .table = 1, .kind = .read, .op_seen = op_seen, .value = @splat(0) },
    .{ .id = 42, .table = 1, .kind = .put, .op_seen = 0, .value = value },
};
var results: [entries.len]nerva.EntryResult = undefined;
try client.commit(&entries, &results);
// results[i].status is .ok (results[i].op is the commit op) or .conflict, .aborted, …

// Point reads.
var rows: [1]nerva.RowValue = undefined;
try client.lookup_rows(&.{.{ .id = 42, .table = 1 }}, &rows);
// rows[0].flags.exists, rows[0].op (version), rows[0].op_read, rows[0].value

// A row as of an op: its last change at or before `op`, or null.
const change: ?nerva.Change = try client.row_as_of(1, 42, op);
```

Also available: `get_changes`, `get_history`, `declare_view`, `get_view`, `declare_ledger`,
`get_ledger` and `get_ledger_slot` (to list the ledgers); and for Part 9, `commit_wide` (512-byte
`WideEntry`s, rows and records in one transaction; a commit key is a first entry made by
`nerva.commit_key_entry(key)`, widened with `WideEntry.from_entry` for `commit_wide`), `lookup_records`, `get_record_changes`, `get_record_history`,
`declare_index`, `scan_index` and `get_index`. A ledger pair is two `add` entries whose `Add` parameters set `flags.pair` on
the first and `flags.delta_from` on the second; the statuses `unpaired`, `conserved_write` and
`views_too_large` come back in `EntryResult.status` like any other. When a call returns
`error.Timeout` (the request may still have committed) or `error.Evicted` (the cluster dropped
the session, for example because more than 64 sessions were registered over its life), the
client cannot make further calls. `client.reconnect()` replaces its session in place, which is what
`nerva api` does. If `reconnect` itself fails, the client is uninitialized: call `init` again,
never `deinit`.

---

## Part 12: Inside Nerva, for contributors

Read this part before changing Nerva itself. Then read, in order: [CLAUDE.md](../CLAUDE.md)
(the working protocol, which applies to people too), [docs/TIGER_STYLE.md](./TIGER_STYLE.md)
(the coding style, which is mandatory), the decision log (why things are the way they are:
[docs/DECISIONS.md](./DECISIONS.md), N1 to N83, frozen, then one file per decision in
[docs/decisions/](./decisions/), named after its pull request, such as `P102`) and
[UPSTREAM.md](../UPSTREAM.md) (what is vendored and patched).

### Where things are

| Path | What it is |
|---|---|
| `src/nerva.zig` | Public wire and storage types: `Row`, `Entry`, `WideEntry`, `Record`, `EntryResult`, `Add`, `Change`, view and index types, `Operation`, `tree_ids`. Start here. |
| `src/nerva/state_machine.zig` | The commit core: `prefetch` and `commit` for every operation. |
| `src/nerva/views.zig` | The pure parts of maintained views: validation, group keys, digests. |
| `src/nerva/indexes.zig` | The pure parts of declared indexes: validation, an entry's place, position prefixes (P123c). |
| `src/nerva/ledgers.zig` | Ledgers: a declaration's checks, and the index that finds conserved fields (N75). |
| `src/nerva/catalog.zig` | Layouts and view declarations as data; field packing. |
| `src/nerva/documents.zig` | Chunking documents over rows. |
| `src/nerva/client.zig` | The blocking Zig client. |
| `src/nerva/api/` | `nerva api`: JSON routes (`api.zig`, `documents_routes.zig`), and the per-request memory budget (`memory_budget.zig`). |
| `src/nerva/client_health.zig` | A gateway's cluster client, and replacing it when it breaks. |
| `src/nerva/view/` | `nerva view`: the feed follower and declared views computed in memory. |
| `src/nerva/http_connection.zig` | The gateways' strict, bounded HTTP/1.1 receiver. |
| `src/nerva/cli.zig`, `src/nerva_main.zig` | The `nerva` binary's commands and flags. |
| `src/nerva/release_peers.zig` | Which peers a replica listens to: only those running its own release (N61) and imported from the same export (P90). |
| `src/nerva/peer_auth.zig` | The replicas' handshake: proving the cluster key (P102). |
| `src/nerva/export.zig`, `export_file.zig`, `import.zig` | `nerva export`, the export file, and `nerva import` (N80, N81). |
| `src/nerva/internal_operations.zig` | Operations only the cluster may send itself, such as `pulse` (N67). |
| `src/nerva/trace_file.zig` | The buffered, bounded writer behind `--trace` (N71). |
| `src/nerva/workload.zig` | The VOPR workload: random traffic checked against a model. |
| `src/nerva/*_tests.zig`, `*_fuzz.zig`, `format_test.zig` | Deterministic tests, fuzzers, format guards. |
| `src/vsr/`, `src/lsm/`, `src/io/`, `src/testing/`, … | Vendored from TigerBeetle. Prefer not to touch. |
| `tests/`, `demo/` | Python end-to-end tests and demos against real processes. |

### The life of a commit

1. A client sends a request: an `Operation` plus a body of fixed-size events (for `commit`,
   128-byte `Entry`s).
2. The primary replica validates its shape (`input_valid`), assigns it the next op and a
   timestamp (`prepare` reserves 5 timestamps per entry, for its change and any view groups it
   creates), and replicates it. Once a quorum has it durably, it is committed.
3. Every replica then executes it in op order:
   - **`prefetch`** loads every row, group and view that the request will touch from the LSM
     forest into memory. **All IO happens here.**
   - **`commit`** executes it synchronously against what was prefetched: it validates entries,
     checks every read's `op_seen` against the row's version, admits the view group budget,
     and, if all is well, writes rows, appends changes and updates view groups. It returns one
     result per entry.
4. The reply goes back to the client with the op.

Because every replica runs the same deterministic code over the same log, they end with
byte-identical state. That is why the invariants in CLAUDE.md are absolute:

- **State machine code is deterministic.** No wall clock, randomness, threads, hash-map
  iteration order, or allocation after startup in `prefetch` and `commit`. Time comes from the
  prepare timestamp.
- **`commit` does no IO.** If you need data in `commit`, prefetch it.
- **Persisted identifiers are stable.** Never renumber `tree_ids` or `Operation` values: they
  are on disk and on the wire. `format_test.zig` fails on any change to a wire or storage
  layout, on purpose.
- **Everything is bounded.** Every queue, batch and buffer has an explicit, asserted limit
  (`views_max`, `groups_per_op_max`, `page_limit_max`, …).

Storage is a set of LSM trees (`tree_ids`): rows by key and by timestamp, changes by timestamp
and by `row_key` (which is what serves history and as-of reads), views, and view groups.
Nothing is physically deleted: deletes are tombstones, and empty groups stay, so history stays
readable.

### The simulator (VOPR)

The VOPR runs a whole cluster (replicas, network, disks, clocks) inside one deterministic
process, injects crashes, partitions, packet loss and disk corruption, and drives it with
`src/nerva/workload.zig`. The workload keeps an in-memory model of what the committed state
must be at every op and checks **every** reply against it: every status, version, value and
change. It also races clients over receipts (checking each is claimed exactly once) and over
hot budgets with adds (checking `available + held` always equals what was funded).

```bash
./zig/zig build vopr -- 42     # seed 42; about 5 minutes in ReleaseSafe
```

A seed reproduces a run exactly. If CI prints a failing seed, run that seed locally and you
will see the same failure, step for step. Any change to the state machine, consensus or storage
needs a VOPR run, and a new operation or behaviour needs the workload and its model extended to
check it.

### The test ladder

| Command | What it checks | Time |
|---|---|---|
| `./zig/zig build check` | Typecheck everything | fast, run constantly |
| `./zig/zig build test:unit` | Unit and deterministic state machine tests (`-- "name"` filters) | minutes |
| `./zig/zig build test:fmt` | Formatting (`./zig/zig fmt src build.zig` fixes it) | seconds |
| `./zig/zig build fuzz -- smoke` | Every fuzzer, briefly | minutes |
| `./zig/zig build vopr -- <seed>` | Simulated cluster under faults | ~5 min |
| `./zig/zig build test:integration` | Three real replicas and the Zig client | ~20 s, 3.5 GiB disk |
| `./zig/zig build test:api` | Every JSON route against a model (records and indexes included); write races; commit-key resends | ~3 min |
| `./zig/zig build test:views` | Declared and maintained views against models | ~2 min |
| `./zig/zig build test:release` | A cluster of two releases (the odd replica is ignored), and an upgrade by export and import, without and with records | ~4 min |
| `./zig/zig build test:demo` | Both demos under random crashes | ~3 min |
| `tests/jepsen/run.sh zig-out/bin/nerva test --nemesis kill,partition` | Jepsen: five real nodes in Docker, clients through `nerva api`, kills, pauses and partitions; the history is checked against what the docs promise (a ledger's conservation, so far). Needs Docker, a JDK and Leiningen; by hand | longer |

`benchmark.perf: usage example` fails in sandboxes that deny `perf_event_open`; that is the
environment, not your change. Everything else must pass. CI runs all of it, as parallel jobs,
on every pull request that changes more than Markdown. On a pull request the VOPR runs four
seeds in Debug; on `main` it runs in ReleaseSafe on about 300 random seeds per push, so a
failure found there comes with a seed to replay. Two more workflows run outside pull requests: `fuzz.yml` (every
fuzzer and the VOPR on random seeds for a time budget, started by hand) and
`perf-nightly.yml` (benchmarks of `main` against the last good night, which file an issue on a
regression).

### How changes are made here

- **Open the pull request first**, as a draft, so you have its number: decisions and notes are
  named after it.
- **Design first.** When a change is larger than one file or its requirements are fuzzy, write
  the design (types, wire and disk formats, signatures, test strategy) at the top of the pull
  request description, then build it in small steps, running `check` and the relevant tests
  between them.
- **Record decisions** in `docs/decisions/P<number>-<slug>.md`, one file per decision, with a
  short header (`id`, `date`, `area`, and `amends` or `supersedes` when it changes an earlier
  one). `docs/DECISIONS.md` is frozen, and no one edits another pull request's decision file.
- **Note the work** in `worklog/<number>.md`: the date, the pull request, and what was done.
  `WORKLOG.md` is frozen too. Separate files per pull request mean no two pull requests ever
  edit the same log.
- **Know when to stop.** A change to a persisted format, a vendored file, a golden value you
  can't explain, an exception to an invariant, or the toolchain stops the work: push what
  compiles, open the pull request as a draft with a `**Question:**`, and wait for the owner.
- **Every pull request description states** the formats it changes, the vendored files it
  touches, and what was not verified (each may be `none` or `nothing`).
- **Vendored code.** Prefer adding code under `src/nerva/`. If a vendored file must change,
  keep the patch minimal and list it in UPSTREAM.md in the same commit.
- **Golden values** (snapshots, checksums) change only with an explanation of why.
- **Pre-existing bugs** you find get a GitHub issue, even if you fix them in the same pull
  request.
- **Releases** are a `CHANGELOG.md` section plus a `VERSION` bump, in their own commit. Each
  release publishes binaries, `SHA256SUMS` and a bill of materials. Before the `VERSION` commit,
  a separate bot that did none of the release's work reviews the candidate adversarially: it
  tries to break it, files each finding as a `release-review` issue, and the release waits until
  every blocker is fixed or waived by the owner (P105).

The VOPR simulates replicas but not real processes, and it does not simulate the gateways at all.
The Jepsen suite (`tests/jepsen/`, N82) covers that gap. Its checks are written from the
documentation rather than the code, so they don't share the implementation's assumptions. A
Jepsen run has no seed: a failure it finds is first reproduced as a VOPR seed or a unit test,
then fixed.

A good first exercise: read `src/nerva.zig` top to bottom, then follow one `commit` request
through `state_machine.zig` (`input_valid` → `prepare` → `prefetch` → `commit`) and find
where a stale read becomes `conflict`. Then look at how `workload.zig` predicts that same
result.

---

## Cheat sheet

**Processes**

```bash
nerva format --cluster=<id> --replica=<i> --replica-count=<n> [--development] <file>
NERVA_CLUSTER_KEY=… [NERVA_CLUSTER_KEY_NEXT=…] \
nerva start  --addresses=<a0,a1,…> [--development] [--cache-grid=…] [--cache-rows=…]
             [--statsd=<host:port>] [--trace=<new file>] [--trace-size-max=…]
             [--commit-stall-probability=<n>/<d>] <file>
NERVA_KEY=… [NERVA_KEY_NEXT=…] nerva api  --cluster=<id> --addresses=<…> --listen=<host:port>
NERVA_KEY=… [NERVA_KEY_NEXT=…] nerva view --cluster=<id> --addresses=<…> --listen=<host:port>
                                          # --listen=[::1]:8080 for IPv6; loopback unless --listen-remote
nerva export --cluster=<id> --addresses=<…> [--as-of=<op>] --output=<new file>
nerva import --cluster=<id> --replica=<i> --replica-count=<n> --input=<export> [--development] <file>
```

**`nerva api` routes** (header `X-Nerva-Key`)

| Route | Body or query |
|---|---|
| `POST /v1/lookup` | `{"rows":[{"table","id"}]}` |
| `POST /v1/commit` | `{"entries":[read / put / delete / add]}` |
| `GET /v1/changes` | `?cursor=&limit=` |
| `GET /v1/history` | `?table=&id=&op_max=<n\|latest>&cursor=&limit=` |
| `GET /v1/row` | `?table=&id=&as_of=` |
| `PUT`, `GET /v1/tables/<t>` | `{"name","fields":[{"name","type"}]}` |
| `PUT /v1/ledgers/<id>` | `{"fields":[{"table","field" or "offset","floor"}]}` (2 to 16 `i64` fields) |
| `GET /v1/ledgers/<id>` | the declaration |
| `PUT /v1/views/<name>` | `{"table","where","group_by","aggregates"}` |
| `GET /v1/views` | every maintained view, with its state |
| `GET /v1/views/<name>` | the whole view; `?min_op=<n\|latest>` or `?as_of=<op>` |
| `GET /v1/views/<name>/groups` | `?limit=&cursor=&as_of=` (a view named `groups`: `/v1/views/groups/groups`) |
| `GET /v1/views/<name>/definition` | the declaration |
| `POST /v1/documents/get` | `{"namespace","keys":[…],"as_of"?}` |
| `POST /v1/documents/commit` | `{"namespace","reads":[{"key","version"}],"writes":[…]}` |
| `GET /v1/documents/changes` | `?namespace=&cursor=&limit=` |
| `GET /healthz` | no key needed; `503` while the gateway cannot reach the cluster |

**`nerva view` routes**: `GET /v1/views` (names), `GET /v1/views/<name>?min_op=<n|latest>` or
`?as_of=<op>`: the same answer as `nerva api`'s, computed independently.

**Statuses**

| HTTP | Meaning |
|---|---|
| 200 | Done. Commits carry their `op`. |
| 400 | Invalid request; nothing applied. |
| 401 | Missing or wrong `X-Nerva-Key`. |
| 404 | No such route, view or ledger; a view read `as_of` an op before its declaration; a view that is not maintained (read it from `nerva view`). |
| 409 | `conflict` (stale read: `index`, current `op`), `out_of_bounds`, `row_absent`, `view_key_field`, `unpaired`, `conserved_write`; or a layout, view or ledger declaration that contradicts an earlier one (`ledger_immutable`, `ledger_field_taken`, …). Nothing applied. |
| 413 | `views_too_large`: the transaction touches more view groups than one op allows; split it (Part 7). Or `request too complex`: the body would take more than 128 MiB once parsed. Nothing applied. |
| 503 | `cluster unavailable` (a commit **may** have applied), a view still `building`, or `views_busy` (nothing applied; retry). |
| 504 | A view's `min_op` or `as_of` is an op not yet committed. |

**Remember**

- Every reply names an op. Versions are ops. `0` means "never existed".
- A transaction is one request; reads assert versions; all or nothing.
- 64-bit numbers are strings.
- Follow cursors until `more` is false.
- Never blindly retry a commit.
- Every replica of a cluster runs the same release and holds the same cluster key; clients may
  trail by one release. Upgrade, or replace a lost replica, by exporting and importing the whole
  cluster.
- Balances that must add up belong in a ledger.
