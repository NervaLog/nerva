---
id: P234
date: 2026-11-06
area: Testing
---

# A gateway is cut off by an owner rule in the mangle table

**Decision.** `gateway-partition` drops the gateway's TCP traffic to port 3000 with
`iptables -t mangle -A OUTPUT -m owner --uid-owner nerva-gwN`, and each gateway runs as its own
Unix user. The rules are in the mangle table, not the filter table.

**Why.** The replica (root) must keep talking to its peers while only the gateway is cut off, which
only a socket-owner match can say. Jepsen's partitioner heals with `iptables -F` on the filter
table; a gateway rule there would be lifted by a `partition` heal in `[:kill :partition :gateway]`.

**Costs.** The nodes need the mangle table and the `owner` match (the hosted run shows it). A user
per gateway, created at setup. Only outbound traffic is cut; inbound requests still reach the
gateway and wait out its `--request-timeout`.
