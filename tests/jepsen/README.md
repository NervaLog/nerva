# Jepsen tests for Nerva

A [Jepsen](https://jepsen.io) suite that runs real `nerva` processes on five nodes, talks to them
the way an application does (JSON over HTTP, through `nerva api`), injects faults, and checks
the history of what every request was told against what Nerva promises (docs/DECISIONS.md
N82). It complements the VOPR: real processes, real sockets, real gateways, no simulator, but
also no seeds: a run cannot be replayed, so a failure found here is reproduced as a VOPR seed
or a unit test before it is fixed.

## Running it

Needs Docker (with privileged containers, for iptables), a JDK (21) and
[Leiningen](https://leiningen.org).

```bash
./zig/zig build -Drelease                       # zig-out/bin/nerva, the build under test
cd tests/jepsen
./run.sh ../../zig-out/bin/nerva test --workload bank --nemesis kill,partition --time-limit 300
./run.sh ../../zig-out/bin/nerva test-all --time-limit 120   # every workload under every nemesis
lein test                                        # the checkers, against hand-written histories
lein run serve                                   # browse store/ at http://localhost:8080
```

`run.sh` starts five Debian containers at `10.77.0.11` to `10.77.0.15` (`node/Dockerfile`),
each with sshd and nothing else; the test uploads the given `nerva`, formats a replica and
starts it and a gateway on every node, and removes the containers when it ends. Each test's
history, analysis (`results.edn`), latency and rate graphs, and every node's `replica.log`
and `api.log` land in `store/`.

Options (`lein run test --help` lists Jepsen's own):

| Option | Default | |
|---|---|---|
| `--workload` | `bank` | What the clients do and what is checked (below) |
| `--nemesis` | none | Comma-separated faults: `kill`, `pause`, `partition` |
| `--nemesis-interval` | 10 | Mean seconds between faults |
| `--rate` | 20 | Requests per second, over all workers |
| `--time-limit` | 60 | Seconds of requests and faults, before healing |
| `--recovery-time` | 20 | Seconds between healing and the final reads |
| `--gateways` | 1 | Gateways per node: 1, or 2 (ports 8080 and 8081; the workload's clients use the first). They listen on `0.0.0.0` with `--listen-remote`, since the control node reaches them over the network |

## What a reply means

`200` applied the request; `409` applied nothing, and neither does a request whose connection
was never made (refused, or timed out connecting). Any other missing reply (a reset, the
client's 35 s timeout), or a `503` (the gateway lost its cluster session, perhaps after the
commit went out), leaves a write's outcome unknown
(Jepsen's `:info`: it may or may not have happened, and the checkers allow both). A read
without a reply changed nothing, so it simply failed. A `400` is a bug in the test.

## Faults

| Fault | Does |
|---|---|
| `kill` | SIGKILLs the replica and the gateway on one node, a minority, a majority or all, then restarts them |
| `pause` | SIGSTOPs the replica (not the gateway) on one node, a minority or a majority, then resumes it |
| `partition` | iptables: one node isolated, the cluster split into a majority and a minority, or a majorities ring |

Planned: killing gateways alone, lost unsynced writes (LazyFS) and bit flips, clock faults (on
separate machines: `nerva` is a static binary, so libfaketime cannot fool it, and containers
share one clock), and rolling upgrades.

## Workloads

**`bank`**: conservation in a declared ledger. Four account rows, each with `available` and
`held` floored at 0, and an unfloored source that funds them once. A transfer is a pair of adds
between any two of the eight conserved fields (half of them clamped). Checked: every read (one
lookup, so one op) totals what was funded with no field below 0, the source never moves, a
sum view over the accounts always answers the funded total, and a transfer is refused only as
`out_of_bounds`.

Planned: `retry` (an application's retry after a `503`: is an add applied twice?), `claim`
(compare-and-set receipts), `register` (transaction isolation, with Elle), and `feed` (the
change feed, history as of an op, and view hashes across gateways).
