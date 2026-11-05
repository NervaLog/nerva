---
id: N67
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# A client may not send `pulse`.

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
