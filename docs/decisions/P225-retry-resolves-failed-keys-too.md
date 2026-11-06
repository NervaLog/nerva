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
`retry` gateways start with `--request-timeout=3000` (brief: short client timeouts below it).

The reason: each follows from the brief's checks and teeth. What it costs: a `:fail` operation's
effect can appear later in the history (the final phase commits it), so Jepsen's `:fail` means
"refused at the time", not "never applied"; only `retry/checker` reads these histories.

`--gateways 2` runs two gateways only on the first three nodes (six in all). A `--development`
replica takes at most 8 client connections (`pipeline_prepare_queue_max`; the `--development`
profile sets `pipeline_requests_limit` to 0), and each gateway is a client on every replica: with
ten, the last gateway to start was closed by all five replicas and exited with NRV-E0604 on
every restart (hosted runs 42167113764 and 42167830114; not the 3 s timeout, as first thought).
The setup restart loop stays.
