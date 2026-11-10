# Nerva in production: the R milestones

*Written 2026-11-04 from `main` at `feb0724`, after a review of Nerva and of how its first client,
Botpike, uses it. Every fact below names its source. Nothing here is built unless its status says
so.*

Nerva's engine already does what Botpike's money needs:

- conserved, floored ledgers (N75);
- commit keys (P123);
- records and indexes in the same transaction (P123b, P123c);
- a VOPR that checks conservation after every commit.

What stands between it and strangers' money is around the engine:

- proof under real faults;
- an always-on search for bugs;
- memory and latency understood on the real topology;
- a gateway that never leaves an outcome ambiguous and can be watched;
- a lost replica replaced without closing the cluster;
- upgrades without downtime;
- bounded growth.

These are milestones R1 to R7. Each ends in a demo that runs for real and becomes an automated
test, `zig build demo-rN` or a CI job. A milestone is marked **delivered** only when that demo is
green in CI, with a link to the run.

## Status

| Milestone | What it adds | Status |
| --- | --- | --- |
| R1 · Proven | Jepsen nightly on a dedicated host: commit keys under unknown outcomes, the gateway killed and cut off | In progress (the retry, bank-keys and gateway workloads and the nightly workflow are merged and run on GitHub-hosted runners; the dedicated host is not provisioned) |
| R2 · Fleet | An always-on VOPR and fuzzer fleet on Hetzner that files every new failure | In progress (scripts and reporter written; host not provisioned) |
| R3 · Measured | Sizing and latency on the real topology: three machines, the Fly p99 explained | Not started |
| R4 · Gateway | Beside its client, never ambiguous, observable: a gateway per client process, no ambiguous 503, metrics | Delivered 2026-11-06 ([demo](https://github.com/NervaLog/nerva/actions/runs/42136037296/job/127624296815), [docs/demos/r4.md](./demos/r4.md)) |
| R5 · Recover | Replace a lost replica, and restore from a backup, with the cluster open | Delivered 2026-11-05 ([demo](https://github.com/NervaLog/nerva/actions/runs/41997293568/job/127143488126), [docs/demos/r5.md](./demos/r5.md)) |
| R6 · Upgrade | Rolling upgrades between releases with the same data format | Not started |
| R7 · Retention | Commit keys, history and view versions trimmed below a horizon: bounded growth | Not started |
| R8 · Native client | The client library over a C ABI, called from the JVM: no gateway, no JSON, batching as TigerBeetle's clients do | Not started |

**The gate for strangers' money** (Botpike's invite-only launch on Nerva, Botpike/app P121b) is
R1 to R5. R6, R7 and R8 follow. Until R6, an upgrade is an export and import with the cluster closed,
as today (README, "Upgrading a cluster").

## R1 · Proven: Jepsen, nightly, on what the client actually does

**Goal:** the histories Botpike produces are checked under real faults every night, against every
commit on `main`.

**Why:** Jepsen ran once, by hand, against v0.4.0 (WORKLOG, 2026-10-06; all runs valid). It has
never run against commit keys, records, the layout cache (P135) or request grouping (P143). The
bank workload sends no commit key. #107 is the CI runner running out of memory, not a Nerva
failure: 5 replicas at about 1.33 GiB plus a 4 GB JVM on an 8 GB runner.

**Scope:**

- **A dedicated host.** The R2 Hetzner box (64 GB), with Jepsen taking the fleet's place for its
  nightly hour. This answers #106's open question of where to run it.
- **Finish #106:** a nightly run that files its failures as issues, with its two fixes (a random
  cluster key, `authorized_keys` that sshd accepts).
- **Workload `retry`:** keyed commits whose replies are lost on purpose (timeouts, 503s, a
  gateway killed mid-request, #120), retried under the same key. Checked: each key commits at
  most once, and the reply to a retry names the original op.
- **Workload `bank` with keys:** today's conservation check, with every transfer under a key and
  records written beside it.
- **New nemeses:**
  - kill a gateway alone;
  - partition a gateway from its replica while both run;
  - pause a gateway.
- **Later in R1:** LazyFS (lost fsyncs) and clock faults on separate machines.

**Demo script:**

1. `tests/jepsen/run.sh zig-out/bin/nerva test --workload retry --nemesis kill,partition,gateway --time-limit 3600`: valid.
2. The same with `bank` and keys: valid; conservation holds; no key commits twice.
3. A build with commit-key deduplication switched off by a test-only flag: Jepsen reports the
   duplicate. This shows the check has teeth.

**Acceptance:**

- [ ] The nightly run is green for 7 nights on `main`.
- [ ] #107 is closed by a passing run.
- [ ] A failure files an issue with the seed, the history and the commit.

## R2 · Fleet: the VOPR never stops

**Goal:** the simulator searches for bugs around the clock, and every new failure becomes an
issue with a command that replays it.

**Why:** CI runs about 300 VOPR seeds per push to `main` (ci.yml, `vopr_main`; N74). One seed
takes 1 to 8 s in ReleaseSafe (N74). A dedicated 8-core host runs roughly 150,000 to 250,000 seeds
a day, about a thousand times more. N74 and N82 already name a Hetzner fleet as the next step.

**Scope:** Zigcube's fleet (`Zigbox/zigcube`, `ops/sim-fleet/`), adapted:

- `ops/sim-fleet/` polls `main`, builds each new tip once, and runs:
  - the VOPR on the `nerva` and `testing` state machines;
  - the 16 fuzzers.
- A reporter files one issue per distinct failure. The fingerprint is the state machine, the
  exit class (127 crash, 128 liveness, 129 correctness) and a normalised signature, never the
  seed or the commit.
- It comments on known failures, at most a few times a day, and posts a daily total on a tracker
  issue. A missing post is the outage alarm.
- Its token can only write issues on this repository.
- Native ReleaseSafe only, no WASM: Nerva has no browser target, and a native seed already replays
  exactly.

**Demo script:**

1. Start the service on a fresh host: within an hour, the tracker shows seeds per kind.
2. Push a commit to a scratch branch with a test-only fault (a conservation slip): the fleet files
   one issue with a replay command, and comments, rather than filing again, on the next commit.

**Acceptance:**

- [ ] 7 days of daily posts.
- [ ] One canary failure filed and deduplicated.
- [ ] **Release gate:** no open `sim-fleet` issue against a release candidate, and the fleet has
  run 24 hours on it.

## R3 · Measured: the real topology, and the memory it needs

**Goal:** sizing and latency come from three replicas on three machines with real disks, not from
one sandbox.

**Why:**

- **Never measured:** every number so far ran the replicas, the gateway and the benchmark on one
  host (#91, #134).
- **The Fly tail:** the nightly on Fly shows p99 of 147 to 188 ms against 20 to 30 ms locally,
  and nobody knows why.
- **Memory:** a replica takes about 3.0 GB at the defaults (#127). Botpike's Machines have 4 GB
  and also run a gateway.
- **The hot set:** the row cache defaults to its minimum, so hot account rows are probably not
  cached (README, "Caches").

**Scope:**

- **`perf/fly/`** runs three replicas on three Machines, with the benchmark and gateways on
  others, and records p50, p99 and p99.9 with checkpoints marked.
- **The p99 tail** is explained: checkpoints, compaction or IO, with a trace (N50).
- **A sizing table** goes in the README, by working set: the memory each cache takes, and what
  `--cache-grid` and the row cache cost and save. This closes #127's open half.
- **A replica refuses to start** when its configured caches exceed the memory it can see, with a
  message naming the flag. Today it starts and is killed later.

**Demo script:** `perf/fly/run.sh --topology 3+1` prints the table. A second run on the same
commit lands within 10%.

**Acceptance:**

- [ ] The README's numbers come from this run.
- [ ] The p99 cause is named in a decision.
- [ ] Botpike's Machine size follows from the table.

## R4 · Gateway: beside its client, honest and observable

**Goal:** a gateway runs beside the process it serves, never as a shared hop in between. Its
client can always tell "not applied" from "unknown", and the operator can see what it does.

**Why:**

- **A shared gateway is an extra network hop and a shared failure** for the clients behind it
  (owner, 2026-11-04, P147g). Botpike runs one beside each replica and reaches it over the
  network, with a cap of 12 callers per gateway, so a second app Machine already needs
  re-tuning (Botpike/app P99b, P120).
- **A gateway on the client's own machine fails only with that client.** It is reached on
  loopback, so its plain HTTP and its key never cross a network. Each client process gets its
  own cluster session, so capacity grows with the clients.

- **#120:** a busy gateway can close a request mid-send, so a client sees a 503 it cannot tell
  from a lost commit.
- **No metrics (until R4 slice 4, P168e, P176):** gateways exported nothing; only replicas sent
  statsd (N50). `nerva api --statsd` now sends them.
- **One session per gateway:** each gateway holds one cluster session and runs one cluster request
  at a time (`src/nerva/api/server.zig:1-6`). Several gateways are the way to scale, but nothing
  says how.

**Scope:**

- **Refuse before reading.** A request the gateway cannot take is refused before its body is read
  or sent, with `503` and `"applied": false`. A 503 after sending says `"applied": "unknown"`.
  Documented per route. This closes #120.
- **The listener stops setting `SO_REUSEPORT`** (#112), so a second process cannot take the port.
- **Gateway metrics** over the replicas' statsd:
  - requests and replies by route and status;
  - group sizes (P143);
  - displacements;
  - cluster-request latency;
  - session reconnects.
- **The sidecar topology is the documented one.** "Running a cluster" in the README shows
  `nerva api` on `127.0.0.1` beside each client process, connected to every replica. It also
  covers sessions against `clients_max` (64, `src/config.zig:222`), eviction, and which ports
  clients need, as against replicas only.
- **A gateway that loses its cluster says so on `/healthz` within one timeout,** so the process
  beside it can stop taking work rather than queue.
- **Several gateways in a test:** two on one cluster, with one killed.
- **Error codes on the wire.** Every error reply gains `"code"` from `docs/ERRORS.md` (P147c); body too large
  becomes 413, and "not yet committed" one status on every route.
- ~~**Conservation as a metric.**~~ Cut from R4 (P168, answer 5): replicas hold no ledger totals,
  and a total kept from applied deltas is zero by construction. A true one needs a scan or a
  persisted total; it is replica work, left for later.

**Demo script:**

0. Three replicas, and two client processes each with its own gateway on loopback. Killing one
   client's gateway stops only that client.
1. 32 callers against a 16-slot gateway: every refused request says `"applied": false`, and no
   keyed commit is lost or doubled.
2. The gateway's statsd counts equal the refusals the callers saw (statsd is pushed; there is no
   endpoint).
3. One client's gateway killed and restarted on the same port: its retries apply once, under
   their keys (a sidecar has no second gateway to fail over to; P168). The full demo is
   `docs/briefs/r4.md`, "The demo".

**Acceptance:**

- [ ] `test:api` gains the refusal cases.
- [ ] `demo_r4` is green in CI (R4 is delivered on this, P168 answer 7).
- [ ] Jepsen R1 runs with two gateways per node (after R1's nightly runs; Botpike's gate waits for it).
- [ ] #120 and #112 are closed.

## R5 · Recover: a lost replica, and a restore, with the cluster open

**Goal:** a replica whose disk is gone rejoins without closing the cluster, and a backup restores
to the same view hashes.

**Why:**

- **A lost replica closes the cluster today.** It means exporting and importing all three; the
  cluster is closed, and importing only the lost replica is unsafe (README, "Upgrading a
  cluster"; P90; #94).
- **The protocol can already do it.** The vendored VSR supports a reformatted replica rejoining by
  state sync, and the VOPR exercises it (`src/vopr.zig:423-436, 514`). What is missing is a
  command, and safety for clusters that were imported (P90).
- **Backups are untested.** The only backup is `nerva export` of a live cluster. Botpike's restore
  drill is a monthly manual step (Botpike/app `docs/runbooks/nerva.md`).

**Scope:**

- **`nerva recover`** formats a replica into an existing cluster, imported or not, that then
  catches up by state sync.
  - It refuses when the other replicas cannot form a quorum.
  - It refuses for a replica that is still alive.
  - It is checked by the VOPR, including on imported clusters.
- **`nerva backup` and `nerva restore`:** an export with a manifest of the op, the SHA-256 and every
  view hash, and a restore that checks the manifest before opening.
- **`test:release`** gains a restore and a recover.
- **Coded operator diagnostics.** Every `nerva` command prints `error[NRV-E…]` with a cause and a fix
  (`docs/ERRORS.md`). The panics on operator input (another release's data file, #95; a missing or
  damaged file; a held lock) become refusals.

**Demo script:**

1. A three-replica cluster takes keyed commits.
2. Replica 2's data file is deleted and the replica restarted with `nerva recover`.
3. Writes continue throughout.
4. Replica 2 catches up, and every view hash agrees.
5. `nerva backup`, wipe, `nerva restore`: the same hashes.

**Acceptance:**

- [ ] The demo runs in CI.
- [ ] VOPR seeds with reformats pass on imported clusters.
- [ ] #94 is closed.

## R6 · Upgrade: rolling, when the format allows

**Goal:** a release that keeps the data format upgrades one replica at a time, with the cluster
open.

**Why:**

- **Every upgrade closes the cluster today.** Replicas of different releases ignore each other
  (N61), so an export and import is needed with the cluster closed.
- **The downtime grows.** It takes about 14 s per million changes (README) and grows with all
  history (see R7).
- **The pieces are vendored but unused.** TigerBeetle's multiversion binaries do this
  (`src/multiversion.zig`, kept but unused, UPSTREAM.md).

**Scope:**

- Releases declare whether they change the format.
- A format-compatible release upgrades rolling, through multiversion binaries.
- A format change still goes by export and import, and the release notes say which applies.
- `test:release` upgrades a running cluster under load.

**Demo script:** three replicas on release N take load while each is replaced in turn by N+1. No
request fails except as retried under its key, and the view hashes agree before and after.

## R7 · Retention: bounded growth

**Goal:** what Nerva keeps for reading the past is kept for a declared horizon, then trimmed, so
disk use, export and import stay bounded.

**Why:** commit keys are kept forever (README, "Commit keys"), and history, changes and view versions
have no retention (README, roadmap item 6; GOALS-1.0).

**Scope:**

- A horizon per kind, declared in the log: commit keys, row history, view versions.
- Compaction drops what is older, deterministically.
- A key older than its horizon answers `key_expired`, never "committed again".
- As-of reads before the horizon answer `before_horizon`.

**Demo script:** a cluster with a 1-day horizon at simulated time. Data, export time and memory
stay flat across 30 simulated days of load. A retry of an expired key is refused as expired.

## R8 · Native client: no gateway in the client's path

**Goal:** a JVM client speaks to the cluster through Nerva's own client library, without a
gateway or JSON, and concurrent callers share one op the way TigerBeetle's clients batch.

**Why:**
- **The gateway is a translation step.** It turns each JSON request into a cluster request,
  grouping at most 16 (P143), where TigerBeetle's clients put up to about 8,000 events in one op.
- **Botpike is a JVM application.** Java 21's foreign-function API calls a C ABI directly, as
  TigerBeetle's Java client does with its native library.
- **The gateway stays** as the language-neutral API other clients use (N39). It just leaves the
  path of a client that has the library.

**Scope:**
- `src/nerva/client.zig` gains a C ABI and a binary encoding of commits, lookups and their
  results, versioned and documented as a wire format.
- A small JVM binding, published with each release, with the native library for Linux x86_64 and
  aarch64.
- Automatic batching of concurrent calls into one op, bounded.
- Typed errors carrying the codes in `docs/ERRORS.md`.

**Demo script:** Botpike's ledger load (`apps/ledger-load`) runs through the binding, with no
gateway. Submits per second and p99 are compared with the sidecar gateway's on the R3 topology.

**Acceptance:**
- [ ] The binding passes the gateway's model tests (`test:api`'s model) for every operation it
  offers.
- [ ] Jepsen's `retry` workload passes through it.

## Order

```text
R2 Fleet ──▶ R1 Proven (shares its host) ──▶ R4 Gateway ──▶ Botpike's gate (R1-R5)
R3 Measured ──────────────────────────────▶ Machine size
R5 Recover ───────────────────────────────▶
                                            R6 Upgrade ──▶ R7 Retention ──▶ R8 Native client
```

- **R2 first:** the host is the same one R1 needs.
- **R3 and R5** run beside them.
- **R4 needs R1's `retry` workload** to prove its refusals.

## Not here

These are Botpike's side, in Botpike/app `docs/specs/runs-on-zigcube/` and `docs/launch.md`:

- moving the pin from v0.5.0 to v0.6.1;
- commit keys in place of P99's read-back;
- one consensus op per submit;
- paging on conservation.

Also not here:

- **TLS on the gateway.** Botpike reaches it over Fly's private WireGuard network.
- **External correctness review.** It remains an owner-accepted risk (GOALS-1.0, non-goals).
