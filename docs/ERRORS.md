# Error codes

Every failure a client, an operator or a script can see has a stable code, registered here once
(P147c). This follows Zigbox's diagnostics standard (`Zigbox/zigbox`, `DIAGNOSTICS.md`): a code,
a one-line summary, who is to blame, the cause and a fix. Codes are never reused or renumbered.

**Status, 2026-11-05: commands emit their codes; the wire does not yet.**
- **On the wire:** replies still carry only the identifiers and texts in the "Today" column. Codes
  reach `nerva api` replies in R4, as a `code` member beside today's `status` or `error`, never in
  their place.
- **In commands:** every `nerva` command failure that Nerva's code reports prints
  `error[NRV-E…]` (or `bug[NRV-B…]`), then a `cause` line (the code's summary) and a `fix` line
  (R5, `src/nerva/diagnostic.zig`; a unit test keeps its table equal to this file). Exit statuses:
  1 the operator's input, 2 the environment (disk, kernel, file system), 70 Nerva's bug (P149e);
  `nerva start`'s runtime exits (2 to 8) keep their statuses. Still uncoded, and R5's later
  slices: the vendored flag parser's own errors (NRV-E0001, `error: …`), and the
  runtime exits of 07xx (E0707 to E0709, E0711).
- **Until the wire has them,** this file maps today's texts to codes, so a client can match on a
  code's identifier now and on the code later.

## Format

- **Code:** `NRV-<kind><4 digits>`. The kind is `E` (error), `W` (warning, the operation went
  ahead) or `B` (a bug in Nerva).
- **Number ranges, by subsystem:**

  | Range | Subsystem |
  | --- | --- |
  | `00xx` | commands and flags |
  | `01xx` | the gateway: transport, keys, routes, requests |
  | `02xx` | commit results |
  | `03xx` | declarations |
  | `04xx` | reads |
  | `05xx` | documents |
  | `06xx` | the cluster and sessions |
  | `07xx` | replicas and data files |
  | `08xx` | export and import |
  | `09xx` | keys between replicas |
  | `10xx` | `nerva view` |

- **Blame:**
  - `client`: the request was wrong; fix it, do not retry it.
  - `retry`: the request was right; send it again, under its commit key.
  - `operator`: a flag, a file or the environment.
  - `internal`: Nerva's bug.

  A code with blame `retry` is the only one a client may resend unchanged.
- **One code covers a family of texts** where they share a cause and a fix, for example every
  malformed field in a commit entry. The text names the exact field, and the code names the kind
  of failure.
- **A wire identifier stays.** `conflict`, `out_of_bounds` and the rest keep their spelling. A
  code is added beside them.

## 00xx · Commands and flags

| Code | Summary | Today | Blame | Fix |
| --- | --- | --- | --- | --- |
| NRV-E0001 | A command or flag is unknown, repeated or malformed | `error: unknown subcommand …`, `<flag>: duplicate argument`, `unexpected argument …` (stdx/flags.zig, vendored: printed as `error: …` without the code, exit 1); `error[NRV-E0001]: export: --as-of must be …`, `--output must name a file`, `--input must name a file` | operator | `nerva --help` |
| NRV-E0002 | A flag's value is out of range | `error[NRV-E0002]: <command>: --replica-count must be …`, `--cache-grid …`, `--cache-rows …`, `--commit-stall-probability …`, `--statsd …`, `--trace …`, exit 1 | operator | The message names the bound |
| NRV-E0003 | `--listen` is not an address | `error[NRV-E0003]: api: --listen must be <ipv4>:<port> or [<ipv6>]:<port>`, same for `view`, exit 1 | operator | Give `host:port`, IPv6 in brackets |
| NRV-E0004 | An output file already exists | `error[NRV-E0004]: start: --trace <p> exists`, `export: <out> exists`, `import: <path> exists`, exit 1 | operator | Give a new path; Nerva never overwrites |
| NRV-E0005 | A data file already exists at `format`'s path | `error[NRV-E0005]: format: <path> exists`, exit 1 (`format`; `import` says E0004 for its path) | operator | Choose another path, or remove the old file if it is really unwanted |
| NRV-E0006 | A data file is missing at `start`'s path | `error[NRV-E0006]: start: <path> does not exist`, exit 1 (pre-flight, before the vendored open, which panics `Path does not exist.`) | operator | Run `nerva format` first, or fix the path |
| NRV-E0007 | A replica, gateway or view server cannot listen | `error[NRV-E0007]: <command>: cannot listen: <reason>`, exit 1 | operator | The port is taken or not allowed, or the host has no socket for that address |
| NRV-E0008 | `NERVA_KEY` is missing or invalid | `error[NRV-E0008]: api: set NERVA_KEY`, `NERVA_KEY_NEXT is set but empty`, `… equals NERVA_KEY` (http_connection.zig:147-150), exit 1 | operator | Set it; `_NEXT` differs from it during a rotation |

## 01xx · The gateway: transport, keys, routes, requests

| Code | Summary | Today | Blame | Fix |
| --- | --- | --- | --- | --- |
| NRV-E0101 | The request is not valid HTTP | 400 `malformed request`, `request head too large`; then the connection closes | client | Send HTTP/1.1, one request per connection |
| NRV-E0102 | The body is larger than 4 MiB | 400 `body too large` (a 413 in R4) | client | Split the request |
| NRV-E0103 | The key is missing or wrong | 401 `invalid key` | client | Send `X-Nerva-Key` |
| NRV-E0104 | No such route, or not with this method | 404 `not found`, 405 `method not allowed` | client | See README, "JSON API" |
| NRV-E0105 | The JSON is malformed, or has an unknown or missing member | 400 `malformed JSON`, `unknown field`, `missing field`, `unexpected body` | client | Send exactly the members the route documents |
| NRV-E0106 | A number is not a decimal string, or is out of range | 400 `<name> must be a decimal string`, `<name> is out of range` | client | 64-bit numbers travel as decimal strings |
| NRV-E0107 | The query string is malformed | 400 `malformed query`, `unknown query parameter`, `repeated query parameter`, `unexpected query`, `<p> is required`, `<p> must be positive` | client | The message names the parameter |
| NRV-E0108 | A table number is missing, zero, reserved or out of range | 400 `table is required`, `table must not be zero`, `table is reserved`, `table is out of range` | client | Use a table the application declared |
| NRV-E0109 | A hex value or id has the wrong length or is not hex | 400 `value_hex must be at most 80 bytes of hex`, `a record's id is 16 bytes of hex`, `… is not hex`, `key must be 16 bytes of hex`, `key must not be zero` | client | Rows are 80 bytes, records 448, record ids and keys 16 |
| NRV-E0110 | A commit entry is malformed | 400 with `"index"`: `entries must not be empty`, `a put needs value_hex or fields`, `an add has delta or delta_from, not both`, `delta_from must be the index of an earlier add`, `min must not exceed max` and the rest (api.zig:912-1234) | client | The message names the member; the index names the entry |
| NRV-E0111 | A lookup is malformed | 400 `rows must not be empty`, `a lookup reads rows or records, not both: send two` | client | As the message says |
| NRV-E0112 | Too many rows or entries for one request | 400 `too many rows or entries for one request` | client | Split it: 8,189 entries per commit |
| NRV-E0113 | The request needs more memory than one request may use | 413 `request too complex` (128 MiB, N69) | client | Fewer or smaller entries |
| NRV-E0114 | A field needs a layout, or names no field of it | 400 `fields need a layout for the table (PUT /v1/tables/<t>)`, `no such field`, `an add's field must be u64 or i64` | client | Declare the layout first |
| NRV-E0115 | A field value does not fit its type | 400 `a bool field takes true or false`, `a bytes field takes at most its size in hex`, `a number is out of range` and the rest (catalog.zig) | client | As the message says |

## 02xx · Commit results

These are the replies to `POST /v1/commit`. The identifier is the state machine's `EntryStatus`
(nerva.zig:256); the HTTP mapping is api.zig:1030-1120.

| Code | Summary | Today | Blame | Fix |
| --- | --- | --- | --- | --- |
| NRV-W0201 | The key committed earlier; this is its answer | 200 `{"status":"committed","replayed":true,"op":…}` | — | None: this is the success of a resend |
| NRV-E0202 | A read saw an old version | 409 `conflict`, with `index` and the newer `op` | client | Read again, then decide again |
| NRV-E0203 | An add would cross its bound | 409 `out_of_bounds`, with `index` and the current `value` | client | Ask for less, or send `clamp` |
| NRV-E0204 | An add names a row that does not exist | 409 `row_absent` | client | Send `create`, or put the row first |
| NRV-E0205 | A conserved field changed other than by a pair | 409 `unpaired`, `conserved_write` | client | Move money only as a pair of adds (README, "Ledgers") |
| NRV-E0206 | An add changes a field a view filters or groups by | 409 `view_key_field` | client | Change that field with a put |
| NRV-E0207 | The key was used for a different transaction | 409 `key_reused` | client | A key names one transaction. A new transaction needs a new key |
| NRV-E0208 | Two keys share their 64-bit hash | 409 `key_collision` | client | Choose a new key (about 3 in 10,000 among 10^8 keys) |
| NRV-E0209 | Two record ids share their 64-bit hash | 409 `id_collision` | client | Choose a new record id |
| NRV-E0210 | A transaction writes one row twice | 400 `a transaction writes a row at most once (adds aside)` | client | Merge the writes |
| NRV-E0211 | Views have no room in this op | 503 `views_busy` | retry | Resend under the same key |
| NRV-E0212 | The transaction alone touches too many view groups | 413 `views_too_large` | client | Split the transaction |

## 03xx · Declarations

| Code | Summary | Today | Blame | Fix |
| --- | --- | --- | --- | --- |
| NRV-E0301 | A layout is malformed | 400 `the layout name must be 1 to 64 bytes`, `a layout has at most 16 fields`, `the fields do not fit in 80 bytes, or 448 in a record` and the rest (catalog.zig:98-235) | client | As the message says |
| NRV-E0302 | A layout may only grow by appending fields | 409 `a layout may only be extended by appending fields` | client | Append; never change a field |
| NRV-E0303 | No layout for this table | 404 `no layout for this table` | client | `PUT /v1/tables/<t>` |
| NRV-E0304 | A ledger declaration is malformed | 400 `a ledger has 2 to 16 fields`, `a ledger's fields must be i64` and the rest | client | As the message says |
| NRV-E0305 | A ledger is declared differently, or its field is taken | 409 `ledger_immutable`, `ledger_field_taken`, `field_viewed` | client | Ledgers are immutable; a field belongs to one ledger and no view |
| NRV-E0306 | The cluster holds 64 ledgers already | 409 `ledgers_full` | client | Raise it in a release, or reuse a ledger |
| NRV-E0307 | A view declaration is malformed | 400 `a view has at most 4 where clauses`, `a view groups by at most 3 fields` and the rest (catalog.zig:299-377) | client | As the message says |
| NRV-E0308 | A view with this name is declared differently | 409 `a view with this name is declared differently; views are immutable` | client | Choose a new name |
| NRV-E0309 | A view filters or groups by a ledger's field | 409 `the view filters or groups by a field of a ledger` | client | Read a ledger's sums from the ledger |
| NRV-W0310 | The view is declared but not maintained by the replicas | 200 `{"maintained":false,"reason":…}`: views full, extremes full, `min and max are not maintained over records` | client | Read it from `nerva view`, or free a slot |
| NRV-E0311 | An index declaration is malformed | 400 `an index has at most 3 eq fields`, `the index breaks a rule (an eq key is at most 64 bytes)` and the rest | client | As the message says |
| NRV-E0312 | An index is declared differently, or there is no room | 409 `different`, `indexes_full`, `table_indexes_full` | client | Choose a new name; 64 indexes, 4 per table |

## 04xx · Reads

| Code | Summary | Today | Blame | Fix |
| --- | --- | --- | --- | --- |
| NRV-E0401 | The op asked for is not committed yet | `as_of is not yet committed`, `min_op is not yet committed`: **504** on `/v1/views/<n>`, **400** on `/v1/views/<n>/groups`, `/v1/row` and documents | retry | Wait and ask again. R4 makes it one status |
| NRV-E0402 | No such view, index or ledger | 404 `no such view`, `no such index`, `no such ledger` | client | Declare it first |
| NRV-E0403 | The view was declared after the op asked for | 404 `the view was declared after as_of` | client | Ask as of a later op |
| NRV-E0404 | The view or index is still building | 503 `the view is still building`, `index building` | retry | Ask again once built |
| NRV-E0405 | The view failed: a group hash collided | 503 `the view failed (a hash collision)` | operator | Declare it again under a new name |
| NRV-E0406 | The view is not maintained by the replicas | 404 `this view is not maintained by the state machine` | client | Read it from `nerva view` |
| NRV-E0407 | The view has more groups than one answer holds | 400 `… read it from /groups` | client | Page through `/groups` |
| NRV-E0408 | A cursor is not one Nerva gave | 400 `invalid cursor`, `after is malformed` | client | Use the cursor from the last reply |
| NRV-E0409 | An index scan is malformed | 400 `eq names every eq field`, `min is above max`, `the scan is malformed` and the rest | client | As the message says |
| NRV-E0410 | `min_op` and `as_of` together | 400 `min_op or as_of, not both` | client | One of them |

## 05xx · Documents

| Code | Summary | Today | Blame | Fix |
| --- | --- | --- | --- | --- |
| NRV-E0501 | A document key or value is malformed | 400 `a key is at most 1024 bytes`, `a key must be UTF-8`, `a value is at most 512 KiB` and the rest | client | As the message says |
| NRV-E0502 | A document request repeats or omits keys | 400 `keys must not be empty`, `repeated key`, `too many keys for one request`, `a commit writes a key at most once` | client | As the message says |
| NRV-E0503 | A document read saw an old version | 409 `{"status":"conflict","key":…,"version":…}` | client | Read again, then decide again |
| NRV-E0504 | Too many documents for one get | 413 `documents too large for one get: ask for fewer keys` | client | Ask for fewer keys |

## 06xx · The cluster and sessions

| Code | Summary | Today | Blame | Fix |
| --- | --- | --- | --- | --- |
| NRV-E0601 | The cluster did not answer; the outcome is unknown | 503 `cluster unavailable` (also after eviction or a 30 s timeout) | retry | Resend under the same commit key: it commits at most once. Without a key, read before you write again |
| NRV-E0602 | The gateway closed a request it could not take | Today the connection closes with no reply, or a 503 like NRV-E0601 (#120) | retry | R4 makes this `"applied": false` |
| NRV-E0603 | A client's session was evicted by a newer one | Zig client `error.Evicted`; behind the gateway, NRV-E0601 | retry | Fewer clients than 64 sessions |
| NRV-E0604 | A gateway or view server could not reach the cluster | `error[NRV-E0604]: api: no reply from the cluster` after the client's 30 s registration timeout, exit 1 (R5 slice 1) | operator | Check `--cluster` and `--addresses`, and that a quorum of replicas is running |

## 07xx · Replicas and data files

| Code | Summary | Today | Blame | Fix |
| --- | --- | --- | --- | --- |
| NRV-E0701 | The data file was written by another release | `error[NRV-E0701]: start: <path> was written by release X, and this is release Y`, exit 1; nothing is written (pre-flight; closes #95, which was a panic `multiversion unsupported`) | operator | Upgrade by export and import (README, "Upgrading a cluster") |
| NRV-E0702 | The data file is not a Nerva data file, or is damaged | `error[NRV-E0702]: start: <path> has no usable superblock (<NotFound\|QuorumLost\|…>)`, exit 1; also a path that is not a file (pre-flight, with the vendored `Quorums` on the file's copies) | operator | Check the path; restore from a backup; see R5 |
| NRV-E0703 | Another process holds the data file | `error[NRV-E0703]: start: another process holds <path>`, exit 1 (pre-flight: `flock` taken and dropped, retried for 250 ms as the vendored open does) | operator | Stop the other replica |
| NRV-E0704 | The file system cannot do direct IO | `error[NRV-E0704]: start: the file system of <path> does not support direct IO`, exit 2 (pre-flight; `--development` allows it) | operator | Put the data file on ext4 or XFS |
| NRV-E0705 | The kernel is older than 5.11 | `error[NRV-E0705]: <command>: the kernel is X.Y; Nerva needs 5.11 or newer`, exit 2 (pre-flight, `format`, `start` and `import`) | operator | Upgrade the kernel |
| NRV-E0706 | The disk is full | Exit 2, `write failed: no space left on device`; commands that write a file (`export`, `import`) print `error[NRV-E0706]`, exit 2 | operator | Free space or grow the volume |
| NRV-E0707 | The data file outgrew its limit | Exit 4 or 5; the message names NRV-E0707 and no longer a `--limit-storage` flag that Nerva does not have (vendored text patch, UPSTREAM.md) | operator | None to raise the limit in this release; the message now says so. The limit is the build's `storage_size_limit_default`; export and import do not change it |
| NRV-E0708 | The disk failed a read, a write or an fsync | Today a panic: `latent sector error`, `fsync failure`; `export` and `import` print `error[NRV-E0708]` for an I/O error on their files, exit 2 | operator | Replace the disk, then the replica (R5) |
| NRV-E0709 | A replica's WAL is damaged | Today a raw `error: WALInvalid` or `WALCorrupt` | operator | Replace the replica (R5) |
| NRV-E0710 | Not every replica address was given | `error[NRV-E0710]: start: all --addresses must be provided`, exit 1 | operator | Give all of them, in replica order |
| NRV-E0711 | This replica was imported from another export than its peers | Exit 8, `origin_mismatch`: `this replica was imported from export <A>, but <n> of the cluster's <m> replicas announce another` (replica.zig, P90) | operator | Import it again from the cluster's export, or `nerva recover` it with `--origin=` the export its peers announce |
| NRV-E0712 | `nerva recover`: the other replicas did not commit its requests; they have no quorum | `error[NRV-E0712]`, exit 1: `only <n> of the other <m> replicas answer` at once, or `did not commit recover's requests within 60 seconds` (`recover.zig`) | operator | Bring back enough of the other replicas first; with fewer, restore from a backup |
| NRV-E0713 | `nerva recover`: the replica it would replace still answers at its address | `error[NRV-E0713]`, exit 1: `replica <i> still answers at <address>` (`recover.zig`) | operator | Stop that replica and destroy its data file, then recover again |
| NRV-E0714 | `nerva recover` needs a cluster of at least three replicas | `error[NRV-E0714]`, exit 1: `recover: --replica-count=<n> is too small` (`recover.zig`) | operator | Restore a smaller cluster from a backup |
| NRV-E0715 | An earlier `nerva recover` did not finish | `error[NRV-E0715]`, exit 1: `an earlier recover did not finish: <path>.recovering is left` (`recover.zig`) | operator | Remove `<path>.recovering`, then recover again |
| NRV-E0716 | `nerva recover`'s session was evicted before it finished | `error[NRV-E0716]`, exit 1: `the cluster evicted this session before it finished` (`recover.zig`; no test triggers it) | retry | Run it again; fewer clients than 64 sessions |

## 08xx · Export and import

| Code | Summary | Today | Blame | Fix |
| --- | --- | --- | --- | --- |
| NRV-E0801 | The cluster did not answer the export | `error[NRV-E0801]: export: no reply from the cluster`, exit 1 | operator | As the message says |
| NRV-E0802 | `--as-of` is past the latest op | `error[NRV-E0802]: export: --as-of is past the cluster's latest op`, exit 1 | operator | Use `latest` or an earlier op |
| NRV-E0803 | The export would be refused by `nerva import` | `error[NRV-E0803]: export: `nerva import` would refuse this export: <first reason>`, also too many tables and records or an index that appeared during the export; exit 1 | operator | Fix what the message names first, then export again |
| NRV-E0804 | The file is not an export, or is damaged or truncated | `error[NRV-E0804]: import: <input>: not an export: the magic is wrong`, `the export is truncated`, `the SHA-256 does not match` and about 40 more (export_file.zig:370-761), exit 1 | operator | Use an intact export |
| NRV-E0805 | The export's version is not one this release imports | `error[NRV-E0805]: import: <input>: the export's version is not one this release reads`, exit 1 | operator | Import with a release that reads it |
| NRV-E0806 | An earlier import did not finish | `error[NRV-E0806]: import: <p>.importing is left from an import that did not finish`, exit 1 | operator | As the message says |
| NRV-E0807 | The imported data failed its checks | `error[NRV-E0807]: import: the export was refused: <first reason>` (and N more in the log above), exit 1 | operator | Read the log lines above the error |
| NRV-E0808 | A backup's manifest is missing, malformed, too large or of an unknown version | Not yet: R5 (`nerva restore`) | operator | Give the `.manifest.json` that `nerva backup` wrote beside the backup |
| NRV-E0809 | A backup does not match its manifest: size, SHA-256, op, version, a view hash or a ledger total | Not yet: R5 (`nerva restore`) | operator | Use the backup the manifest names, or another backup with its own manifest |
| NRV-E0810 | A file `export` or `import` was given cannot be opened, read or written | `error[NRV-E0810]: import: cannot use <path>: no such file or directory` and the like, exit 1 (R5 slice 1) | operator | Check the path and its permissions |

## 09xx · Keys between replicas

| Code | Summary | Today | Blame | Fix |
| --- | --- | --- | --- | --- |
| NRV-E0901 | `NERVA_CLUSTER_KEY` is missing, short, or wrongly paired with `_NEXT` | `error[NRV-E0901]: start: set NERVA_CLUSTER_KEY (at least 32 bytes)` and the rest (peer_auth.zig:45-94), exit 1 | operator | As the message says |
| NRV-E0902 | A peer proved a different cluster key | Logged by the replica; the peer is ignored | operator | Give every replica the same key |

## 10xx · `nerva view`

| Code | Summary | Today | Blame | Fix |
| --- | --- | --- | --- | --- |
| NRV-E1001 | The op asked for is not committed yet | 504 `the op is not committed yet` | retry | As NRV-E0401 |
| NRV-E1002 | The view does not match its table's layout | 409 `the view does not match its table's layout` | client | Declare the view again under a new name |
| NRV-W1003 | More changes than `nerva view` keeps; declared views stop here | Logged only (N35) | operator | Read views from the replicas (N52) |

## Bugs

| Code | Summary | Today | Fix |
| --- | --- | --- | --- |
| NRV-B0001 | The gateway hit an internal error | 500 `internal error`, the Zig error only logged (server.zig:116, 206); includes `error.Corrupt` from a missing layout or bad document chunks | Report it with the gateway's log line |
| NRV-B0002 | The gateway got a commit result it never expects | Today a panic of the gateway (api.zig:1051, 1116; documents_routes.zig) on `kind_invalid`, `field_invalid`, `key_invalid` and the rest: statuses the gateway's own checks should make impossible | Report it; R4 turns the panic into this reply |
| NRV-B0003 | A replica stopped on an unknown protocol command | Exit 7, `unknown VSR command, crashing for safety` (#111) | Report it |
| NRV-B0004 | A `nerva` command hit an error it did not expect | `bug[NRV-B0004]: <command> hit an error it did not expect`, exit 70; the Zig error name only on a `detail` line under `--log-debug` | Report it with the command's output under `--log-debug` |

## What the codes change, and when

| Milestone | Change |
| --- | --- |
| R4 | Every `nerva api` and `nerva view` error reply gains `"code"`. Body too large becomes 413. "Not yet committed" becomes one status (504) on every route. Gateway panics become NRV-B0002. |
| R5 | Every `nerva` command prints `error[NRV-E…]: <summary>` with a cause and a fix, never a raw Zig error name. The panics in 07xx become coded refusals (slice 2). The exit codes follow Zigbox's: 1 operator, 2 environment, 70 internal. |

**Tests:** each registered code gets a test that triggers it and checks its code and summary, and
a check fails any command output that contains a stack trace or a raw `error.Name`.
