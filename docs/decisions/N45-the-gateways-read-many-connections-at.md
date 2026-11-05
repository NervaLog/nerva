---
id: N45
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# The gateways read many connections at once, parse requests strictly, and never wait for an op not yet committed.

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
