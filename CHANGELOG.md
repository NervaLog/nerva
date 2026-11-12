# Changelog

What changed in each release, for people running Nerva or building on it. The release workflow
publishes a version's section as its GitHub release notes, and refuses to release a version
without one. Design reasons are in [docs/DECISIONS.md](./docs/DECISIONS.md); the full log of
work is [WORKLOG.md](./WORKLOG.md).

## Unreleased (v0.7.2)

### Upgrading from v0.7.1

- **Gateway keys need 32 bytes (#335).** `nerva api` and `nerva view` refuse a `NERVA_KEY` or
  `NERVA_KEY_NEXT` shorter than 32 bytes, or one with leading or trailing space or tab or a control
  byte (`NRV-E0008`). Before upgrading, rotate a gateway key shorter than 32 bytes through
  `NERVA_KEY_NEXT`: set `NERVA_KEY_NEXT=$(openssl rand -hex 32)`, move clients to it, then make it
  `NERVA_KEY` ([README, Limits](./README.md#limits)).
- **The development cluster key is refused off loopback (#336).** `nerva start` refuses
  `NERVA_CLUSTER_KEY` or `NERVA_CLUSTER_KEY_NEXT` equal to the published development key unless
  every address is loopback (`NRV-E0901`).

## v0.7.1 — 2026-11-11

The first Nerva release for people outside the project. It changes no data file, protocol or
state machine: what is new is how you install it, what it tells you about itself, and the pages
that say how to run it. **Upgrading from v0.7.0 is a binary swap, one replica at a time, then the
gateways** ("Upgrading from v0.7.0", below).

**Maturity: alpha** ([docs/MATURITY.md](https://github.com/NervaLog/nerva/blob/main/docs/MATURITY.md)).
Try Nerva, report what breaks, and expect at least one export and import before 1.0. Do not keep
real money, or data you cannot rebuild elsewhere, only in Nerva. What the label promises about
your data:

- v0.7.x data files open in place in every v0.7.x release whose notes say so; this one does
  ([the audit](https://github.com/NervaLog/nerva/blob/main/docs/releases/v0.7.1-audit.md)).
- The next protocol release, the first with rolling upgrades (R6), moves by `nerva export` with
  the old release and `nerva import` with the new one (P259g).
- An export (format version 1 or 2) is read by at least the next release (N80).
- Wire identifiers (`conflict`, `out_of_bounds`, `key_reused` and the rest) and `NRV-` codes keep
  their spelling. Anything else in the API may change, with notes here.

### Install

[docs/INSTALL.md](https://github.com/NervaLog/nerva/blob/main/docs/INSTALL.md) covers each download
and how to check it; [docs/QUICKSTART.md](https://github.com/NervaLog/nerva/blob/main/docs/QUICKSTART.md)
takes you from a download to three replicas, a gateway and a first commit.

- **macOS** (development and evaluation, not production): `brew install nervalog/tap/nerva`, or
  `nerva-v0.7.1-universal-macos.zip`, one universal binary (arm64 and x86_64) checked against
  `nerva-v0.7.1-universal-macos.zip.sha256`. Both are signed with a Developer ID and notarized by
  Apple. The `nerva-v0.7.1-aarch64-macos.tar.gz` and `nerva-v0.7.1-x86_64-macos.tar.gz` assets
  stay, with the same names and layout as before, for scripts that pin them. They are not
  notarized: the arm64 binary is signed ad hoc and the x86_64 one is unsigned, so Gatekeeper may
  block them. On a Mac, take Homebrew or the zip.
- **Linux, with systemd:** `nerva-v0.7.1-<x86_64|aarch64>-linux.tar.gz` now holds `install.sh`,
  two systemd units (`nerva@.service` for a replica, `nerva-api@.service` for a gateway) and two
  commented settings examples beside the binary. `sudo ./install.sh` installs the binary in
  `/usr/local/bin`, creates the `nerva` user, `/var/lib/nerva` and `/etc/nerva`, and installs the
  units. It formats, enables and starts nothing; `--dry-run` says what it would do. A refusal is
  one coded block (headline, cause, fix), NRV-E1101 to NRV-E1109; the packages refuse with
  NRV-E1105 or NRV-E1111.
- **Linux packages, new:** `nerva_0.7.1-1_amd64.deb`, `nerva_0.7.1-1_arm64.deb`,
  `nerva-0.7.1-1.x86_64.rpm` and `nerva-0.7.1-1.aarch64.rpm`, with the same binary, units and
  examples (the examples in `/usr/share/nerva`). **They are not signed** and there is no apt or
  dnf repository yet (#296): check the file against `SHA256SUMS`, then install it from disk.

  ```bash
  sudo apt install ./nerva_0.7.1-1_amd64.deb      # Debian 12, Ubuntu 24.04
  sudo dnf install ./nerva-0.7.1-1.x86_64.rpm     # Rocky 9, Fedora
  ```

  On Fedora use `dnf`: its rpm refuses an unsigned file with `rpm -i` or `rpm -U` unless you add
  `--nosignature`.
- **Linux, by hand:** the tarball's `nerva` runs from anywhere (QUICKSTART.md, "One machine").
- `SHA256SUMS` covers the tarballs, the packages and the bill of materials
  (`nerva-v0.7.1.cdx.json`); the Mac zip has its own `.sha256`.

### New: `nerva version` names the release

`nerva version` prints one more line, last:

```
Nerva version 0.0.6+<commit>
release 0.0.6
release_client_min 0.0.4
format a2d6e50b122836b2b596f8548a391e77c3b2beead93ee5e30939479601259362
bundles none
version 0.7.1
```

`version 0.7.1` is the release you downloaded. The first five lines are unchanged, and the format
digest is the same as v0.7.0's, because the data format is. `--verbose` prints this line before
its own, and now ends with `commit_keys deduplicate`: `release.yml` refuses to ship a binary
without it (NRV-E1113, #271). **Scripts still read the first line only** (`nerva version | head -n1`): one that takes
the last word of the whole output now gets `0.7.1`, which is not the protocol release.

### New documentation

Written for someone who did not build Nerva:

- [docs/INSTALL.md](https://github.com/NervaLog/nerva/blob/main/docs/INSTALL.md): every download,
  `install.sh`, the packages, checking `SHA256SUMS` and the SBOM.
- [docs/QUICKSTART.md](https://github.com/NervaLog/nerva/blob/main/docs/QUICKSTART.md): one
  machine, then three hosts with a cluster key and the units.
- [docs/OPERATING.md](https://github.com/NervaLog/nerva/blob/main/docs/OPERATING.md): sizing, a
  production checklist, backups and a restore drill, upgrades, what to alert on, the 64 client
  sessions.
- [docs/API.md](https://github.com/NervaLog/nerva/blob/main/docs/API.md): every route of
  `nerva api` and `nerva view`, with its request, reply, statuses and codes.
- [docs/TROUBLESHOOTING.md](https://github.com/NervaLog/nerva/blob/main/docs/TROUBLESHOOTING.md):
  from a symptom (a `503`, `applied: "unknown"`, a replica that exits or will not join, an
  installer refusal) to its code and fix.
- [SECURITY.md](https://github.com/NervaLog/nerva/blob/main/SECURITY.md): what `NERVA_KEY` and
  the cluster key protect and what they do not, and how to report a vulnerability.
- [docs/MATURITY.md](https://github.com/NervaLog/nerva/blob/main/docs/MATURITY.md) and
  [docs/NON-GOALS.md](https://github.com/NervaLog/nerva/blob/main/docs/NON-GOALS.md): the label,
  and what Nerva does not do (no SQL, no TLS, no per-user authorization, no encryption at rest,
  no retention or rolling upgrades yet).

The README's first line no longer says "toy / research": it gives the label and links these pages.

### Fixed

- **#278:** CI had never run Nerva on macOS. CI now builds the universal binary on a Mac, runs a
  smoke test on Apple silicon and on Intel (three replicas, a gateway with `--statsd`, a commit, a
  lookup, the change feed) and the unit tests on Apple silicon (#293). `zig build -Drelease
  mac-release` builds, signs, zips and notarizes the universal binary and writes the Homebrew
  formula (#291). CI runs it on a Mac, ad hoc and not notarized (`-Dsign-identity=-`), and checks
  its zip (#315); the Developer ID signature and the notarization run only on the owner's Mac.
- **#271:** the release workflow did not check that the binary it publishes deduplicates commit
  keys. It now refuses a binary built with `-Dtest-commit-keys=off`, and checks that the
  `version` line matches the release (#311).
- **#288:** `nerva start` right after the previous process was killed could refuse with
  NRV-E0703 ("data file locked"), because the kernel can hold a killed process's lock for a
  moment. Pre-flight now waits up to 2 s for the lock (#290). A lock that stays held is refused as
  before.
- v0.7.0's `nerva version` named the protocol release (`0.0.6`) and never the release you
  downloaded: see "`nerva version` names the release" above (#291).

### What was tested

The release candidate is `main` at `TO FILL: candidate SHA`. The figures below are filled in
after the soak and the reviews, and are quoted here from their records. **TO FILL** marks what
is not in yet.

- **Simulation:** **TO FILL** (the `sim_fleet.py soak --commit <candidate>` line: at least
  24.0 hours of fleet rounds on the candidate, and no open `sim-fleet` issue against it).
- **Jepsen:** **TO FILL** (the night's `jepsen/nightly` status on the candidate: `retry` and
  `bank` valid, kill and partition nemeses, with its link).
- **Two adversarial reviews** (P147b): **TO FILL** (each reviewer's verdict, and its
  `release-review` issues).
- **macOS:** the owner builds, signs and notarizes the zip on a Mac and uploads it to the draft
  release. The `mac-verify` workflow then checks it on Apple silicon and on Intel: the zip against
  its checksum, the binary's version and commit, its Developer ID signature, hardened runtime and
  secure timestamp, and the smoke test; it is run on the draft before publishing, and once the
  release is published its run also does `brew install nervalog/tap/nerva && brew test nerva`.
  Those runs are listed under Actions, "Mac verify", for tag v0.7.1.
- **Mixed releases** (P275): a v0.7.0 cluster with a v0.7.1 gateway, a rolling upgrade, a
  v0.7.0 gateway on v0.7.1 replicas, and a rollback, run by hand
  ([the audit](https://github.com/NervaLog/nerva/blob/main/docs/releases/v0.7.1-audit.md)).
- **Linux packages:** `packages.yml` installs the tarball under systemd (three replicas, a
  gateway, a kill, uninstall), and installs, upgrades, downgrades and removes each package in
  Ubuntu 24.04, Debian 12, Rocky 9 and Fedora.

### Upgrading from v0.7.0

**Replace the binary, one replica at a time, then the gateways, in any order.** v0.7.0 and v0.7.1
run the same protocol release (`release 0.0.6`), the same data file format (the same `format`
digest) and the same export format, and v0.7.1 sends no new kind of op and changes nothing in
the state machine ([the audit](https://github.com/NervaLog/nerva/blob/main/docs/releases/v0.7.1-audit.md),
P275). No export or import.

1. Take a backup first (`nerva backup`, OPERATING.md "Backups and a restore drill").
2. For each replica: stop it, replace the binary, start it, and wait until it has caught up
   before the next one: its `tb.replica_commit_min` gauge (`--statsd`) has reached the other
   replicas', or its log says `sync: done` if it state-synced. A cluster of three keeps its
   quorum while one replica is down.
3. Then each gateway (`nerva api`, `nerva view`), in any order.

With the tarball's `install.sh`, replicas and gateways on one host share `/usr/local/bin/nerva`,
and the gateway unit restarts on its own: stop that host's gateways before you swap the binary
(OPERATING.md, "Upgrading"). `install.sh --upgrade` replaces the binary; stop the host's replicas
first.

**Rolling back to v0.7.0** is the same swap the other way, and is safe: neither release sends an
op the other cannot run, and v0.7.0 opens what v0.7.1 writes (tested, see the audit).

### Upgrading from v0.6.1

v0.6.1, v0.7.0 and v0.7.1 share release `0.0.6`, so they can share a cluster, and v0.7.0's order
still applies (P260): **every replica first, then the gateways.** A v0.6.1 replica panics on an
op of several resent keyed transactions over `min`/`max` view members (#254, #255), and a v0.7.x
gateway combines requests into such ops.

1. Check that no v0.7.x gateway and no client that sends several batches in one request runs
   against the cluster.
2. Upgrade the replicas to v0.7.1 one at a time, as in step 2 above. Wait for the gauge or
   `sync: done`, not for a log line saying it is committing: no replica writes that line, and
   v0.7.0's notes were wrong to ask for it (#308).
3. Only when every replica runs v0.7.1 (`nerva version | head -n1` on each), upgrade the gateways.

Roll back to v0.6.1 only if no v0.7.x gateway and no multi-batch client has run since you began.
Gateways that bind beyond loopback need `--listen-remote` (v0.7.0's notes, #183).

**Botpike:** bump the replicas' pin before the app's gateway (Botpike/app#159), and parse only
the first line of `nerva version` (Botpike/app#160): taking the last word of the whole output now
gives `0.7.1`.

### Known issues

Open issues an operator should know about before relying on this release:

- **#302:** `nerva export` and `nerva backup` create their files and manifests world-readable
  (0644). Run them under `umask 077`, into a directory only the `nerva` user can read.
- **#303:** a replica's client port takes no key. Anyone who reaches it can take all 64 client
  sessions, which evicts every gateway, or declare a view that blocks a later `nerva import`.
  Let only the replicas, the gateways and the hosts that run backup, export or recover reach it
  (SECURITY.md).
- **#306:** the settings examples' placeholder keys pass the length check. Replace both
  `NERVA_CLUSTER_KEY` and `NERVA_KEY` before you start anything, or the cluster runs on a key
  published in this repository.
- **#304:** a replica's exit statuses 3 and 6 print vendored text with no NRV code; exit 3 names a
  flag Nerva does not have (TROUBLESHOOTING.md, "A replica exits").
- **#300:** every flag refusal says to run `nerva <command> --help`, which is itself refused.
  Run `nerva --help`.
- **#294:** a replica refused with NRV-E0703 after a crash exits 1, and `nerva@.service` does not
  restart on exit 1, so it stays down until you start it. Pre-flight's 2 s wait is a bound, not
  a check of who holds the lock.
- **#292:** `install.sh --upgrade` does not check that the replicas are stopped, and does not
  warn when a package's `/usr/bin/nerva` is shadowed by `/usr/local/bin/nerva`.
- **#296:** the `.deb` and `.rpm` are unsigned, and there is no package repository.

## v0.7.0 — 2026-11-10

A lost replica can now be replaced while the cluster stays open, and a cluster can be backed up
and restored with a record kept apart from the backup (R5). Each client process can have its own
`nerva api` gateway on loopback: every connection gets a reply with a status line, every refusal
says whether anything was applied, and the gateway sends metrics (R4). Every failure a command or
the JSON API reports now has a stable code (`NRV-…`, [docs/ERRORS.md](./docs/ERRORS.md)). **Data
files, the replica protocol and the export format do not change.** The protocol release is still
`0.0.6`, so replicas upgrade in place with no export or import. **`nerva api` and `nerva view`
now refuse a non-loopback `--listen` unless you pass `--listen-remote`:** see "Upgrading from
v0.6.1" below.

### New: `nerva recover` replaces a lost replica with the cluster open (R5, #94)

When a replica's disk is lost, `recover` builds a new data file for that replica from the running
cluster. The new replica then catches up by repair or state sync. You need at least three
replicas, and must recover one at a time:

```bash
# The lost replica is destroyed first. On its replacement host:
nerva recover --cluster=0 --replica=2 --replica-count=3 --addresses=3001,3002,3003 \
    --origin=none 0_2.nerva
nerva start --addresses=3001,3002,3003 0_2.nerva
```

- `--origin` has no default. Pass `none` for a cluster made with `nerva format`. For a cluster
  made with `import` or `restore`, pass the SHA-256 of the export it was made from. With the
  wrong origin, the replica exits with status 8 and `NRV-E0711` when it starts.
- `recover` refuses while the lost replica's address still answers (`NRV-E0713`) and when fewer
  than a quorum of the other replicas run (`NRV-E0712`). If a `recover` is killed, its
  `<path>.recovering` file blocks the next attempt (`NRV-E0715`) until you remove it.
- The new data file's view is two past the cluster's, so the replacement never contradicts
  what the lost replica promised (TigerBeetle's `replica_reformat`, P149b).

### New: `nerva backup` and `nerva restore` (R5)

```bash
nerva backup --cluster=0 --addresses=3001,3002,3003 --output=b.nerva-backup
# backup b.nerva-backup: op 10001, sha256 521eb1ce3f94...
# manifest b.nerva-backup.manifest.json
nerva restore --cluster=0 --replica=0 --replica-count=3 --input=b.nerva-backup \
    --manifest=b.nerva-backup.manifest.json 0_0.nerva      # and --replica=1, 2
```

- A backup is a normal export (format version 1 or 2, as before) plus a JSON manifest
  (`"format":"nerva-backup","version":1`). The manifest records the release, the op, the
  export's SHA-256 and size, and every view hash and ledger total. `backup` reads the export
  back through `import`'s checks before it writes the manifest. It never overwrites either file
  (`NRV-E0004`).
- `restore` compares the backup with its manifest before it creates any file. On a mismatch it
  refuses with `NRV-E0809`, naming the first difference. A missing, malformed or
  unknown-version manifest is `NRV-E0808`, and a damaged backup is `NRV-E0804`.
- For a restore drill, use another `--cluster` id. That restores the backup beside the running
  cluster, so you can compare the drill's view hashes and ledger totals with the manifest.

### New: each client process can have its own gateway (R4)

```bash
NERVA_KEY=secret nerva api --cluster=1 --addresses=10.0.0.1:3001,10.0.0.2:3001,10.0.0.3:3001 \
    --listen=127.0.0.1:8080 --request-timeout=4000 --statsd=127.0.0.1:9125
```

- **Every connection gets a reply.** When all 16 slots are busy, the gateway answers
  `503 {"error":"busy","applied":false,"code":"NRV-E0602"}` and does not read the request.
  Before, it closed the request mid-send (#120). A request that has not arrived whole after
  10 s gets `408`, NRV-E0116. A second gateway on the same port now exits with NRV-E0007.
  Before, both shared the port through `SO_REUSEPORT` (#112).
- **`applied` and `code` on every reply that is not `2xx`**, beside the `error` or `status`
  each reply already had. Those strings keep their spelling (P168b, P173c). With
  `"applied": false`, the request is safe to send again. With `"applied": "unknown"`, a write
  went out and no reply came back. Send a `/v1/commit` again only under its `key`, or read the
  rows to find out what happened. A replayed commit answers `200` with
  `"replayed":true,"code":"NRV-W0201"`.
- **`--request-timeout=<ms>`** (`nerva api`, `nerva view`; default 30000) sets one deadline for
  each HTTP request. It covers every cluster call that request makes, a reconnection included
  (#186). The gateway answers a request within 1 s of queue wait, plus `--request-timeout`,
  plus 1 s: 32 s by default. When less than a sixteenth of the deadline is left, the gateway
  does not send the call. It answers `503` NRV-E0606, nothing is sent, and the session stays
  open (P209). Set this flag below your client's own timeout.
- **An idle gateway checks its cluster.** It sends one read whenever it has had no reply for
  5 s, so `/healthz` turns `503` (NRV-E0605) within 5 s plus `--request-timeout` of the cluster
  going away.
- **`nerva api --statsd=<host:port>`** sends `nerva.api.*` metrics every 10 s: requests by route
  and status, refusals by reason, `unknown` outcomes (page on these), group sizes, cluster
  latency, queue wait, reconnects, session state and connections. README, "Gateway metrics",
  lists them.
- **Commits and lookups that wait together are combined** into one cluster request, at most 16
  of them. Each request still gets the reply it would have had alone (P143). With 12 callers on
  one 4-CPU machine, one gateway went from about 340 to about 1,400 Botpike-shaped submits per
  second, and its p99 latency fell from about 75 ms to about 30 ms.
- **`/v1/documents/commit` takes a commit `key`**, as `/v1/commit` does. A resend answers
  `replayed` and applies nothing (P180). A malformed key is NRV-E0109 on every route (P180b).

### New: coded errors everywhere

- A command that refuses prints one `error[NRV-…]` block with its cause and fix. It exits 1 for
  bad operator input, 2 for an environment problem and 70 for a bug in Nerva (P149e).
  `nerva start`'s runtime exit statuses 2 to 8 are unchanged. Flag-parser errors are now
  NRV-E0001, still with exit status 1 (#167).
- Before a command opens a data file, a pre-flight check refuses bad input (a missing file,
  wrong sizes, a mismatched cluster) with a code, where TigerBeetle's vendored open would have
  panicked (P152).
- `nerva start --statsd` with an address this host cannot send to is refused with NRV-E0010 at
  start. Before, it was reported as a bug or as "cannot listen" (#181, #184).
- `nerva start --trace` removes its trace file when startup fails, panics or is stopped by
  SIGINT or SIGTERM, so the next start is no longer refused with NRV-E0004 (#197, P208).
- When 16 attempts in a row to declare a layout or a view lose to concurrent declarations, the
  gateway answers `503 {"error":"catalog busy","applied":"unknown","code":"NRV-E0313"}` and keeps
  its session. Before, it answered `cluster unavailable` and reconnected (#216, P228).

### New: `nerva version` prints the release and the data format (#269)

`nerva version` now prints five lines (`--verbose` prints the same):

```
Nerva version 0.0.6+b1ea448
release 0.0.6
release_client_min 0.0.4
format a2d6e50b122836b2b596f8548a391e77c3b2beead93ee5e30939479601259362
bundles none
```

The first line is what v0.6.1 printed. The next lines are the protocol release, the oldest
client release it accepts, the digest of the data format and the bundled extensions. **A script
that compares or parses the whole output must read only the first line:** `nerva version | head -n1`
(see "Upgrading from v0.6.1").

### Fixed

- **#276:** the v0.7.0 release run failed building the macOS binaries (`x86_64-macos` and
  `aarch64-macos`): the trace-file cleanup (#206) used Linux-only calls, and the gateway's metrics
  send used a flag that does not exist on macOS. Fixed in #277, which also adds a CI job that
  cross-compiles every release target. The macOS binaries have not been run on a Mac (#278).
- **#120:** a busy gateway closed a request mid-send, so the client could not tell whether it was
  applied. Fixed in #170.
- **#112:** two gateways could silently share one port through `SO_REUSEPORT`. Fixed in #170.
- **#172:** a full lingering table reset refused clients that were still sending. Fixed in #173
  (the table holds 128).
- **#174:** a gateway polled on `/healthz` at least once a second never replaced its broken
  cluster client. Fixed in #175.
- **#186:** `--request-timeout` bounded each cluster call, not the whole HTTP request. Fixed in
  #195 and #213.
- **#205:** a call started near the end of its deadline timed out and broke the session. Fixed in
  #209.
- **#216:** contention on a catalog write was reported as `cluster unavailable`. Fixed in #228.
- **#181, #184:** a `--statsd` address that cannot be used was reported as a bug or as the wrong
  layer's error. Fixed in #196.
- **#197:** after a failed start, `nerva start --trace` left an empty trace file behind. Fixed in
  #202 and #208.
- **#95:** a replica given a data file of another release panicked instead of refusing it.
  Pre-flight now refuses it (#152).
- **#141:** VOPR seed 10957567299726034325. The workload's `lookup_records` batches exceeded
  `event_max`, so the client was evicted (test workload only). Fixed in #142.
- **#226:** a `client.zig` test cast an unaligned stack array. Fixed in #227.
- **#254, #255:** a replica panicked, and panicked again on every restart, on an op that holds
  several resent keyed transactions that touch a view with `min` or `max` (`integer overflow` or
  `reached unreachable code` in the member prefetch). Every replica commits the same op, so every
  one of them panics. Fixed in #263 and #267. **A v0.6.1 replica has this bug.** A client that
  sends several batches in one request can trigger it, and so can a v0.7.0 gateway, which
  combines up to 16 requests into one op (P143). Every v0.6.1 operator should upgrade. Until
  then, do not send several batches in one request to a v0.6.1 cluster.

### Testing

- Jepsen (R1, in progress): the suite runs against real replicas and gateways. It covers commit
  keys under unknown outcomes, gateway kill and partition nemeses, and a keyed bank with records,
  and it can be dispatched from `jepsen.yml`. A nightly on a dedicated host files failures as
  issues (`ops/jepsen`). A test-only build, `-Dtest-commit-keys=off`, turns commit-key
  deduplication off so the suite can show that it detects duplicates. That build is never
  installed.
- The VOPR can start a cluster from an imported checkpoint (P159). It draws the primary's commit
  stall per seed (P143b), and it says when a run stops at TigerBeetle's liveness exemption
  (P171).
- `zig build demo-r4` and `zig build demo-r5` run in CI.

### Release review

The release candidate is `main` at `b1ea448`. Two independent reviewers reviewed it adversarially
before release (P147b), in two rounds. They first reviewed `a0a6a80`, whose issues are
[#270](https://github.com/NervaLog/nerva/issues/270),
[#271](https://github.com/NervaLog/nerva/issues/271),
[#272](https://github.com/NervaLog/nerva/issues/272) and
[#273](https://github.com/NervaLog/nerva/issues/273). #270 and #272 are why "Upgrading from
v0.6.1" gives an order and limits rollback.

The release run for `a0a6a80` failed on macOS (#276), so the candidate moved to `b1ea448` (#277,
and #269, which changes `nerva version`). Two new reviewers, given only `a0a6a80..b1ea448`,
reviewed that delta. Their issues are
[#279](https://github.com/NervaLog/nerva/issues/279),
[#280](https://github.com/NervaLog/nerva/issues/280),
[#281](https://github.com/NervaLog/nerva/issues/281),
[#282](https://github.com/NervaLog/nerva/issues/282) (a duplicate of
[#278](https://github.com/NervaLog/nerva/issues/278), running the macOS binaries on a Mac) and
[#276](https://github.com/NervaLog/nerva/issues/276). #279 and #281 are why this section's
"`nerva version`" notes exist.

### Upgrading from v0.6.1

**Order: replicas first, then gateways (#272, #270, P260).** The protocol release is unchanged
(`0.0.6`), so v0.6.1 and v0.7.0 replicas accept each other. That is a hazard, not only a
convenience: a v0.6.1 replica panics, and panics again on every restart, on an op of several
resent keyed transactions over `min`/`max` view members (#254, #255), and v0.7.0 gateways
combine requests into such ops. Do it in this order:

1. Check that no client sends several batches in one request, and that no v0.7.0 gateway
   (`nerva api`) runs against the cluster. A v0.6.1 gateway is safe: it does not combine requests.
2. Upgrade the replicas one at a time. Data files, the superblock, the replica protocol,
   `tree_ids`, `Operation` values and the export format are the same, so v0.7.0 replicas open
   v0.6.1 data files: no export or import. For each replica: stop it, start it with the v0.7.0
   binary, and wait for it to rejoin (its log says it is committing) before the next one.
3. Only when every replica runs v0.7.0 (`nerva version | head -n1` on each), upgrade the gateways and start
   any multi-batch client.

Never run a v0.7.0 gateway, or any client that sends several batches in one request, while a
v0.6.1 replica is in the cluster. If it happens, a v0.6.1 replica that has committed such an op
cannot start again until it runs the v0.7.0 binary, and if v0.6.1 replicas are a quorum the
cluster stops committing: upgrade them at once.

**Rolling back.** A rollback to v0.6.1 is safe only if no v0.7.0 gateway and no multi-batch
client has run against the cluster since you began the upgrade. In that case v0.6.1 opens the
data files v0.7.0 has written (tested, `docs/releases/v0.7.0-audit.md`): stop each replica and
start it with the v0.6.1 binary, one at a time. If a v0.7.0 gateway or a multi-batch client has
run, an op of the shape above may be in the log. A v0.6.1 replica replays it when it opens its
data file and panics on every start. We have not run that case against a real v0.6.1 binary, so
treat the rollback as unsafe unless you are sure none ran. Without a rollback, keep v0.7.0.

**Gateways: check `--listen` first (#183).** `nerva api` and `nerva view` now refuse a
`--listen` address outside `127.0.0.0/8` and `::1` with NRV-E0009 (exit 1). If you bind
`0.0.0.0` or `[::]`, add `--listen-remote` before you upgrade. With it, the gateway logs
NRV-W0010: the key and every reply cross the network in plain HTTP. The alternative is to bind
`127.0.0.1` and run the caller beside the gateway. Check scripts and test fixtures that start
either command, for example a Docker fixture that serves `nerva api` on `0.0.0.0` to its host.
A forwarder in front of a gateway (`socat`, a proxy) still reaches a loopback gateway, and it is
the operator's choice.

**Gateways: other changes.**

- Set `--request-timeout` below your client's own HTTP timeout, so that your client always
  gets the gateway's answer. The default (30 s) suits only clients that wait longer than 32 s.
- Clients that match on error replies keep working: `error`, `status` and their spellings are
  unchanged, and `applied` and `code` are new fields. Before, a busy or slow connection was
  closed without a reply. Now it gets `503 busy` (E0602) or `408` (E0116). Treat both as
  "nothing applied".
- Two gateways can no longer share one port.
- v0.6.1 gateways may run against v0.7.0 replicas. Do not run v0.7.0 gateways against v0.6.1
  replicas (see "Order" above).

**After v0.7.0.** The first release with rolling upgrades between releases (R6) will not run
on release `0.0.6`, so moving from v0.7.0 to it is an export and import (P259g). That release's
notes will say so.

**`nerva version` has five lines now.** Scripts must read the first line only
(`nerva version | head -n1`). Anything that compares the whole output, takes a field with `awk`,
or takes the last word of it gets the wrong text from v0.7.0 (for example `bundles none`'s
`none`). Release builds fail closed on this, and no data is at risk. The release workflow
already uses `head -n1`.

**Botpike (`nerva.pin`).** The repository moved to `NervaLog/nerva`, so releases are published
there. Set `NERVA_REPO=NervaLog/nerva` along with the new tag, commit and tarball checksums.
Three of Botpike's checks read the whole output of `nerva version` and fail on v0.7.0 until they
read the first line only: the replica image's Dockerfile check, `scripts/nerva.sh`'s version
check and `NervaContainer`'s version check (Botpike/app#160). Fix them before, or in the same
change as, the pin bump. Bump the replicas' pin and the gateway's separately, replicas first
(P260, Botpike/app#159): one pin feeds both.
Botpike's Fly gateway already listens on `127.0.0.1`. The `NervaContainer` test fixture
(`cluster.sh`) runs `nerva api --listen=0.0.0.0:8080` and needs `--listen-remote`. Botpike's
client timeout is 5 s, so set `--request-timeout` below it (INF-2).

## v0.6.1 — 2026-10-21

`nerva api` no longer reads table layouts from the log on every request, so a lookup and a
commit that use `fields` now take one log op each instead of several: about 3.5 times the
submits per second through one gateway. `nerva start` gains `--commit-stall-probability`.
Nothing about data files, the wire protocol or the API changes: the protocol release is still
`0.0.6`.

### Faster: gateways keep table layouts (#135)

Each `nerva api` keeps up to 64 table layouts between requests (P135). A submit made of a
lookup and a commit over three tables with layouts took 8 log ops and now takes 2. On a 4-CPU
machine, through one gateway, that went from about 150 to 510–580 submits per second, at 1 to
12 callers. Answers do not change, also with several gateways on one cluster:

- **Writes** encode the same bytes under a kept layout as under the log's, because a layout
  only grows by appending fields and fields a request does not name are zero. A field only a
  newer layout has is refused, and the gateway then answers from layouts read from the log
  before replying, so it is never refused wrongly. Nothing is sent before that check, so a
  commit is never sent twice.
- **Lookups** read the kept layouts' catalog rows in the same op as your rows and read a
  layout again if it moved, so a field another gateway just added is there.

### New: `nerva start --commit-stall-probability=<n>/<d>` (#136)

When backups keep up, the primary waits one 10 ms tick before a commit with probability 2/5
to give them room (TigerBeetle's default, unchanged). With several requests in flight this
wait is most of an op's time. The flag sets that probability, from `0` to `1`; the default
stays 2/5, and the stall for backups that fall behind is unchanged. Measured with 8 clients
on one machine: 2/5 about 245 ops/s, 1/5 about 470, 0 about 1,150, but at 0 backups fell
behind far more often (P136, #134). Use other values to test; the default will change only
after the simulator covers them.

```bash
nerva start --addresses=3001,3002,3003 --commit-stall-probability=1/5 0_0.nerva
```

### Benchmarks

- `bench:load --workload=botpike` drives one `nerva api` gateway over HTTP the way Botpike's
  app does (a lookup, then a keyed commit with a transfer row and a ledger pair), with
  `--clients` concurrent callers, and the nightly runs it at 1 and 12 (P132, #132).
- Every `bench:load` result also reports `requests_per_s`.

### Fixed

- **#133:** a failing nightly could not file its `perf-regression` issue, because
  `file_issue.py` used `gh api --slurp`, which the runner's `gh` does not have. Since
  v0.6.0's nightly issue filing (1a03952). Fixed in #132.

### Release review

Reviewed adversarially before release (P105): [#139](https://github.com/Botpike/nerva-ledger/issues/139).
No blockers. Non-blockers: [#137](https://github.com/Botpike/nerva-ledger/issues/137) (the
layout cache replaces entries in turn, not the oldest as its comment says: speed only, past 64
tables), and [#138](https://github.com/Botpike/nerva-ledger/issues/138) (the tutorial's layout
note and cheat sheet, fixed in this release). Not run: Jepsen (no Docker in the review's
environment), and upgrade and downgrade by hand (waived by the owner).

### Upgrading from v0.6.0

The protocol release is unchanged (`0.0.6`), so v0.6.1 replicas open v0.6.0 data files: stop a
replica, start it with the v0.6.1 binary, and wait for it to rejoin before the next one. No
export or import. Restart gateways (`nerva api`, `nerva view`) on v0.6.1 to get the layout
cache; v0.6.0 and v0.6.1 gateways may run against one cluster side by side. This path was not
tested by hand for this release (`zig build test:release` passed).

## v0.6.0 — 2026-10-16

Facts can now live beside the money they record. A transaction may carry a **commit key**, so a
client that lost its reply resends it and it commits at most once. **Records** hold facts of
448 bytes under 128-bit ids, written in the same transaction as rows. **Declared indexes** find
records by their fields, kept exact in every commit. **Data files must be exported with v0.5.0
and imported with v0.6.0, a replica needs about 0.5 GiB more memory, and v0.6.0 replicas must
never share a cluster with older ones:** see "Upgrading from v0.5.0" below. v0.4.0 and v0.5.0
clients and gateways keep working; they cannot use records or indexes.

### New: commit keys, so a resent transaction commits once

Start a transaction with a key (16 bytes you choose, one per logical operation). When it
commits, Nerva keeps the key, in the same op. Sent again, it commits nothing and answers with
the op it committed at; sent with other entries, `key_reused`. A transaction that did not
commit (a conflict, a bound) keeps no key, and its resend runs again. (P123)

```bash
curl -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/commit -d '{"key":"0190f1c2a7e47b3c9d2e5f6a7b8c9d0e",
  "entries":[{"kind":"add","table":7,"id":"1","field":"available","delta":"-30","min":"0"}]}'
# {"status":"committed","op":"812","adds":[…]}; the same request again:
# {"status":"committed","op":"812","replayed":true}
```

- A resend's reply has no adds' amounts: read the rows as of its op.
- Keys are kept forever, one 80-byte row each. `/v1/documents/commit` takes no key yet.

### New: records, 128-bit ids and 448-byte values

Tables `2147483648` (`0x80000000`) to `4294901759` hold records: `(table, id)` with a 128-bit id
(a UUID, as 32 hex digits) and a 448-byte value, with layouts of up to 448 bytes (a bytes field
up to 255). One transaction may read, put and delete rows and records together, so a fact
commits in the op that moves its money. (P123b)

```bash
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/tables/2147483649 -d '{"name":"executions",
  "fields":[{"name":"agent","type":"bytes","size":16},{"name":"status","type":"u8"},
            {"name":"created","type":"u64"},{"name":"amount","type":"u64"}]}'
curl -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/commit -d '{"entries":[
  {"kind":"add","table":7,"id":"1","field":"available","delta":"-30","min":"0"},
  {"kind":"put","table":2147483649,"id":"0190f1c2a7e47b3c9d2e5f6a7b8c9d0e",
   "fields":{"agent":"…","status":1,"created":"1760600000","amount":"30"}}]}'
```

- `/v1/lookup`, `/v1/history` and `/v1/row?as_of` take record ids; one lookup reads rows or
  records, not both. `/v1/changes` serves both feeds in one order under one cursor.
- Records are written whole: they take no adds. Keep counters and balances in rows.
- The Zig client has `commit_wide`, `lookup_records`, `get_record_changes` and
  `get_record_history`.

### New: declared indexes

An index lists a record table's records by up to three `eq` fields, then an `order` field (or
the op of the last write), optionally only those matching `where`. Nerva keeps it exact in every
commit; scan one `eq` key a page at a time, ascending or descending, between bounds. Records
that tie on order list in the order they were first written, the same after an export and
import. (P123c)

```bash
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/indexes/by_agent -d '{"table":2147483649,
  "eq":["agent"],"order":"created"}'
curl -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/indexes/by_agent/scan -d '{"eq":{"agent":"…"},
  "min":"1760000000","limit":100}'
# {"index":"by_agent","op":"…","records":[{"id":"…","op":"…","order":"…","fields":{…}},…],"next":"…"}
```

- Declared over records that exist, an index builds in the background (`503` until it is ready).
- Indexes read the latest state; read the past through `/v1/history` and `/v1/row?as_of`.
- At most 64 indexes, 4 per table. `GET /v1/indexes` lists them.

### New: views over records

A maintained view may group and filter a record table's fields, with `count` and `sum`
(`min` and `max` are refused). It is served by `nerva api`, not `nerva view`. (P123d)

### Upgrading from v0.5.0

1. **Give each replica about 0.5 GiB more memory, or a smaller grid cache.** At the default
   settings, a replica took 2.5 GB resident at startup with v0.5.0, and takes 3.0 GB with
   v0.6.0: the in-memory tables of the new trees (with `--development`, 1.33 and 1.83 GB). The
   grid cache is 1 GiB by default; `nerva start --cache-grid=512MiB` brings v0.6.0 back to
   2.5 GB, at the cost of more reads from disk. (#127)
2. **Move rows out of tables `2147483648` to `4294901759` first.** v0.5.0 allowed rows there;
   those tables now hold records. `nerva import` refuses an export with rows or views in them,
   naming the table (#126): with v0.5.0, copy them to tables below `2147483648`, and export
   again.
3. **Export, then import every replica**, as for v0.5.0 (N80): with v0.5.0, `nerva export`; stop
   every replica; with v0.6.0, `nerva import` once per replica from the same export; start the
   replicas, then the gateways. v0.6.0 reads v0.5.0's exports (format version 1). Its own
   exports are version 2 once the cluster holds a record or an index, and v0.5.0 cannot read
   them: a downgrade is possible only before the first record or index.
4. **Never run v0.5.0 and v0.6.0 replicas in one cluster.** They ignore each other (N61).
5. v0.4.0 and v0.5.0 clients and gateways keep working against v0.6.0 replicas. They cannot
   write records: `commit` refuses an entry in a record table (`table_invalid`).

The adversarial release review found six issues, all fixed before this release:
[#124](https://github.com/Botpike/nerva-ledger/issues/124),
[#125](https://github.com/Botpike/nerva-ledger/issues/125),
[#126](https://github.com/Botpike/nerva-ledger/issues/126),
[#127](https://github.com/Botpike/nerva-ledger/issues/127),
[#128](https://github.com/Botpike/nerva-ledger/issues/128),
[#129](https://github.com/Botpike/nerva-ledger/issues/129).

## v0.5.0 — 2026-10-07

Replicas now prove to each other that they hold a cluster key, and refuse replicas imported
from a different export. Gateways rotate their key without downtime and listen on IPv6. Several
crashes are now refusals that name their cause. **A replica no longer starts without
`NERVA_CLUSTER_KEY`, its data files must be imported again, and its replicas must never run in
one cluster with v0.4.0 replicas:** see "Upgrading from v0.4.0" below. v0.4.0 clients and
gateways keep working.

### New: replicas authenticate each other

Before any replica message flows on a connection between two replicas, each proves that it holds
the cluster key, `NERVA_CLUSTER_KEY`: an HMAC-SHA256 over fresh nonces from both sides. A
process without the key cannot join the cluster, pose as a replica or vote. Clients and gateways
don't hold the key and aren't affected. (P102)

```bash
export NERVA_CLUSTER_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"  # the same on every replica
nerva start --addresses=3001,3002,3003 1_0.nerva
```

- **The key:** at least 32 bytes and secret. `nerva start` refuses to run without it and never
  prints it. With `--development`, a public development key is used, with a warning, but only
  when every address is a loopback address.
- **Rotating it, with no downtime:**
  1. restart every replica with the new key as `NERVA_CLUSTER_KEY_NEXT`;
  2. restart every replica with the new key as `NERVA_CLUSTER_KEY` and the old one as
     `NERVA_CLUSTER_KEY_NEXT`;
  3. restart every replica without `NERVA_CLUSTER_KEY_NEXT`.
- **What it doesn't cover:** the key authenticates who opened a connection, not the traffic
  after it. Replicas still need a private network that encrypts (WireGuard; Fly.io's 6PN).

### New: replicas imported from different exports refuse each other

A data file now records the export it was imported from: the export's SHA-256. `nerva export`
prints it, and `nerva import` and `nerva start` log it. Replicas announce it to each other. A
replica that can never reach a quorum with replicas of its own export exits with **status 8**
(`origin_mismatch`), naming both exports and telling you to import it again. The others log
that they ignore it and keep running. Before, replicas imported from two exports that reached
the same checkpoint crashed in the journal. (P90, #81)

- **Replacing a lost replica is a whole-cluster operation:** export the cluster again and import
  every replica. Importing one replica alone joins and catches up, but it has forgotten the
  prepares the lost replica acknowledged, so a later failure could lose a committed op. A safe
  single-replica replacement is future work (#94).

### New: gateways rotate their key, and listen on IPv6

- **`NERVA_KEY_NEXT`:** `nerva api` and `nerva view` also accept `X-Nerva-Key` equal to
  `NERVA_KEY_NEXT` when it is set. Rotate in three restarts:
  1. give every gateway the new key as `NERVA_KEY_NEXT`;
  2. move callers to the new key;
  3. make it `NERVA_KEY` and unset `NERVA_KEY_NEXT`.

  A gateway refuses to start with an empty `NERVA_KEY_NEXT`, or one equal to `NERVA_KEY`. Both
  keys are compared in constant time on every request. (P96)
- **`--listen=[<ipv6>]:<port>`**, as `--addresses` already took, for example `--listen=[::]:8080`
  on an IPv6-only network such as Fly.io's. Zone ids (`[fe80::1%2]`) are refused. On Linux,
  `[::]` also accepts IPv4 unless `net.ipv6.bindv6only` is set. (#99, #104)
- **README "Limits"** gathers every limit a caller can hit, each checked against the code. (#96,
  #110)

### Fixed

- Replicas imported from different exports crashed instead of refusing each other. They now
  exit with status 8. (#81)
- **A client older than its replicas couldn't commit to a cluster of more than one replica:**
  backups dropped every prepare that carried an older accepted client's release, including its
  registration. This has been so since v0.3.0, which accepted v0.2.x clients that then timed
  out. It now works, so v0.4.0 clients and gateways work against v0.5.0 clusters. (#93)
- A gateway, the Zig client or a replica given an address its kernel can't open a socket for
  (`[::1]` without IPv6) aborted on an assertion. It now logs the error once and keeps retrying.
  (#92)
- The nightly benchmark reported documents encoding and decoding 8 times slower. The benchmark
  had grown with the document limit; the code hadn't changed. Writing a document now computes
  its chunk ids' prefix once, and encoding takes about a third of the time it did. (#88)
- A `413` reply had no reason phrase in its status line. It now reads `413 Content Too Large`.
  (#110)

### Release review

Before this release, a bot that did none of its work reviewed it adversarially (P105).
- **Fixed:** #108 (the nightly benchmark couldn't start its cluster without the key), #110 (the
  README Limits wording) and #111 (P115: a v0.4.0 replica dialed by a v0.5.0 one exits with
  `unknown_vsr_command`, status 7; it doesn't just close the connection).
- **Answered by these notes:** #109 (the key is now mandatory).
- **Carried to 0.6.0:** #112.

### Known issues, carried to 0.6.0

- **#112:** gateways listen with `SO_REUSEPORT`, so two gateways can silently share a port.
- **#95:** a replica given another release's data file stops on a panic (`multiversion
  unsupported`) rather than a message.
- **#94:** no safe way yet to replace one lost replica. Replace by exporting and importing the
  whole cluster.
- **#116:** the nightly showed contended (`c3`) p99 latency 39% above v0.4.0's. Throughput and
  p50 held, and the baseline's own spread is nearly as wide. Being watched.
- **#109, downstream:** deployments must set `NERVA_CLUSTER_KEY` before starting a v0.5.0
  replica. Botpike's own deploy tracks this in Botpike/app#93.
- **CI and benchmarks:** #107 (the Jepsen suite doesn't fit the CI runner's memory; it passes
  where it has room), #101 (CI runners short of disk), and #91 (benchmarks in one process move
  each other's numbers).
- Divergence alerts (replica metrics and a view check) move to 0.6.0.

### Upgrading from v0.4.0

1. **Choose a cluster key and give it to every replica**, as `NERVA_CLUSTER_KEY`: at least 32
   bytes, the same everywhere, secret (for example a Fly secret). A v0.5.0 replica refuses to
   start without it. `--development` falls back to its public key only when every address is a
   loopback address. (#109)
2. **Export with v0.4.0, then stop every replica.** Run
   `nerva export --cluster=<id> --addresses=<…> --output=cluster.nerva-export`.
3. **Import every replica with v0.5.0**, from that one export, before any of them starts:
   `nerva import --cluster=<id> --replica=<i> --replica-count=<n> --input=cluster.nerva-export <file>`.
   Then `nerva start` each replica with the key set. Binaries report `0.0.5+<commit>`. A v0.5.0
   replica refuses a v0.4.0 data file.
4. **Never run v0.4.0 and v0.5.0 replicas in one cluster.** They can't authenticate each other,
   and a v0.4.0 replica that a v0.5.0 one dials exits at once (status 7, P115).
5. Clients and gateways may stay on v0.4.0 for now: v0.5.0 replicas accept clients from v0.4.0
   on.
6. **Going back** to v0.4.0 means exporting with v0.5.0 and importing with v0.4.0, which reads
   v0.5.0's exports. A v0.4.0 replica given a v0.5.0 data file stops without writing to it.

## v0.4.0 — 2026-10-06

Declared ledgers, so that the cluster itself conserves balances; views with `min` and `max`,
read as of any op and served whole by `nerva api`; and a round of fixes that keep replicas and
gateways up. **This release is not compatible with v0.3.0's data files, its replicas must never
run in one cluster with v0.3.0 replicas, and it refuses v0.3.0 clients:** see "Upgrading" below.

### New: declared ledgers

A ledger is a declared set of conserved `i64` fields, each with an optional floor. Its fields
then change only by a **pair** of adds that moves one amount from one field to another, never
below a floor, whoever sends the request. Value is neither created nor destroyed, a floored
field is never overdrawn, and puts and deletes cannot overwrite a balance.

```bash
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/ledgers/1 -d '{"fields": [
  {"table": 7, "field": "available", "floor": "0"}, {"table": 7, "field": "held", "floor": "0"},
  {"table": 8, "field": "balance", "floor": null}]}'
# Reserve up to 30: the first half may clamp at its floor; the partner moves what it took.
curl -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/commit -d '{"entries": [
  {"kind": "add", "table": 7, "id": "1", "field": "available", "delta": "-30", "pair": true,
   "clamp": true},
  {"kind": "add", "table": 7, "id": "1", "field": "held", "delta_from": 0}]}'
```

- An add to a conserved field outside a pair answers `409 {"status": "unpaired", "index"}`; a
  put, delete or overlapping add that would change one, `409 {"status": "conserved_write"}`.
- A partner stopped by its floor fails the whole transaction `out_of_bounds`.
- `GET /v1/ledgers/<id>` reads a declaration back. Declarations are immutable
  (`409 ledger_immutable`), a field is in one ledger at most (`409 ledger_field_taken`), and a
  view may sum a conserved field but not filter or group by it.
- At most 64 ledgers of 2 to 16 fields. See README, "Ledgers".

### New: views, complete in the cluster

- `min` and `max` are maintained by the state machine too, and stay exact when the row holding
  them is deleted, moved or changed. A table's views have at most four of them.
- A view reads as of any op since its declaration: `?as_of=<op>`.
- `GET /v1/views/<name>` on `nerva api` is now the whole view, groups sorted by key, read at
  one op, byte for byte what `nerva view` answers, with `hash`, the replicated `view_hash` and
  `declared_op`. **It used to return the declaration, which moved to
  `GET /v1/views/<name>/definition`.** `GET /v1/views` lists the views. A view of more than
  10,000 groups is read in pages from `/groups`.
- A view that filters or groups by a ledger's field is refused with `409`, and nothing is
  written.
- **`GET /v1/views/<name>/groups` names its replicated hash `view_hash`, as the whole view
  does; it was `hash`** (#66). `hash` on `nerva api` now always means `nerva view`'s.

### New: upgrades keep the data

From this release on, a cluster moves to the next release with its data. The old release's
`nerva export` writes the cluster's changes, views, ledgers and checks to a file; the new
release's `nerva import` builds each replica's data file from it, recomputing views and
everything else derived with its own code, and refuses a damaged export or a state that does
not match the checks.

```bash
nerva export --cluster=1 --addresses=3001,3002,3003 --output=cluster.nerva-export
# Stop the replicas; with the new release, once per replica:
nerva import --cluster=1 --replica=0 --replica-count=3 --input=cluster.nerva-export 1_0.nerva
nerva start --addresses=3001,3002,3003 1_0.nerva
```

- Rows, versions, history, `row?as_of`, the change feed and its cursors, documents, layouts,
  ledgers and every view's answer carry over. A view declared over rows that already existed is
  rebuilt after the new cluster starts, and its as-of history starts again; client sessions
  start again.
- Op numbers jump: the new cluster goes on from the first checkpoint at or after the export's
  op. Versions (`op_seen`) and feed cursors from before stay valid.
- Export and import work between two releases that both have them: from v0.4.0 on, the old
  release's `nerva export` and the new release's `nerva import`.
- A view declared only through the Zig client, without a catalog document, cannot be imported:
  `nerva import` refuses it. Declare views through `nerva api`.
- `nerva export` refuses an export that `nerva import` would refuse, before anything is
  stopped. `nerva import` writes `<path>.importing` and names it `<path>` only once its checks
  pass, so a failed or interrupted import leaves no data file to start.
- `--as-of=<op>` exports the cluster as of an op; by default, as of the export's start.
- See README, "Upgrading a cluster".

### New: releases carry a bill of materials

Each release has a CycloneDX 1.5 software bill of materials next to its binaries.

### New: larger documents

A document holds up to 512 KiB (it was 64 KiB), the most one commit writes atomically. Larger
values belong outside Nerva, stored by their hash. One `documents/get` reads at most as many
chunks as 256 documents of 64 KiB, and answers `413` past that: ask for fewer keys. (#25)

### Fixed

- One request with the raw operation value 134 (`pulse`) from any client crashed every replica,
  for good. Clients can no longer send it. (#33)
- Any eviction (more than 64 client sessions over a cluster's life, a client release too old)
  aborted `nerva api`, `nerva view` and Zig clients. They now report `error.Evicted` and
  reconnect. (#48, #52)
- A reply arriving after its request timed out could abort a gateway, and `nerva view` exited
  on one timeout. Both recover on their own now. (#42, #44)
- A transaction that touched more view groups than any op allows got `503 views_busy`, and
  retrying never helped. It now gets `413 views_too_large`: split it. (#32)
- A large JSON body kept up to 0.8 GB allocated in `nerva api`. A request may use at most
  128 MiB (`413 request too complex` past that), and the gateway keeps at most 8 MiB between
  requests. (#31, #60)
- With `--trace`, a full or failing trace disk panicked the replica, and the trace grew
  without bound. Trace writes are buffered and bounded now, and a write error stops tracing,
  not the replica. (#30)
- A bad view name was refused with a message about field names. It now says "a view name".
  (#77)

### Upgrading from v0.3.0

- **Stop every replica, then start them all on v0.4.0, on newly formatted data files.**
  Binaries report `0.0.4+<commit>`. A cluster cannot run two releases, and a v0.4.0 replica
  stops on a v0.3.0 data file. Load your data again.
- **Upgrade clients and gateways too.** v0.4.0 replicas refuse clients older than v0.4.0.
- `GET /v1/views/<name>` now answers the view; read the declaration at `/definition`.
- `GET /v1/views/<name>/groups` sends the replicated hash as `view_hash`; it was `hash`.
- v0.3.0 has no `nerva export`: this upgrade still means loading your data again. From
  v0.4.0 on, run the old release's `nerva export` and the new release's `nerva import`.
- Zig client users: new operations `declare_ledger` and `get_ledger` (by id, or by `slot` to
  list them: `Client.get_ledger_slot`), `AddFlags.pair`, new
  statuses `views_too_large` (15), `unpaired` (16) and `conserved_write` (17),
  `DeclareStatus.ledger_field` (10) and `table_extremes_full` (9), `DeclareLedgerStatus`,
  `min` and `max` in `AggregateFunction`, and `ViewQuery.as_of`. Existing values keep their
  numbers.

## v0.3.0 — 2026-10-05

Views that the cluster keeps itself, metrics and traces from replicas, a faster client, and a
round of gateway fixes. **This release is not compatible with v0.2.0's data files, and its
replicas must never run in one cluster with v0.2.0 replicas:** see "Upgrading" below.

### New: maintained views

A view whose aggregates are `count` and `sum` is now kept by the state machine inside every
commit, like the rows. Every replica holds the same groups and the same hash at every op, and
nothing is rebuilt when a process restarts. Declare it as before; read its groups from
`nerva api`:

```bash
curl -X PUT -H 'X-Nerva-Key: secret' http://127.0.0.1:8080/v1/views/revenue -d '{
  "table": 5, "where": [{"field": "sold", "op": "eq", "value": true}],
  "group_by": ["section"], "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"}]}'
curl -H 'X-Nerva-Key: secret' 'http://127.0.0.1:8080/v1/views/revenue/groups?limit=100'
# {"view":"revenue","id":1,"state":"ready","op":"1240","hash":"…","group_count":"8",
#  "groups":[{"section":4,"count":"369","sum_price":"184590"},…],"more":false,"cursor":null}
```

- A view declared over existing rows says `"state":"building"` until the cluster has added
  them, a bounded number per op; then `"ready"`.
- Groups come a page at a time (`cursor`, `limit`), in storage order.
- An `add` to a field a maintained view filters or groups by answers `409 view_key_field`.
- One op touches at most about 4,000 distinct groups; a transaction past that answers
  `503 views_busy`.
- `min`, `max` and as-of answers are still served by `nerva view`.

### New: metrics and traces

- `nerva start --statsd=<host:port>` sends the replica's metrics (requests, commits, caches,
  client round trips) over UDP every 10 seconds, in statsd format with DogStatsD tags.
- `nerva start --trace=<path>` writes a JSON span trace. The path must be a new file: an
  existing one is refused (#29).
- `nerva start --cache-rows=<size>` sizes the row cache.
- `zig build bench` and `zig build bench:load` measure Nerva's parts and a running cluster.

### Faster

The Zig client, and so `nerva api`, returns as soon as its reply arrives instead of at the end
of a 10 ms tick. Through `nerva api` on a local three-replica cluster, lookup p50 went from
10.60 ms to 1.05 ms and commit p50 from 10.53 ms to 0.92 ms.

### Fixed

- A request head ending in a bare LF crashed `nerva api` and `nerva view` before the key was
  checked. (#8)
- A slow client stalled a gateway: the timeout was per read, not per request. Gateways now read
  up to 16 connections at once, with a 10 s deadline per request. (#9)
- The `X-Nerva-Key` check took time that depended on the key. It is constant-time now. (#10)
- When all 16 slots were taken by idle connections, a gateway shut everyone else out for
  minutes, with no key needed. A new connection now displaces the oldest one that is still
  sending its request. (#28)
- `GET /v1/views/groups` crashed `nerva api`. It is now `404`, and a view named `groups` reads
  at `/v1/views/groups/groups`. (#26)
- After one cluster timeout, `nerva api` answered `503` to every later request, while
  `/healthz` still said `200`. It now reconnects, and `/healthz` answers `503` until the
  cluster is reachable again. (#27, #37)
- `nerva start --trace=<path>` truncated whatever file it named, a data file included. (#29)
- A replica of another release could join a cluster: it counted toward quorums while running
  the log with different code, and panicked with `checkpoint diverged` at the first checkpoint
  (about 960 ops). Replicas now ignore peers that run another release, and log it:
  `replica 2 runs release 0.0.2, this replica runs 0.0.3: ignoring it`. (#34)
- A JSON body with newlines (`curl -d` with a multi-line body, as in the examples above) was
  refused with `400 malformed request` when it arrived in the same read as its head. (#36)
- `documents.Transaction` (Zig) could read a value stitched from two versions when a rewrite
  landed between its reads. (#7)

### Known issues

- With `--trace`, a trace write error panics the replica, and the trace grows without bound.
  (#30)
- A 4 MiB JSON body keeps about 0.8 GB allocated in `nerva api` for the rest of its life. (#31)
- A transaction touching more view groups than one op allows gets `503 views_busy`, and
  retrying will never make it succeed. (#32)
- Any client can send `pulse`, the cluster's internal backfill operation. (#33)

### Upgrading from v0.2.0

- **Stop every replica, then start them all on v0.3.0.** A cluster cannot run two releases. A
  v0.3.0 replica ignores v0.2.0 peers, so during a one-at-a-time upgrade it never counts toward
  their quorums, nor they toward its own. A v0.2.0 replica facing a v0.3.0 majority stops with
  `panic: attempt to use null value` at the first operation it does not know.
- **Reformat data files.** Binaries now report `0.0.3+<commit>`. A v0.3.0 replica stops on a
  v0.2.0 data file with `panic: multiversion unsupported`. Format new files and load your data
  again.
- **Clients and gateways can follow.** v0.3.0 replicas still accept v0.2.0 clients, so a v0.2.0
  `nerva api` keeps committing and reading against a v0.3.0 cluster. It does not have the new
  routes (`/v1/views/<name>/groups`).
- Zig client users: new operations `declare_view`, `get_view` (`pulse` is internal), new
  statuses `view_key_field` and `views_busy`, and `Client.reconnect`. Existing values keep their
  numbers.

## v0.2.0 — 2026-10-04

Two new capabilities for applications on `nerva api`, values larger than a row and counters
that many clients can change at once, plus two crash fixes. **This release is not compatible
with v0.1.0's data files or clients:** see "Upgrading" below.

### New: documents (larger values by key)

Store values of up to 64 KiB under string keys (up to 1024 bytes of UTF-8), grouped by a
namespace, without chunking them yourself. Reads and writes are optimistic transactions, like
rows.

```bash
curl -H 'X-Nerva-Key: secret' -d '{"namespace":"7",
  "reads":[{"key":"cart/1","version":"0"}],
  "writes":[{"key":"cart/1","value_hex":"7b7d"}]}' http://127.0.0.1:8080/v1/documents/commit
# {"status":"committed","op":"42"}
curl -H 'X-Nerva-Key: secret' -d '{"namespace":"7","keys":["cart/1"]}' \
    http://127.0.0.1:8080/v1/documents/get
# {"op":"43","documents":[{"key":"cart/1","exists":true,"version":"42","value_hex":"7b7d"}]}
```

- `POST /v1/documents/get` reads up to 256 keys at one op: the latest, or `"as_of"` any
  committed op. Each document has a `version` (the op of its last write; `"0"` if never
  written).
- `POST /v1/documents/commit` is one transaction of reads at the version seen, puts and
  deletes. A stale read answers `409` with the key and its current version; nothing applies.
- `GET /v1/documents/changes?namespace=&cursor=&limit=` lists a namespace's document writes in
  commit order, including deletes (each with its key).
- Up to about 600 KB of keys and values per commit.

### New: adds (counters and budgets without conflicts)

An `add` changes one 64-bit field of a row inside the commit, without reading it first. Adds to
the same row never conflict, so many clients can draw on one budget or stock count at once with
no retries.

```bash
# Reserve up to 30 from `available` and hold exactly what was taken, in one transaction.
curl -H 'X-Nerva-Key: secret' -d '{"entries":[
  {"kind":"add","table":5,"id":"1","field":"available","delta":"-30","min":"0","clamp":true},
  {"kind":"add","table":5,"id":"1","field":"held","delta_from":0}]}' \
    http://127.0.0.1:8080/v1/commit
# {"status":"committed","op":"44","adds":[{"index":0,"applied":"-20","value":"0"},
#                                         {"index":1,"applied":"20","value":"20"}]}
```

- Fields are `u64` or `i64`, named by the table's layout or given by `offset` and `type`.
- `min` and `max` bound the result. Crossing a bound fails the transaction with `409
  out_of_bounds` (with the field's current value), or with `clamp` the add takes what fits.
- `delta_from` moves exactly what an earlier add of the same transaction applied, so a
  reservation can never overdraw.
- An add to a row that does not exist answers `409 row_absent`, unless `create` starts it at
  zero.
- Adds appear in the change feed, history, as-of reads and declared views like any other write.

### Fixed

- A cluster could crash when one request carried two writes that left a row unchanged (for
  example two identical puts). Every replica failed on the same op. Nerva's own client never
  sent such requests, but the protocol allows them. (#4)
- One oversized request (too many rows or entries) made the next request to the same
  `nerva api` gateway crash it. Oversized requests now just answer `400`. (#5)

### Upgrading from v0.1.0

- **Reformat data files.** v0.2.0 refuses data files formatted by v0.1.0 ("found incompatible
  superblock version 0"). Nothing carries over: format new files and load your data again.
- **Upgrade every process together.** Replicas refuse clients from v0.1.0, and the two releases
  cannot run in one cluster. Binaries now report `0.0.2+<commit>` (the protocol release, then
  the commit).
- Zig client users: `EntryResult` is now 32 bytes (with `applied` and `value`), and
  `EntryKind`, `EntryStatus` gained values. Existing values keep their numbers.
- JSON API users: nothing changes for existing requests and replies; a commit reply carries
  `adds` only when the commit had adds.

## v0.1.0 — 2026-10-04

The first release.

- **Commit core:** rows of 80 bytes keyed by `(table, id)`, optimistic transactions (reads at
  the version seen, puts and deletes), a change feed, and every row's history as of any op.
- **`nerva api`:** the core operations as JSON over HTTP, table layouts (named, typed fields).
- **`nerva view`:** declared views (where, group by, count, sum, min, max) over a table, latest
  or as of any op, each answer with a hash.
- Replication, storage and the simulator from TigerBeetle; binaries for Linux and macOS
  (x86_64, aarch64). Binaries report `0.0.1+<commit>`.
