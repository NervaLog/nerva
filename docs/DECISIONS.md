# Decision log

Decisions taken while building Nerva towards 1.0, with the reason for each and what it costs.
Newest sections at the bottom. Dates are 2026-10-04 unless stated. Botpike is the first customer
(see [GOALS-1.0.md](./GOALS-1.0.md)); where a decision rests on reading Botpike's repositories,
the repository and file are named.

Decisions marked **(assumed)** were taken without the owner's input under a standing
instruction to proceed on reasonable assumptions; they are the first to revisit.

## Foundations (recorded after the fact)

**N1. Vendor TigerBeetle's consensus, storage, IO and simulator; write our own state machine.**
Pinned at `6f8e6b5`, copied rather than linked (see UPSTREAM.md). Reason: VSR, protocol-aware
recovery and the VOPR are the hardest parts to build and the most valuable. Cost: a permanent
fork; upstream fixes are pulled by hand.

**N2. Rows are fixed-size: `(table: u32, id: u64)` → 80-byte value.**
TigerBeetle's LSM stores fixed-size values only. Cost: anything longer must be chunked by the
caller (see N12).

**N3. Deletes are tombstones.**
Upstream `Groove.remove` is untested and compiles only in verification builds. Tombstones also
keep versions exact: a row deleted and re-created never looks unchanged. Cost: rows are never
reclaimed.

**N4. One batch is one transaction; reads assert the version (`op`) they saw.**
Optimistic validation at commit, serial execution, so point reads are serializable. Fits
TigerBeetle's multi-batch framing with no framework change. Cost: hot rows conflict (G8).

**N5. The integration test is an executable, not a `zig test`.**
Test binaries use the `test_min` config; the client must share the server's production config.

## Milestone 2b: how Botpike reaches Nerva

**N6. The gateway speaks the Botpike runtime's ledger protocol, not a new JSON API.**
`Botpike/runtime` already defines a small HTTP protocol between its daemon and a ledger
(README, "The ledger protocol"): `POST` with `key=value` lines, `X-Ledger-Key`, sixteen routes,
a reference implementation (`ledger/ledgerd.py`) and an acceptance bar — "the same journal
against it as against `ledgerd.py`". Botpike's app serves the same protocol from TigerBeetle +
PostgreSQL (`/runtime-ledger/v1/...`). Serving it from Nerva gives Nerva a real consumer with no
change to Botpike, and exercises G1 (one log), G3 (`/v1/claim` is the receipt race) and G7
(blocks, approvals and journalled results). A general-purpose JSON API is deferred until a
consumer needs it. Cost: the gateway is shaped by one customer's protocol; it lives in
`src/nerva/ledgerd/`, separate from the core, so it can be replaced without touching the core.

**N7. (assumed) Nerva's ledger is a reference ledger, not Botpike's money.**
GOALS-1.0 keeps Botpike's balances in TigerBeetle until Nerva has an external correctness review.
`nerva ledgerd` therefore replaces `ledgerd.py` (dev, CI, demos), not Botpike's production
adapter. Revisit with the G8 decision.

**N8. Acceptance is differential: identical requests to `ledgerd.py` and to Nerva must produce
identical replies.**
Scripted scenarios plus randomized sequences, compared byte for byte (status, every reply line,
every journal line). The runtime's own scenarios (`demo.sh`, `tests/*.sh`) need the Unison
toolchain, which this sandbox cannot download (Unison Share and GitHub release downloads are
blocked); running them against Nerva is a follow-up wherever `ucm` is available. A copy of
`ledgerd.py` is kept as the oracle, with its source commit.

