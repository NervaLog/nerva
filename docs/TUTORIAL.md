# Nerva tutorial

This tutorial takes you from an empty directory to a running Nerva cluster, then through every
capability it has today: rows and versions, transactions, the change feed and time travel, typed
layouts, conflict-free counters, declared views, documents, and surviving a crash. It ends with a
tour of the code for people who want to change Nerva itself.

It assumes you are comfortable with a shell, `curl` and JSON, and know roughly what a database
transaction is. You do not need to know Zig until the last two parts.

Every reply shown below is real output from a run of these exact commands. **Your op numbers
will differ**: see "Ops move on their own" in Part 1.

> Nerva is a research database (see the [README](../README.md)). Do not put data in it that you
> cannot lose.

## Contents

- [Part 0: The idea in five minutes](#part-0-the-idea-in-five-minutes)
- [Part 1: Build and start a cluster](#part-1-build-and-start-a-cluster)
- [Part 2: Rows and versions](#part-2-rows-and-versions)
- [Part 3: Transactions](#part-3-transactions)
- [Part 4: The log: changes, history, time travel](#part-4-the-log-changes-history-time-travel)
- [Part 5: Layouts: typed fields instead of hex](#part-5-layouts-typed-fields-instead-of-hex)
- [Part 6: Adds: counters and budgets without conflicts](#part-6-adds-counters-and-budgets-without-conflicts)
- [Part 7: Declared views](#part-7-declared-views)
- [Part 8: Documents: larger values by key](#part-8-documents-larger-values-by-key)
- [Part 9: Crashes, timeouts and retries](#part-9-crashes-timeouts-and-retries)
- [Part 10: The Zig client](#part-10-the-zig-client)
- [Part 11: Inside Nerva, for contributors](#part-11-inside-nerva-for-contributors)
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

The machinery underneath (Viewstamped Replication consensus, an LSM storage engine, io_uring
IO and a deterministic simulator) is vendored from [TigerBeetle](https://github.com/tigerbeetle/tigerbeetle).
Nerva's own code is the state machine on top, plus the gateways and tools around it.

### The processes you will run

```
             curl / your app (JSON over HTTP)
                 │                       │
        writes and reads           view reads
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
- **`nerva view`** follows the change feed and answers declared views, latest or as of any op.

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
# Nerva version 0.0.2+eaa7520
```

The version is `<protocol release>+<commit>`. Replicas, clients and data files of different
protocol releases refuse each other.

Release binaries are on the [releases page](https://github.com/Botpike/nerva-ledger/releases),
but this tutorial follows `main`: maintained views (Part 7) came after v0.2.0, so build from
source.

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
`listening on … port = 3001` when it is ready.

### Start the JSON gateway

```bash
export NERVA_KEY=secret
$NERVA api --cluster=1 --addresses=3001 --listen=127.0.0.1:8080 > api.log 2>&1 &

curl http://127.0.0.1:8080/healthz
# {"ok":true}
```

The gateway reads its shared secret from `NERVA_KEY`, and every request must carry it in
`X-Nerva-Key`. Define a short helper for the rest of the tutorial:

```bash
n() { curl -s -H 'X-Nerva-Key: secret' "$@"; echo; }
A=http://127.0.0.1:8080
```

> **Write JSON bodies on one line.** On current `main`, the gateways can refuse a body that
> contains a newline with `400 malformed request` ([#36](https://github.com/Botpike/nerva-ledger/issues/36)).
> All examples here are single-line.

### A three-replica cluster

When you want the real thing, format one file per replica and give every replica every
address:

```bash
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
against every write. One HTTP call can also take more than one op (the gateway reads the
table's layout from the log too, Part 5), and other processes make requests of their own:
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
n -d '{"entries":[{"kind":"read","table":1,"id":"42","op_seen":"5"},{"kind":"put","table":1,"id":"42","value_hex":"776f726c64"}]}' $A/v1/commit
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
This "receipt race" is the scenario Nerva's simulator checks on every CI run (Part 11).

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
n -d '{"entries":[{"kind":"put","table":5,"id":"1","fields":{"section":1,"price":"100","sold":true}},{"kind":"put","table":5,"id":"2","fields":{"section":1,"price":"100","sold":false}},{"kind":"put","table":5,"id":"3","fields":{"section":2,"price":"250","sold":true}},{"kind":"put","table":5,"id":"4","fields":{"section":2,"price":"250","sold":true}}]}' $A/v1/commit
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

## Part 6: Adds: counters and budgets without conflicts

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
n -d '{"entries":[{"kind":"add","table":6,"id":"1","field":"available","delta":"-30","min":"0","clamp":true},{"kind":"add","table":6,"id":"1","field":"held","delta_from":0}]}' $A/v1/commit
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

---

## Part 7: Declared views

A **view** is a declaration stored in the log, not code you run. Declare "count and total
price of sold seats, by section":

```bash
n -X PUT $A/v1/views/revenue -d '{"table":5,"where":[{"field":"sold","op":"eq","value":true}],"group_by":["section"],"aggregates":[{"fn":"count"},{"fn":"sum","field":"price"}]}'
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

There are two ways to read a view, and the difference is worth understanding.

### 1. Maintained by the replicas (`nerva api`)

`"maintained": true` means the view uses only `count` and `sum`, so **the state machine
maintains it inside every commit**, alongside the rows. Every replica holds the same groups and
the same hash at every op, and reading it reads the groups, not the rows:

```bash
n "$A/v1/views/revenue/groups?limit=100"
```
```json
{"view":"revenue","id":1,"state":"ready","op":"77",
 "hash":"0c8ceeee30d22fcca2f2a5b97e80be1cf94912ed80cfc7218ff1225874c29739",
 "group_count":"2",
 "groups":[{"section":1,"count":"1","sum_price":"100"},
           {"section":2,"count":"2","sum_price":"500"}],
 "more":false,"cursor":null}
```

Seat 2 (section 1) is not sold, so section 1 counts one seat. The view was declared after the
seats were written, and it still counts them: a view declared over existing rows reports
`"state":"building"` while the cluster backfills them, a bounded number per op, then `"ready"`.
With four rows, that was instant. Groups come a page at a time, in storage order (by group
hash, not by key); follow `cursor` while `more` is true.

### 2. Computed by `nerva view`, at any op

`nerva view` is a separate process that follows the change feed and answers any declared view,
latest or **as of any op**, including ops from before the view was declared. Start one:

```bash
$NERVA view --cluster=1 --addresses=3001 --listen=127.0.0.1:8091 > view.log 2>&1 &
V=http://127.0.0.1:8091

n $V/v1/views
# {"views":["revenue"]}
n "$V/v1/views/revenue?min_op=latest"
# {"view":"revenue","op":"87","hash":"aa945a74…","groups":[{"section":1,"count":"1","sum_price":"100"},{"section":2,"count":"2","sum_price":"500"}]}
```

Now sell seat 2 and note the op:

```bash
n -d '{"entries":[{"kind":"put","table":5,"id":"2","fields":{"section":1,"price":"100","sold":true}}]}' $A/v1/commit
# {"status":"committed","op":"90"}
```

**Read your own write.** `nerva view` is asynchronous: it may not have applied op 90 yet. Ask
for "at least op 90" and it waits until it has:

```bash
n "$V/v1/views/revenue?min_op=90"
# {"view":"revenue","op":"91","hash":"2560a945…","groups":[{"section":1,"count":"2","sum_price":"200"},{"section":2,"count":"2","sum_price":"500"}]}
```

**Read the past.** The view just before the sale:

```bash
n "$V/v1/views/revenue?as_of=89"
# {"view":"revenue","op":"89","hash":"aa945a74…","groups":[{"section":1,"count":"1","sum_price":"100"},{"section":2,"count":"2","sum_price":"500"}]}
```

Op 89 has the same groups as op 87, so it has the same hash. **A hash is a function of the
groups only**: two `nerva view` processes, or two clusters fed the same writes, agree on it
exactly. You can check that two copies of a report agree by comparing 64 hex digits. (In two
separate runs of this tutorial, the groups above hashed to `2560a945…` both times.)

The two kinds of hash are computed differently: `nerva view` hashes its whole answer, while the
replicas sum per-group digests so that one write updates the hash cheaply. Compare maintained
hashes with maintained hashes, and `nerva view` hashes with `nerva view` hashes.

| | Maintained (`/v1/views/<name>/groups` on `nerva api`) | `nerva view` (`/v1/views/<name>`) |
|---|---|---|
| Aggregates | `count`, `sum` | `count`, `sum`, `min`, `max` |
| Reads | latest | latest, `min_op=<n>`, `as_of=<op>` |
| Where the state lives | replicated, durable, in every replica | in the process's memory, rebuilt from the feed on restart |
| Cost of a read | reads the groups | computes from rows held in memory (v0) |
| Limit | about 4,000 distinct groups touched per op (`503 views_busy`, retry) | two million changes in memory |

### Adds and views

Adds to a summed field are what maintained views are for, and they work as expected:

```bash
n -d '{"entries":[{"kind":"add","table":5,"id":"3","field":"price","delta":"-50"}]}' $A/v1/commit
# {"status":"committed","op":"99","adds":[{"index":0,"applied":"-50","value":"200"}]}
```

An add to a field that a view **filters or groups by** is refused, because an add must never
move a row from one group to another. Here an add over the first 8 bytes, which include
`section`:

```bash
n -d '{"entries":[{"kind":"add","table":5,"id":"3","offset":0,"type":"u64","delta":"1"}]}' $A/v1/commit
# {"status":"view_key_field","index":0}      (409)
```

Change such fields with a `put`.

---

## Part 8: Documents: larger values by key

Rows are 80 bytes with numeric ids. **Documents** hold up to 64 KiB under a string key (up to
1024 bytes of UTF-8), in a numeric `namespace`. Nerva splits them over rows of a reserved table
for you. They follow the same optimistic model: a read names the `version` you saw, and `"0"`
means "must not exist".

```bash
# {"items":[]} as hex
n -d '{"namespace":"7","reads":[{"key":"cart/alice","version":"0"}],"writes":[{"key":"cart/alice","value_hex":"7b226974656d73223a5b5d7d"}]}' $A/v1/documents/commit
# {"status":"committed","op":"102"}

n -d '{"namespace":"7","keys":["cart/alice","cart/bob"]}' $A/v1/documents/get
# {"op":"103","documents":[{"key":"cart/alice","exists":true,"version":"102","value_hex":"7b226974656d73223a5b5d7d"},{"key":"cart/bob","exists":false,"version":"0","value_hex":""}]}
```

A stale read conflicts and names the key:

```bash
n -d '{"namespace":"7","reads":[{"key":"cart/alice","version":"0"}],"writes":[{"key":"cart/alice","delete":true}]}' $A/v1/documents/commit
# {"status":"conflict","key":"cart/alice","version":"102"}     (409)
```

`documents/get` takes up to 256 keys and an optional `"as_of"`. A commit carries up to about
600 KB of keys and values. Each namespace has its own feed:

```bash
n "$A/v1/documents/changes?namespace=7&limit=1000"
# {"documents":[{"key":"cart/alice","op":"102","kind":"put","value_hex":"7b2269…"}],"more":false,"cursor":"…","op":"105"}
```

This feed is filtered from the shared change feed, `limit` records at a time, so a page can come
back **empty with `more: true`**. That means "nothing for this namespace in that stretch, keep
going", not "done". Always loop until `more` is false.

---

## Part 9: Crashes, timeouts and retries

Kill the replica the hard way, as in a power cut:

```bash
kill -9 %1        # or: kill -9 <pid of nerva start>
```

While it is down, the gateway holds requests and waits for the cluster (up to 30 seconds, then
`503 {"error":"cluster unavailable"}`). Restart it from the same data file:

```bash
$NERVA start --addresses=3001 --development 1_0.nerva >> replica.log 2>&1 &
# …about ten seconds later:
n -d '{"rows":[{"table":6,"id":"1"}]}' $A/v1/lookup
# {"op":"128","rows":[{"table":6,"id":"1","exists":true,"op":"55",…,"fields":{"available":"0","held":"50"}}]}
```

Everything committed is there. A commit is acknowledged only once it is durable on a quorum
of replicas. With three replicas you can kill any one and the other two keep committing (if it
was the primary, after a short election); the restarted one catches up by itself.

> **After an outage longer than 30 seconds, restart `nerva api`.** Once one request has timed
> out, the gateway keeps answering `503` even after the cluster is back, while `/healthz` still
> says ok ([#37](https://github.com/Botpike/nerva-ledger/issues/37)). Short outages, like the
> one above, are fine.

### The one rule about retries

If a commit answers 503, or the connection drops, **you do not know whether it committed**. It
may have reached the log just before the failure. Never blindly resend a write. Instead, make
writes safe to retry:

- **Compare-and-set** writes are naturally idempotent: if the first attempt committed, the
  retry's `read` is stale and answers `conflict`. Then look the row up to see whether it holds
  your value.
- **Claims** with `op_seen: "0"` behave the same way.
- **Adds** are *not* idempotent: a retried `-30` takes 30 again. Pair an add with a claim on
  a request-id row in the same transaction, so a retry conflicts instead of applying twice.
  Here request 9001 claims row `(7, 9001)` and spends 30, and is sent twice:

  ```bash
  n -d '{"entries":[{"kind":"read","table":7,"id":"9001","op_seen":"0"},{"kind":"put","table":7,"id":"9001","value_hex":"01"},{"kind":"add","table":6,"id":"1","field":"available","delta":"-30","min":"0"}]}' $A/v1/commit
  # first:  {"status":"committed","op":"11","adds":[{"index":2,"applied":"-30","value":"20"}]}
  # again:  {"status":"conflict","index":0,"op":"11"}     ← already applied, at op 11
  ```

  The conflict's `op` even tells you which op the first attempt committed at.

The demos' client (`demo/nerva_http.py`) never retries a commit for this reason.

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

## Part 10: The Zig client

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

Also available: `get_changes`, `get_history`, `declare_view` and `get_view`. Two rules from the
client's doc comment: after `error.Timeout` the request may still commit and the client must
not be reused (only `deinit`); after `error.Evicted`, create a new client.

---

## Part 11: Inside Nerva, for contributors

Read this part before changing Nerva itself. Then read, in order: [CLAUDE.md](../CLAUDE.md)
(the working protocol, which applies to people too), [docs/TIGER_STYLE.md](./TIGER_STYLE.md)
(the coding style, which is mandatory), [docs/DECISIONS.md](./DECISIONS.md) (why things are
the way they are, numbered N1…N55) and [UPSTREAM.md](../UPSTREAM.md) (what is vendored and
patched).

### Where things are

| Path | What it is |
|---|---|
| `src/nerva.zig` | Public wire and storage types: `Row`, `Entry`, `EntryResult`, `Add`, `Change`, view types, `Operation`, `tree_ids`. Start here. |
| `src/nerva/state_machine.zig` | The commit core: `prefetch` and `commit` for every operation. |
| `src/nerva/views.zig` | The pure parts of maintained views: validation, group keys, digests. |
| `src/nerva/catalog.zig` | Layouts and view declarations as data; field packing. |
| `src/nerva/documents.zig` | Chunking documents over rows. |
| `src/nerva/client.zig` | The blocking Zig client. |
| `src/nerva/api/` | `nerva api`: JSON routes (`api.zig`, `documents_routes.zig`). |
| `src/nerva/view/` | `nerva view`: the feed follower and declared views computed in memory. |
| `src/nerva/http_connection.zig` | The gateways' strict, bounded HTTP/1.1 receiver. |
| `src/nerva/cli.zig`, `src/nerva_main.zig` | The `nerva` binary's commands and flags. |
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
| `./zig/zig build test:api` | Every JSON route against a model; write races | ~3 min |
| `./zig/zig build test:views` | Declared and maintained views against models | ~2 min |
| `./zig/zig build test:demo` | Both demos under random crashes | ~3 min |

`benchmark.perf: usage example` fails in sandboxes that deny `perf_event_open`; that is the
environment, not your change. Everything else must pass. CI runs all of it on every pull
request.

### How changes are made here

- **Design first.** New types, wire or disk formats and function signatures are agreed before
  they are implemented, along with the tests that will prove them. Larger changes go through a
  written design step (CLAUDE.md, "DEEP WORK").
- **Record decisions.** Add an entry to `docs/DECISIONS.md` when you decide something, and to
  `WORKLOG.md` when you finish something.
- **Vendored code.** Prefer adding code under `src/nerva/`. If a vendored file must change,
  keep the patch minimal and list it in UPSTREAM.md in the same commit.
- **Golden values** (snapshots, checksums) change only with an explanation of why.
- **Pre-existing bugs** you find get a GitHub issue, even if you fix them in the same pull
  request.
- **Releases** are a `CHANGELOG.md` section plus a `VERSION` bump, in their own commit.

A good first exercise: read `src/nerva.zig` top to bottom, then follow one `commit` request
through `state_machine.zig` (`input_valid` → `prepare` → `prefetch` → `commit`) and find
where a stale read becomes `conflict`. Then look at how `workload.zig` predicts that same
result.

---

## Cheat sheet

**Processes**

```bash
nerva format --cluster=<id> --replica=<i> --replica-count=<n> [--development] <file>
nerva start  --addresses=<a0,a1,…> [--development] [--cache-grid=…] [--statsd=…] <file>
NERVA_KEY=… nerva api  --cluster=<id> --addresses=<…> --listen=<host:port>
NERVA_KEY=… nerva view --cluster=<id> --addresses=<…> --listen=<host:port>
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
| `PUT`, `GET /v1/views/<name>` | `{"table","where","group_by","aggregates"}` |
| `GET /v1/views/<name>/groups` | `?limit=&cursor=` |
| `POST /v1/documents/get` | `{"namespace","keys":[…],"as_of"?}` |
| `POST /v1/documents/commit` | `{"namespace","reads":[{"key","version"}],"writes":[…]}` |
| `GET /v1/documents/changes` | `?namespace=&cursor=&limit=` |
| `GET /healthz` | no key needed |

**`nerva view` routes**: `GET /v1/views`, `GET /v1/views/<name>?min_op=<n|latest>` or `?as_of=<op>`.

**Statuses**

| HTTP | Meaning |
|---|---|
| 200 | Done. Commits carry their `op`. |
| 400 | Invalid request; nothing applied. |
| 401 | Missing or wrong `X-Nerva-Key`. |
| 409 | `conflict` (stale read: `index`, current `op`), `out_of_bounds`, `row_absent`, `view_key_field`; or a layout or view declaration that contradicts an earlier one. Nothing applied. |
| 503 | `cluster unavailable` (a commit **may** have applied; see #37) or `views_busy` (nothing applied, retry). |
| 504 | `nerva view`: `min_op` not committed yet. |

**Remember**

- Every reply names an op. Versions are ops. `0` means "never existed".
- A transaction is one request; reads assert versions; all or nothing.
- 64-bit numbers are strings.
- Follow cursors until `more` is false.
- Never blindly retry a commit.
