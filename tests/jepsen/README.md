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
| `--nemesis` | none | Comma-separated faults: `kill`, `pause`, `partition`, `gateway` (= `gateway-kill`, `gateway-partition`, `gateway-pause`, each also nameable alone), `lose-unfsynced-writes` |
| `--nemesis-interval` | 10 | Mean seconds between faults |
| `--rate` | 20 | Requests per second, over all workers |
| `--time-limit` | 60 | Seconds of requests and faults, before healing |
| `--recovery-time` | 20 | Seconds between healing and the final reads |
| `--keys` / `--no-keys` | `--keys` | `bank`: send each transfer under a commit key with a record, retried as `retry`'s are, or unkeyed as before |
| `--drop-reply` | 0.1 | Keyed workloads (`retry`, `bank --keys`): the probability that the client discards a `200` and resends it as if it were lost |
| `--attempts` | 8 | Keyed workloads: attempts per operation (one key) before it ends unresolved |
| `--gateways` | 1 (2 for `retry` and `bank --keys`) | Gateways per node: 1, or 2 (on the first three nodes only, as a development replica takes 8 clients; ports 8080 and 8081; `bank --no-keys`'s clients use the first, keyed workloads' use both). They listen on `0.0.0.0` with `--listen-remote`, since the control node reaches them over the network |

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
| `gateway-kill` | SIGKILLs one gateway, one node's gateways, or a minority of nodes' gateways, the replica left running; the undo starts the gateways that are not running and probes them for 10 s plus at most one round of probes (the final phase's start instead waits for and restarts every gateway that is not up, each wait longer than the gateway's 30 s registration window, and the `gateways` checker makes the run invalid, citing NRV-E0604, if one is still down, pending or the start threw); one that exited at start (still cut off, NRV-E0604) is reported in the op as `:down`, one still alive but not answering at the deadline as `:pending`, neither as hit, and the next start op starts them again |
| `gateway-partition` | Drops a gateway's traffic to its own node's replica, to a majority of the replicas, or to all of them (`iptables -t mangle -A OUTPUT -m owner --uid-owner nerva-gwN -p tcp -d REPLICA --dport 3000 -j DROP`, one rule per replica); the gateways are one, one node's, or a minority of nodes'; its clients still reach it and wait out its `--request-timeout`. In the mangle table, so a `partition` heal does not lift it |
| `gateway-pause` | SIGSTOPs one gateway or one node's gateways, the replica left running, then SIGCONTs them |
| `gateway` | The three above, mixed; its final phase resumes, heals and starts every gateway |
| `lose-unfsynced-writes` | LazyFS (below): kills the replica and gateways on a minority of nodes (1 or 2 of 5) and clears LazyFS's cache there (with `--lazyfs-all-nodes`, also kills a majority, then the rest, and clears every node's cache; off by default, and refused with NRV-E0607, as one line and exit 2, on a host with under 32 GiB or under 16 GiB available: only the 64 GB R1 host runs it, see `docs/demos/r1.md`, P242j). LazyFS is mounted on 2 of the 5 nodes (the first two) unless `--lazyfs-all-nodes`, so a hosted run has the memory; `--lazyfs-strict-sync` fails a run that finds any unsynced byte after a kill (the canary); the undo starts the nodes it killed |

