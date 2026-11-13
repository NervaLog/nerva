---
id: P412
date: 2026-11-13
area: Releases
amends: N61
---

# The owner approves telling the replica which connection delivered a message (#358)

**Decision.** The owner approved, on 2026-11-13, patching vendored `src/vsr/replica.zig`,
`src/message_bus.zig`, `src/testing/cluster/message_bus.zig` and `src/vsr/client.zig` so that the
replica learns which replica's connection delivered a message, and `release_peers.admits` requires
that connection's announcement for a prepare received directly from its maker. What this change
patches: `message_bus.zig` (a field `recv_from`, set around each `on_messages_callback` from the
connection's peer), `testing/cluster/message_bus.zig` (the same field, always null: the simulated
network's buffer holds messages of several senders), `replica.zig` (passes `recv_from` to
`admits`). `client.zig` needed no change: the field is read only by the replica, so the approved
patch to it is not taken.

**Reason.** N61 admitted a prepare whose maker had not announced since this replica started, so a
replica of another release (or the keys-off build, P354) whose prepares arrive before its first
ping was handled for about a ping interval. The bus did not pass the sender, so a directly
received prepare could not be told from a relayed or repaired one (#358).

**Rule.** A prepare whose connection is the maker's own is admitted only when that connection has
announced this replica's release and origin. A relayed or repaired prepare, or one on a connection
whose peer is not yet known, keeps N61's and P90's rule (its maker's last announcement, admitted if
none), so a dead primary's prepares are still repaired.

**Cost.** A connection not yet identified as a replica's (its first message was a prepare) still
gets the lenient rule: the window is narrowed, not closed there. The VOPR does not exercise the new
rule (the simulated bus never names a sender); `release_peers` unit tests and
`tests/release/mixed.py` (replicas restarting beside an other-release primary) do.
