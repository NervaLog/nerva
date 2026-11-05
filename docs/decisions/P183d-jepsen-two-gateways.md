---
id: P183d
date: 2026-11-05
area: Releases
---
Jepsen's `--gateways` option is 1 or 2; gateway i listens on 8080 + i.

**Decision.** `tests/jepsen` gains `--gateways 1|2` (default 1). Each node runs that many
`nerva api` processes with `--listen-remote`, the second on 8081 with its own pid and log file;
`kill-all!` stops both. The workload clients still use 8080 only.

**Why.** R4's acceptance line (two gateways per node, P168) needs the topology to exist before R1
can route a workload through it; routing is R1's change, not R4's. Two is the number the
acceptance line names, and a fixed port per gateway keeps the nemesis and the logs simple.

**Cost.** Until R1 routes clients to 8081, the second gateway is started and killed but carries no
traffic. Not compiled here (no `lein`): R1 runs `lein test` first.