Each gateway runs as its own Unix user (`nerva-gw0`, `nerva-gw1`) so that iptables can name one.
The nemesis draws its targets from the gateways the test runs (`--gateways 2` gives two only to the first three nodes; every other node runs one, index 0 on port 8080, and has no index 1 to kill, pause or cut, so no fault names a gateway that does not exist, and `retry`'s clients use only the gateways that exist). The op's value in the history lists the targets (`:gateways`, or `:cut` and `:scope` for a partition), and its completion adds `:hit`, the `[node index]` pairs reached: for a kill, a cut or a pause only gateways running when checked (one that exits between the check and the action is still counted); for a start only gateways that came up (the others are `:down`, exited, or `:pending`, alive and not yet answering). In the final phase `gateway-resume` and `gateway-heal` run before the replicas' `start`, and `gateway-start` after it; that last start retries each gateway (bounded, with backoff). The `gateways` checker judges two things apart. A gateway still down or pending after it is a Nerva availability finding: `:valid? false`, NRV-E0604, and it wins over the other. A failure of the harness says nothing about Nerva: `:valid? :unknown`, NRV-E0607, for a final start that threw, did not finish or never ran when the faults called for it (`:expected 1`), a gateway whose probe threw (named in the op's `:error`, while the node's other gateways keep their `:up`, `:down` and `:pending`), or a final `gateway-heal` that failed. A gateway that answers `/healthz` with a body it cannot read counts as not healthy (NRV-E0604), not as a harness failure. That start also runs under the replica `kill` nemesis alone, and under `lose-unfsynced-writes`: their main-phase `:start` restarts gateways with only the short settle (P244), so the final start is what brings them back and judges them. The heal deletes each gateway rule (at most 8 copies per replica), then asks `iptables -C` and accepts only its exit 1 (no such rule) as healed: a rule left, or iptables failing, fails the heal with NRV-E0607; only the final phase's heal is judged (it returns the failure per node), a mid-run heal that failed is listed as `:mid-run-heal-failures` and changes nothing. A teardown after the run only logs a failed heal, so the analysis still runs. The nightly's reporter reads the checker's `:code`: a verdict carrying NRV-E0607 is the host's (counted, status `error`, no issue) unless another checker found something. `gateway-pause` and `gateway-resume` signal only gateways whose pidfile names a process of the gateway's own user.

### Lost unsynced writes (LazyFS)

With `lose-unfsynced-writes` in `--nemesis`, each node's data directory, `/opt/nerva/data`, is a
[LazyFS](https://github.com/dsrhaslab/lazyfs) FUSE mount (`jepsen.nerva.lazyfs`, on
`jepsen.lazyfs`) and the replica's data file is `/opt/nerva/data/replica.nerva`. LazyFS keeps
every write in its own cache until it is fsynced; clearing the cache after the replica is dead
loses the writes the replica never made durable. Stock LazyFS (9c5685e8) does not honour the
`O_DSYNC` the replica opens its data file with: a non-extending direct write reaches it with no
fsync, so it loses acknowledged writes (#246). The node image therefore builds LazyFS with
`node/lazyfs-osync.patch`, which syncs the file in `lfs_write` when it was opened `O_DSYNC` or
`O_SYNC` (P242d); without it a clear is replica amnesia, not a lost unfsynced write. The fault
still never acts while an earlier victim is down or has not caught up (such a fault is recorded
`:skipped`; a combined run takes few faults, so read `:faults` against `:skipped`), and its verdict
(`:lazyfs`) is `:unknown` with NRV-E0607 when a clear was not seen to take, the unsynced sentinel file written before
the clear survived it (the fault did not bite, P242e; the bytes lost are reported, not judged),
a fault op threw, or the final recovery judged no node, and invalid with NRV-E0604 when the final
recovery left a gateway or the replica down. The final recovery settles every node the fault has
hit, not only the ones still down. Whether a `--development` replica gets `O_DIRECT` on FUSE is
not measured (`replica.log` says if the mount refused it). With the fault the data file is formatted on LazyFS's backing path before the mount, so its cache
starts empty (P242h). Without the fault the data file is where it was
and nothing is mounted. A run that never asked for the fault (the nightly, the default
`kill,partition` run) is not judged by `:lazyfs`.

The node image (`node/Dockerfile`) builds LazyFS from one pinned commit (0.3.0, the version
`jepsen.lazyfs` is written for) in a first stage that fails unless the checkout is exactly that
commit, the patch applies and the binary finds its libraries; `run.sh` passes `/dev/fuse` to the nodes. The fault's
op in the history lists `:killed`, `:unsynced-bytes` (what LazyFS held and so lost, by node,
from its own report) and `:remaining` (the report after the clear, 0 when it took), `:sentinel` (`:gone`, `:truncated`, `:survived`, `:unwritten` or `:unchecked`), `:cache-usage` (LazyFS's cache before the clear, in percent; 100 means it wrote through and the fault lost nothing: the verdict is `:unknown`, `:cache-full`, P242h), and each node's `lazyfs.log` is in `store/`.

Planned: bit flips, clock faults (on
separate machines: `nerva` is a static binary, so libfaketime cannot fool it, and containers
share one clock), and rolling upgrades.

## Workloads

**`bank`**: conservation in a declared ledger. Four account rows, each with `available` and
`held` floored at 0, and an unfloored source that funds them once. A transfer is a pair of adds
between any two of the eight conserved fields (half of them clamped). Checked: every read (one
lookup, so one op) totals what was funded with no field below 0, the source never moves, a
sum view over the accounts always answers the funded total, and a transfer is refused only as
`out_of_bounds`.

With `--keys` (the default), each transfer is sent as Botpike sends one. It carries a fresh
128-bit key and is retried exactly as `retry` retries (`keyed.clj` holds the code both share:
lost and discarded replies, resends to another gateway, the final phase). The same transaction
writes a record in the `transfers` record table (table `0x80000014`; id the key; `from` and `to`
as indexes of the eight conserved fields, and the requested `amount`), and the bootstrap
declares an index by `from` and a `count` view over the table. A transfer ends `:ok` on a `2xx`,
`:fail` with Nerva's status on a `409` refusal (`out_of_bounds`, which no key outlives, unless
an earlier attempt of the key got no answer: then the op is `:info` and the key is resent after
healing, in case the original commits later), `:fail :refused` if only gateways refused it (a
`503 views_busy` or `413 views_too_large` included), else `:info`; keys without a definite
answer are resent after healing, and then every record is read through the index (eight
`from` keys, paged) and the count view. Conservation alone cannot see a duplicate transfer, so
also checked: `duplicate`
(every `2xx` for a key names the same op), `missing` (every key that committed has a record),
`extra` (every record is of a key that committed, or may have: an attempt got no answer),
`duplicated` and `wrong` (one record per key, with the transfer's `from`, `to` and `amount`), and
`count-view` (the view equals the records listed, which lie between the committed keys and those
that may have committed). A key refused after an attempt of it committed makes the run invalid
(`refused-after-commit`: keys are kept forever, so a resend replays), and so does a final-phase
refusal that is not `out_of_bounds`; so does a record of a key that only a refusal answered
(`refused-with-record`: the key committed, so a refusal means the cluster lost it). A key no `2xx` or refusal answered (one after an attempt
that got no answer counts only in the final phase) makes the result `:unknown`.
Each transfer reads its record as absent (`op_seen "0"`) before putting it, so a second
application of a key (a lost original, then a re-execution) is refused `409 conflict`, which the
`refusals` checker fails; a duplicate whose two `2xx` replies both arrived is `duplicate`. `--no-keys` is today's run, with no key and no record; `test-all` runs both, as `nerva bank`
and `nerva bank no-keys` (the reporter files the latter as workload `bank-no-keys`).

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
