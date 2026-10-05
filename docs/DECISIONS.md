# Decision log

Decisions taken while building Nerva towards 1.0, with the reason for each and what it costs.
Newest sections at the bottom. Dates are 2026-10-04 unless stated. Decisions superseded by N39
(an application-specific gateway, since removed) keep their numbers, so references stay valid;
their full text is in the git history before that change.

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

## Milestone 2b: the first gateway (superseded)

**N6–N20. Superseded by N39.** An application-specific HTTP gateway, differential tests against
that application's reference implementation, and its storage choices. Two choices outlived it,
in `documents.zig`: values longer than a row are chunked across rows (N12), and chunk ids are
the first 8 bytes of SHA-256 over the key (N13), with tail chunks' ids derived from chunk 0's
(N25).

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
not (a client that never sees ops) passes `latest`: the view first pages the feed to its end,
which reaches past every write committed before the read began. Every reply starts `op=<n>`,
the watermark it reflects (G2). A wait that does not reach the position within 10 s answers
504. (Replies were `key=value` lines at first; declared views answer in JSON, N35.)

**N24–N26. Superseded by N39.** The first views were application-specific (a journal and a spend
rollup) and checked against that application's files. Declared views (N35) replace them.

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

**N28–N29. Superseded by N39.** As-of reads of the gateway's keys, and a key-value route for an
application's workflow state. `row?as_of=` (N33) and declared views `as_of` (N35) cover the
first; applications chunk large values themselves, as `documents.zig` does for the catalog.

**N30. Not built: attributed approvals and claim leases. They need an identity model.**
G7 asks that every approval be attributed to an identity, and claims that outlive a process
need a lease held by someone. Nerva's gateways authenticate with one shared key, so they cannot
tell one approver from another. Attribution needs either (a) the caller asserting an identity,
recorded beside the claim in one transaction (trusting whoever holds the key), or (b) each
approver signing the answer with a key the application issues, verified before it is recorded.
That choice settles a wire format and stored records, and belongs to the application's owner,
so it is not assumed.

**N31. Dog-fooding, not a specification.**
Owner's direction (2026-10-04): Nerva is tested on a real application, not specialized for it.
Nerva grows only general capabilities (transactions, the change feed, history, layouts, views).
An application's own rules live in the application, on top of the generic API. A gap the
application finds is reported as the general gap it exposes, not patched with an
application-only route. N39 removed the one application-specific gateway Nerva had.

**N32. CI on every push; releases are tags; the binary's release string stays `0.0.1`.**
`ci.yml` runs on every push and pull request to `main`: typecheck, format, unit tests, the
integration test, the gateway and demo suites, and the
VOPR on seeds 1, 2 and 5, plus one random seed written to the job summary. `release.yml` (as first
written; N40 changed the trigger) ran on a `v*` tag: it calls the same CI on that commit, then cross-compiles Linux and macOS binaries
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
operations without an application-specific protocol. `nerva api` is a thin translation: five routes
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
- Keyed by `X-Nerva-Key` from `NERVA_KEY`. Sequential; run more gateways for throughput.

**N34. Typed tables, minimal form: layouts are metadata in the log.**
Declared views need to read named fields (`price`, `color`) out of 80-byte values, and demo
clients want to write fields rather than hex. A table may have a layout: up to 16 fields
(`u8`, `u16`, `u32`, `u64`, `i64`, `bool`, fixed-size `bytes`), packed in declaration order,
each aligned to its size, little-endian, within 80 bytes. Choices:
- The core does not know layouts. It stores bytes and validates nothing about them; layouts are
  read by the API (to encode and decode `fields`) and, next, by views. This keeps the state
  machine unchanged and the choice reversible. The cost: a client writing `value_hex` can write
  bytes its layout does not describe well, which is accepted.
- Layouts live in the log, in a reserved catalog table (`0xFFFF0001`), chunked as documents
  (`documents.zig`) and keyed `table.<id>`, so declarations are committed facts with ops. Tables from
  `0xFFFF0000` up are reserved: the API refuses them, and leaves their rows out of `changes`.
- A layout may only grow by appending fields: data written earlier reads the same later, and a
  reader holding an older layout decodes a correct prefix. Anything else answers 409.
- A declaration is a transaction that reads the current layout, so two gateways declaring at
  once cannot both "create": the loser retries and finds it unchanged (tested).
- 64-bit fields render as decimal strings, as elsewhere (N33).
- The API reads layouts from the log on each request that needs them (at most once per table
  per request); no cache yet. Measure before adding one.

**N35. Declared views v0: declarations in the catalog, computed on read in `nerva view`.**
The demos' "Declare" moment, and Nerva's core claim, need views that are data rather than code.
- A view is `{table, where, group_by, aggregates}`: `where` ANDs up to four comparisons on
  numeric or bool fields; up to three `group_by` fields of any type; one to six aggregates
  (`count`, `sum`, `min`, `max`). It is declared with `PUT /v1/views/<name>` on `nerva api`,
  checked against the table's layout, stored in the catalog as `view.<name>`, and immutable:
  the same declaration again is "unchanged", a different one under the name is 409. Changing
  a view means declaring a new name. Deleting views is not supported yet.
- Semantics: over the table's rows as they are at op N (deletes remove rows), not over events.
  This fits the demos: seats sold and revenue per section, pixels per color.
