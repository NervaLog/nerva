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

