# The JSON API

Every route of `nerva api` and `nerva view`, with its request, its reply, its statuses and the
codes it answers with. The README's [JSON API](../README.md#json-api) section is the tour; this page
is the reference.

> Every request and reply below was run against a candidate built from `main` at commit 4ddd232
> (`nerva version` printed `version 0.7.0`), one development replica, on 2026-11-10 (the review
> fixes of the same day re-ran the ones they changed). This is not a release. Replies are
> shortened with `…` only where a value is hex of 80 or 448 bytes. Anything not run is marked
> **not run**.

- [Conventions](#conventions)
- [Errors every route can answer](#errors-every-route-can-answer)
- [Health](#health)
- [Rows and records](#rows-and-records): lookup, commit, changes, history, row
- [Layouts](#layouts): tables
- [Declared views](#declared-views)
- [Ledgers](#ledgers)
- [Indexes](#indexes)
- [Documents](#documents)
- [nerva view](#nerva-view)

## Conventions

- **Transport.** HTTP/1.1, one request per connection, JSON bodies of at most 4 MiB. The gateway
  listens on loopback unless started with `--listen-remote` (NRV-E0009). It serves at most 16
  connections at once. A request must arrive whole within 10 s (`408`, NRV-E0116).
- **Key.** Every route but `GET /healthz` needs `X-Nerva-Key: <NERVA_KEY>`. During a rotation the
  gateway also takes `NERVA_KEY_NEXT`. A wrong or missing key is `401` NRV-E0103. The key is
  checked before the route: with no valid key, `GET`, `POST` and `PUT` get `401` even on a route
  that does not exist (`404`) or that does not take the method (`405`). Only a method that is none
  of the three (`DELETE`, `PATCH`, …) is answered `405` before the key is looked at.
- **Numbers.** 64-bit numbers (ids, ops, cursors, deltas, `u64` and `i64` fields) travel as
  decimal strings: `"op":"183"`. Table numbers, `u8` to `u32` fields and `limit` are JSON numbers.
- **Values.** A row is 80 bytes, sent and returned as `value_hex`. Tables from `2147483648`
  (`0x80000000`) up hold *records*: a 16-byte id as 32 hex digits, given back as sent, and a value of
  448 bytes. With a layout declared (`PUT /v1/tables/<table>`), a put may send `fields` instead of
  `value_hex`, and reads return `fields` beside it. Examples abbreviate 448-byte values.
- **Every reply that is not a success** carries `"error"` (or `"status"`), `"applied"` and
  `"code"`. `"applied": false` means nothing was written. `"applied": "unknown"` means a write was
  sent and no answer came back: resend it under the same commit key (see
  [`POST /v1/commit`](#post-v1commit)). Codes are in [ERRORS.md](ERRORS.md).
- **Commit keys.** A `key` of 32 hex digits (not all zero) makes a commit idempotent: the same
  key with the same entries answers `200` again with `"replayed": true` and NRV-W0201.
- **Pages.** `changes`, `history`, `groups` and `documents/changes` return a `cursor` to send back
  as `cursor`; a scan returns `next` to send back as `after`. `history`, `groups` and a scan end
  with `null`. The two feeds, `changes` and `documents/changes`, never do: on the last page
  (`"more": false`) the `cursor` is the place to resume from, and a follower that tails the feed
  keeps it and asks again later. Do not loop on `cursor != null` over a feed.
- **Reading at an op.** `as_of` and `min_op` name an op. An op not yet committed is `504`,
  NRV-E0401 (NRV-E1001 on `nerva view`): wait and ask again.

## Errors every route can answer

| Status | Code | Reply | Cause |
|---|---|---|---|
| 400 | NRV-E0101 | `malformed request` | Not HTTP/1.1, or a head too large |
| 400 | NRV-E0105 | `unknown field`, `malformed JSON`, `missing field` | The body has a member the route does not take, or lacks one |
| 400 | NRV-E0106 to E0115 | the message names the member | A number, hex value, query parameter, table or entry is malformed ([ERRORS.md](ERRORS.md#01xx--the-gateway-transport-keys-routes-requests)) |
| 401 | NRV-E0103 | `invalid key` | `X-Nerva-Key` is missing or wrong |
| 404 | NRV-E0104 | `not found` | No such route |
| 405 | NRV-E0104 | `method not allowed` | The route does not take this method |
| 408 | NRV-E0116 | `request not received within 10 s` | The client was too slow |
| 413 | NRV-E0102 | `body too large` | More than 4 MiB |
| 413 | NRV-E0113 | `request too complex` | The parsed request needs more than 128 MiB. `"applied"` is `"unknown"` if an earlier call of the request sent a write |
| 500 | NRV-B0001 | `internal error` | A bug. `"applied"` may be `"unknown"` (a write may have been sent): see [`applied: "unknown"`](TROUBLESHOOTING.md#applied-unknown), then report it |
| 503 | NRV-E0602 | `busy` | All 16 connections are in use and this one was not read |
| 503 | NRV-E0605 | `cluster unavailable`, `"applied": false` | The gateway has no cluster session now; nothing was sent |
| 503 | NRV-E0601 | `cluster unavailable` | The cluster did not answer. `"applied"` is `"unknown"` if a write was sent, `false` if not |
| 503 | NRV-E0606 | `request deadline passed` | `--request-timeout` was spent before the next cluster call. `"applied"` is `"unknown"` if an earlier call of the request sent a write |
| 504 | NRV-E0401 | `… is not yet committed` | `as_of` or `min_op` is ahead of the log |

Real replies:

```
GET /v1/commit            -> 405 {"error":"method not allowed","applied":false,"code":"NRV-E0104"}
GET /v1/nope              -> 404 {"error":"not found","applied":false,"code":"NRV-E0104"}
POST /v1/lookup {"rows":[{"table":1,"id":"5"}],"x":1}
                          -> 400 {"error":"unknown field","applied":false,"code":"NRV-E0105"}
POST /v1/lookup {"rows":[{"table":4294901761,"id":"5"}]}
                          -> 400 {"error":"table is reserved","applied":false,"code":"NRV-E0108"}
(wrong key)               -> 401 {"error":"invalid key","applied":false,"code":"NRV-E0103"}
POST /v1/commit, a 4,300,000-byte body
                          -> 413 {"error":"body too large","applied":false,"code":"NRV-E0102"}
```

`nerva view` answers `413` to any `POST` with a body, even `POST /v1/views/revenue {}` (run),
because it takes no body; the API gateway answers that request `405`.

When the gateway cannot reach the cluster, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md#a-503).

## Health

### `GET /healthz`

No key. `200 {"ok":true,"session":"ready"}` when the gateway has a cluster session. Otherwise
`503 {"ok":false,"error":"cluster unavailable","applied":false,"code":"NRV-E0605","session":"reconnecting"}`.
The gateway reconnects by itself, trying at most every 5 s. Served by `nerva view` too.

## Rows and records

### `POST /v1/lookup`

Point reads. Request: `{"rows":[{"table":<n>,"id":"<id>"}, …]}`. Rows or records, not both in one
request (NRV-E0111).

Reply: `{"op":"<op read at>","rows":[{"table","id","exists","op","value_hex"[,"fields"]}, …]}`.
A row that does not exist has `"exists":false`, `"op":"0"` and a zero value.

Statuses: 200; 400 (NRV-E0105, E0108, E0109, E0111).

```
POST /v1/lookup {"rows":[{"table":7,"id":"1"},{"table":7,"id":"2"}]}
-> 200 {"op":"184","rows":[{"table":7,"id":"1","exists":true,"op":"183","value_hex":"6400…00","fields":{"available":"100","held":"0"}},{"table":7,"id":"2","exists":false,"op":"0","value_hex":"0000…00"}]}
POST /v1/lookup {"rows":[]}
-> 400 {"error":"rows must not be empty","applied":false,"code":"NRV-E0111"}
```

### `POST /v1/commit`

One transaction. Request: `{"key"?:"<32 hex>","entries":[…]}`. Entries, applied together or not
at all:

| `kind` | Members | Does |
|---|---|---|
| `read` | `table`, `id`, `op_seen` | Fails the transaction (`conflict`) if the row changed after `op_seen` |
| `put` | `table`, `id`, `value_hex` or `fields` | Replaces the whole row. With `fields`, a field the put does not name becomes zero |
| `delete` | `table`, `id` | Deletes the row |
| `add` | `table`, `id`, `field` (or `offset` and `type`: `u64` or `i64`), `delta` or `delta_from` | Adds to a field atomically. Optional `min`, `max`, `clamp`, `create`, `pair` |

A `put` with `fields` is not an update of those fields: the row is rebuilt from what the put
names. To change one field, send an `add`, or `read` the row, keep its `op`, and `put` every field
with a `read` entry at that `op_seen`. A row with a [ledger](#ledgers) field cannot be `put` or
`delete`d at all (`conserved_write`, below).

`delta_from` is the index of an earlier add whose applied amount is moved the other way (a pair,
see README, [Ledgers](../README.md#ledgers)). A transaction writes a row at most once, adds aside
(NRV-E0210).

Reply `200`: `{"status":"committed","op":"<op>"[,"adds":[{"index","applied","value"}]][,"replayed":true,"code":"NRV-W0201"]}`.
`adds` gives, for each add, the amount applied and the field's new value. A replayed reply has no
`adds` (see below).

Refusals are `409` with a `status` and `"applied": false`:

| `status` | Code | Meaning |
|---|---|---|
| `conflict` | NRV-E0202 | A read saw an old version; `index` and the newer `op` |
| `out_of_bounds` | NRV-E0203 | An add would cross `min` or `max`; `index` and the current `value` |
| `row_absent` | NRV-E0204 | An add names a missing row (send `create`, or put it first) |
| `unpaired` | NRV-E0205 | A conserved field was added to other than as one half of a pair |
| `conserved_write` | NRV-E0205 | A `put` or `delete` of a row that holds a conserved field. Move amounts with a pair of adds |
| `view_key_field` | NRV-E0206 | An add changes a field a view filters or groups by |
| `key_reused` | NRV-E0207 | The key committed a different transaction |
| `key_collision`, `id_collision` | NRV-E0208, E0209 | Two keys, or two record ids, share a 64-bit hash |

Other statuses: 400 (NRV-E0110 entry malformed, E0114 field needs a layout, E0115 value does not
fit, E0210); 413 (NRV-E0212); 503 (NRV-E0211 `views_busy`: resend under the same key).

```
POST /v1/commit {"entries":[{"kind":"put","table":7,"id":"1","fields":{"available":"100","held":"0"}}]}
-> 200 {"status":"committed","op":"183"}
POST /v1/commit {"entries":[{"kind":"read","table":7,"id":"1","op_seen":"1"},{"kind":"put","table":7,"id":"1","fields":{"available":"90","held":"10"}}]}
-> 409 {"status":"conflict","index":0,"op":"183","applied":false,"code":"NRV-E0202"}
POST /v1/commit {"entries":[{"kind":"add","table":7,"id":"1","field":"available","delta":"-95","min":"0"}]}
-> 409 {"status":"out_of_bounds","index":0,"value":"90","applied":false,"code":"NRV-E0203"}
POST /v1/commit {"entries":[{"kind":"add","table":7,"id":"9","field":"available","delta":"5"}]}
-> 409 {"status":"row_absent","index":0,"applied":false,"code":"NRV-E0204"}
POST /v1/commit {"key":"000102030405060708090a0b0c0d0e0f","entries":[{"kind":"delete","table":7,"id":"2"}]}
-> 200 {"status":"committed","op":"295"}
(the same request again)
-> 200 {"status":"committed","op":"295","replayed":true,"code":"NRV-W0201"}
POST /v1/commit {"key":"000102030405060708090a0b0c0d0e0f","entries":[{"kind":"delete","table":7,"id":"3"}]}
-> 409 {"status":"key_reused","op":"295","applied":false,"code":"NRV-E0207"}
```

A replayed reply has no `adds`, only the original `op`: the amounts the first answer carried are
not kept. A client that used `clamp` and needs the amount that was applied must not read it from
the resend. It reads the rows as of that `op` (`POST /v1/lookup` and `GET /v1/row?…&as_of=<op>`),
or keeps the first reply's `adds` whenever it had one. A client that lost the first reply sees
this on every `clamp` it resends:

```
POST /v1/commit {"key":"000102030405060708090a0b0c0d0e0f","entries":[{"kind":"add","table":7,"id":"1","field":"available","delta":"-30","pair":true,"clamp":true},{"kind":"add","table":7,"id":"1","field":"held","delta_from":0}]}
-> 200 {"status":"committed","op":"68","adds":[{"index":0,"applied":"-30","value":"70"},{"index":1,"applied":"30","value":"30"}]}
(the same request again)
-> 200 {"status":"committed","op":"68","replayed":true,"code":"NRV-W0201"}
```

A pair of adds moves an amount between two fields of a ledger (the second takes what the first
applied, so `clamp` on the first is safe):

```
POST /v1/commit {"entries":[{"kind":"add","table":7,"id":"1","field":"available","delta":"-30","pair":true,"clamp":true},{"kind":"add","table":7,"id":"1","field":"held","delta_from":0}]}
-> 200 {"status":"committed","op":"1182","adds":[{"index":0,"applied":"-30","value":"60"},{"index":1,"applied":"30","value":"40"}]}
POST /v1/commit {"entries":[{"kind":"add","table":7,"id":"1","field":"available","delta":"-1"}]}
-> 409 {"status":"unpaired","index":0,"applied":false,"code":"NRV-E0205"}
POST /v1/commit {"entries":[{"kind":"put","table":7,"id":"1","fields":{"available":"1000","held":"0"}}]}
-> 409 {"status":"conserved_write","index":0,"applied":false,"code":"NRV-E0205"}
```

A `503` on a commit may mean the answer is not known to the gateway: look at `"applied"`. If it is
`"unknown"` (NRV-E0601, E0606, E0113 or B0001 can carry it), resend the same request under the same
`key`: it commits at most once. Never resend an unkeyed write blindly: read the rows first. If
`"applied"` is `false`, nothing was written and a resend is safe. See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#applied-unknown).

### `GET /v1/changes`

The change feed, paged. Query: `limit` (required; a value above 1024 is served as 1024), `cursor`.
Reply:
`{"changes":[{"kind","table","id","op","value_hex"[,"fields"]}, …],"more":<bool>,"cursor":"…","op":"<op>"|null}`.
`op` is `null` while `more` is true; a page may hold fewer changes than `limit`, so follow
`cursor` until `more` is false. The `cursor` of the last page is not `null`: it is where a
follower resumes (see Pages above).

Statuses: 200; 400 (NRV-E0107 `limit is required`, unknown or repeated parameter; NRV-E0106
`cursor must be a decimal string`).

```
GET /v1/changes?limit=3
-> 200 {"changes":[{"kind":"put","table":7,"id":"1","op":"183","value_hex":"6400…00","fields":{"available":"100","held":"0"}}],"more":true,"cursor":"1794348978194367436","op":null}
GET /v1/changes?limit=2000
-> 200 {"changes":[… 4 changes …],"more":false,"cursor":"1794350816765002777","op":"70"}
GET /v1/changes?limit=5&cursor=abc
-> 400 {"error":"cursor must be a decimal string","applied":false,"code":"NRV-E0106"}
GET /v1/changes?bogus=1
-> 400 {"error":"unknown query parameter","applied":false,"code":"NRV-E0107"}
```

### `GET /v1/history`

One row's writes, newest first. Query: `table`, `id`, `limit` (all required), `op_max` (`latest` or
an op), `cursor`. Reply as `changes`; `cursor` is `null` when there is no older write. An `op_max`
beyond the log reads as `latest`: it is not refused.

Statuses: 200; 400 (NRV-E0107, E0108, E0109).

```
GET /v1/history?table=7&id=1&op_max=latest&limit=5
-> 200 {"changes":[{"kind":"put","table":7,"id":"1","op":"292","value_hex":"5a00…00","fields":{"available":"90","held":"10"}},{"kind":"put","table":7,"id":"1","op":"183","value_hex":"6400…00","fields":{"available":"100","held":"0"}}],"more":false,"cursor":null,"op":"303"}
GET /v1/history?table=7&id=1
-> 400 {"error":"limit is required","applied":false,"code":"NRV-E0107"}
```

### `GET /v1/row`

One row as it was at an op. Query: `table`, `id`, `as_of` (all required). Reply:
`{"table","id","as_of","exists","op","value_hex"[,"fields"]}`.

Statuses: 200; 400 (NRV-E0107 `as_of is required`); 504 (NRV-E0401).

```
GET /v1/row?table=7&id=1&as_of=183
-> 200 {"table":7,"id":"1","as_of":"183","exists":true,"op":"183","value_hex":"6400…00","fields":{"available":"100","held":"0"}}
GET /v1/row?table=7&id=1&as_of=99999
-> 504 {"error":"as_of is not yet committed","applied":false,"code":"NRV-E0401"}
```

## Layouts

### `PUT /v1/tables/<table>`

Declares the layout of a table: `{"name":"<1 to 64 bytes>","fields":[{"name","type"[,"size"]}, …]}`,
at most 16 fields. Types: `u8`, `u16`, `u32`, `u64`, `i64`, `bool`, `bytes` (with `size`, at most
255). A row's fields fit in 80 bytes, a record's in 448. Sending a layout again changes nothing; a
layout may only grow by appending fields.

Reply `200`: `{"table":<n>,"layout":"created"|"extended"|"unchanged"}`. A layout sent again with
the same fields and a different `name` answers `unchanged` and keeps the first name.

Statuses: 200; 400 (NRV-E0301 malformed); 409 (NRV-E0302 not an append); 503 (NRV-E0313 catalog
busy, `"applied":"unknown"`: send it again).

```
PUT /v1/tables/7 {"name":"accounts","fields":[{"name":"available","type":"i64"},{"name":"held","type":"i64"}]}
-> 200 {"table":7,"layout":"created"}
(the same request again)
-> 200 {"table":7,"layout":"unchanged"}
PUT /v1/tables/7 {"name":"accounts","fields":[{"name":"held","type":"i64"}]}
-> 409 {"error":"a layout may only be extended by appending fields","applied":false,"code":"NRV-E0302"}
PUT /v1/tables/2147483649 {"name":"executions","fields":[{"name":"agent","type":"bytes","size":16},{"name":"status","type":"u8"},{"name":"created","type":"u64"}]}
-> 200 {"table":2147483649,"layout":"created"}
```

### `GET /v1/tables/<table>`

The layout: `{"name","fields":[{"name","type"[,"size"]}, …]}`. Statuses: 200; 404 (NRV-E0303).

```
GET /v1/tables/7
-> 200 {"name":"accounts","fields":[{"name":"available","type":"i64"},{"name":"held","type":"i64"}]}
GET /v1/tables/99
-> 404 {"error":"no layout for this table","applied":false,"code":"NRV-E0303"}
```

## Declared views

A view is a table's rows grouped and aggregated, kept by the replicas (README,
[Declared views](../README.md#declared-views)).

### `PUT /v1/views/<name>`

Declares a view. A name is lowercase letters, digits and `_`, starting with a letter or `_`.
Request: `{"table":<n>,"where":[{"field","op","value"}],"group_by":["field", …],"aggregates":[{"fn","field"?}, …]}`.
`op` is `eq`, `ne`, `lt`, `le`, `gt` or `ge`; `fn` is `count`, `sum`, `min` or `max`
(`count` takes no `field`). `where` and `group_by` may be left out. At most 4 `where` clauses and
3 `group_by` fields.

Reply `200`: `{"view":"<name>","declared":"created"|"unchanged","maintained":<bool>[,"reason":"…"]}`.
A view declared again exactly as it is answers `unchanged` (not `exists`: ledgers and indexes say
`exists`); declared differently it is `409` NRV-E0308. `"maintained": false` (NRV-W0310) means the
view is declared but the replicas do not keep it; read it from [`nerva view`](#nerva-view). The
`reason` is one of (from the source, not run): `min and max are not maintained over records`; `the
table's views have too many min and max aggregates (at most 4)`; `the cluster's views are full`;
`the table's views are full`; `declared differently in the state machine`; `the view filters or
groups by a field of a ledger`; `refused by the state machine`.

Statuses: 200; 400 (NRV-E0307); 409 (NRV-E0308 declared differently, E0309, E0305 `field_viewed`);
503 (NRV-E0313).

```
PUT /v1/views/revenue {"table":5,"where":[{"field":"sold","op":"eq","value":true}],"group_by":["section"],"aggregates":[{"fn":"count"},{"fn":"sum","field":"price"}]}
-> 200 {"view":"revenue","declared":"created","maintained":true}
PUT /v1/views/revenue {"table":5,"where":[{"field":"sold","op":"eq","value":true}],"group_by":["section"],"aggregates":[{"fn":"count"},{"fn":"sum","field":"price"}]}
-> 200 {"view":"revenue","declared":"unchanged","maintained":true}
PUT /v1/views/revenue {"table":5,"where":[],"group_by":["section"],"aggregates":[{"fn":"count"}]}
-> 409 {"error":"a view with this name is declared differently; views are immutable","applied":false,"code":"NRV-E0308"}
PUT /v1/views/Bad {}
-> 400 {"error":"a view name is lowercase letters, digits and _","applied":false,"code":"NRV-E0307"}
```

### `GET /v1/views`

`{"views":[{"name","id","state","declared_op","group_count"}, …]}`. `state` is `ready` once the
view has been built. (`nerva view` answers `{"views":["name", …]}`: names only.)

```
GET /v1/views
-> 200 {"views":[{"name":"revenue","id":1,"state":"ready","declared_op":"647","group_count":"1"}]}
```

### `GET /v1/views/<name>`

The view's groups. Query: `min_op` (an op, or `latest`) or `as_of` (an op), not both (NRV-E0410).
Reply: `{"view","op","hash","view_hash","declared_op","groups":[{<group_by fields>,"count","sum_price", …}, …]}`.
A group's aggregate members are named `count`, `sum_<field>`, `min_<field>`, `max_<field>`.
A view with more than 10,000 groups is refused (NRV-E0407): read it from `/groups`.

Statuses: 200; 400 (NRV-E0410, E0407); 404 (NRV-E0402, E0403 declared after `as_of`, E0406 not
maintained); 503 (NRV-E0404 building, E0405 failed); 504 (NRV-E0401).

```
GET /v1/views/revenue
-> 200 {"view":"revenue","op":"661","hash":"6ff0…cd3de","view_hash":"c15c…ac9dd","declared_op":"647","groups":[{"section":1,"count":"2","sum_price":"5400"}]}
GET /v1/views/nope
-> 404 {"error":"no such view","applied":false,"code":"NRV-E0402"}
GET /v1/views/revenue?min_op=1&as_of=1
-> 400 {"error":"min_op or as_of, not both","applied":false,"code":"NRV-E0410"}
```

(`hash` and `view_hash` are shortened above; the full values are 64 hex digits.)

### `GET /v1/views/<name>/groups`

The groups in pages. Query: `limit` (default 1024), `cursor`, `as_of`. Reply:
`{"view","id","state","op","declared_op","view_hash","group_count","groups":[…],"more","cursor"}`.

Statuses: 200; 400 (NRV-E0106 a cursor that is not a decimal string, E0107); 404 (NRV-E0402); 503
(NRV-E0404); 504 (NRV-E0401).

```
GET /v1/views/revenue/groups?limit=1
-> 200 {"view":"revenue","id":1,"state":"ready","op":"667","declared_op":"647","view_hash":"c15c…ac9dd","group_count":"1","groups":[{"section":1,"count":"2","sum_price":"5400"}],"more":false,"cursor":null}
```

### `GET /v1/views/<name>/definition`

The declaration as stored. Statuses: 200; 404 (NRV-E0402).

```
GET /v1/views/revenue/definition
-> 200 {"table":5,"where":[{"field":"sold","op":"eq","value":"1"}],"group_by":["section"],"aggregates":[{"fn":"count"},{"fn":"sum","field":"price"}]}
```

## Ledgers

A ledger names 2 to 16 `i64` fields whose sum the replicas conserve (README,
[Ledgers](../README.md#ledgers)). At most 64 per cluster.

### `PUT /v1/ledgers/<id>`

Request: `{"fields":[{"table","field" (or "offset"),"floor"}, …]}`; `floor` is a decimal string or
`null` for none. Reply `200`: `{"ledger":<id>,"declared":"created"|"exists","op":"<op>"}`.

Statuses: 200; 400 (NRV-E0304); 409 (NRV-E0305 `ledger_immutable`, `ledger_field_taken`,
`field_viewed`; NRV-E0306 `ledgers_full`).

```
PUT /v1/ledgers/1 {"fields":[{"table":7,"field":"available","floor":"0"},{"table":7,"field":"held","floor":"0"},{"table":8,"field":"balance","floor":null}]}
-> 200 {"ledger":1,"declared":"created","op":"1167"}
PUT /v1/ledgers/1 {"fields":[{"table":7,"field":"available","floor":"0"},{"table":7,"field":"held","floor":"0"}]}
-> 409 {"status":"ledger_immutable","ledger":1,"applied":false,"code":"NRV-E0305"}
```

### `GET /v1/ledgers/<id>`

`{"ledger","op","fields":[{"table","offset","field","floor"}, …]}`. Statuses: 200; 404 (NRV-E0402).

```
GET /v1/ledgers/1
-> 200 {"ledger":1,"op":"1167","fields":[{"table":7,"offset":0,"field":"available","floor":"0"},{"table":7,"offset":8,"field":"held","floor":"0"},{"table":8,"offset":0,"field":"balance","floor":null}]}
GET /v1/ledgers/2
-> 404 {"error":"no such ledger","applied":false,"code":"NRV-E0402"}
```

## Indexes

An index orders the records of a record table by an `order` field, under up to 3 `eq` fields
(README, [JSON API](../README.md#json-api)). At most 64 indexes, 4 per table.

### `PUT /v1/indexes/<name>`

Request: `{"table":<n>,"eq":["field", …],"order"?:"field","where"?:[{"field","op","value"}]}`.
Reply `200`: `{"index","id","declared":"created"|"exists","op"}`.

Statuses: 200; 400 (NRV-E0311); 409 (NRV-E0312 declared differently, or no room).

```
PUT /v1/indexes/reserved {"table":2147483649,"eq":["agent"],"order":"created","where":[{"field":"status","op":"eq","value":1}]}
-> 200 {"index":"reserved","id":1,"declared":"created","op":"1193"}
```

### `GET /v1/indexes`

`{"indexes":[{"name","id","table","state","declared_op","record_count"}, …]}`. (The README's
table calls `record_count` "records".)

```
GET /v1/indexes
-> 200 {"indexes":[{"name":"reserved","id":1,"table":2147483649,"state":"ready","declared_op":"1193","record_count":"1"}]}
```

### `GET /v1/indexes/<name>`

One entry of the list above. Statuses: 200; 404 (NRV-E0402).

```
GET /v1/indexes/reserved
-> 200 {"name":"reserved","id":1,"table":2147483649,"state":"ready","declared_op":"1193","record_count":"1"}
```

### `POST /v1/indexes/<name>/scan`

A page of records. Request: `{"eq":{<field>:<value>, …},"min"?,"max"?,"descending"?,"limit"?,"after"?}`.
`eq` names every `eq` field of the index (NRV-E0409). `limit` defaults to 100. `after` is the
`next` of the previous page. Reply: `{"index","op","records":[{"id","op","order","value_hex"[,"fields"]}, …],"next":"<cursor>"|null}`; `next` is `null` on the last page. A scan has no `cursor` or `more` member, and its `fields` appear when the table has a layout.

Statuses: 200; 400 (NRV-E0409, E0408); 404 (NRV-E0402); 503 (NRV-E0404 `index building`).

```
POST /v1/indexes/reserved/scan {"eq":{"agent":"aa000000000000000000000000000001"},"limit":10}
-> 200 {"index":"reserved","op":"141","records":[{"id":"0190f1c2a7e47b3c9d2e5f6a7b8c9d0e","op":"117","order":"1760600000","value_hex":"aa00…00","fields":{"agent":"aa000000000000000000000000000001","status":1,"created":"1760600000"}}],"next":null}
POST /v1/indexes/reserved/scan {"limit":5}
-> 400 {"error":"eq is required","applied":false,"code":"NRV-E0409"}
POST /v1/indexes/nope/scan {"eq":{"agent":"aa000000000000000000000000000001"}}
-> 404 {"error":"no such index","applied":false,"code":"NRV-E0402"}
```

## Documents

Keyed byte values in a namespace, with a version per key (the op that wrote it). A key is at most
1,024 bytes of UTF-8, a value at most 512 KiB.

### `POST /v1/documents/get`

Request: `{"namespace":"<n>","keys":["…", …],"as_of"?:"<op>"}`: 1 to 256 keys. Reply:
`{"op","documents":[{"key","exists","version","value_hex"}, …]}`; a key that does not exist has
`"version":"0"`.

Statuses: 200; 400 (NRV-E0501, E0502); 413 (NRV-E0504); 504 (NRV-E0401).

```
POST /v1/documents/get {"namespace":"7","keys":["plan","absent"]}
-> 200 {"op":"1353","documents":[{"key":"plan","exists":true,"version":"1350","value_hex":"68656c6c6f"},{"key":"absent","exists":false,"version":"0","value_hex":""}]}
POST /v1/documents/get {"namespace":"7","keys":[]}
-> 400 {"error":"keys must not be empty","applied":false,"code":"NRV-E0502"}
```

### `POST /v1/documents/commit`

Request: `{"namespace","key"?,"reads":[{"key","version"}],"writes":[{"key","value_hex"} or {"key","delete":true}]}`.
A read that saw an older version than the key now has fails the commit. `key` is the commit key,
as for `/v1/commit`. `reads` may be left out. Reply `200`:
`{"status":"committed","op"[,"replayed":true,"code":"NRV-W0201"]}`.

Statuses: 200; 400 (NRV-E0501, E0502); 409 (NRV-E0503 `conflict` with the `key` and its `version`;
NRV-E0207, E0208).

```
POST /v1/documents/commit {"namespace":"7","reads":[{"key":"plan","version":"0"}],"writes":[{"key":"plan","value_hex":"68656c6c6f"}]}
-> 200 {"status":"committed","op":"1350"}
(a second commit reading version 0)
-> 409 {"status":"conflict","key":"plan","version":"1350","applied":false,"code":"NRV-E0503"}
```

### `GET /v1/documents/changes`

Query: `namespace`, `limit` (required), `cursor`. Reply: `{"documents":[…],"more","cursor","op"}`.
A page may be empty while `more` is true: follow `cursor`. As for `changes`, the `cursor` of the
last page is where to resume, not `null`. A cursor that is not one Nerva gave is `400` NRV-E0408.

```
GET /v1/documents/changes?namespace=7&limit=10
-> 200 {"documents":[],"more":true,"cursor":"1794349000890440805","op":null}
```

## nerva view

`nerva view` is a read-only gateway: it follows the change feed and recomputes declared views
itself, so it can serve views the replicas do not maintain (NRV-W0310). It takes the same
`X-Nerva-Key`, the same `--listen` and `--request-timeout`, and serves three routes:

| Route | Reply |
|---|---|
| [`GET /healthz`](#get-healthz) | As the API gateway's |
| [`GET /v1/views`](#get-v1views) | `{"views":["name", …]}`, no query allowed |
| [`GET /v1/views/<name>`](#get-v1viewsname) | `{"view","op","hash","groups"}`; query `min_op` (an op or `latest`) or `as_of`, not both |

Every other path is `404` (NRV-E0104), every other method `405`, and a body is `413`. A name starts
with a lowercase letter or `_`. An unknown view is `404` NRV-E0402. An op that is not committed yet
is `504` NRV-E1001. Other codes it answers with: NRV-E0107, E0410, E0605, E0601, E0606 and E1002
(`409`: the view does not match its table's layout).

```
GET /v1/views                    -> 200 {"views":["revenue"]}
GET /v1/views/revenue            -> 200 {"view":"revenue","op":"662","hash":"6ff0…cd3de","groups":[{"section":1,"count":"2","sum_price":"5400"}]}
GET /v1/views/revenue?as_of=99999 -> 504 {"error":"the op is not committed yet","applied":false,"code":"NRV-E1001"}
GET /v1/tables/7                 -> 404 {"error":"not found","applied":false,"code":"NRV-E0104"}
```

In the recording its `hash` equalled the API gateway's for the same groups. Its reply has no
`view_hash` or `declared_op` in this candidate.

## Where to go next

[QUICKSTART.md](QUICKSTART.md) starts a cluster and a gateway and calls them. A refusal is looked up in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#other-statuses-from-a-gateway) and [ERRORS.md](ERRORS.md).
What `NERVA_KEY` protects, and why a gateway stays on loopback, is in [SECURITY.md](../SECURITY.md);
what a gateway needs to run is in [OPERATING.md](OPERATING.md#sizing).