- `nerva view` mirrors the catalog and every application table (not Nerva's own) from the feed, with every change, in memory, capped at two million changes;
  past that it stops rather than answer wrongly. A view is computed when read, over current
  rows for the latest answer or over rows replayed to op N for `as_of`. Consequences: a view
  answers for ops before it was declared, declaring needs no backfill, and reads cost
  O(rows) (latest) or O(changes up to N) (as of). Incremental maintenance and snapshots are
  later steps; this computation stays as their oracle.
- An answer at op N waits until the view process has seen op N (else 504), as for ledger
  `as_of` (N28).
- Each answer carries `hash`, SHA-256 of the `groups` JSON exactly as served (groups sorted by
  key, fields in declaration order, 64-bit numbers as decimal strings), so any two processes,
  or a reader recomputing it, can check agreement.
- `nerva view` takes its key from `NERVA_KEY` and checks `X-Nerva-Key`.

**N36. The seat demo: Python standard library, the seat map as a view, crashes that keep quorum.**
- The demo server, supervisor and client are Python with no dependencies (`demo/`), so running
  the demo needs only the `nerva` binary and Python 3. The page is one HTML file with plain
  JavaScript. The API key stays in the server; visitors reach Nerva only through endpoints that
  validate what they send (seat ids, view names prefixed `v_`, at most 24 visitor views,
  bodies up to 16 KiB).
- The venue is a typed table (N34) and three declared views (N35). The seat map itself is a
  view (`group_by` section, row and number; `max(sold)`, `max(buyer)`), so rewinding is the
  same view read `as_of` the slider's op: the demo uses Nerva's feature, not a side channel.
- A purchase is a read at the version seen plus a write; a lost race answers 409. A commit is
  never retried by the client: a retry after a crash could report a seat that was won as lost.
  "Sold out" is judged by the view, because a purchase whose reply was lost to a crash still
  sold its seat.
- Crashes are SIGKILL. The supervisor refuses to stop a second replica while one is down, so
  the cluster keeps quorum and the demo never stalls; crashed processes restart after 20 s.
- Two view processes compute sales by section; the server reads view b as of the op view a
  answered at, so the page compares their hashes at exactly the same op.
- SIGTERM to the server stops the cluster (found when a stop left six processes behind).
- `tests/demo/seats_chaos.py` (`zig build test:demo`, in CI) crashes random processes for a
  minute while buyers and visitors buy. It was mutation-tested: purchases as blind writes
  (no read) sell seats twice, and the test fails.

**N37. Nerva's HTTP gateways take one request per connection, with a 10 s receive deadline.**
Nerva's HTTP gateways serve one request at a time. Each used to keep a
connection open for further requests, so a client holding an idle keep-alive connection
starved every other client. The demo's buyer threads hit this at once; any application with
concurrent clients would have too. The test suites missed it because they open
a connection per request. Now every reply says `Connection: close`, and a connection that sends
nothing within 10 s is dropped. Cost: one TCP connect per request, which is negligible next to
a cluster round trip. `tests/api/api.py` checks both cases, and fails against the old server.
Replies are also sent with `TCP_NODELAY`, so a reply written in pieces is not held back by
Nagle's algorithm.

**N38. The canvas demo, the shared demo base, and what profiling it found.**
- The canvas is a 64 x 64 typed table (`x`, `y`, `color`, `paints`, `painter`) with three
  views; the canvas itself is a view, so a timelapse frame is the view read as of an op, as
  the seat map is (N36). A paint reads the pixel and writes it at the version read, counting
  repaints, so painters on one pixel race. The canvas clears every `--reset-minutes`.
- Moderation defaults, **to be confirmed by the owner before anything is public**: 8 colours,
  one pixel a second per visitor, a clear every hour, no free text except view names
  (lowercase letters, digits and `_`, which can still spell words: a policy question).
- `demo/common.py` holds what both demos share, including rate limits per visitor (crash or
  restart one every 5 s, declare one view every 10 s, paint 1 a second, buy 2 a second).
  `--behind-proxy` takes the visitor from `Fly-Client-IP` or `X-Forwarded-For`; otherwise the
  socket address, which a client cannot forge.
- Profiling a timelapse frame (650 ms) found that `ArrayHashMap.sort` is insertion sort, O(n²):
  a 4,096-group view took 145 ms to sort. Declared views now use `sortUnstable` (keys are
  unique): 10 ms. A Debug build had made it look like a build-mode problem; it was not.
- Measured: about 11 ms per request through one gateway to a three-replica `--development`
  cluster, so one gateway serves about 90 requests a second, enough for the demos.
- `tests/demo/canvas_chaos.py` checks that every confirmed paint is on the canvas as of its op
  (each timelapse frame is such a read), under crashes. Mutation-tested: frames that ignore
  `as_of` fail it.

**N39. No application-specific code in Nerva: the first gateway is removed.**
Owner's direction: the dog-fooding application uses releases and the generic API, and no
application-specific code or mention remains in Nerva. Removed: the gateway that spoke that
application's ledger protocol (with its key-value routes), the two views written for it, the
differential tests against its reference implementation (which included a copy of that
implementation), their build step and CI step, the `LEDGER_KEY` fallback, and the integration
guide, which now lives with the application. Kept, as general pieces: chunked documents
(`documents.zig`, used by the catalog; the id derivation's domain strings changed, which is safe
because nothing is deployed), and everything the gateway taught (one request per connection
N37, chunk ids N12/N13/N25). The application keeps its own rules on its side, on top of
`nerva api`: transactions with reads at the version seen, chunking its larger values, and
declared views where they fit. Decisions N6–N20, N24–N26 and N28–N29 are marked superseded and
keep their numbers; GOALS-1.0 and the worklog describe the workload instead of naming it.

**N40. Releases are cut by committing a new `VERSION`, not by pushing a tag.**
The agents working on Nerva can push commits to `main` but not tags. `release.yml` now runs
when a push to `main` changes `VERSION` (or by hand): it checks the version is semver and not
already tagged (releasing twice fails), runs the full CI on that commit, builds the four
targets, and creates tag `v<VERSION>` on exactly that commit while publishing the release with
`SHA256SUMS`. A version with a suffix (`0.2.0-rc.1`) is a prerelease. Pushing a tag no longer
releases: one way in is simpler to reason about, and a tag created by a workflow could not
trigger another workflow anyway. `VERSION` names the release; the binary's release string stays
`0.0.1+<commit>` (N32). First release: `0.1.0`.


**N41. Documents in the generic API: values up to 64 KiB by key, as one more reserved table.**
Every application with state larger than an 80-byte row was chunking it by hand (the catalog
did; so did the dog-fooding application). `nerva api` now serves `documents.zig` documents in a
reserved table, `catalog.table_documents` (`0xFFFF0002`), under a `u64` namespace and a string
key (1–1024 bytes of UTF-8), with values up to 64 KiB:
- `POST /v1/documents/get` reads up to 256 keys as of one op, the latest or `as_of` a committed
  op (folded into `get` rather than a separate route, so several keys share one position).
  Each document's `version` is chunk 0's op. A tail chunk whose op differs from its chunk 0's
  (a later write landed between the two lookups, or the read is `as_of`) is read from its
  history at that version, so a read is consistent without retries.
- `POST /v1/documents/commit` is one transaction: reads assert chunk 0 at the version seen (every
  write rewrites chunk 0, so that covers the document); writes put every chunk. `409` names the
  stale key and its current version.
- **A delete is a tombstone document**: chunk 0 (and any tails the key needs) written with a new
  `deleted` header flag (the header's formerly reserved `u16`; old documents read the same) and
  the key, but no value. A row delete would carry no value, so the feed could not name the key
  deleted; and the version still advances, so a read at it still conflicts correctly.
- `GET /v1/documents/changes?namespace=` decodes the feed into document writes. An op's chunks
  are grouped by op (pages always end at an op boundary, reading on while one op fills a page),
  and each document an op wrote is reported once, as the op left it. Chunk 0 is recognised by
  decoding: only a real chunk 0 decodes to a key that hashes back to its id.
- Accepted costs: a write that shrinks a document, and a delete, leave its old trailing chunks
  in place, unread (deleting them would need a read first); `as_of` reads of documents
  rewritten since cost one history read per chunk.
Found on the way: `Client` refused an oversized request (`TooManyEvents`) after marking itself
busy, so the next request on that client panicked. It now checks before; `tests/api/
documents.py` sends an oversized commit and then reads.

**N42. Adds: conditional, commutative changes to a field, applied inside the commit (G8).**
Optimistic transactions serialize every client of a hot row through retries. An `add` entry
(`EntryKind.add = 4`) changes one 64-bit field of a row (`u64` or `i64`, little-endian, at a
byte offset ≤ 72) inside the commit, reading the current value there, with no version check:
two adds to one row never conflict.
- **Parameters** live in the entry's 80-byte value (`nerva.Add`): `delta`, optional `min` and
  `max` (as the field's type), flags `clamp`, `create`, `delta_from`. `Entry` stays 128 bytes.
- **Bounds bind in the direction of the move.** An add never moves the field past `min` (delta
  negative) or `max` (positive), nor out of the type's range: the transaction fails with
  `out_of_bounds` (the result carries the field's current value), or, with `clamp`, the add
  applies as much as fits, possibly nothing. A field already outside its bounds may move back
  towards them; that makes clamping and failing agree exactly (`nerva.add_amount`, shared by the
  state machine, the VOPR model and the API).
- **`delta_from: k`** makes the delta minus what earlier add `k` of the same transaction
  applied. "Reserve up to X" is `add(available, -X, min 0, clamp)` then `add(held, delta_from 0)`:
  it can never overdraw, and money is conserved by construction. A delta of `minInt(i64)` is
  invalid, so every applied amount can be negated.
- **Transactions.** Static checks, then duplicate writes, then read versions, then adds in
  entry order (resolved against the rows and the transaction's earlier adds, without writing),
  then everything applies. Several adds may change one row (`available` and `held` in one row);
  an add and a put or delete of one row is `write_duplicate`. A row that does not exist (or is
  deleted) is `row_absent`, unless `create` starts it from zeros.
- **Results.** `EntryResult` grows from 16 to 32 bytes: `applied` (signed) and `value` (the
  field after the add, or before it for `out_of_bounds`). New statuses are appended:
  `out_of_bounds` 9, `row_absent` 10, `field_invalid` 11, `delta_from_invalid` 12.
- **The feed.** Each add is a change of kind `put` carrying the whole new row, so history,
  as-of reads, views and every reader of the feed are unchanged.
- **Tests.** Unit tests of the arithmetic and validation; deterministic state machine cases;
  the VOPR model resolves adds independently and checks every `applied` and `value`, and plays
  hot budgets (fund, reserve, release by adds only) asserting, apart from the model, that each
  budget's available plus held equals what was funded and that adds alone never fail;
  `tests/api/adds.py` races fifty reservations through the JSON API.
- **Found on the way:** two writes in one op that leave a row's bytes unchanged (an add that
  applies nothing after another write in the same request, or two identical puts in two
  transactions of one request) tripped the LSM groove's assertion against no-op updates, which
  would have crashed every replica. The row update is now skipped when nothing changed; the
  change is still recorded.
- **The release string** moves to `0.0.2` for this protocol change: N43.

**N43. The release string moves to `0.0.2`; data files from v0.1.0 must be reformatted.**
Adds changed the client protocol (`EntryResult` is 32 bytes, N42), and N32 ties the release
string to the protocol. Owner's decision: bump it, accepting that existing data files are not
carried over (nothing real is stored in Nerva). `release` and `release_client_min` in
`build.zig` are both `0.0.2`, so replicas refuse clients built before the change instead of
misreading their replies. Data files formatted by v0.1.0 are refused at open ("found
incompatible superblock version 0"), for a reason beyond the release number: TigerBeetle treats
release `0.0.1` (`Release.minimum`) as a development build and writes its data files with
superblock version 0, while every other release writes version 2. So `0.0.1` files cannot be
upgraded, only reformatted. (A replica opening a file of another non-development release would
look for that release among those bundled in its binary; Nerva bundles only its own.) Verified
with the v0.1.0 binary: it formats a file and opens it; the new binary refuses it. The golden
checksum of a formatted data file changes with the release string (UPSTREAM.md). The release
workflow now writes the binary's own version string into the release notes.

**N44. Release notes come from `CHANGELOG.md`.**
The release notes said only "Changes: WORKLOG.md", a log of work rather than what a user needs.
Each release now has a "what's new" section in `CHANGELOG.md` (`## v<VERSION> — <date>`):
new capabilities with examples, fixes with their issues, and upgrade steps. `release.yml`
publishes that section as the GitHub release notes (`.github/scripts/release_notes.sh`), and
refuses, before CI runs, to release a version without one. v0.1.0's section was written after
the fact, for completeness.

**N45. The gateways read many connections at once, parse requests strictly, and never wait for
an op not yet committed.**
Two holes in N37, both reproduced on v0.1.0: a request whose head ended in a bare LF crashed
`nerva api` and `nerva view` before the key was checked (`std.http`'s header iterator unwraps a
CRLF it assumes, #8), and the 10 s deadline was per `recv`, so a client sending a byte every few
seconds held the gateway's one thread indefinitely (#9). A total deadline alone would not do:
with one connection read at a time, any slow client still stalls everyone for as long as the
deadline. So, in `http_connection.zig`:
- A `Receiver` accepts and reads up to `connections_max` connections (16 per gateway) at once
  with `poll`, and hands out complete requests one at a time, oldest connection first; requests
  still execute serially, as before. Further connections wait in the listen backlog. All
  buffers are allocated at startup: head (16 KiB) plus the largest body per connection, about
  64 MiB for `nerva api`.
- A request must arrive whole within 10 s of being accepted, however it trickles in; the reply
  is written within another 10 s. Known limit: a client holding the key that asks for a large
  reply and never reads it can still hold the thread for up to 10 s. Replies to clients without
  the key are small enough for the socket's send buffer.
- `std.http.Server` is no longer used. `head_parse` accepts HTTP/1.0 and 1.1 heads whose lines
  all end in CRLF, without control bytes, folded lines, a repeated `Content-Length` or
  `X-Nerva-Key`, or any `Transfer-Encoding` (a body must state its length; chunked bodies were
  accepted before and are refused now, as unknown input is elsewhere, N33). `Expect:
  100-continue`, which curl sends for larger bodies, gets its `100 Continue`. Anything else
  malformed answers `400`; a bare LF is refused as soon as it arrives.
- The key is compared through SHA-256 digests in constant time, so the comparison's time
  reveals neither where a wrong key differs nor its length (#10).
- `nerva view` no longer waits up to 10 s for `min_op` or `as_of` (amends N23). Reading the feed
  to its end reaches past every op committed before the request began, so an op still ahead
  after one `catch_up` was not committed when the request arrived; it answers `504` ("the op is
  not committed yet") at once, rather than holding the only thread. The status stays `504`, so
  clients need no change. A client that knows an op from a commit reply always finds it.
Tests: `head_parse` cases and the `Receiver` on loopback (a slow client holds up nobody and is
closed at its deadline; malformed and oversized requests answer 400; with every slot busy, a
connection waits for one); `tests/api/api.py` sends each malformed head and then needs
`/healthz` to answer (the first crashes the old gateway), and serves clients while another
drips a byte every 2 s; `tests/views/declared.py` checks the immediate 504 and the same for
`nerva view`.

**N46. Fuzzing runs again, and covers Nerva's own code.**
`zig build fuzz -- smoke` had been failing since the vendoring: `lsm_scan`'s test groove uses
tree ids 1–15, and the trace's tree enum, derived from Nerva's four trees, panicked on the rest
(#6). No fuzzer ran in CI, so nothing noticed, and none covered Nerva's code.
- The tree enum stays exhaustive (its values index timing and metric slots, and traces print
  them by name) and names a placeholder `test_<id>` for every id up to 15 that Nerva does not
  use. A non-exhaustive enum would only have moved the panic to `@tagName`. Placeholders never
  receive events in a replica, and slots never set are never emitted, so metrics are unchanged.
  A vendored test with a higher id fails smoke, as this did.
- Three fuzzers for Nerva's code, cheap enough for smoke (each well under its 10 s budget in a
  Debug build), all pure functions, so no cluster is needed:
  - `nerva_adds`: `add_amount` and `add_apply` against a reference written from N42's text (a
    binary search for the largest amount that fits, rather than `add_amount`'s closed form), and
    properties of every applied amount (direction, magnitude, bounds, maximal clamping, exact
    application, the negated amount restoring the field); `entry_validate` on arbitrary
    parameters. The VOPR model shares `add_amount` with the state machine, so it cannot catch a
    mistake there; this does.
  - `nerva_http_head`: generated valid heads parse to exactly what was generated; mutated heads
    and random bytes never crash `head_parse`, and whatever it accepts keeps what the gateways
    rely on (CRLF lines only, a `/` target of visible bytes, a key without control bytes);
    `key_matches` is equality.
  - `nerva_documents`: encode and decode round-trip at sizes around chunk boundaries, with
    distinct row ids; random and damaged chunks decode within the limits or are `Corrupt`, and
    never from the wrong number of chunks.
- Each fuzzer asserts that its generators reach every outcome (applied, clamped, refused;
  accepted and refused heads; decoded and corrupt chunks), so a generator that rots fails
  rather than passing vacuously. Its first run found its own generator writing blank header
  lines.
- Mutation-tested on the smoke seed: an off-by-one clamp in `add_amount`, `chunks_decode`
  dropping a value's last byte, `head_parse` accepting control bytes in values, and
  `head_parse` accepting a repeated `X-Nerva-Key` each fail their fuzzer. (`head_parse`
  accepting a bare CR does not, and need not: a CR left after splitting on CRLF lands in a
  method, target, name or value, each of which refuses control bytes, so that check is a
  redundant guard. The last mutation was caught only after adding header-count properties.)
- `ci.yml` is unchanged while CI is re-wired; it should run `fuzz -- smoke`.

**N47. CI runs on Botpike's own runners.**
`ci.yml` and `release.yml` run every job on `[self-hosted, fly]`: Botpike/ci-runners starts a Fly
Machine (performance-2x, 8 GB, its own 10 GB volume) for the job and stops it afterwards, so a
job waits seconds for a runner and the Zig cache survives between jobs. They behave as GitHub's
runners do where this repository depends on it: jobs run as a non-root user with
`perf_event_paranoid` 2, so the perf test still skips itself (N32); the workspace is on the
volume, which holds the integration test's 3.5 GiB; `xz` and `gh` are installed for Zig's
download and the release. Nothing else changed: the steps, seeds and release are as N32 and N40
set them.

**N48. A document read through `documents.Transaction` is read whole at chunk 0's version.**
`Transaction.get` read chunk 0, then the tail chunks, in two lookups that can execute at
different ops. A rewrite committed between them made the read decode chunk 0 of one version
with tails of the next: a spurious `Corrupt`, or a value stitched from both (#7). A transaction
that went on to commit got `conflict`, so no write was ever based on it; but read-only callers
(the API reading table layouts and view declarations through `catalog_store.zig`) could see the
mix. Amends N41, whose public route already read this way:
- Every write rewrites every chunk of a document in one transaction, so in a consistent read
  every tail has chunk 0's op. A tail at a later op is read from its history at chunk 0's
  version (`Client.row_as_of`), as `documents_routes.zig` does; a tail at an earlier op cannot
  happen, and is `Corrupt`. A read without a race costs nothing more: still two lookups.
- Every chunk is recorded as read at chunk 0's version, not at the version its row holds now,
  so a transaction that commits after such a read conflicts, as it should.
- `Transaction` is now `TransactionType(Client)`, so a test can give it a stub client and land
  a rewrite between the two lookups. Callers are unchanged.
Tests (`documents.zig`): the rewrite between the lookups returns the old document whole, with
every chunk recorded at the old version (with the previous code the same test returns a value
stitched from both versions, differing from byte 49, where the first tail starts); a read
without a race reads no history; a tail older than chunk 0 is `Corrupt`.

**N49. The VOPR workload checks exact ops, sends the inputs it never did, and reaches the limits.**
An audit of the workload found what it generated and checked well, and what it never touched:
- **Exact ops.** Replies were checked only to be later than every op seen before. `vopr.zig` now
  passes the op each request committed at, and the workload asserts it exactly: each committed
  transaction's `op`, each lookup's `op_read`, and a complete feed or history reply's `end.op`.
  A reply reporting a later op than it executed at passed before.
- **Inputs never sent.** `op_seen` on a put, delete or add; kind zero; non-zero `reserved_a` or
  `reserved_c`; reads asserting a version no row has yet (they conflict); lookups with
  `RowKey.reserved` set (not found); and feed and history filters with reserved bytes set or a
  timestamp past `maxInt(u63)` (invalid: an empty reply).
- **Validation checked apart from itself.** The model took each entry's status from
  `nerva.entry_validate`, the state machine's own function, so a mistake there could not fail.
  `entry_status_check` now derives, from the rules `EntryStatus` documents, the set of rules an
  entry breaks, and requires `entry_validate` to accept exactly the entries breaking none and
  otherwise to name one it breaks. Which rule wins when several are broken stays
  `entry_validate`'s choice; an add's own parameters are `nerva_adds`'s (N46).
- **Limits.** Feed and history limits sometimes sit at `changes_limit_max`, just past it, or at
  `maxInt(u32)`, and must be clamped; lookups sometimes fill a batch to what the reply holds;
  about one commit request in a hundred is one transaction as large as the request allows,
  which runs prefetch and the state machine's scratch space at capacity. The model's scratch
  for a transaction's expected results is sized for that (`commit_entries_max`).
- **Cursors fed back.** The cursor an incomplete feed or history reply returns is kept and,
  sometimes, the next request continues from it, so the cursors the state machine hands out are
  themselves checked.
- In short-log mode the VOPR now prints the workload's end-of-run summary, with counters for
  each of the above, so a run shows what it exercised.
Signed adds were already generated (N42). Proven by planting bugs in the state machine, each
caught by a VOPR seed: see WORKLOG.

**N50. Replicas export metrics with `--statsd` and spans with `--trace`.**
Nightly performance tests and anyone running Nerva need the replica's timings, and the vendored
tracer already records them (request latency per operation, commit stages, compaction, lookups
and scans per tree, storage IO, cache hits) and emits them every 10 s. `nerva start` simply
gave it no output. Now:
- `--statsd=<host:port>` sends them over UDP in TigerBeetle's statsd format (port 8125 by
  default; a bare port means 127.0.0.1; IPv6 in brackets; port 0 refused). UDP never blocks
  the replica, and a lost packet loses one window of numbers, not correctness.
- `--trace=<path>` writes the JSON span trace (Perfetto, chrome://tracing). It writes each span
  as it happens, unbuffered, so it is for diagnosis, not for timed runs.
- No vendored file changed. Names keep the `tb.` prefix and TigerBeetle's tag spellings
  (`operation:Operation.commit`): renaming would patch the vendored tracer for no gain yet.
- `format`, `api` and `view` export nothing: `format` is brief, and the gateways are measured
  from outside (load tools see their latency directly).
- Not done here: the client's round-trip time is still reported as 0 by the vendored VSR client,
  so `client_request_round_trip` stays empty.
- `test:integration` starts replica 0 with `--statsd` (to a UDP socket the test binds) and
  replica 1 with `--trace`, then waits up to 15 s for request, commit and cache metrics and
  checks the trace holds commit spans. Mutation-tested: dropping either wiring fails it.

**N51. The Zig client returns as soon as its reply arrives, not at the end of a 10 ms tick.**
Every call through `src/nerva/client.zig` (so every `nerva api` and `nerva view` request) took at
least 10 ms: the client waited with `IO.run_for_ns(tick_ms)`, which runs callbacks as completions
arrive but always waits out its deadline. Measured on a local three-replica `--development`
cluster through `nerva api`, 200 requests each:

| | before: min / p50 / p99 | after: min / p50 / p99 |
|---|---|---|
| lookup | 10.37 / 10.60 / 12.86 ms | 0.59 / 1.05 / 1.64 ms |
| commit | 10.38 / 10.53 / 11.37 ms | 0.62 / 0.92 / 1.55 ms |

This was most of N38's "about 11 ms per request".
- The vendored IO had no public call that waits for the next completion and returns: `run`
  never blocks, `run_for_ns` never returns early. `IO.run_once(nanoseconds)` (Linux) submits,
  waits up to `nanoseconds` for a completion, runs every ready callback and returns. A minimal
  patch, listed in UPSTREAM.md. On macOS and Windows it calls `run_for_ns`: correct, only as slow
  as before; a kqueue version would need a timeout completion that outlives the call.
- The client still ticks its VSR client every `tick_ms` by the monotonic clock (VSR's timeouts
  count ticks), and between ticks waits with `run_once` until the next tick or the call's
  deadline, checking its state after every callback.
- Rejected: polling `run_for_ns` in short slices. No vendored change, but it spins thousands of
  syscalls a second while waiting and still leaves a floor.
- Tests: an IO unit test (a 1 ms timeout ends a 10 s `run_once` within 1 s; an idle `run_once`
  waits its duration); `test:integration` asserts the median of 50 lookups is under one tick
  (1.4 ms locally). Mutation-tested: with `run_once` waiting out its duration, both fail (the
  median becomes 10.2 ms).

**N52. Views maintained by the state machine: groups and their hash are replicated state.**
`nerva view` (N35) keeps every row and change in memory and computes a view when it is read,
so memory, restarts and `as_of` all grow with history, and its hash shows two processes agree,
not that they are right. Owner's decision (option B over an incremental view process): views
are maintained inside the commit, like rows. This first step covers `count` and `sum`; `min`,
`max` and `as_of` come next, and `nerva view` stays for those until then.
- **Declaring.** `declare_view` (operation 133) takes a binary `ViewDefinition`: the view with
  its fields resolved to offsets by `nerva api` from the table's layout, so the state machine
  reads no JSON and no layouts. Views are immutable (`exists`, `different`), at most 64 in the
  cluster and 4 per table, with ids 1..64 in declaration order. `PUT /v1/views/<name>` declares
  into the catalog as before (for `nerva view`) and then into the state machine, and says
  whether the view is maintained.
- **Storage.** Two new grooves: `views` (tree ids 5, 6; 512-byte objects) and `groups` (tree ids
  7, 8; 256 bytes), keyed by `view_id << 64 | group_hash`, the group hash being the first 8
  bytes of SHA-256 of the view id and the group key. The group key (the group_by fields'
  bytes) is stored and compared on every update: a collision fails the view, on every replica
  at the same op, rather than merging two groups. Empty groups are kept, so that their history
  can be read later.
- **The hash** of a view is the sum, modulo 2^256, of its non-empty groups' digests; each change
  subtracts the old digest and adds the new, so it costs the same whatever the view's size, and
  every replica holds the same value at every op.
- **Maintenance in the commit.** Commit prefetch runs in three stages: the views, then the rows,
  then every group the request may touch (the old row's group and the put's new one, per view
  of the table; an all-zero row's for a creating add). Adds may not change a field a view
  filters or groups by (`view_key_field`), so an add never moves a row between groups and the
  prefetch needs no simulation of the commit.
- **Bounded per op.** Each LSM tree's tables are sized from its writes per op. Budgeting for the
  worst case (every entry of a commit, two groups in each of four views) would have needed
  about 1 GB of table memory per replica. Instead one op writes at most
  `StateMachine.groups_per_op_max` distinct groups (half a commit's entries, 4,095 in
  production, so the groups tree is the rows tree's size). A commit's group changes are
  coalesced in memory and each group is written once, at the end of the op.
- **Admission by distinct groups.** The first budget charged 2 per write per view, and made
  any transaction of more than about 2,000 writes to a viewed table permanently `views_busy`:
  the canvas demo's large strokes livelocked. What costs memory is distinct groups, so that is
  what is counted. In prefetch, from the rows as they are before the op, each transaction in
  request order adds the groups it may touch (for every write, in every view of its table, the
  old row's group and the put's, or a creating add's empty row's, where they pass the filter):
  a superset of what the commit touches, since an earlier transaction's put is counted by that
  transaction and adds never move rows. A transaction whose groups do not fit is refused whole
  with `views_busy` (status 14), at its first write to a viewed table, before any other check,
  and can be retried in a later op; later transactions of the op may still fit. Commit only
  reads the decision, so prefetch and commit agree by construction. A transaction is refused
  only if the op's distinct groups exceed about 4,000, whatever its number of writes.
- **Timestamps.** Objects need unique timestamps, and one entry may create a group in each view
  of its table, so a commit reserves a block of 5 timestamps per entry (its change takes the
  first). Change timestamps are now sparse; feed cursors are unaffected.
- **Backfill by pulse.** A view starts `building`. While one is, `pulse_needed` is true and the
  replica sends itself `pulse` (mapped from `vsr.Operation.pulse` to operation 134, as
  TigerBeetle maps it to its own): the pulse scans the table's rows from the view's cursor (a
  range scan over the rows' key index, `scan_unique_key_range`, a small vendored addition) and
  adds up to `groups_per_op_max` rows, then the view is `ready`. Commits skip a building view's
  rows at or past its cursor; the pulse reads them later as they are then. After a restart the
  state machine does not know whether a view is building, so one pulse finds out.
- **Reading.** `get_view` (operation 132) returns a header (state, declared op, the read's op,
  hash, group count) and a page of groups in storage order, by view id or by name;
  `GET /v1/views/<name>/groups` renders them through the layout as `nerva view` does.
- Tests: `views.zig` unit tests (validation, membership, the hash's order independence, a
  pinned group-key vector); deterministic state machine tests (maintenance across transactions,
  moves, deletes and stale reads; backfill in several pulses with writes on both sides of the
  cursor; refusals; paging); the VOPR declares random views and checks every ready view's
  groups, hash and group count against groups computed from the model's rows, reproduces
  `view_key_field` and admission (`views_busy`) exactly, and checks a ready view never builds
  again; `tests/views/maintained.py` backfills 5,000 seats and compares each answer with `nerva view`
  at the same op, recomputing the hash in Python. Mutation-tested: groups that never lose rows
  fail the unit tests and the VOPR (seeds 1, 3 and 7); rows past the cursor counted twice fail
  the backfill test; admission refusing one group early fails the VOPR (seed 7).

**N53. CI runs every fuzzer at its smoke size.**
`ci.yml`'s `test` job runs `zig build fuzz -- smoke` after the unit tests: every vendored fuzzer
and Nerva's own (N46), each at a fixed seed and a size chosen to stay within its smoke budget.
#6 went unnoticed because nothing ran the fuzzers; now a fuzzer that stops working fails CI. It
was held back while CI moved to Botpike's own runners (N47). The fixed seed makes smoke a
regression check, not a search: finding new bugs takes many seeds, which is a scheduled job's
work, not every pull request's. `lsm_segmented_array` logs "too slow for the smoke mode" in a
Debug build (about 20 s against its 10 s budget); that is a warning, not a failure.

**N54. Format guards: tests that fail on any change to what Nerva puts on the wire or on disk.**
Only struct sizes (comptime asserts), one document id vector and an empty formatted data file
were pinned. Reordering fields of equal size, renumbering an enum value or tree id, or changing a
derived key, the catalog's stored JSON, a layout's packing or what a commit stores would all
have passed every test. Three guards, all tests, no production code:
- `format_test.zig`, "wire and storage layouts": every wire and storage type (rows, entries and
  results, add parameters, keys, values, changes, both filters, the document header) rendered by
  reflection with its size and each field's offset, size and type (bits, for flags), every
  persisted enum's values, and `tree_ids`, compared to a snapshot.
- `format_test.zig`, "persisted derivations": golden values for `row_key`, documents' `tail_id`
  (computed apart from the code, in Python, as `row_id`'s was), and the catalog's canonical
  layout and view JSON and its packing of a layout's fields into a row (checked by hand against
  N34's rules). The canonical view stores `true` as `"1"`; the guard records it as it is.
- `state_machine_tests.zig`, "what a fixed script commits": puts, a delete and re-create, a read
  at the version seen and a stale one, unsigned and signed adds, a clamped reservation moved by
  `delta_from`; every result, row, change and history record, summarized (checked by hand) and
  checksummed.
A meant change updates the snapshots with `SNAP_UPDATE=1` and says why (CLAUDE.md); one that
changes the protocol or the data file also moves the release string (N32). Not guarded here: the
data file's own encoding (grid, LSM, superblock). That is the vendored code's, pinned upstream
and by the formatted-file checksum (`replica_format.zig`); a populated golden data file would
need checkpointing the harness does not do, and would test TigerBeetle's encoding more than
Nerva's. The script guard sees what a client can observe: a stored byte no reply exposes (a
deleted row's old value) is not covered.
Written before views (N52) and merged after them: the layouts guard also covers views' wire and
storage types (definitions, views, groups, queries, records, their enums and flags), the new
operations and tree ids 5 to 8. The script guard's first run on the merged code failed, as it
should: N52 reserves 5 timestamps per entry, so change timestamps step by 5. N52 records that
change; the snapshot was updated for it. (The release string stayed `0.0.2` through N52's new
trees, operations and timestamps: whether that needed a bump under N32 is the owner's call.)
Proven by planted changes, each failing exactly its guard: two `HistoryFilter` fields swapped,
`EntryStatus.conflict` renumbered, a tree id renumbered (layouts); `row_key`'s halves swapped,
one character of `layout_render`'s output (derivations); change timestamps shifted (script).

**N55. Phase 0 of performance testing: client round trips, a row cache flag, `zig build bench`
and a load generator.**
The rest of what the nightly performance job needs before it can measure anything:
- **Client round trips.** A primary records `client_request_round_trip` from each request's
  `previous_request_latency`, which the vendored `vsr.Client.request` always sent as 0.
  `src/nerva/client.zig` now builds its request messages itself (`send`, with the public
  `get_message` and `raw_request`), carrying the previous call's round trip in nanoseconds: a
  replica reads the field as nanoseconds before release 0.17.0, as microseconds after, and a
  comptime assertion fails if Nerva's release string ever crosses that line. No vendored change.
  Found on the way: only the primary records round trips (at prepare), while every replica
  records request timings (at commit); `test:integration` now has every replica send statsd.
- **`--cache-rows=<size>`** sizes the row object cache, which was fixed at its minimum (one set,
  a few hundred rows). Bytes are divided by the row size (128) and rounded down to whole sets;
  less than one set is refused. The default is unchanged: changing it is a measured decision for
  later.
- **`zig build bench`** runs every `benchmark:` test in benchmark mode, ReleaseSafe, from a
  separate test binary (the existing route, `-Drelease test -- "benchmark: …"`, still works).
  `Bench.metric` (a vendored addition) prints `bench-json:` lines for machines. Nerva's first
  benchmarks: `documents` (chunk encode with ids, and decode) and `declared views` (latest and
  as of a middle op). First numbers (ReleaseSafe, this sandbox): a 64 KiB document takes about
  0.69 ms to encode, nearly all of it the SHA-256 of each of its ~820 chunk ids.
- **`zig build bench:load`** (`src/bench_load.zig`): one thread and one blocking client per
  `--clients`, closed or open loop, workloads c1–c5, c3_adds and c7 of the plan, a log-linear
  `LatencyHistogram` (`src/nerva/latency_histogram.zig`, at most 1/16 relative error), one JSON
  object out. `--local` starts a three-replica `--development` cluster (at most 6 clients there).
  Built by `zig build check`, so it cannot rot. Not done: C6 (history of deep rows) and C8 (a
  replica crash), which belong to the harness that owns the processes.
- First local readings (4-CPU sandbox, `--development`, 5 s each): adds on four hot rows commit
  691 a second against 223 for read-modify-write with retries (541 conflicts). Lookups: one or
  two clients reach about 1,550 a second with p99 1.4–10 ms; four clients fall to 710 a second
  with p90 20 ms and p99 32 ms, in steps of the replicas' 10 ms tick. Either CPU contention (3
  replicas and 4 clients on 4 CPUs) or requests waiting on a replica tick: the first thing for
  the nightly job, on dedicated machines, to settle.

**N56. A nightly A/B performance run on one Fly Machine.**
`perf-nightly.yml` (06:47 UTC, and by hand) measures `main` against the last night that passed:
- **Where.** The job runs on Botpike's CI runners (N47) and creates one dedicated Machine for the
  night (performance-8x, 16 GB, a 50 GB volume) in the `nerva-perf` app, with both builds baked
  into its image, and destroys it on exit, failure included; each night first sweeps anything
  older than four hours. One Machine (three replicas and the load on localhost) keeps noise low
  and the orchestration simple; replicas on separate Machines are a later step (v2).
- **What.** `perf/nightly/run.sh` runs each build in each of three rounds, in alternating order
  (A B, B A, A B) so drift over the night falls on both: every `benchmark:` test, then nine
  `bench:load` workloads (c1, c1 batch 64, c2, c3, c3_adds, c4, c4 batch 64, c5 batch 1024, c7;
  8 clients, 20 s each) against three replicas in production config. One JSON line per result.
- **Verdict.** `perf/nightly/compare.py` pairs the builds within each round. A metric fails when
  the candidate is worse than its threshold in every round (at least two), warns when the median
  is worse, and improves when the median is better. Thresholds, fixed until calibrated: 10% for
  throughput and microbenchmarks, 15% for p50, 25% for p99. A failed night files a
  `perf-regression` issue and does not move the baseline; it never blocks a release (owner's
  decision).
- **Records.** Each night's results, log, verdict and summary go to `results/<date>-<commit>/` on
  the `perf-results` branch, whose `baseline` file names the commit to beat.
- **The baseline must build `bench:build`** (added here). A baseline from before it is replaced
  by the candidate itself, which makes that night a measure of noise.
- **Credentials.** The secret `FLY_API_TOKEN_PERF`; meant to be a deploy token scoped to
  `nerva-perf` rather than an organization token.
- **Trial** (2026-10-05, from a session, the same commit as both builds, 2 rounds of 5 s):
  every metric passed, within 9% at the median. The Machine and volume were destroyed.
- **Found by the trial, the first thing to investigate:** in production config on the Fly
  volume, 8 clients reach only about 245 operations a second with a 31 ms median (c1, c4), against
  about 1 ms locally with `--development`. The microbenchmarks match local numbers, so the CPU is
  not the difference: most likely Direct IO writes, from three replicas sharing one volume capped
  at 16,000 IOPS and 64 to 128 MiB/s. Until that is understood, the nightly's load numbers mostly
  measure the volume; they still detect regressions, which is what they are for.

**N57. CI runs its tests as parallel jobs, and keeps the Zig toolchain on the runner's volume.**
Measured on run 37240753012, the single `test` job was the critical path at 7m05 (typecheck 48 s,
format 0 s, unit 3m06, integration 29 s, API 2m10, views 21 s), then `demo` at 6m03 (a release
build, the seat demo, then the canvas demo); the VOPR seeds take 40 s to 2m01. `ci.yml` now runs:
- `unit`: the unit tests alone, the longest step.
- `system` ("check, integration, API, views"): typecheck and format first, then the
  integration, API and view tests. The typecheck builds the `nerva` binary those tests run, so
  its 48 s is mostly work they would do anyway.
- `demo`, one job per demo (`seats_chaos.py`, `canvas_chaos.py`): a release build, then the demo
  with `--seconds=75`, exactly the command `zig build -Drelease test:demo -- --seconds=75` runs for
  it. A step fails the job if build.zig's demo list and the matrix differ, so a new demo cannot
  be left out of CI. Nothing a demo checks changed.
- `vopr`, as before.
- `fuzz`: every fuzzer's smoke pass (N53), a job of its own so it does not lengthen `unit`
  (about 1.5 minutes).
Every check that ran before still runs, on the same commands. There is no aggregate `test` job:
this private repository's plan has no branch protection or rulesets (the API answers 403), so
no check name is required, and `release.yml` depends on the called workflow as a whole. Should
a required check be configured later, add an aggregate job then.
Checkout cleans `./zig`, so each job spent 7 to 9 s downloading Zig. The toolchain is now kept on
the Machine's volume at `$XDG_CACHE_HOME/nerva-toolchain/zig-<hash of zig/download.sh>` and
linked into `./zig` (Zig finds its `lib` next to the real binary). Changing the pinned version
changes the script, so the key. A copy is written aside and renamed when complete, used only if
it runs and has its standard library, and otherwise replaced by a fresh download; download.sh
then checks the version as before. `release.yml` still downloads (one job per release).
A run now takes 10 Machines instead of 6, of the org's pool of 30.

**N58. Gateway fixes from the second hardening pass: routes, recovery, slots, trace files.**
Five bugs found by the second pass, each reproduced before it was fixed:
- **`GET /v1/views/groups` crashed `nerva api` (#26).** The path matched both the views prefix and
  the groups suffix, and the name between them was sliced from 10 to 9. A path is a groups route
  only with a name between the two: `/v1/views/groups` is the view named `groups`, which can now
  be read and declared, and `/v1/views/groups/groups` reads its groups.
- **One timeout disabled `nerva api` for good (#27).** A client that timed out or was evicted
  stays unusable, and the gateway never replaced it, while `/healthz` said 200. The gateway now
  keeps the client's health: after a timeout or eviction it answers 503 at once, and the next
  request for the cluster at least 5 s later replaces the client (`Client.reconnect`, or `init`
  alone if a replacement failed partway, never `deinit` twice). `/healthz` answers 503 until it
  is ready again, so a load balancer stops sending to it. The 5 s bound keeps an outage from
  tying up the gateway's thread with a registration per request. `nerva view` still exits when
  it cannot follow the feed, leaving recovery to its supervisor.
- **Idle connections locked clients out (#28).** N45's 16 slots each held an idle connection for
  its whole 10 s deadline, while new connections queued behind them: 200 idle connections held
  `/healthz` up for 85 s, with no key. With every slot busy, the `Receiver` now still polls the
  listening socket, and a waiting connection displaces the oldest one still sending its request
  (closed without a reply). A client that sends its request promptly is served; an attacker must
  open connections faster than a request arrives, not merely hold sixteen. Not a per-peer limit:
  behind a proxy every client has one address. Amends N45, whose further connections waited in
  the backlog.
- **`--trace=<path>` truncated whatever it named (#29)**, a data file included. It is now
  created exclusively, and an existing file is refused with a message.
- **A body with a newline was refused when it arrived with its head (#36).** N45's early
  refusal of a bare LF scanned every byte read so far, body included, so `curl -d` with
  pretty-printed JSON (the README's own examples) got `400 malformed request` whenever head and
  body shared a read. The scan now stops at the end of the head; the body is bytes.
Tests that fail on the binary before these fixes: a view named `groups` read and declared
(`tests/views/maintained.py`); 200 idle connections and `/healthz` within 3 s, `start --trace`
of an existing file leaving it intact, and a replica stalled past the client's timeout, then
resumed, with the gateway reporting itself unhealthy and recovering (`tests/api/api.py`); and a
`Receiver` unit test of displacement; and a multi-line body sent in one write with its head
(`tests/api/api.py`, and a `Receiver` unit test that also keeps a bare LF in the head refused).

**N59. Long fuzzing, by hand, on runners started for it.**
Smoke (N53) runs each fuzzer once at a fixed seed: it keeps fuzzers working, but finds little.
Finding bugs takes many seeds. `.github/workflows/fuzz.yml` runs, on `workflow_dispatch` only,
one job per fuzzer (all sixteen but `canary` and `smoke`), six VOPR lanes on Nerva's state
machine and one on the testing state machine, each searching random seeds for a budget of
minutes (default 120, at most 300). The owner starts Fly runners (Botpike/ci-runners) for a run
and stops them afterwards, so it costs only while it runs. `.github/scripts/fuzz_loop.sh` builds
once (ReleaseSafe), then gives each run a fresh seed and a 30-minute cap. A failing seed replays
exactly, so the job prints the seed and the command that replays it, in its log and summary, and
stops: one failing seed is the finding. A run past the cap is a warning, not a failure (some
fuzzers' default sizes are long). Not scheduled: a schedule would need runners standing by.

**N60. Release v0.3.0: the release string moves to `0.0.3`; clients from `0.0.2` are still
accepted.**
Maintained views (N52) changed what a commit does on every replica (5 timestamps per entry,
operations 132–134, trees 5–8) without moving the release string, so v0.2.0 and later binaries
both said `0.0.2` (#34). Owner's decision (N32, option (a) of #34): bump `release` to `0.0.3`
and reformat, as for N43. `release_client_min` stays `0.0.2`: the client protocol only gained
operations, and a v0.2.0 `nerva api` was measured committing and reading against a `0.0.3`
cluster. Measured on what the bump does and does not do:
- A `0.0.3` replica opening a `0.0.2` data file stops with `multiversion unsupported`: it looks
  for `0.0.2` among the releases bundled in its binary, and Nerva bundles only its own (N43).
- It does **not** keep releases apart on the wire. In a three-replica cluster with two v0.2.0
  replicas and one freshly formatted `0.0.3` replica, the `0.0.3` replica joined as a backup,
  was needed for quorum (and committed) once a v0.2.0 replica stopped, and panicked with
  `checkpoint diverged` at op 960, the first checkpoint. TigerBeetle expects a newer binary to
  run older releases' prepares with the older code it bundles; Nerva has no older code to run.
  N61 makes replicas ignore peers of another release, so a mixed cluster cannot diverge.
- The golden checksum of a formatted data file did not change: only the development release
  `0.0.1` writes a different superblock (N43).
v0.3.0's notes list #30–#33 as known issues; #38's fixes (#26–#29, #36) and N61 (#34) ship in
it.

**N61. Replicas ignore peers that run another release.**
N60 measured that a release string only guards data files: a replica of another release joins
the cluster, counts toward quorums while it executes the log with other code, and is caught only
at the first checkpoint (#34). TigerBeetle lets releases mix because a newer binary bundles the
older releases and runs their prepares with the older code; Nerva bundles one (N43). Owner's
decision: fix it in v0.3.0.
- **By peer, not by message.** Only pings and pongs carry their sender's running release; most
  replica messages carry release 0. A replica records each peer's release from its pings and
  pongs and handles a peer's messages only once that peer has announced the release it runs
  itself (`nerva/release_peers.zig`, `admits`). A peer that has not announced yet counts for
  nothing, about a second at startup. Prepares and blocks do not name their sender (any replica
  relays or repairs them) but carry the release they were made in, so they are checked by that:
  root and reserved prepares carry 0. Requests, client pings and replies pass:
  `release_client_min` governs clients.
- **Restarts.** A restart always drops the restarting replica's connections, so a replica
  forgets a peer's release when the message bus no longer holds a connection to it, and pings a
  peer as soon as a connection appears, so each side learns the other's release within a tick
  rather than at the next ping timeout. (Pinging first on open, the first design, does not
  work: the bus drops messages to replicas it is not yet connected to.)
- **Opt-in, for Nerva.** `Replica.Options.release_peers_strict`, set by `nerva start`. Vendored
  `replica_test.zig` and the VOPR's `testing` lane simulate TigerBeetle's in-place upgrades, in
  which replicas of different releases cooperate, and keep upstream behaviour. The VOPR's `nerva`
  lane simulated them too, a path Nerva never runs (N43: a new release is a reformat). It now runs
  one release with the option on, as production does.
- **With a v0.2.0 peer**, which ignores no one (measured with the v0.2.0 binary). One v0.3.0
  replica and two v0.2.0: the v0.3.0 replica logs that it ignores both, drops their prepares,
  and never counts; the v0.2.0 pair cannot commit without each other. Two v0.3.0 and one v0.2.0:
  the v0.3.0 pair ignores the v0.2.0 replica and commits past a checkpoint; the v0.2.0 replica
  takes the v0.3.0 primary's view, commits its prepares, and panics on the first operation it
  does not know (`Operation.cast`, a views operation). Either way only one release's replicas
  count toward quorums. Between v0.3.0 and later releases neither side executes the other's
  prepares.
Tests: unit tests of `admits`; `zig build test:release` (`tests/release/mixed.py`) builds a
second `nerva` with release `0.0.200` and runs replicas 0 and 1 on one release and replica 2 on
the other: both sides log the mismatch, nothing commits without replica 1, and with it back
1,000 commits pass the first checkpoint with no panic (before: `checkpoint diverged`). VOPR
seeds 1, 2, 5 and two random seeds on the `nerva` lane, 1 and 2 on `testing`. Mutation-tested:
without the gate a commit succeeds with replica 1 stopped (`test:release`); admitting unannounced
peers or prepares of another release fails the unit tests. Forgetting a release on disconnect is
not covered by a failing test: a restart onto another release would need two binaries swapped on
one replica index within a ping interval.

**N62. Views' `min` and `max` from each group's members in order; views read as of any op.**
The second step of N52 (design approved by the owner before implementation). After it, every
aggregate `nerva view` offers is maintained by the state machine, and a view reads as of any
committed op since its declaration.
- **Members.** `count` and `sum` change by adding and subtracting; `min` and `max` cannot: when
  the row holding a group's minimum leaves, the new minimum is another row's. So every `min` or
  `max` slot keeps, for each row in the view, a `Member` (tree ids 9 to 11; 128 bytes): keyed by
  view, slot and row, and, while the row is in a group, indexed by `order`, the group's 64-bit
  prefix (SHA-256 of the view id, the slot and the group key) then the value, encoded so that it
  sorts as the field does (signed fields with the sign bit flipped; every comparable field is at
  most 64 bits). A group's slot is the first member of its range in `order` (`min`) or the last
  (`max`), and the group stores it, so reads cost nothing more. Members are never removed: a row
  that leaves the view keeps its member, out of the order. The member stores its group key: a
  prefix shared by two groups is found when the order is read, and fails the view at that op on
  every replica, as a group hash collision does (N52).
- **Exact at every op, with no IO in commit.** Commit prefetch gains two stages. Stage 3
  prefetches the member of every admitted write in every `min` or `max` slot of its table.
  Stage 4 counts, per group and slot, the writes that may take a member out (from the rows as
  they are before the op, a superset, as admission's count is), `r`; and where one of them may
  take away the member holding the group's value, reads the first `r + 1` members of the order,
  one scan each: at least one of them is untouched by the op, unless the slot has no more. At
  the end of the op each touched group's slot is the best of the members the op brought into it
  and either its stored value (if the op did not take away its holder) or the first untouched
  member read. The view's hash and group count are now kept there too, once per group per op,
  from the group as stored and as left.
- **Bounds.** At most 4 `min` and `max` slots per table, across its views (`declare_view`
  answers `table_extremes_full`, status 9). One op writes at most a request's entries' worth of
  distinct members (`members_per_op_max`, 8,190 in production), and admission counts them as it
  counts groups (N52): a write counts its member in each `min` or `max` slot of each view whose
  filter its old or new value passes, and a transaction that would take the op past the limit
  is refused whole (`views_busy`). With one such slot on a table any request fits; with k, a
  transaction of more than 8,190 / k writes to that table never does: 4,094 with two, 2,047 with
  four (measured; this said two slots fit any request, corrected after the 0.0.4 hardening pass,
  and such a transaction is refused `views_too_large` since N72). The owner chose
  this over sizing the members trees so that nothing is ever refused: measured on one replica
  (`--development`, RSS after start), `main` takes 1,014 MiB, this change 1,295 MiB, and with
  members sized for 4 × a request's entries 1,953 MiB. The 281 MiB are mostly the two version
  trees. A pulse adds at most as many rows as both limits allow (`backfill_rows_max`). The scans
  of stage 4 count each member once, so they read at most twice as many members as the op may
  touch. Each entry's block of timestamps grows from 5 to 9 (its change, a group in each of 4
  views, a member in each of 4 slots); a pulse's rows take the same blocks.
- **As of an op.** Two append-only trees, like the changes: `group_versions` (tree ids 12, 13;
  256 bytes), the group as each op that changed it left it, and `view_versions` (14, 15; 128
  bytes), the view's state, hash and group count likewise, written once per op at the end of
  the op. Each op reserves timestamps for them, below its writes' (`group_writes_limit` plus
  `views_max`), so entries keep the top of the op's range as before. A version key orders a
  group's versions by op (`view_id`, the group hash, then the op in 57 bits: ops below 2^57).
  `ViewQuery.as_of` (zero: the latest; the last 8 of v0.3.0's 12 reserved bytes, which its
  clients send as zeros, so their queries still read the latest) reads the view's last version at or before `as_of`, then walks the
  current groups in storage order (groups are never removed) and reads each one's last version,
  one scan per group: so an `as_of` page holds at most 128 groups (`view_as_of_limit_max`). A
  group with no version then did not exist yet; a view with none, `missing`. `as_of` past the
  read's op reads the latest. History is kept forever, as rows' is.
- **API.** `GET /v1/views/<name>/groups?as_of=<op>` (refused for an op not yet committed, as
  `GET /v1/row` is; `404` before the declaration), and every group renders each aggregate as
  `<fn>_<field>`, as `nerva view` does. The reply now carries `declared_op`. `PUT /v1/views`
  says `"maintained": true` for `min` and `max`; `unsupported` (status 8) is no longer returned.
- **Tests.** Unit tests for the ordered encoding, member keys and order prefixes and version
  keys; golden values for all four (computed in Python) in the derivations guard. The state
  machine tests' harness now compacts and checkpoints as the replica does, so a test may run
  for hundreds of ops: a randomized test (ids few and prices fewer, so that ties are common;
  puts, deletes and adds; several transactions per op) compares two views, with four `min` and
  `max` slots over unsigned and signed fields, to a brute-force model after each of 300 ops,
  after a backfill with commits between the pulses; then reads every one of those ops back as of
  it, and as of before and at the declaration. The VOPR declares views with random `min`, `max`
  and `sum` slots, predicts `table_extremes_full`, checks ready views' slots against the model
  (computed apart from the members), reads as of random past and future ops against the rows
  replayed from the model's change feed, and checks that a view read ready as of an op is never
  building as of a later one. `tests/views/maintained.py` adds a view with `min` and `max`, and
  compares both views with `nerva view` latest and then as of every op compared before.
- **The canvas demo** declares a view with a group per pixel and `max`, maintained since this
  change: its reset, one transaction of 4,096 pixels, needed one group more than an op takes and
  was refused forever, and `commit_retrying` retried it forever (found by `test:demo`). The
  owner chose to reset in two transactions of 2,048 pixels; an epoch starts at the second.
- **Mutation-tested.** In the state machine: reading one member instead of `r + 1`, ignoring that
  an op took away a group's holder, and reading versions as of `as_of - 1` each fail the
  randomized unit test. The VOPR's comparison is live (every `min` and `max` set to zero fails
  seeds 1 and 13), but the two subtler of those bugs pass seeds 1, 2, 3 and 13: its few reads of
  ready views rarely meet a group whose holder left, or a group changed at exactly `as_of`.
  The unit test is what guards them.
- **Release `0.0.4`, clients from `0.0.4`** (owner's decisions, on N32 and N60). What a commit
  does on every replica changed (9 timestamps per entry, a reserve per op, trees 9 to 15), so a
  `0.0.3` and a `0.0.4` replica would diverge: the release string moves, data files must be
  reformatted, and N61 keeps replicas of the two releases apart. Clients of v0.3.0 are refused:
  a v0.3.0 `nerva api` asserts that a maintained view's aggregates are sums, and does not know
  status 9, so against this cluster it would crash on a `min` or `max` view. Measured: a `0.0.2`
  `nerva api` is evicted at registration with `client_release_too_low`, and then segfaults, an
  older bug in the client's eviction (#48). `ViewQuery` keeps v0.3.0's layout regardless:
  `as_of` takes the last 8 of its 12 reserved bytes, so had old clients been kept, their
  queries would still read the latest. The formatted data file's golden checksum is unchanged,
  as for `0.0.3` (N60).
- **Format guards** (N54) updated, as they should fail on all of this: the layouts snapshot
  gains the three new types, tree ids 9 to 15, `table_extremes_full` and `ViewQuery.as_of` in
  its reserved bytes; the script snapshot's change timestamps step by 9 per entry, plus each op's reserve
  for versions.

**N63. Each release carries a software bill of materials (CycloneDX 1.5).**
Owner's request after v0.3.0. Nerva has no package dependencies, so its bill of materials is
read from the repository's own pins rather than from a package manager:
- **Components.** Nerva (version, commit, protocol release from `build.zig`); TigerBeetle,
  vendored as source with local changes, at the commit pinned in UPSTREAM.md; the Zig standard
  library and compiler-rt, compiled into every binary (Linux binaries are static with no libc;
  macOS binaries link the system's libSystem, not shipped); and the Zig compiler that built
  them, `scope: excluded`, with the SHA-256 of the x86_64-linux archive that `zig/download.sh`
  pins and verifies, since every target is cross-compiled there.
- **Consistency.** `.github/scripts/sbom.py` refuses to write one when the Zig version in
  `zig/download.sh`, UPSTREAM.md and `build.zig` disagree, or a pin is missing.
- **Reproducible.** The serial number is a UUIDv5 of the tag and commit, and the timestamp is the
  commit's (UTC), so the same release always gives the same file.
- **Published** as `nerva-v<VERSION>.cdx.json` beside the binaries, in `SHA256SUMS`. The release
  workflow's `version` job writes it once before CI runs, so a broken pin stops a release early.
- **Not included: signed provenance.** GitHub artifact attestations need a public repository or
  Enterprise Cloud; signing with another tool (cosign) is a separate decision.
Tests: `.github/scripts/test_sbom.py` (CI's `system` job): the SBOM names this repository's pins,
is well formed and reproducible, and is refused for disagreeing Zig versions, a missing pin, or
a bad tag or commit. The output for v0.3.0's commit passed strict validation against the
CycloneDX 1.5 JSON schema (`cyclonedx-python-lib`, run once locally; not a CI dependency).
Mutation-tested: dropping the version cross-check, or citing another host's archive, fails it.

**N64. Gateways recover from a broken cluster client on their own; a late reply is dropped.**
Two follow-ups to N58 (#27), found after v0.3.0:
- **#42: a reply after the timeout panicked the client.** `Client.on_reply` asserted the
  client was waiting. After a request times out, `deinit` (and so `reconnect`) still drives IO
  while it closes the connections, and the reply to the abandoned request can arrive then.
  `on_reply` now drops a reply in `timed_out`; any other state is asserted as before. Since N58
  this could abort `nerva api` too, when the cluster was slow rather than down.
- **#42: `nerva view` exited on one timeout.** It now keeps a `ClientHealth`, as `nerva api`
  does: a request or feed read that times out (or an eviction) breaks the client; requests
  answer 503 and `/healthz` 503 until it is replaced; then the follower reads the feed on from
  its cursor, which a failed read leaves unchanged (`get_changes` is read before anything is
  applied). The view keeps everything it had built, so nothing is rebuilt. A timeout during the
  rebuild at startup still exits: the process has served nothing yet, and its supervisor
  restarts it.
- **#44: `/healthz` stayed 503 until a request arrived.** The client was replaced only inside a
  request for the cluster, so a gateway taken out of rotation by a load balancer never got the
  request that would bring it back. While the client is broken, both gateways now wake at least
  every second and try to replace it, still at most every 5 s (`reconnect_interval_ns`). An
  attempt blocks the gateway's one thread for up to the client's timeout, as it did inside a
  request.
`ClientHealth` moved from `api/server.zig` to `src/nerva/client_health.zig`, shared by both.
Tests: a unit test delivers a reply to a timed-out client (it panicked before). In `test:api`,
after a stall past the client's timeout, only `/healthz` is polled until it answers 200 (before:
503 for as long as no request came). In `test:views`, a view process stalled the same way stays
up, answers 503 and `/healthz` 503, then recovers with only `/healthz` polled and serves the
same hash as before the stall (before: it exited).

**N65. CI frees the runner volume before a job when it is nearly full.**
Each runner Machine's 10 GB volume keeps the Zig toolchain and Zig's global build cache between
jobs (N57). Nothing pruned the build cache, so as branches built it filled the volume, and jobs
on a well-used volume failed at the integration test's first data file with `NoSpaceLeft`
(#50). `.github/scripts/free_disk.sh` runs first in every CI job (`INSTALL_ZIG`) and in
`release.yml`'s build job. It logs free space on the workspace's and the cache's filesystems,
and below 6 GiB free (`FREE_MIN_GIB`) on either it empties the build cache and every toolchain
but the pinned one. A job then rebuilds from scratch, about a minute more. A threshold rather than
always emptying keeps the cache's speed-up on most jobs. If space is still short afterwards, it
warns and lists what is large, so the next full disk names its cause.

**N66. `nerva api` serves views whole, as `nerva view` answers them; `nerva view` becomes the
check.** The third step of N52 (design approved by the owner). Applications read views where
they write, from replicated state, and `nerva view` stays as an independent recomputation.
- **Routes.** `GET /v1/views/<name>` is now the view (it was the declaration, now at
  `/definition`; before 1.0 anything may break): every group, sorted by key, rendered by the
  same code as `nerva view` (`declared.render`, shared), so the answer, and `hash`, the SHA-256
  of its `groups` JSON, are `nerva view`'s byte for byte. `view_hash` (the replicated hash, N52)
  and `declared_op` come with it. `as_of` and `min_op` mean what they mean in `nerva view`, and
  an op not yet committed answers 504 as there; a view still building or failed answers 503
  rather than part of an answer. `GET /v1/views` lists the views the state machine maintains;
  the `get_view` header now carries the view's name in `group_key` for it.
- **One op.** The gateway reads the first page at the latest op (or `as_of`), and every later
  page as of the first's op, so a whole answer is one op's even while writes go on. More than
  10,000 groups is refused (400): such a view is read in pages from `/groups`.
- **Reads as of an op scan only what changed.** `Group.op` (from `reserved`) is the last op that
  changed a group. A read as of `a` takes a group whose `op <= a` as it stands, and scans for the
  version of the others. A page as of an op ends before the group that would take more than 128
  scans (`view_as_of_scans_max`; fewer with tests' small messages, so that pages end early), not
  at 128 groups as in N62: a whole canvas (4,096 groups) as of an op costs 4 pages, and scans
  only the pixels painted since.
- **Demos.** The seat and canvas demos read their views from `nerva api`; the agreement panel
  compares its hash with a `nerva view` process's at the same op ("maintained" and
  "recomputed").
- **Tests.** `tests/views/maintained.py` compares `GET /v1/views/<name>` with `nerva view`, byte
  for byte, at every op it checks, latest and as of past ops; and checks 504 for `min_op` and
  `as_of` past the log, 400 for both together, 404 before the declaration, `/definition`, the
  listing, and the refusal past 10,000 groups. The randomized state machine test reads pages of
  3 groups with 1 scan each, so pages end early. Mutation-tested: skipping the scan for a group
  changed after `as_of`, and resuming the next page one group late, each fail it.
- **Found.** The canvas test fails about three runs in four on `main` since N62, before this
  change: a replica killed while another syncs stalls the cluster past `nerva view`'s 30 s
  client timeout, and the process then exits (#42; #49 carries the fix). N62's heavier commits
  for the canvas's per-pixel `max` view make such stalls longer.

**N67. A client may not send `pulse`.**
`Operation.pulse` (134, N52) is the replica's own backfill operation: the replica sends it to
itself as `vsr.Operation.pulse` with `client == 0`, and `Request.invalid_header` refuses that
from a client. But a client could send the raw value 134: `vsr.Operation.valid` accepts it (it
is in Nerva's enum), `from_vsr` maps it to `.pulse`, and `input_valid` accepts the empty body,
and the replicas then crash executing it: the trace event's operation conversion
(`trace/event.zig`) has no value 134 (`panic: invalid enum value`). Restarted replicas replay the
committed prepare and crash again, so one request from any client that can reach the replicas
took the cluster down for good (#33; measured at `825355c`). The replica's
own pulse passes through the same `on_request` and `input_valid`, so the state machine cannot
tell the two apart. A vendored check in `on_request`, beside the operation check, evicts a
client (`invalid_request_operation`) whose request maps to the state machine's pulse operation
without being `vsr.Operation.pulse` itself; the predicate is Nerva's
(`internal_operations.pulse_from_client`), generic over the state machine, and unit-tested for
every operation. Upstream TigerBeetle maps its own pulse the same way. The guard cannot repair a
cluster whose log already holds a client's 134. End to end (once, with #53's client fix, since
an eviction used to abort the client): the client gets `error.Evicted` and the cluster commits
on; without the guard, as above.

**N68. CI does not run for a change to Markdown alone.**

A push or pull request whose every changed file is Markdown (the README, WORKLOG, DECISIONS,
CHANGELOG, docs/) starts no CI run: `ci.yml` has `paths-ignore: ['**.md']` on both. No code or
test reads a Markdown file, so such a run could only repeat the last result, in nine jobs for
about five minutes. No check is required on `main` (the repository's plan has no branch
protection), so a run that never starts blocks no merge. A release still runs CI first:
`release.yml` calls `ci.yml`, and a call is not filtered by paths. If a test ever reads a
Markdown file, it must be added back to the filter.

**N69. A `nerva api` request may allocate at most 128 MiB, and is given back when it answers.**
Request bodies are parsed into `std.json.Value` in a per-request arena, which costs many times
the body for nested or long arrays, and the arena was reset with `.retain_capacity`, so one
4 MiB body pinned its peak for the gateway's life (#31; measured at `825355c`: 91 to 788 MiB for
nested arrays, 527 MiB for a long one). A request now allocates through `MemoryBudget`
(`src/nerva/api/memory_budget.zig`), over the arena: it counts the bytes the request asks for,
refuses an allocation past 128 MiB, and records it, so the gateway answers
`413 {"error":"request too complex"}` instead of 500 and serves on. The arena is reset as soon as
the reply is written (`respond` writes it before returning), keeping at most 8 MiB. A budget,
rather than limits on JSON depth or array length, bounds every shape of body at once.
- **Above the arena, not below** (#60). #57 first put the budget below the arena, at 64 MiB.
  But `ArenaAllocator` sizes each new block from the last one plus the request, so below it the
  budget counted several times what the request asked for: the largest valid request, a
  `documents/get` of 256 documents of 64 KiB, asks for about 100 MB (rows, chunks, values, hex
  reply) yet counted 330 MiB, and was refused. Above the arena the budget counts requests, and
  128 MiB holds that `get`. The cost is that the memory the arena touches can reach two to three
  times the budget for a moment (about 290 MiB for the nested-array body, from 788 MiB), and it
  is given back at once. The `get` reply is also sized up front, so it is not copied as it grows.
Tests: unit tests of the budget (refusal, frees, a request over an arena failing on nested JSON,
then the next fitting); `test:api` sends both bodies (413) and checks the gateway's RSS returns
within 100 MiB of where it was (93 MiB, then 101 MiB), and that the largest valid
`documents/get` answers 200.

**N70. An evicted client is deinit'ed by `Client.deinit`, not by its eviction callback.**
The vendored VSR client asks its eviction callback to deinit it, but calls the callback from
inside the message bus's receive path, which then invalidates the receive buffer that `deinit`
has just freed. Every eviction aborted the process (#52): `nerva api`, `nerva view` and Zig
clients, whatever the reason (`no_session` after `clients_max` newer sessions, a release too
low, an invalid operation such as #33's raw `pulse`). Nerva's `Client.on_eviction` now only
records the eviction; `Client.deinit` (and so `reconnect`) deinits the VSR client. In between,
nothing drives the client's IO, since every call returns `error.Evicted`, so the evicted VSR
client processes no message. No vendored file changes. Test: `test:integration` ends by
restarting replica 0 (down since the failover step, which makes registrations slow) and pushing
a client's session out with `clients_max` newer ones; its next two requests get
`error.Evicted` (before: the process aborted on an assertion in `MessageBuffer.invalidate`).

**N71. `--trace` writes through a buffered, bounded writer that never fails.**
The vendored tracer writes each span with one `write(2)` on the replica's thread and panics if
it fails, and nothing bounded the file: with `--trace` (N50), a full trace disk killed the
replica, and the trace grew with the request rate (#30; measured at `03b3c93` with the trace on a
1 MiB tmpfs: `panic: Tracer.start: error.NoSpaceLeft` after 283 lookups). Rather than patch the
vendored tracer, Nerva hands it a writer that cannot fail (`src/nerva/trace_file.zig`): it
buffers spans and writes them 64 KiB at a time; on a write error, or once the file would pass
`--trace-size-max` (new, default 1 GiB, refused without `--trace`), it logs once
(`warning(trace_file): tracing stopped: …`) and drops what follows. `nerva start` flushes it on
exit. Up to 64 KiB of spans are lost if the replica crashes, an acceptable cost for a diagnostic
flag. Tests: unit (buffering, a failing writer, the size limit); `test:api` runs a replica with
`--trace-size-max=64KiB` under load (stopped at 65,503 bytes, still serving). Measured once on a
1 MiB tmpfs: the replica logs the stop and served 54,915 lookups in the time `main`'s panicked.

**N72. A transaction too large for any op gets `views_too_large` (413), not `views_busy`.**
`views_busy` (N52) said "retry in a later op", but a transaction whose own distinct view groups
(or `min`/`max` members, N62) exceed the per-op budget fits in no op, and every retry got the
same answer (#32). Nerva's clients send one transaction per request, so for them every
`views_busy` was this case. Admission (`view_txn_admit`) now returns `views.Admission`: `fits`,
`busy`, or `too_large`, which is decided when the budget runs out: if every group (or member)
the op has counted is this transaction's own, it would fill any op alone. A transaction that
shares keys with earlier ones of the request and is also too large alone gets `busy` first, then
`too_large` when retried alone. New status `views_too_large = 15`, appended (persisted values
keep their numbers; the format snapshot gains that line). `nerva api` answers `413
{"status":"views_too_large","index":…}`; `views_busy` stays 503. The VOPR workload models the same
rule. Tests: the unit test's transaction of `limit + 1` new groups now expects `views_too_large`,
and the request whose third transaction overflows only with the first two expects `views_busy`
and then commits alone; `test:views` sends 4,200 new groups (413) and the same rows split in two
(200 each).

**N73. The op's `min`/`max` scratch holds two keys per member.**
`extremes_gather` gives each touched member up to two (group, slot) keys: the group it left, when
it held that group's value as stored, and the group it entered. `extremes_scratch` was sized for
one per member, so one admitted transaction moving the holders of many groups' values to new
groups (about 1,640 rows, each alone in its group, under four slots) overflowed it: every replica
panicked (`integer overflow` in `getOrPutAssumeCapacity`), and again replaying the op after a
restart (#62; reproduced at `8c206f2`, found by the 0.0.4 hardening pass). It is now sized for
`2 * members_limit`, the most admission lets an op reach. Other scratch structures were checked
against admission and are sized right. Tests: a state-machine test moves every holder the op's
member limit admits to new groups in one transaction (it panicked; it now commits and every new
group holds its row's values); at production limits, 2,047 rows moved in one transaction commit
and the replica serves on.

**N74. On `main`, the VOPR runs in ReleaseSafe on about 300 seeds; pull requests keep Debug.**
CI ran the VOPR on seeds 1, 2, 5 and one random seed in Debug on every push and pull request
(N32): 40 s to 2m01 a seed (N57). ReleaseSafe runs the same seed 10 to 40 times faster (measured
locally, one core: seed 1 in 8 s, 2 in 1 s, 5 in 3 s; `fuzz_loop.sh` searched 25 random seeds
in 2 minutes) with the same checks, since the simulator always builds with `config_verify`
(`vopr.zig`). Owner's decision: pull requests keep the Debug matrix as it was; everything else
(pushes to `main`, the run `release.yml` calls, a dispatch) runs `vopr_main` instead, five
jobs: seeds 1, 2 and 5 in ReleaseSafe, and four lanes of `fuzz_loop.sh vopr nerva 6`, each
searching fresh random seeds for 6 minutes, as the long fuzzing does (N59), about 300 seeds a
push in all. A lane stops at its first failing seed and prints the command that replays it
(`./zig/zig build -Drelease vopr -- <seed>`). The jobs fit inside the run's critical path, the
`demo` jobs, about 6 minutes after their build (N57), plus the ReleaseSafe build (about 2
minutes locally). A run on `main` takes 11 Machines instead of 10, of the org's 30. This is a
step towards TigerBeetle's continuous fuzzing on dedicated machines; the always-on fleet
(Hetzner, the owner's choice) is a later decision.

**N75. Declared ledgers: conserved fields that only pairs of adds change.**
The owner's spec (NV-1, design approved before implementation). Adds (N42) conserve value only
when the client pairs them correctly and picks the right bounds; a ledger of record must refuse
a bad move whoever sends it, as TigerBeetle refuses an unbalanced or overdrawing transfer. A
**ledger** is an immutable declaration of 2 to 16 conserved `i64` fields (`(table, offset)`),
each with an optional floor. Generic: a ledger could conserve seats or stock as well as money.
- **A core operation, not a catalog document.** `declare_ledger` (`reserved + 7`) and
  `get_ledger` (`reserved + 8`, which serves `GET /v1/ledgers/<id>`: the gateway keeps no state,
  so reading a ledger needs an operation of its own). The layout catalog is rows any client can
  put or delete, so a declaration kept there could be deleted and the balances overwritten after
  it; and the core does not read layouts (N34). Ledgers live in their own groove, `ledgers`,
  with tree ids 16 (`timestamp`) and 17 (`slot`), keyed by a dense `slot` (1..64, in declaration
  order) so that every op can prefetch them all, as views are (N52); the client's `id` is inside
  the definition. No table id reaches them. They are loaded at prefetch like views, and indexed
  in memory (`ledgers.Index`: the conserved fields sorted by `(table, offset)`, found by
  bisection); the index only grows, since ledgers are immutable, and is rebuilt after a reset.
  `Ledger` is 512 bytes: grooves need a power of two.
- **Declaration rules.** `DeclareLedgerStatus`: `created` 1, `exists` 2 (the same definition
  again; it names the op it was declared at), `ledger_immutable` 3, `ledger_field_taken` 4 (a
  field already in another ledger), `invalid` 5, `table_invalid` 6, `ledgers_full` 7, and
  `field_viewed` 8 (a view the state machine maintains filters or groups by a field). Fields
  must be strictly ascending by `(table, offset)` (assumed): one canonical form per set of
  fields, so that "identical" is byte equality and duplicates are refused; `nerva api` sorts
  them. Offsets are 8-aligned and at most 72; a floor's bytes are zero without its flag. At most
  64 ledgers, 16 fields each. A ledger may be declared over rows that already exist: its total is
  then whatever it was at that op (Nerva has no scans to check).
- **Pairs** (`AddFlags.pair`, from its padding). An add is conserved when its `(table, offset)`
  is a ledger's field. A first half (`pair`) at `i` needs its partner at `i + 1`: a conserved add
  of the same ledger whose `delta_from` is `i`, without `pair`, `clamp`, `min` or `max`, and not
  on the same field of the same row. Anything else is `unpaired` (`EntryStatus` 16): a conserved
  add outside a pair, another add naming a first half, and (assumed) `pair` on an add outside
  every ledger. The index is the first half's when its partner is missing, the partner's when it
  breaks a rule. Checked in `commit_failure` after the per-entry checks and before
  `write_duplicate`, from the entries and the ledgers alone.
- **Floors.** `nerva.ledger_bounds(add, floor)` raises a conserved add's `min` to its field's
  floor (pure, shared by the state machine, the VOPR model and the fuzzer; `add_amount` is
  unchanged). The first half may clamp there; the partner never does, so a partner its floor or
  the `i64` range stops fails the transaction `out_of_bounds`. A field below its floor moves back
  up freely.
- **Other writes** are `conserved_write` (`EntryStatus` 17): an add that overlaps a conserved
  field without matching it (an exact match that is not `i64` too, assumed), checked per entry
  in `commit_failure`; a put that changes a conserved field's bytes, or a delete of a row where
  one is not zero, checked in `adds_resolve` in entry order. An absent row is zeros. A put or
  delete is the only write to its row in its transaction (`write_duplicate`), so the stored row
  is what it changes. An add with `create` starts from zeros, and is allowed.
- **Views.** A maintained view may not filter or group by a conserved field (adds would move
  rows between groups and be refused `view_key_field`): `field_viewed` for a ledger declared
  after such a view, `DeclareStatus.ledger_field` (10) for a view declared after the ledger.
  `nerva api` now sends `declare_view` before writing the view's catalog document, after
  checking the catalog for a different declaration under the name as before, so a view refused
  over a ledger's field answers 409 and leaves no document (owner's choice). Only views the state
  machine maintains are checked (assumed): one it refused lives only in `nerva view`, which
  recomputes it on read, so adds never touch it.
- **The invariant**: for every ledger, the sum of its fields over all rows equals the sum at its
  declaration's op, and no field moves down past its floor.
- **Numbers.** The spec named `unpaired = 15` and `conserved_write = 16`; `views_too_large`
  took 15 first (N72), and persisted values are never renumbered, so they are 16 and 17. The
  release string stays `0.0.4`: it has not shipped.
- **Tests.** `state_machine_tests.zig`: pairs, every `unpaired` case, floors with and without
  `clamp` and own bounds, partners stopped by a floor or the `i64` range, a field below its floor,
  puts, deletes and straddling adds, declarations (identical, different, taken, invalid, full,
  reloaded after what a reset forgets, untouched by writes to every table id), views in both
  orders, and a sum view following pairs. VOPR (`workload.zig`): a ledger over 2 to 5 accounts
  and a source; moves (fund, reserve, post, void, clamped or not) and transactions that must not
  change it, after the ledger is known declared; the model mirrors the checks in the state
  machine's order, with the pair rules written apart from its scan; `check_ledger` asserts the
  invariant after every commit from the adds' results alone. `adds_fuzz.zig`: floors and the
  partner's arithmetic against the reference, and conservation. `tests/api/ledgers.py` (in
  `test:api`): fifty threads of clamped reservations through two gateways, a sum view answering
  the funded total, every refusal. The format guards gain the new types, statuses, operations
  and tree ids, and the fixed script a ledger, a clamped pair and a refused put. Mutation-tested:
  floors not applied, puts and deletes not checked, straddling adds not checked, each fail the
  unit tests and the VOPR; `ledger_bounds` taking the lower bound fails the fuzzer.

**N76. Documents hold up to 512 KiB, the most one commit writes atomically; larger values live
outside, by hash.**
Documents held at most 64 KiB (N39, N41), and applications storing model outputs, files or
program state needed more (#25). A document is written in one commit request, so atomicity caps
it: a request carries 8,190 entries in production, one per 80-byte chunk. `value_size_max` is
now 512 KiB: with the longest key that is 6,567 chunks, leaving over 1,600 entries for the rest
of the transaction (asserted at compile time against the production message size). Not larger:
a document split across requests would no longer be written atomically, and a design for that
(staged chunks, a commit record) is a 1.0-sized change. The chunk format and ids are unchanged, so
existing documents read as before; a client older than this change refuses a larger document as
corrupt, but v0.3.0 clients are refused by 0.0.4 clusters anyway (N62).
- **A `get` reads at most as many chunks as 256 documents of 64 KiB** (about 16 MiB of values),
  and answers `413` past that, before reading any tail chunk. Every `get` that answered before
  still does, and a reply stays inside the request's 128 MiB budget (N69): 256 documents of
  512 KiB would be 128 MiB of values alone.
- **Larger values**: the documented pattern is content-addressed blobs outside Nerva, with their
  hash in a document (README, TUTORIAL Part 8).
Tests: `tests/api/documents.py` writes a 512 KiB value under a 1024-byte key in one transaction
and reads it back, refuses one byte more, and checks the `get` cap at its edge (33 documents of
512 KiB answer 413, 32 answer 200); the documents fuzzer draws values up to the new limit.

