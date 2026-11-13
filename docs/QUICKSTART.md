# Quickstart

From a downloaded release to a running cluster, a table, a commit, a read and the change feed, in
about fifteen minutes. First on one machine (three replicas and a gateway as plain processes, to
learn the shape), then on three machines with a cluster key and systemd (to run it).

**Where the outputs come from.** The one-machine half was run, command by command, in a fresh
directory with the binary from a tarball laid out as the release's is, built from `main` at commit
`4ddd232` on Linux x86_64. Your `op` numbers, cursors and times will differ: use the numbers from
your own replies ("Ops move on their own" in the
[tutorial](./TUTORIAL.md#ops-move-on-their-own)). The three-machine half **was not run**: it needs
three hosts and systemd, and every output in it is marked as not run. The release re-records both.

Install first: [INSTALL.md](./INSTALL.md). Nerva is alpha ([MATURITY.md](./MATURITY.md)); do not put in it data you
cannot lose.

## One machine

You need `nerva` (from the unpacked tarball or zip, Homebrew, a package or a build from
source), `curl`, and about 3.5 GiB of free disk: each replica's data file is 1.1 GiB. Three
replicas at `--development`'s small caches take about 1.8 GB of memory each
([sizing](./OPERATING.md#sizing)).

Set `NERVA` to the path of the binary, by whichever line fits:

```bash
NERVA=$PWD/nerva-v0.7.1-x86_64-linux/nerva              # the tarball, unpacked here (the zip: nerva-v0.7.1-universal-macos/nerva)
NERVA=$(command -v nerva)                                # Homebrew, a package or install.sh
```

Every command below writes `"$NERVA"`, quoted, so a path with a space works.

```bash
"$NERVA" version
```
```
Nerva version 0.0.6+4ddd232
release 0.0.6
release_client_min 0.0.4
format a2d6e50b122836b2b596f8548a391e77c3b2beead93ee5e30939479601259362
bundles none
version 0.7.0
```

The first line is `<protocol release>+<commit>`; the last is the release as people name it
(`0.7.0` here only because this is a candidate build, a released one says `0.7.1`). The tutorial's
[Build](./TUTORIAL.md#build) explains the lines between.

**1. Format three data files.** A replica's data file holds its share of the log. Cluster id `1`
is yours to choose (`0` is reserved for tests); every client names it.

```bash
mkdir -p ~/nerva-quickstart && cd ~/nerva-quickstart
for i in 0 1 2; do
  "$NERVA" format --cluster=1 --replica=$i --replica-count=3 --development 1_$i.nerva
done
```
```
2026-11-10 22:15:30.365Z info(io): creating "1_0.nerva"...
2026-11-10 22:15:30.365Z info(io): allocating 1.06298828125GiB...
2026-11-10 22:15:30.504Z info(main): 0: formatted: cluster=1 replica_count=3
2026-11-10 22:15:30.506Z info(io): creating "1_1.nerva"...
2026-11-10 22:15:30.506Z info(io): allocating 1.06298828125GiB...
2026-11-10 22:15:30.539Z info(main): 1: formatted: cluster=1 replica_count=3
2026-11-10 22:15:30.542Z info(io): creating "1_2.nerva"...
2026-11-10 22:15:30.542Z info(io): allocating 1.06298828125GiB...
2026-11-10 22:15:30.579Z info(main): 2: formatted: cluster=1 replica_count=3
```

`--development` lets a replica run without Direct IO (some file systems, such as tmpfs, lack it)
and with small caches, and lets it start without a cluster key because every address is loopback.
It is for a laptop. Never use it in production.

**2. Start the three replicas.** `--addresses` lists every replica's address in replica order; a
bare port means `127.0.0.1`.

```bash
for i in 0 1 2; do
  "$NERVA" start --addresses=3001,3002,3003 --development 1_$i.nerva > replica_$i.log 2>&1 &
done
sleep 5; grep -h listening replica_*.log
```
```
2026-11-10 22:15:32.750Z info(main): 0: cluster=1: listening on net.SocketAddress{ .ip = 127.0.0.1, .port = 3001 }; data file from export none (formatted)
2026-11-10 22:15:32.756Z info(main): 1: cluster=1: listening on net.SocketAddress{ .ip = 127.0.0.1, .port = 3002 }; data file from export none (formatted)
2026-11-10 22:15:32.778Z info(main): 2: cluster=1: listening on net.SocketAddress{ .ip = 127.0.0.1, .port = 3003 }; data file from export none (formatted)
```

Each log also starts with a warning that `NERVA_CLUSTER_KEY` is unset and the public development
key is in use. That key authenticates nothing, which is fine here; the three-machine half sets a
real one.

**3. Start the gateway.** `nerva api` serves the JSON API on loopback, and every request must carry
its secret in `X-Nerva-Key`.

```bash
export NERVA_KEY=secret
"$NERVA" api --cluster=1 --addresses=3001,3002,3003 --listen=127.0.0.1:8080 > api.log 2>&1 &
sleep 5
n() { curl -s -H "X-Nerva-Key: $NERVA_KEY" "$@"; echo; }
A=http://127.0.0.1:8080
n $A/healthz
```
```
{"ok":true,"session":"ready"}
```

**4. A table.** Every table exists, empty, from the start; a *layout* only gives the 80 bytes of a
row names and types ([Layouts](./TUTORIAL.md#part-5-layouts-typed-fields-instead-of-hex)).

```bash
n -X PUT $A/v1/tables/1 -d '{"name":"orders","fields":[{"name":"customer","type":"u64"},{"name":"total","type":"u64"},{"name":"paid","type":"bool"}]}'
```
```
{"table":1,"layout":"created"}
```

**5. A commit, with a key.** A commit is a list of entries applied together or not at all. The
`key` (32 hex digits, one per logical operation) makes a retry safe: the same request sent again
commits once ([Commit keys](./TUTORIAL.md#commit-keys-send-it-again-it-commits-once)).

```bash
R='{"key":"0190f1c2a7e47b3c9d2e5f6a7b8c9d0e","entries":[{"kind":"put","table":1,"id":"1001","fields":{"customer":"7","total":"4200","paid":false}}]}'
n -d "$R" $A/v1/commit
n -d "$R" $A/v1/commit      # the same request again
```
```
{"status":"committed","op":"8"}
{"status":"committed","op":"8","replayed":true,"code":"NRV-W0201"}
```

The second answer names the op the first committed at, and nothing was written twice.
`NRV-W0201` is a warning that says so ([docs/ERRORS.md](./ERRORS.md)); it is not a failure.

**6. A lookup.** A read goes through the log too, so its `op` says exactly which commits it
reflects; the row's own `op` is the op that wrote it.

```bash
n -d '{"rows":[{"table":1,"id":"1001"}]}' $A/v1/lookup
```
```
{"op":"10","rows":[{"table":1,"id":"1001","exists":true,"op":"8","value_hex":"07000000000000006810…0000","fields":{"customer":"7","total":"4200","paid":false}}]}
```

(`value_hex`, 160 hex digits in the real reply, is shortened here.)

**7. The change feed.** Change the order, then read the log of changes. The feed is in commit
order, and a consumer keeps its `cursor` to read only what is new
([The change feed](./TUTORIAL.md#the-change-feed)).

```bash
n -d '{"entries":[{"kind":"put","table":1,"id":"1001","fields":{"customer":"7","total":"4200","paid":true}}]}' $A/v1/commit
n "$A/v1/changes?limit=100"
```
```
{"status":"committed","op":"11"}
{"changes":[{"kind":"put","table":1,"id":"1001","op":"8","value_hex":"07…00","fields":{"customer":"7","total":"4200","paid":false}},{"kind":"put","table":1,"id":"1001","op":"11","value_hex":"07…00","fields":{"customer":"7","total":"4200","paid":true}}],"more":false,"cursor":"1794348963630280727","op":"12"}
```

(`value_hex` is shortened here too.) `"more":false` with `"op":"12"` says the feed is complete through
op 12. The row's history and its value at any past op are one request each:

```bash
n "$A/v1/row?table=1&id=1001&as_of=5"     # any op below your first commit's
```
```
{"table":1,"id":"1001","as_of":"5","exists":false,"op":"0","value_hex":"00…00"}
```

A wrong key is refused, with a code:

```bash
curl -s -H 'X-Nerva-Key: wrong' $A/v1/lookup -d '{"rows":[{"table":1,"id":"1"}]}' -w ' (HTTP %{http_code})\n'
```
```
{"error":"invalid key","applied":false,"code":"NRV-E0103"} (HTTP 401)
```

**8. Stop and clean up.**

```bash
kill $(jobs -p); wait
rm -f ~/nerva-quickstart/1_*.nerva
```

Stopping with `kill` is safe: a replica's data file survives a crash, and a restart replays it. To
keep what you made, leave the files and start the replicas again with step 2.

## Three hosts

The same cluster as a service: three machines on a private network, a cluster key, systemd
units. **Not run for this page**: it needs three hosts with systemd. The commands come from the
unit files and the examples the tarball and the packages ship
([`packaging/linux/`](../packaging/linux/)), and every output below is marked as not run.

Before you start:

- Three Linux machines (call their addresses `10.0.0.1`, `10.0.0.2`, `10.0.0.3`) on a private
  network that encrypts, such as WireGuard. **Only the three replicas, and the hosts that run a
  gateway or `nerva backup`, `export` or `recover`, may reach port `3001`.** The cluster key
  authenticates replicas to each other, not clients: anyone who can reach a replica's port can read
  and write without any key, and nothing on that port is encrypted. Close `3001` to everything
  else ([SECURITY.md](../SECURITY.md), [README, Limits](../README.md#limits)).
- A host for each gateway: usually the host of the process that calls it, which may be one of the
  three. It needs Nerva installed too (step 5) and must reach `3001` on all three replicas.
- Nerva installed on each host ([INSTALL.md](./INSTALL.md#linux)): `sudo ./install.sh` from the
  tarball, or a package. Both leave the user `nerva`, `/var/lib/nerva`, `/etc/nerva` and the units,
  and start nothing. They differ in two paths: the tarball's `install.sh` puts `nerva` in
  `/usr/local/bin` and the examples in `/etc/nerva`; a package puts `nerva` in `/usr/bin` and the
  examples in `/usr/share/nerva`. A leftover tarball install makes a package refuse on a first install with
  NRV-E1111 ([INSTALL.md](./INSTALL.md#the-deb-and-the-rpm)).
- A file system for `/var/lib/nerva` that supports Direct IO (ext4 and xfs do; tmpfs does not), and
  memory: about 3 GiB a replica at the defaults, 256 MiB for a gateway, and 1.1 GiB of disk for a
  replica's data file to start. Sizing and the rest of the production checklist are in
  [OPERATING.md](./OPERATING.md#sizing).

**1. Make one cluster key**, once, on any machine, and keep it as a secret (at least 32 bytes;
the same on all three replicas):

```bash
openssl rand -hex 32
```

**2. On each host, a replica's settings.** Copy the example to `/etc/nerva/replica-<n>.env`, where
`<n>` is that host's replica index (`0` on `10.0.0.1`, `1` on `10.0.0.2`, `2` on `10.0.0.3`), and
edit it; the file holds the key, so only root may read it. The example is in `/etc/nerva` after
`install.sh` and in `/usr/share/nerva` after a package; or write the file from the block below:

```bash
EX=/etc/nerva/replica.env.example               # after install.sh
EX=/usr/share/nerva/replica.env.example         # after a .deb or .rpm
sudo install -m 0600 -o root -g root "$EX" /etc/nerva/replica-0.env
sudoedit /etc/nerva/replica-0.env
```
```
NERVA_ADDRESSES=10.0.0.1:3001,10.0.0.2:3001,10.0.0.3:3001
NERVA_CLUSTER_KEY=<the key from step 1>
NERVA_DATA_FILE=/var/lib/nerva/0.nerva
NERVA_FLAGS=
```

**Set the example's `NERVA_CLUSTER_KEY` to your own.** The example leaves it empty, so a replica
whose file was copied and not edited is refused with `NRV-E0901` (`set NERVA_CLUSTER_KEY (at least
32 bytes)`) instead of starting on a key anyone can read.
`NERVA_ADDRESSES` is the same on all three hosts, in replica order. On the second host the file is
`replica-1.env` with `NERVA_DATA_FILE=/var/lib/nerva/1.nerva`, and so on. Leave `NERVA_FLAGS` empty:
never `--development` in production.

**3. Format each data file, as the `nerva` user** (the unit may write only `/var/lib/nerva`; give
the full path, since `sudo` and `runuser` may not search `/usr/local/bin`: `/usr/local/bin/nerva`
after `install.sh`, `/usr/bin/nerva` after a package). On host 0:

```bash
sudo runuser -u nerva -- /usr/local/bin/nerva format --cluster=1 --replica=0 --replica-count=3 /var/lib/nerva/0.nerva
```
```
(not run) info(main): 0: formatted: cluster=1 replica_count=3
```

On host 1, `--replica=1` and `/var/lib/nerva/1.nerva`; on host 2, `--replica=2` and
`/var/lib/nerva/2.nerva`.

**4. Start the replicas**, one `systemctl` on each host (`@0` on host 0, `@1` on host 1, `@2` on
host 2; the number is the instance, and it names the env file):

```bash
sudo systemctl enable --now nerva@0
systemctl status nerva@0
```
```
(not run) ● nerva@0.service - Nerva replica 0
(not run)      Active: active (running)
```

Once two of the three are up, the cluster has a quorum and commits. A replica that stops with an
exit status the unit lists (`1` to `8`) is not restarted, because a restart cannot fix it:
`journalctl -u nerva@0` shows its `error[NRV-E…]` block, and
[docs/ERRORS.md](./ERRORS.md) says what to do.

**5. A gateway beside each client.** `nerva-api@.service` runs `nerva api` for the process that
uses it, on loopback. On the gateway's host (Nerva installed there, and port `3001` of all three
replicas reachable), copy `api.env.example` (from `/etc/nerva` or `/usr/share/nerva`, as in step 2)
to `/etc/nerva/api-0.env`, set the cluster id, the three addresses and a key of your own for
`NERVA_KEY` (the example leaves it empty, and a gateway started with it empty is refused with
`NRV-E0008`, `set NERVA_KEY`),
and give it the same ownership and mode:

```
NERVA_CLUSTER=1
NERVA_ADDRESSES=10.0.0.1:3001,10.0.0.2:3001,10.0.0.3:3001
NERVA_KEY=<a key from openssl rand -hex 32>
NERVA_LISTEN=127.0.0.1:8080
NERVA_FLAGS=
```
```bash
sudo systemctl enable --now nerva-api@0
curl http://127.0.0.1:8080/healthz
```
```
(not run) {"ok":true,"session":"ready"}
```

The gateway speaks plain HTTP: leave it on loopback, beside its client, and put TLS in front of it
if anything off the machine must call it ([Gateways beside their clients](../README.md#gateways-beside-their-clients)).
A gateway that starts before the cluster has a quorum waits up to 30 seconds and then exits;
the unit restarts it.

**6. Use it.** Steps 4 to 7 of the one-machine half work unchanged against this gateway: the same
requests, with `$NERVA_KEY` set to the gateway's key. Replicas never take `--development`'s
shortcuts here: a wrong key between replicas is refused with `wrong cluster key` in the log, and a
replica without a key does not start.

## Where next

- [TUTORIAL.md](./TUTORIAL.md): every capability, with real replies: transactions, ledgers that
  conserve money, declared views, documents, records and indexes, crashes and retries.
- [README, JSON API](../README.md#json-api) and [Limits](../README.md#limits): the routes and what a
  caller can hit.
- [README, Backups](../README.md#backups), [Replacing a lost replica](../README.md#replacing-a-lost-replica)
  and [Upgrading a cluster](../README.md#upgrading-a-cluster): what to do before you rely on it.
- [README, When a command refuses](../README.md#when-a-command-refuses) and
  [docs/ERRORS.md](./ERRORS.md): every `NRV-` code.
- [API.md](./API.md): every route the gateway serves.
- [OPERATING.md](./OPERATING.md), [TROUBLESHOOTING.md](./TROUBLESHOOTING.md),
  [MATURITY.md](./MATURITY.md) and [SECURITY.md](../SECURITY.md): what a replica needs, what to do
  when something fails, what the label promises, and what the keys protect.
