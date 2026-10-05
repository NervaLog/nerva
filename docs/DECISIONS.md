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

**N49. Views maintained by the state machine: groups and their hash are replicated state.**
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
  `view_key_field` and admission (`views_busy`) exactly, and checks a ready view never builds again;
  `tests/views/maintained.py` backfills 5,000 seats and compares each answer with `nerva view`
  at the same op, recomputing the hash in Python. Mutation-tested: groups that never lose rows
  fail the unit tests and the VOPR (seeds 1 and 13); rows past the cursor counted twice fail
  the backfill test; admission refusing one group early fails the VOPR (seed 3).
