# Jepsen tests for Nerva

A [Jepsen](https://jepsen.io) suite that runs real `nerva` processes on five nodes, talks to them
the way an application does (JSON over HTTP, through `nerva api`), injects faults, and checks
the history of what every request was told against what Nerva promises (docs/DECISIONS.md
N82). It complements the VOPR: real processes, real sockets, real gateways, no simulator, but
also no seeds: a run cannot be replayed, so a failure found here is reproduced as a VOPR seed
or a unit test before it is fixed.

## Running it

Needs Docker (with privileged containers, for iptables), `ssh-keygen`, gnuplot (for the perf
graphs: without it a result is `:unknown`), and a JDK (21). Leiningen is `$LEIN`, else `lein` on
PATH, else the pinned 2.12.0 that `tools.sh` downloads into `.tools/` (both files sha256-checked;
`run.sh` does this by itself).

```bash
./zig/zig build -Drelease                       # zig-out/bin/nerva, the build under test
cd tests/jepsen
./run.sh ../../zig-out/bin/nerva test --workload bank --nemesis kill,partition --time-limit 300
./run.sh ../../zig-out/bin/nerva test-all --time-limit 120   # every workload under every nemesis
lein test                                        # the checkers, against hand-written histories
lein run serve                                   # browse store/ at http://localhost:8080
```

Replicas authenticate each other with `NERVA_CLUSTER_KEY` (P102): the suite passes the control
node's `$NERVA_CLUSTER_KEY` (at least 32 bytes) to every replica, or, if it is unset, a fresh
random key for the run. It reaches a node over stdin into a mode `600` file that the replica's
start command reads, so it is in no command line, in no log and not in `store/`.

`run.sh` starts five Debian containers at `10.77.0.11` to `10.77.0.15` (`node/Dockerfile`),
each with sshd and nothing else; the test uploads the given `nerva`, formats a replica and
starts it and a gateway on every node, and removes the containers when it ends. The SSH key is
copied into each node with `docker exec` and owned by root: a mounted file keeps its owner on the
host, and sshd refuses it. Each test's
history, analysis (`results.edn`), latency and rate graphs, and every node's `replica.log`
and `api.log` land in `store/`.

Options (`lein run test --help` lists Jepsen's own):

| Option | Default | |
|---|---|---|
| `--workload` | `bank` | `bank` or `retry`: what the clients do and what is checked (below) |
| `--nemesis` | none | Comma-separated faults: `kill`, `pause`, `partition` |
| `--nemesis-interval` | 10 | Mean seconds between faults |
| `--rate` | 20 | Requests per second, over all workers |
| `--time-limit` | 60 | Seconds of requests and faults, before healing |
| `--recovery-time` | 20 | Seconds between healing and the final reads |
| `--drop-reply` | 0.1 | `retry`: the probability that the client discards a `200` and resends it as if it were lost |
| `--attempts` | 8 | `retry`: attempts per operation (one key) before it ends unresolved |
| `--gateways` | 1 (2 for `retry`) | Gateways per node: 1, or 2 (ports 8080 and 8081; `bank`'s clients use the first, `retry`'s use both). They listen on `0.0.0.0` with `--listen-remote`, since the control node reaches them over the network |

## What a reply means

The suite reads a reply's body as R4 defines it (README, "What a reply means"; P215d), not the
status alone:

| Reply | Outcome |
|---|---|
| `2xx` | Applied: `:ok`. With `"replayed": true` (NRV-W0201) the request had already committed: `:ok`, `:replayed? true`, and the `op` is the original commit's |
| any other status with `"applied": false` | Definite: `:fail`. A `409` is Nerva refusing a well-formed request (its status is the `:error` a checker judges); any other (busy, no session, too large) is `{:code .., :http ..}`, which no checker takes for a refusal |
| `"applied": "unknown"` | A write may have committed: `:info`. A read: `:fail` |
| no reply (a reset, the client's 35 s timeout) | A write: `:info`. A read: `:fail`. A connection never made (refused, or timed out connecting) sent nothing: `:fail` |
| a non-2xx without both `applied` and `code`, or a `400` | A failure of the test: R4 promises both, and a `400` means the test sent a malformed request |

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

**`retry`**: what Botpike does after a lost reply (P123): resend a keyed commit, under the same
key, until the answer is definite. Eight account rows (`balance`, floored at 0) and an unfloored
source in a declared ledger; an operation is a pay-in of 1 to 30 from the source to one account
(a pair of adds, no `clamp`, so a pay-in never fails for funds and every commit of it moves
exactly its amount). Each draws a fresh 128-bit key from Jepsen's random source (`--seed` steers
it). Replies are lost on purpose: a client timeout of 35 s, or with probability 1/4 a short one
(50 to 1,999 ms, below the gateways' `--request-timeout=3000`), and `--drop-reply` of the `200`s
discarded. An attempt that is not definite goes to another gateway of any node, after a backoff,
up to `--attempts`. The operation is `:ok` with the op of its first `200`, `:fail` if every
attempt was `applied: false` (or never connected), else `:info`. After healing, every key whose
operation did not end `:ok` is resent until a `2xx` answers it, and then every account is read
in one lookup. Checked: `duplicate` (every `200` for a key, a discarded one included, names the
same op), `balance` (each account holds the sum of the amounts of the keys that committed for
it, each once, and the source holds minus their total), `applied-lie` (a key whose attempts were
all `applied: false` is answered first-time, never `replayed`), `key-reused` and `key-collision`
(the client never changes a key's entries; a collision is reported with its key). A key no
`2xx` answered even in the final phase makes the result `:unknown`, not invalid.

Planned: `claim` (compare-and-set receipts), `register` (transaction isolation, with Elle), and
`feed` (the change feed, history as of an op, and view hashes across gateways).

## On a hosted runner

`.github/workflows/jepsen.yml` runs the suite on GitHub's `ubuntu-24.04` runner, so a workload,
nemesis or checker runs for real before the R2 host exists. Push a commit to a scratch branch
named `jepsen/<slice>-<slug>` (`git push origin HEAD:jepsen/s2-footing`) or dispatch it:

| Input | Default | |
|---|---|---|
| `args` | `test --workload bank --nemesis kill,partition --time-limit 300` | The `lein run` arguments: `test` and options, `--time-limit` at most 1200. A push runs the default |
| `teeth` | `false` | Test the build with commit-key deduplication off (`-Dtest-commit-keys=off`, R1 slice 1). Fails at once, saying so, on a commit whose `build.zig` lacks that option |

It builds `nerva` ReleaseSafe, runs `lein test` and then `run.sh` with a fresh `NERVA_CLUSTER_KEY`,
fails if any file in `store/` holds that key, and uploads `store/` as the `jepsen-store` artifact
(14 days). A scratch branch is deleted when the run ends; push a new commit to the same name to
run again. The workflow never files an issue.
