---
id: P225
date: 2026-11-06
area: Releases
---

# The `retry` workload resends every key that did not end `:ok`, `:fail` ones included

The decision: the final phase of the Jepsen `retry` workload resends each key whose operation
ended `:info` or `:fail`, until a `2xx` answers it. The brief names only the `:info` keys, but its
check 3 (a key whose attempts were all `applied: false` must be answered first-time, never
`replayed`) can only be made on a key that is sent again. Because a pay-in never fails for funds,
a `2xx` is the only definite answer to its key, so the phase waits for one (at most 180 s a key;
past that the key is `unresolved` and the result `:unknown`).

Also taken: a client's discarded `200` is kept in the history as an attempt of kind `:committed`
with `dropped? true`, naming its op. Without it, a duplicate with the first reply discarded
(the case the teeth run produces) could be seen only as a wrong balance, not as the `duplicate`
the brief expects. And `--gateways` has no fixed default: `retry` takes 2, `bank` 1, and the
`retry` gateways start with `--request-timeout=10000` (brief: short client timeouts below it).

The reason: each follows from the brief's checks and teeth. What it costs: a `:fail` operation's
effect can appear later in the history (the final phase commits it), so Jepsen's `:fail` means
"refused at the time", not "never applied"; only `retry/checker` reads these histories.

The gateway timeout is 10000 ms, not 3000: a gateway registers with the cluster at start within
the same bound, and on the hosted runner (10 gateways and 5 replicas on 4 vCPU) a 3 s bound made a
gateway exit with NRV-E0604 on all six starts while the cluster was still electing a primary
(run 42167113764). The setup restart loop stays, and waits up to 15 s per start.
