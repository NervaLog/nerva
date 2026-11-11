# Troubleshooting

Start from what you see, find the code, then read the code's row in [ERRORS.md](ERRORS.md). Every
refusal Nerva prints or answers carries a code, `NRV-E` for a cause you can fix, `NRV-W` for a
warning and `NRV-B` for a bug in Nerva.

> The messages quoted below were run against a candidate built from `main` at commit 4ddd232
> (`nerva version` printed `version 0.7.0`), on 2026-11-10, one development replica. This is not a
> release. A message marked **not run** is quoted from ERRORS.md or the source, not reproduced.

ERRORS.md has one section per range of codes, and each code is a row in its section. This page
links the section; look the code up in its table.

- [A command refused](#a-command-refused)
- [A request got a 503](#a-503)
- [A reply says `applied: "unknown"`](#applied-unknown)
- [Other statuses from a gateway](#other-statuses-from-a-gateway)
- [A gateway will not start](#a-gateway-will-not-start)
- [A replica exits](#a-replica-exits)
- [A replica will not start or will not join](#a-replica-will-not-start-or-will-not-join)
- [The installer refused](#the-installer-refused)
- [When the code is not here](#when-the-code-is-not-here)

## A command refused

A `nerva` command that refuses prints one block and exits (README,
[When a command refuses](../README.md#when-a-command-refuses)):

```
error[NRV-E0006]: start: data/missing.nerva does not exist
  cause  A data file is missing at `start`'s path
  fix    run nerva format first, or fix the path
```

The exit status says whose it is: 1 your input, 2 the environment (disk, kernel, file system),
70 a bug in Nerva (`bug[NRV-B…]`). The code's section in ERRORS.md has the cause and the fix again,
with the cases. If the block shows `NRV-B…`, report it with the command and its output.

| You see | Code | Do |
|---|---|---|
| `--addresses: argument is required`, an unknown or repeated flag | NRV-E0001 | `nerva --help` lists every command and flag (`nerva <command> --help` is itself refused with this code, [#300](https://github.com/NervaLog/nerva/issues/300)) |
| `--request-timeout must be 1000 to 60000 milliseconds`, any flag out of range | NRV-E0002 | The message names the bounds |
| `--listen must be <ipv4>:<port> or [<ipv6>]:<port>` | NRV-E0003 | Give `host:port` |
| `<path> exists` on `format`, `export`, `import` | NRV-E0004, NRV-E0005 | Give a new path; Nerva never overwrites a file |
| `start: <path> does not exist` | NRV-E0006 | `nerva format` first, or fix the path |

Section: [00xx · Commands and flags](ERRORS.md#00xx--commands-and-flags).

## A 503

A `503` from a gateway has four causes. The code in the reply says which.

```
{"error":"cluster unavailable","applied":false,"code":"NRV-E0605"}
```

| Code | Meaning | What to do |
|---|---|---|
| NRV-E0605 | The gateway has no cluster session now and sent nothing. `/healthz` is `503` too | Wait: it reconnects by itself, at most every 5 s. If it does not, a quorum of replicas is not running: see [a replica exits](#a-replica-exits) |
| NRV-E0601 | The cluster did not answer within `--request-timeout` (30 s unless set) | Retry. For a write, see [`applied: "unknown"`](#applied-unknown) |
| NRV-E0606 | The request's one `--request-timeout` window was spent before the next cluster call | Look at `"applied"`. `false`: resend. `"unknown"`: an earlier call of the request sent a write, so treat it as [below](#applied-unknown) |
| NRV-E0602 | All 16 connections were busy and this one was not read | Retry; fewer concurrent clients |

NRV-E0211 (`views_busy`) and NRV-E0313 (`catalog busy`) are also `503`: resend, under the same
commit key for a commit.

Reproduced: the replica was killed while an API gateway and a view gateway ran. Within seconds, with
the replica down:

```
GET /v1/lookup, /v1/changes, /v1/commit on the gateway
-> 503 {"error":"cluster unavailable","applied":false,"code":"NRV-E0605"}
GET /v1/views on nerva view
-> 503 {"error":"cluster unavailable","applied":false,"code":"NRV-E0605"}
GET /healthz (either gateway)
-> 503 {"ok":false,"error":"cluster unavailable","applied":false,"code":"NRV-E0605","session":"reconnecting"}
```

The gateway logged `reconnecting to the cluster: error.Timeout` and, once the replica was started
again, answered `GET /healthz` with `200 {"ok":true,"session":"ready"}` without a restart.

With the replica stopped (`SIGSTOP`) rather than gone, a commit waited out `--request-timeout` and
was answered `503` NRV-E0601, with `"applied":"unknown"` when the write had been sent (see the next
section).

Sections: [01xx · The gateway](ERRORS.md#01xx--the-gateway-transport-keys-routes-requests),
[06xx · The cluster and sessions](ERRORS.md#06xx--the-cluster-and-sessions).

## `applied: "unknown"`

Every non-success reply says whether anything was written: `"applied": false` (nothing), or
`"applied": "unknown"`. `"unknown"` means a write was sent to the cluster and no answer came back
(a timeout, or the session was evicted), so it may or may not have committed. It comes with NRV-E0601
on a write, with NRV-E0313, and with NRV-E0606, NRV-E0113, NRV-B0001 or NRV-B0002 when an earlier call of
the same request had already sent a write. Check `"applied"` on each of these: a `500` or `413`
that says `"unknown"` is not only a bug to report.

**Only a keyed resend is safe.** Never resend an unkeyed write on `"unknown"` without reading the
rows first: it may apply twice.

- A commit **with a `key`**: resend the same request with the same key. It commits at most once; if
  it had committed, the answer is `200` with `"replayed": true` and NRV-W0201, which is a success.
  A key used for a different transaction is `409 key_reused` (NRV-E0207). A replayed reply has no
  `adds`: a client that used `clamp` reads the rows as of the reply's `op` to learn what was applied
  ([API.md](API.md#post-v1commit)).
- A commit **without a key**: read the rows (or `GET /v1/history`) to see whether it landed, then
  decide. Use a key for every write you may need to resend.
- A layout or view declaration (`PUT`): send it again. Declarations are idempotent.

Reproduced: an API gateway with `--request-timeout=2000`, the replica stopped (`SIGSTOP`), a keyed
`put` of one row, then the replica continued (`SIGCONT`):

```
POST /v1/commit {"key":"0a0b0c0d0e0f000102030405060708aa","entries":[{"kind":"put","table":1,"id":"5","value_hex":"c0ffee"}]}
-> 503 {"error":"cluster unavailable","applied":"unknown","code":"NRV-E0601"}
(the replica continues; `GET /healthz` answers 503 reconnecting, then 200 within seconds)
(the same request again)
-> 200 {"status":"committed","op":"52","replayed":true,"code":"NRV-W0201"}
```

The first request had landed, and the resend said so without writing it again. NRV-E0606, E0113
and B0001 with `"unknown"` were not run.

Section: [06xx · The cluster and sessions](ERRORS.md#06xx--the-cluster-and-sessions);
[API.md](API.md#post-v1commit) for commit keys.

## Other statuses from a gateway

| Status | Code | Cause |
|---|---|---|
| 400 | NRV-E0105 to E0115 | The request is malformed. The `error` text names the member |
| 401 | NRV-E0103 | `X-Nerva-Key` is missing or wrong (during a rotation `NERVA_KEY_NEXT` is accepted too) |
| 404 | NRV-E0104 | No such route (with a valid key; without one it is `401`). `GET /v1/tables/7` on `nerva view` is this: it serves three routes only |
| 405 | NRV-E0104 | The route does not take this method. The key is checked first for `GET`, `POST` and `PUT`: with no valid key those are `401`, even for a route that does not exist. Only `DELETE`, `PATCH` and other methods get `405` before the key is looked at |
| 408 | NRV-E0116 | The request did not arrive whole within 10 s |
| 413 | NRV-E0102 | The body is over 4 MiB |
| 409 | NRV-E0202 to E0209 | A commit was refused on its merits (`conflict`, `out_of_bounds`, …). Nothing was written |
| 504 | NRV-E0401 (NRV-E1001 on `nerva view`) | `as_of` or `min_op` is an op not yet committed: ask again later |

`GET /v1/changes?cursor=abc` with no `limit` answers `limit is required`, not a cursor error:
`limit` is checked first. The full list with replies is [API.md](API.md#errors-every-route-can-answer).

Sections: [01xx](ERRORS.md#01xx--the-gateway-transport-keys-routes-requests),
[02xx · Commit results](ERRORS.md#02xx--commit-results), [04xx · Reads](ERRORS.md#04xx--reads),
[10xx · `nerva view`](ERRORS.md#10xx--nerva-view).

## A gateway will not start

`nerva api` and `nerva view` check what they can before they connect, and exit 1:

```
error[NRV-E0008]: api: set NERVA_KEY
  cause  `NERVA_KEY` is missing or invalid
  fix    set NERVA_KEY; during a rotation NERVA_KEY_NEXT differs from it
```

```
error[NRV-E0009]: api: --listen=0.0.0.0:8713 is not loopback; the gateway speaks plain HTTP
  cause  `--listen` is not loopback and `--listen-remote` was not given
  fix    listen on 127.0.0.1 beside the client, or pass --listen-remote and put TLS in front
```

```
error[NRV-E0007]: api: cannot listen: the address is in use
  cause  A replica, gateway or view server cannot listen
  fix    free the port, or give another address
```

```
error[NRV-E0003]: api: --listen must be <ipv4>:<port> or [<ipv6>]:<port>
error[NRV-E0002]: api: --request-timeout must be 1000 to 60000 milliseconds
```

If the flags are right and the gateway still does not come up, it cannot reach the cluster. After
the client's registration timeout (`--request-timeout`, 30 s by default) it exits 1:

```
error[NRV-E0604]: api: no reply from the cluster
  cause  A gateway or view server could not reach the cluster
  fix    check --cluster and --addresses, and that a quorum of replicas is running
```

This was run with every replica stopped: the gateway logged `on_connect: error to=0
error.ConnectionRefused` repeatedly, then printed the block above, about 30 s after it started.
Check that `--cluster` is the id the replicas were formatted with, that `--addresses` lists them in
replica order, and that a majority of them run.

NRV-E0010 (the gateway cannot send metrics to `--statsd`) was not run.

Section: [00xx](ERRORS.md#00xx--commands-and-flags),
[06xx · The cluster and sessions](ERRORS.md#06xx--the-cluster-and-sessions).

## A replica exits

`nerva start` keeps its exit statuses when it stops on a condition it cannot continue from. The
status says which:

| Exit | Condition | Code | Notes |
|---|---|---|---|
| 1 | A flag or file refusal before it opens anything | NRV-E0001 to E0010, E0701 to E0703, E0710 | See [the next section](#a-replica-will-not-start-or-will-not-join) |
| 2 | The disk is full: `write failed: no space left on device` | NRV-E0706 | Free space or grow the volume. Not run |
| 3 | The manifest node pool is exhausted | none yet | Its message names a flag, `--memory-lsm-manifest`, that `nerva start` does not have ([#304](https://github.com/NervaLog/nerva/issues/304)). Not run |
| 4 | The data file is over its size limit | NRV-E0707 | The limit is the build's; Nerva has no flag to raise it. Not run |
| 5 | The next checkpoint would put the data file over its limit | NRV-E0707 | As exit 4. Not run |
| 6 | The forest's table count would exceed its limit | none yet | The message tells you to contact "the team"; report it ([#304](https://github.com/NervaLog/nerva/issues/304)). Not run |
| 7 | `unknown VSR command, crashing for safety` | NRV-B0003 | A bug: report it. Not run |
| 8 | `origin_mismatch`: this replica was imported from another export than its peers | NRV-E0711 | In a running cluster, `nerva recover` this replica with `--origin=` the export its peers announce (never import it alone again). When the whole cluster is being restored with the cluster closed, import every replica from the same export. Not run |

The statuses are `FatalReason` in `src/vsr.zig`. None of exits 2 to 8 was reproduced for this page.
A damaged disk or write-ahead log (NRV-E0708, NRV-E0709) is today a panic or a raw
`error: WALInvalid`, still without a code; see ERRORS.md.

Sections: [07xx · Replicas and data files](ERRORS.md#07xx--replicas-and-data-files),
[Bugs](ERRORS.md#bugs).

## A replica will not start or will not join

> **Never re-format, re-import or restore one replica of a running cluster.** A replica that is
> formatted again has forgotten what its predecessor promised the others, and the cluster's
> guarantees are void (README, [Backups](../README.md#backups): "a replica of a running cluster is
> never restored alone", P90). A damaged or lost replica of a cluster that is running and has a
> quorum is replaced with `nerva recover`, which makes its new data file safely (README,
> [Replacing a lost replica](../README.md#replacing-a-lost-replica),
> [OPERATING.md](OPERATING.md#replacing-a-lost-replica)). `format`, `import` and `restore` are for
> a new cluster, a lone replica (a cluster of one), or **every** replica together with the cluster
> closed, and a restore loses every op after the backup
> ([OPERATING.md](OPERATING.md#backups-and-a-restore-drill)).

Refusals before the replica opens its data file, each exit 1 unless noted:

```
error[NRV-E0703]: start: another process holds data/0_0.nerva
  cause  Another process holds the data file
  fix    stop the other replica that uses this data file
```

```
error[NRV-E0005]: format: data/0_0.nerva exists
  cause  A data file already exists at `format`'s path
  fix    give a new path, or remove the old file if it is really unwanted
```

That `fix` fits a new cluster or a data file that never held anything. Do not remove the data file
of a replica of a running cluster and format it again: see the warning above, and use
`nerva recover`.

```
error[NRV-E0901]: start: NERVA_CLUSTER_KEY is shorter than 32 bytes
  cause  `NERVA_CLUSTER_KEY` is missing, short, or wrongly paired with `_NEXT`
  fix    set NERVA_CLUSTER_KEY (and NERVA_CLUSTER_KEY_NEXT during a rotation) as the message says
```

Also run: `format --replica=3 --replica-count=1` is NRV-E0002 (`--replica must be less than
--replica-count`).

Not run, quoted from ERRORS.md:

| You see | Code | Do |
|---|---|---|
| `start: <path> was written by release X, and this is release Y` | NRV-E0701 | Upgrade by export and import (README, [Upgrading a cluster](../README.md#upgrading-a-cluster)) |
| `start: <path> has no usable superblock (…)` | NRV-E0702 | Check the path. If the file is damaged: a replica of a running cluster is replaced with `nerva recover`; a lone replica or a closed cluster is restored from a backup (every replica, from the same one) |
| `start: all --addresses must be provided` | NRV-E0710 | Give every replica's address, in replica order |
| `start: the file system of <path> does not support direct IO`, exit 2 | NRV-E0704 | Put the data file on ext4 or XFS (`--development` allows it) |
| `<command>: the kernel is X.Y; Nerva needs 5.11 or newer`, exit 2 | NRV-E0705 | Upgrade the kernel |

**A replica starts but the cluster does not form.** The replica is running and nothing joins it.
Look at its log:

- A peer proved a different cluster key: NRV-E0902, logged, the peer is ignored. Every replica
  needs the same `NERVA_CLUSTER_KEY`. Not run.
- `replica N runs release X, this replica runs Y: ignoring it`: a peer on a release this binary does
  not run. Start every replica on the same release. Not run.
- Exit 8, NRV-E0711 (above): the replica was imported from another export than its peers.
- Fewer than a majority of the replicas run, so no gateway gets a session: NRV-E0604 on the gateway.
  Start the others. To bring back a lost replica, see README,
  [Replacing a lost replica](../README.md#replacing-a-lost-replica) and
  [OPERATING.md](OPERATING.md#replacing-a-lost-replica). Do not format it again by hand.

NRV-E0901 and NRV-E0902 are in
[09xx · Keys between replicas](ERRORS.md#09xx--keys-between-replicas).

## The installer refused

`install.sh` in the Linux release tarball prints `error[NRV-E11xx]: install.sh: <what>`; the
`.deb`'s preinst and the `.rpm`'s `%pre` print `error[NRV-E11xx]: nerva package: <what>`. Each is
followed by a `cause` and a `fix` line, changes nothing, and exits 1 (your input) or 2 (the machine).

```
error[NRV-E1101]: install.sh: must run as root
  cause  The installer was not run as root
  fix    run it with sudo
```

```
error[NRV-E1102]: install.sh: this machine is not running systemd
  cause  The installer found no running systemd
  fix    install on a machine that boots with systemd, or run nerva by hand (docs/QUICKSTART.md)
```

```
error[NRV-E1106]: install.sh: unknown argument --bogus
  cause  install.sh was given a flag or a combination of flags it does not take
  fix    usage: install.sh [--dry-run] [--upgrade] | --uninstall [--dry-run] (see --help)
```

`--upgrade --uninstall` together is NRV-E1106 too (exit 1). NRV-E1102 exits 2 (it was run as root in a
container with no systemd). The `fix` line of NRV-E1102 names [QUICKSTART.md](QUICKSTART.md).

Not run, from ERRORS.md:

| You see | Code | Do |
|---|---|---|
| `/usr/local/bin/nerva is a different build (…)` | NRV-E1103 | Stop the replicas, run `install.sh --upgrade`, restart them |
| `the nerva in <dir> is for <arch>, and this machine is <arch>` | NRV-E1104 | Use the tarball for this machine |
| `the user nerva exists, with home <dir>` and its kin | NRV-E1105 | Rename or remove that user, group or unit; change units with a drop-in |
| `nerva package: <path> exists and is not this package's` (the `.deb` or `.rpm`, on a first install) | NRV-E1111 | A tarball install: `install.sh --uninstall` from the tarball. Otherwise (a source build, a full unit copy from `systemctl edit --full`) move or remove the file; change units with a drop-in. Upgrades are not checked |
| `the nerva in <dir> cannot run (exit status <n>)` | NRV-E1107 | Unpack where programs may run (not a `noexec` mount) |
| `<dir>/<file> is missing` | NRV-E1108 | Unpack the tarball whole and run `install.sh` from its directory |
| `sha256sum is not installed` | NRV-E1109 | Install coreutils |

Section: [11xx · Installation and packages](ERRORS.md#11xx--installation-and-packages).

## When the code is not here

Look the code up in ERRORS.md: its section is the first two digits (`NRV-E06xx` is
[06xx](ERRORS.md#06xx--the-cluster-and-sessions)). A message with no code is a gap in Nerva's own
error handling: today exits 3 and 6 above, and a damaged disk or write-ahead log. Report it on
GitHub with the command, its output and `nerva version`.

## Where to go next

[INSTALL.md](INSTALL.md) and [QUICKSTART.md](QUICKSTART.md) install Nerva and run a first cluster.
[OPERATING.md](OPERATING.md) is what a replica needs, what to alert on and how to upgrade.
[SECURITY.md](../SECURITY.md) says what a `401` and a key protect, and [MATURITY.md](MATURITY.md)
says what the alpha label promises.
