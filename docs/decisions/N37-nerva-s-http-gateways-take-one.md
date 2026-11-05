---
id: N37
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Nerva's HTTP gateways take one request per connection, with a 10 s receive deadline.

Nerva's HTTP gateways serve one request at a time. Each used to keep a
connection open for further requests, so a client holding an idle keep-alive connection
starved every other client. The demo's buyer threads hit this at once; any application with
concurrent clients would have too. The test suites missed it because they open
a connection per request. Now every reply says `Connection: close`, and a connection that sends
nothing within 10 s is dropped. Cost: one TCP connect per request, which is negligible next to
a cluster round trip. `tests/api/api.py` checks both cases, and fails against the old server.
Replies are also sent with `TCP_NODELAY`, so a reply written in pieces is not held back by
Nagle's algorithm.