**N9. Error replies match on status and the presence of `error=`, not on message text.**
`ledgerd.py`'s 400 messages are Python exception strings (`'request_id'`, `invalid literal for
int()…`). The runtime treats any non-2xx or `error=` reply as a failure and never parses the
text (README: "a reply is an answer only if…"). Cost: operators see different wording.

**N10. The gateway is part of the `nerva` binary (`nerva ledgerd`), single-threaded, one
request at a time.**
`ledgerd.py` holds one global lock; one Nerva client allows one request in flight. Sequential
handling gives the same serialization with no locking. The listen address and cluster come from
flags; the key from `LEDGER_KEY`, as in `ledgerd.py`, so it never appears in `ps`. Cost:
throughput is one route at a time per gateway (adequate for a reference ledger).

**N11. Each route is one Nerva transaction over a key-value view of the ledger; conflicts
retry.**
`ledgerd.py` keeps a flat dict (`ledger.txt`), an append-only journal and a results file. The
gateway keeps the same keys as Nerva rows, reads what a route needs (recording each row's
version), computes the reply with the same rules, and commits reads plus writes atomically. A
`conflict` (another gateway on the same ledger) re-runs the route from scratch, up to 8 times,
then answers 503. Route logic is written against a small store interface, so it is unit tested
against an in-memory store and run against Nerva unchanged.

**N12. (assumed) Values longer than a row are chunked across rows.**
Memos, journal lines and recalled results are arbitrary text; rows hold 80 bytes (N2). A value
is stored as chunk 0 (header: key length, total length, then data) plus chunks 1..n of 80 bytes,
each a row whose id is derived from the key (N13). Reading costs one lookup for chunk 0 and one
for the rest; a shorter rewrite leaves stale tail chunks, which the header's length makes
unreachable. A value is at most 64 KiB. Cost: write amplification and an extra round trip for
long values. This is the "variable-size data" open question of the white paper; native support
would replace this encoding without changing the protocol.

**N13. Row ids are the first 8 bytes of SHA-256 over (ledger, generation, key, chunk).**
Keys are strings (`hold.planner-1:0:3`); rows are keyed by `u64`. SHA-256 is stable across Zig
versions (unlike `std.hash`). Chunk 0 stores the key itself, so a 64-bit collision is detected
on read and answered 500 rather than read as another key's value.

**N14. One Nerva cluster hosts many ledgers; `--ledger=<id>` picks one.**
`ledgerd.py` is one ledger per process and state directory; Botpike runs many runs. A ledger's
rows live in one table (1000), namespaced by the hash (N13); its root row (table 1001, id =
ledger) holds a generation number.

**N15. `/v1/admin/init` starts a new generation instead of deleting rows.**
`ledgerd.py` resets the dict and deletes its journal and results. Bumping the generation makes
every old key unreachable in one write, and keeps the old generation's history in the log for
audit. Cost: old rows are never reclaimed (as N3).

**N16. `/v1/status` lists state keys from an index row, since Nerva has no range scans.**
`ledgerd.py` lists every key starting `seq.`, `hold.`, `resuming.` or `blocked.`. The gateway
keeps that set of key names as one more chunked value, updated whenever such a key appears or
disappears. Cost: an extra write on those routes; the list is bounded by the 64 KiB value limit.

**N17. Inputs outside what `ledgerd.py` documents are not chased for parity.**
Python's `int()` accepts `+5`, ` 5` and `1_000`; `bytes.fromhex` accepts spaces between bytes;
`str.splitlines` splits on Unicode line separators. The gateway accepts canonical decimal and
hex and splits lines on `\n`, `\r\n` and `\r`, and the differential fuzzer sends what the runtime
sends. Invalid UTF-8 inside hex text *is* matched (replaced with U+FFFD per maximal subpart, as
Python does), because agent-chosen memos reach the journal.

**N18. A route's writes commit even when it answers 400; routes check before they write.**
`ledgerd.py` persists only at explicit `write_ledger()` calls, and `count_denial` persists
immediately, so `/v1/refused` with a bad `memo_hex` answers 400 yet counts the denial. The
gateway commits whatever a route wrote before failing, and every route computes its checked
totals before its first write, so a 400 leaves exactly what `ledgerd.py` leaves.

**N19. Journal lines are stored under random unique keys, not a shared counter.**
Found by the two-gateway race test: a `journal.count` row written by every journaling route
made any two of them conflict, and a request gave up with 503. Unique keys remove that hot row;
the change feed records the order in which lines were committed. Cost: reading the journal back
in order means reading the change feed, not counting keys.

**N20. Conflicts back off with random jitter, up to 32 attempts, then answer 503.**
Also found by the race test: immediate retries let two gateways keep colliding. Backoff is
1..min(2^attempt, 64) ms. A 503 is safe: the runtime treats it as a crash and every route is
safe to repeat (runtime README). Contention on the shared balance (`available`) remains
inherent to one budget; that is G8's problem, not the gateway's.

## Milestone 3: positioned reads and the first views

**N21. `lookup_rows` results carry the op they were read at (`RowValue.op_read`).**
G2: every read names its position. The field replaces `reserved_a` (same size and offset), so
the wire format grows no larger. `get_changes` already carries its op in the `end` record.

**N22. Views run in a separate process, `nerva view`, that follows the change feed.**
As in the white paper: the core only commits; a view process pages through `get_changes`,
groups changes by op, applies complete ops, and keeps a watermark (the op through which it is
complete). v0.1 state is in memory and rebuilt from the start of the feed on restart. Cost:
restart time grows with history until views snapshot (later).

**N23. View reads wait for a position: `min_op=<n>` or `min_op=latest`.**
A reader that knows the op of its write passes it and gets read-your-writes. A reader that does
not (the runtime never sees ops) passes `latest`: the view first pages the feed to its end,
which reaches past every write committed before the read began. Every reply starts `op=<n>`,
the watermark it reflects (G2). A wait that does not reach the position within 10 s answers
504. The wire style is the ledger protocol's: `key=value` lines, `X-Ledger-Key`, `ok=true`.

**N24. (assumed) The first views are over `nerva ledgerd` ledgers: `journal` and `spend`.**
GOALS-1.0 Milestone 3 names "Botpike's spend rollup". Botpike's own rollup
(`Botpike/app`, `modules/delegation`, `agent_spend_rollup`) gives per agent: own spend, subtree
spend, admitted and rejected counts, and depth in the agent tree. The runtime ledger carries the
same tree in its request ids (runtime D6: `agent:sequence:step`, `/child:step` per sub-agent),
so `spend` applies Botpike's definition to it: own = sum of settled `done.` amounts whose request
id's agent path is that agent's, subtree = own plus descendants', settled and denied counts,
depth. `journal` is the ledger's journal lines in commit order, which N19 left to the change
feed. Botpike's production rollup stays in PostgreSQL (N7); these are the first real consumers
of the view machinery, chosen because they can be checked against `ledgerd.py`.

**N25. A ledgerd row's chunk 0 records its ledger and generation.**
A view sees only rows; to attribute a row to a ledger, and to recompute its tail chunks' ids,
it needs both. The header grows from 8 to 24 bytes (chunk 0 carries 56 bytes of key and value
instead of 72). Tail chunks' ids now derive from chunk 0's id rather than from the key: a view
holding chunk 0 of a long key could not otherwise find the chunks that hold the rest of the key.
Changed now because no ledgerd data has been deployed.

**N26. Views are checked against `ledgerd.py`'s files.**
After driving both services with the same requests, the `journal` view must equal the oracle's
`journal.log` line for line, and the `spend` view must equal the rollup recomputed independently
from the oracle's `ledger.txt` (`done.` and `denied.` lines). A restarted view process must give
the same answers.

**N27. History is an index on the change feed: `get_history`.**
G6 asks for any row as of any op. The change feed already keeps every write with its op and
value, so history needs no second copy of the data: a derived index `row_key(table, id)` on
`Change` (tree id 4) orders each row's writes by timestamp, and timestamps increase with op.
`get_history` scans one row's changes newest first from a cursor (`timestamp_max`) and returns
those with `op <= op_max`. Changes after `op_max` are skipped, but they count toward `limit`,
so every call is bounded and pages on. The cursor counts down, and `end.op` is the query's op
once the history is exhausted (as for `get_changes`). `op_max = 0` is invalid rather than
meaning "no bound", because "as of op 0" must not quietly read the latest (caught by the first
unit test); clients pass `maxInt(u64)` for the latest. Cost: 32 bytes of index per write. History
is kept forever: pruning is not a 1.0 goal. Changed now because no Nerva data has been deployed.

**N28. ledgerd keys are readable as of an op, through `nerva view`.**
`GET /v1/ledgers/<ledger>/as_of?op=<n|latest>&key_hex=<hex>` reads a key as it was at op `n`:
the ledger's generation as of `n`, then the key's chunk 0 as of `n`, then its tails, each of
which must carry chunk 0's op. A read at `n` waits until the view has seen op `n` (else 504), so
nothing can still commit at or before it; `latest` reads at the watermark. Journal lines are now
`line=<op>:<hex>`, so "what did the ledger hold when this line was written" is one read. It is
served by `nerva view` rather than the gateway because it is a read at a position, like the
views, and the runtime never sees ops. Checked by snapshotting `ledgerd.py`'s `ledger.txt` and
`results.txt` every 7th request and re-reading sampled keys (present and absent) as of each
snapshot's op.

**N29. (assumed) The runtime's `Store` ability is served as `/v1/store/get` and `/v1/store/put`.**
G7 wants suspended agents in the log, not in files that two daemons can both claim. The runtime
already funnels all agent state through one ability (`Store`: `get : Text -> Optional Bytes`,
`put : Text -> Bytes -> ()`, runtime.u), whose production handler writes files. A Nerva handler
needs only these two routes: `name_hex` and `value_hex`, replies in the ledger protocol's style.
The values are chunked like ledger values but stored in table 1002 with no generations, because
`/v1/admin/init` resets the ledger and must not erase agents. There is no delete route because
the ability has none. The 64 KiB value limit holds: the runtime's demo suspends at 2–5 KB
(`demo-output.txt`). The runtime's crash-safe suspend (staged `.next.*` files, committed by the
sequence advance; runtime D34) works unchanged on top. An atomic suspend route, which would
remove the staging, is a later proposal to the runtime, not an assumption made here.

**N30. Not built: approval attribution and a claim lease. They wait on Botpike's identity model.**
G7 also asks that every approval be attributed to an identity. The runtime never stores an
approval: `brt approve <id> yes|no` passes the answer straight to `resume.plan`. The ledger
protocol authenticates with one shared `X-Ledger-Key`, so Nerva cannot tell one approver from
another. Attribution needs one of these:
(a) the caller asserts an approver id, and the gateway records it beside the claim in one
transaction (this trusts whoever holds the key);
(b) each approver signs the answer with a key Botpike issues, and the gateway verifies the
signature before recording it.
Choosing between them settles the wire format, the stored record and key distribution. Getting
it wrong means replacing the stored approval records, so it is not assumed. The claim lease
that would remove the runtime's per-directory lock (D43) depends on the same question: a lease
is held by an identity.

**N31. Botpike is dog-fooding, not a specification.**
Owner's direction (2026-10-04): Nerva is tested on Botpike, not specialized for it. Nerva grows
only general capabilities (transactions, the change feed, history, views, a key-value store).
Botpike-specific behaviour stays in adapters at the boundary: `nerva ledgerd` speaks the
runtime's existing protocol, and the ledgerd views read its rows. A gap Botpike finds is
reported as the general gap it exposes, not patched with a Botpike-only route.
`docs/BOTPIKE-INTEGRATION.md` gives the integrating bot these rules, and a phased plan that adds
Nerva beside Botpike's existing ledger and file store, never in place of them.

**N32. CI on every push; releases are tags; the binary's release string stays `0.0.1`.**
`ci.yml` runs on every push and pull request to `main`: typecheck, format, unit tests, the
integration test, the ledgerd suites (one at a time, so the runner is not crowded) and the
VOPR on seeds 1, 2 and 5, plus one random seed written to the job summary. `release.yml` runs on
a `v*` tag: it calls the same CI on that commit, then cross-compiles Linux and macOS binaries
(x86_64, aarch64) from one Linux runner and publishes them, with `SHA256SUMS`, as a GitHub
release. A tag containing `-` is a prerelease.
The tag names a release; the binary does not take its version from the tag. Its release string
(`0.0.1`) is what TigerBeetle's replication and data file format record and check (it is in the
formatted data file's golden checksum), so it changes only when the protocol or format does,
in a commit that says why. Binaries report `0.0.1+<commit>`, and the release workflow checks the
commit matches.
Not set: `kernel.perf_event_paranoid`. The perf test skips itself where permission is denied,
as on GitHub's runners (as upstream's CI relies on); allowing it without hardware counters is
what makes it fail in sandboxes.

**N33. A general JSON API: `nerva api`.**
The public demos (seat booking, then a shared canvas) and any non-Zig user need Nerva's
operations without the Botpike ledger protocol. `nerva api` is a thin translation: five routes
(`lookup`, `commit`, `changes`, `history`, `row`), each one Nerva request, and no application
concepts. Choices:
- 64-bit numbers are decimal strings, because JavaScript loses precision past 2^53. `table` and
  `limit` are numbers.
- A value is hex: up to 80 bytes, zero-padded on write; reads always return all 80 bytes, so
  what comes back is exactly what is stored.
- One commit request is one transaction. The answer is `200` committed, `409` conflict (with the
  stale entry's index and the row's current version, so the caller can retry from it), or `400`
  for a row written twice or an invalid entry. Entries are validated before they reach the
  cluster, so the core's other entry statuses cannot occur.
- Unknown fields, unknown or repeated query parameters, and non-decimal numbers are refused,
  not ignored.
- `row?as_of=` first checks that the op is committed (a lookup's own op is newer than every
  committed op). The end-to-end test caught the first version answering for a future op.
- Keyed by `X-Nerva-Key` from `NERVA_KEY`. Sequential like `ledgerd`; run more for throughput.

**N34. Typed tables, minimal form: layouts are metadata in the log.**
Declared views need to read named fields (`price`, `color`) out of 80-byte values, and demo
clients want to write fields rather than hex. A table may have a layout: up to 16 fields
(`u8`, `u16`, `u32`, `u64`, `i64`, `bool`, fixed-size `bytes`), packed in declaration order,
each aligned to its size, little-endian, within 80 bytes. Choices:
- The core does not know layouts. It stores bytes and validates nothing about them; layouts are
  read by the API (to encode and decode `fields`) and, next, by views. This keeps the state
  machine unchanged and the choice reversible. The cost: a client writing `value_hex` can write
  bytes its layout does not describe well, which is accepted.
- Layouts live in the log, in a reserved catalog table (`0xFFFF0001`), chunked like ledgerd
  values and keyed `table.<id>`, so declarations are committed facts with ops. Tables from
  `0xFFFF0000` up are reserved: the API refuses them, and leaves their rows out of `changes`.
- A layout may only grow by appending fields: data written earlier reads the same later, and a
  reader holding an older layout decodes a correct prefix. Anything else answers 409.
- A declaration is a transaction that reads the current layout, so two gateways declaring at
  once cannot both "create": the loser retries and finds it unchanged (tested).
- 64-bit fields render as decimal strings, as elsewhere (N33).
- The API reads layouts from the log on each request that needs them (at most once per table
  per request); no cache yet. Measure before adding one.

