# Operating Nerva

For someone who runs a Nerva cluster they did not build: how much machine it needs, what to check
before production, how to back it up and prove the backup, how to upgrade, how to replace a
replica, and what to alert on. It links to the README for the details and does not repeat them.

Nerva is alpha ([MATURITY.md](./MATURITY.md)). This page is advice for running
it with that label, not a promise of anything the label does not give.

**Recorded from.** Every output below was run by hand against the v0.7.1 candidate built from
`main` at `4ddd232` (`nerva version` printed `Nerva version 0.0.6+4ddd232`, `release 0.0.6`,
`version 0.7.0`: `VERSION` is bumped at release). It is re-recorded on the release commit. A
number or output that was not run says so. The review of this page re-ran the drill and the
backup file modes with the same binary; the `NRV-E0809` output and the 0600 modes under
`umask 077` were recorded again for this revision.

## Sizing

All numbers come from **one host**: 4 CPUs, 15 GiB of memory, no swap, an ext4 disk. They are
what that host measured, not a model. R3 (performance work across hosts, `docs/PRODUCTION.md`) has
not started, so there is no throughput or latency figure here and no CPU sizing: CPU use was not measured.

| What | Measured | Source |
| --- | --- | --- |
| A replica, defaults, started and idle | 3,006,008 kB resident (2.87 GiB). The log says `allocated 2925MiB during replica init` | `nerva start`, one replica, run for this page; the README says "3.0 GB at startup with the defaults" ([#127](https://github.com/NervaLog/nerva/issues/127), README "Upgrading a cluster") |
| The same, after 500,000 rows committed | 3,006,396 kB: it does not grow with the data | one replica, 5,000 commits of 100 puts of an 80-byte value, through a gateway, run for this page |
| A replica with `--cache-grid=512MiB` | 2,481,824 kB (2.37 GiB) | the same data file, run for this page; README "Caches" says what the flag sets |
| A replica with `--development` | 1,834,096 kB (1.75 GiB); `allocated 1780MiB during replica init` | run for this page. `--development` uses small caches and relaxes Direct IO: never in production |
| A gateway (`nerva api`), idle or after the same load | 91,832 kB idle, 92,204 kB after (about 90 MiB) | run for this page. README "Limits" bounds it: at most 8 MiB kept between requests, 128 MiB while one request is parsed |
| A data file, just formatted | 1,141,374,976 bytes (1.06 GiB), allocated whole, the same with or without `--development` | `nerva format`, run for this page |
| A data file after 100,000 rows | 1,175,982,080 bytes | the same replica |
| A data file after 500,000 rows | 1,312,821,248 bytes: about 340 bytes a row on top of the formatted size here, for 80-byte values, 100 to a commit | the same replica |

What follows from them:

- **Memory.** Plan **3 GiB a replica** at the defaults, **2.5 GiB** with `--cache-grid=512MiB`,
  and **256 MiB a gateway**: about 90 MiB idle, and README "Limits" lets one request take up to
  128 MiB more while it is parsed (about 220 MiB; that peak was not measured). The replica's memory is a fixed allocation made at start (the
  state machine's and the caches'), so a replica that starts is a replica that has its memory.
  Three replicas on one host take about 9 GiB at the defaults; give each its own host in
  production (below). A smaller `--cache-grid` trades memory for reads from disk.
- **Disk.** One data file per replica, at least 1.1 GiB on day one, growing with the log: every
  change is kept, and history grows with writes (README "Declared views"). **There is no
  retention before R7**: nothing is deleted, so budget for the data file you will have, not the
  one you have. Every replica's file is identical, so **all replicas fill together**. Backups,
  exports and drill files written to the same disk count against the same space. The default limit is 16 TiB; a file that outgrows it stops the replica with exit
  4 or 5 and NRV-E0707, and the limit cannot be raised in this release (`docs/ERRORS.md`). A
  backup is a whole export, about 121 bytes a change (README "Backups"), and one made while this
  page was written (50,005 changes) was 6,050,938 bytes.
- **Not measured.** Data file growth past 500,000 rows, a three-host cluster's memory, any
  workload's latency, and how many gateways one replica takes before it slows. Do not read them
  into this table.

## Production checklist

Do these before a cluster holds anything you care about.

1. **Linux.** Production is Linux, with a kernel of 5.11 or newer (io_uring; NRV-E0705
   refuses an older one). macOS runs the same binary for development only. x86_64 with AES, or
   aarch64.
2. **Direct IO and the file system.** A data file goes on **ext4 or XFS**. A file system that
   cannot do direct IO refuses the start (NRV-E0704, exit 2). Do not pass `--development` to get
   round it: it also shrinks the caches, and it is for tests. A network file system, an overlay or
   a `tmpfs` is not what you want under a data file.
3. **Clocks.** Run chrony or systemd-timesyncd on every replica host. The replicas' clocks must
   agree within 10 seconds (`clock_offset_tolerance_max`, `src/config.zig`); past that the
   cluster cannot synchronise its clock, the primary drops client requests (its log says
   `on_request: dropping (clock not synchronized)`) and writes stop. None of the alerts below
   names that cause.
4. **One replica per host, three hosts at least.** A cluster of three survives one lost host
   and a cluster of one or two cannot replace a replica (README "Replacing a lost replica").
   Put each replica's data file on its own disk, away from the disk anything else writes to
   hard.
5. **Memory.** Use the sizing above. The unit sets `LimitMEMLOCK=infinity` and
   `LimitNOFILE=65536`; if you start `nerva` another way, set them too.
6. **Ports and the firewall.** Each replica has one `host:port` in `--addresses` (the examples use
   3001). A replica's port is reachable **only** by the other replicas, by the hosts that run
   gateways, and by the hosts that run `backup`, `export` or `recover`, and by nothing else.
   Anyone who reaches it needs no key: they can take all 64 client sessions and evict every
   gateway, and they can declare a view with no catalog document, which makes every later
   `export`, `backup` and `import` refuse, blocking backups and the only cross-release upgrade
   path (#303). Nothing needs to reach a gateway from outside its own host: it listens on
   `127.0.0.1` (README "Gateways beside their clients"). Open a replica's port to those hosts
   and to nothing else.
7. **A private network that encrypts.** The cluster key proves who opened a connection between
   two replicas; what follows is neither encrypted nor signed, and anyone who can reach a
   replica's port can act as a client (README "Replicas authenticate each other", "Network"
   under Limits). Run replicas on WireGuard or Fly.io's 6PN, reachable only by the cluster and
   its gateways. A gateway speaks plain HTTP on loopback: if one must listen elsewhere, put TLS in
   front of it and read [SECURITY.md](../SECURITY.md) first.
8. **Keys.** The cluster key (`NERVA_CLUSTER_KEY`, at least 32 bytes, the same on every replica)
   and each gateway's `NERVA_KEY` live in root-owned, mode 0600 environment files, never on a
   command line. Make them with `openssl rand -hex 32`. README gives the rotations without
   downtime ("Replicas authenticate each other", "Limits").
9. **systemd.** The tarball's `install.sh` and the packages install `nerva@.service` (one
   replica per instance, `nerva@0` reads `/etc/nerva/replica-0.env`) and `nerva-api@.service` (one
   gateway per instance, `/etc/nerva/api-0.env`), from
   [packaging/linux](../packaging/linux/). Format each data file first, as the `nerva` user, then
   `systemctl enable --now nerva@0`. Nothing formats, enables or starts a replica for you. The
   units run as the `nerva` user with `ProtectSystem=strict` and write only to `/var/lib/nerva`;
   change a setting with a drop-in (`systemctl edit nerva@0`), not by editing the unit. Their
   restart rules matter for alerting, below. [INSTALL.md](./INSTALL.md) and [QUICKSTART.md](./QUICKSTART.md) do the
   installation and a first cluster.
10. **A time for the backups, and a place for them** (below), and a drill that you have run once.
11. **Metrics going somewhere.** `--statsd=<host:port>` on every replica and gateway (README
    "Metrics and traces", "Gateway metrics"), and the alerts below.

## Backups and a restore drill

`nerva backup` is an export that checks itself and writes a manifest beside it; `nerva restore` is
`nerva import` with the manifest checked first. Their behaviour, refusals and codes are in the
README ("Backups") and the v0.7.0 notes in [CHANGELOG.md](../CHANGELOG.md). What to do with them:

- **Take one on a schedule** from a host that is allowed to reach the replicas' ports (checklist
  item 6; it takes one of the cluster's 64 client sessions, below). Neither file is overwritten,
  so give each a new name, for example by date. `--as-of=<op>` backs up an earlier op while
  writers go on.
- **Make them private.** Until [#302](https://github.com/NervaLog/nerva/issues/302) is fixed, `nerva backup` (and `nerva export`) creates the backup and its manifest
  **world-readable** (mode 0644, though the data file is 0600; [SECURITY.md](../SECURITY.md)): run it under `umask 077` (in the
  unit or the cron job) and write into a directory of mode 0700. Under `umask 077` both files
  were 0600 in the run recorded here. A backup holds every row and its history unencrypted
  (there is no encryption at rest), so protect every copy you keep elsewhere as you would the
  data.
- **Alert on the job.** Check the job's exit status, and the age of the newest backup that
  passed (a refusal is a failed job: `backup` refuses, among other things, a full destination,
  NRV-E0706, and a cluster where a view was declared without a catalog document). A job that
  has failed for weeks is the data loss this page exists to prevent.
- **Keep both files, apart.** The manifest is the record that catches a damaged or swapped
  backup, and it holds no checksum of its own: keep it somewhere the backup's storage cannot
  change it, and keep more than one generation. How long is yours to decide; Nerva has no
  retention.
- **What a backup does not hold.** A backup is the committed log's contents (rows, records, their
  history, documents, layouts, views, ledgers, indexes' declarations and commit keys), not a copy
  of a data file. It does **not** hold client sessions: a client that was connected registers
  again after a restore. It does not hold the cluster key or any gateway key (keep those
  yourself), the replicas' logs, their configuration, or the checkpoint and op numbers: a
  restored cluster is an imported one, op numbers jump to the next checkpoint, and its replicas
  carry the backup's SHA-256 as their origin, which `nerva recover` then needs as `--origin`.
  Indexes are declared again and rebuilt by the new cluster. Writes after the backup's op are not
  in it.

### The drill

Run it once before you need it and again after every upgrade. `--cluster` may differ from the
backup's, so the backup is restored into a **separate one-replica cluster of another id** and
compared with the live one. Run the drill **on a spare host**, never beside a live replica: a
replica at the defaults is about 3 GiB resident (3,006,456 kB measured for a drill replica) plus
its gateway, and its data file is 1.15 GB plus the backup. Beside a live replica on a host sized
as this page says, the OOM killer may take either process or the restore may fill the data
disk (NRV-E0706, which the unit does not restart). On the live cluster the drill costs one
client session (the backup) and some reads.

1. **Back up.**

   ```bash
   nerva backup --cluster=3 --addresses=127.0.0.1:3101 --output=b.nerva-backup
   ```

   The reply is one line on stdout and one naming the manifest (the log lines before them are
   stderr):

   ```
   backup b.nerva-backup: op 520, sha256 4516542ab2933614d0ec57f78c93115375af91e6684ef4d181a6996e94b0baf9
   manifest b.nerva-backup.manifest.json
   ```

   The manifest here was 368 bytes: `{"format":"nerva-backup","version":1,"release":"0.0.6",
   "cluster":"3","op":"520","export_sha256":"4516…baf9","export_size":"6050938",
   "export_version":1,"views":[{"name":"by_section","id":1,"state":"ready","view_hash":"8583…49e5",
   "groups":"10"}],"ledgers":[]}`.
2. **Restore into another cluster id, on the spare host.** Use `--replica-count=1`:

   ```bash
   nerva restore --cluster=4 --replica=0 --replica-count=1 \
       --input=b.nerva-backup --manifest=b.nerva-backup.manifest.json 4_0.nerva
   ```

   ```
   restored replica 0 from backup 4516542ab2933614d0ec57f78c93115375af91e6684ef4d181a6996e94b0baf9 at op 520: 1 view and 0 ledgers match the manifest
   ```

   Before it creates a file, it compares the backup's size, SHA-256, op and version and every
   view's and ledger's check with the manifest. A mismatch is refused, and no data file is left.
   Recorded from a separate, empty one-replica cluster (its backup was as of op 5), with a copy
   of the manifest edited to say `"op":"999999"` and passed as `--manifest=bad.manifest.json`:

   ```
   error[NRV-E0809]: restore: b.nerva-backup does not match bad.manifest.json: the backup is as of op 5; the manifest says op 999999
   ```

   A manifest that is missing or malformed is `NRV-E0808`, a damaged backup `NRV-E0804`
   (`docs/ERRORS.md`).
3. **Start it and look.** `nerva start --addresses=<its own address> 4_0.nerva` (with its own
   `NERVA_CLUSTER_KEY`), a gateway with `--cluster=4` and its address, and read what you
   declared:

   ```bash
   curl -H 'X-Nerva-Key: secret' http://127.0.0.1:8081/v1/views/by_section
   ```

   Compare its `view_hash` and `groups` with the **manifest's** (and a ledger's total with
   `GET /v1/ledgers/<id>`), or with the live cluster read `?as_of=<backup op>`: the live
   cluster has taken writes since the backup, so its current view differs and is not the
   comparison. In the run recorded here the drill and the live cluster read at the backup's op
   had the same `view_hash`, `8583cb08…`, and identical `groups`. The drill cluster answered at op 1006, not 520: op numbers
   jump after a restore, and versions you hold from before stay valid.
4. **Stop and delete the drill's files.** Never start a drill replica with the live cluster's id
   and addresses.

For a real restore of a three-replica cluster:

1. Stop every replica, and copy the backup and its manifest to each replica's host.
2. On each host, **move the old data file away** (`restore` never overwrites a file: NRV-E0004;
   keep the old file until the restored cluster is checked). Then restore from the same backup,
   with the cluster's own id and `--replica=0`, `1`, `2` on the three hosts:

   ```bash
   nerva restore --cluster=<id> --replica=0 --replica-count=3 \
       --input=b.nerva-backup --manifest=b.nerva-backup.manifest.json 0_0.nerva
   ```

3. **Write down the backup's SHA-256** (`restore` prints it, and the manifest has it as
   `export_sha256`): it is now the cluster's origin, and a later `nerva recover` needs
   `--origin=<that sha256>`. With `--origin=none` the recovered replica exits 8 with NRV-E0711.
4. Start the three replicas.

A replica of a running cluster is never restored alone (P90): that is `nerva recover`, below.

**What was run, and what was not.** The page's drill ran on one replica as the live cluster
(`--development`, because the disk could not hold four data files), with a declared view over
50,000 rows. The `restore` flags in the real-restore steps are those of `nerva --help`; the
steps themselves were not run as written on three hosts. The same drill with a three-replica source, a restore of all three replicas and a
ledger in the manifest was not run for this page; `zig build demo-r5` runs those against three
replicas (`docs/demos/r5.md`).

## Upgrading

- **v0.7.0 to v0.7.1, in place.** Both binaries run the same protocol release (`release 0.0.6` in
  `nerva version`), the same data file and the same export format, and the v0.7.1 audit found
  no new kind of op and no state machine change (P284, P275). [MATURITY.md](./MATURITY.md) states
  the promise as no more than this: within v0.7.x a newer release is *meant* to open an older
  one's data files in place, and the release audit confirms each such path. So this one upgrade
  is a binary swap, one replica at a time: no export or import. The swap works only
  because both binaries run the same release; it is not R6's rolling upgrade across releases.
  **Each later v0.7.x's notes say whether it is in place** (P275 makes that a per-release audit,
  and P260 withdrew the same promise for two releases that shared `0.0.6`: #272, #270), and
  **a rollback holds only where the notes say so**. Read them before you upgrade, not after.
  Take a backup and run the drill first, and compare `nerva version` before and after.
  **Order: every replica first, then gateways and other clients** (P260). For each replica: stop
  it, start it with the new binary, and wait until its `tb.replica_commit_min` gauge
  (`--statsd`) has reached the other replicas', or its log says `sync: done` if it
  state-synced (README "Replacing a lost replica"), before the next one. A cluster of three
  keeps its quorum while one is down. Never run a new gateway, or a client that sends several
  batches in one request, against a replica of an older release that has the bug the new notes
  name: the v0.7.0 notes ("Upgrading from v0.6.1" in
  [CHANGELOG.md](../CHANGELOG.md#upgrading-from-v061)) say which and why.
  **On a host with the tarball's single `/usr/local/bin/nerva`, replicas and gateways share one
  binary.** Replacing it means a `nerva-api@` gateway on that host runs the new release on its
  next restart, and the gateway unit restarts on exit 1, which can happen before every replica is
  done. Stop that host's gateways before the swap, or install the new binary beside the old
  one and point the replica units at it with a drop-in. Under systemd: `systemctl restart
  nerva@0` after replacing the binary, one instance at a time, then `nerva-api@0`.
- **A rollback** is safe only as the release notes say it is (the v0.7.0 notes give the condition
  for v0.7.0 to v0.6.1).
- **The next protocol release** (the first one that ships rolling upgrades, R6) **is an export
  and import** from v0.7.x, said in its notes (P259g): a v0.7.0 binary runs one release and
  cannot offer a newer one, so replicas of the two cannot take turns. Take a backup, then follow
  README "Upgrading a cluster": `nerva export` with the old release, stop every replica,
  `nerva import` once per replica with the new one, start them. The cluster is closed for the
  time that takes (a million changes took 5.8 s to export and 14 s to import on a 4-CPU
  sandbox, README), and client sessions do not carry over. No release has a rolling upgrade
  yet: the first one will be from that release to the next.

## Replacing a lost replica

A replica whose disk is gone rejoins a running cluster without closing it: `nerva recover`
makes the replacement's data file and `nerva start` runs it. The steps, the refusals and the
address-change case are in the README ([Replacing a lost replica](../README.md#replacing-a-lost-replica));
`zig build demo-r5` and [docs/demos/r5.md](./demos/r5.md) show it under load. Three replicas at
least; a cluster of one or two restores from a backup. One replica at a time, and
`--origin` is `none` for a cluster made by `nerva format`, or the SHA-256 of the export or backup
it was made from.

## What to alert on

Send both processes' metrics with `--statsd` (README "Metrics and traces" and "Gateway
metrics"; a window is 10 seconds). Page on these, in this order of importance:

| Alert on | Why |
| --- | --- |
| `nerva.api.unknown` above 0 (any `route`) | A reply said `applied: "unknown"`: a write went out and no answer came back (NRV-E0601, B0002 or B0001). The caller must resend only under its commit `key`, or read the rows. This is the one to page on |
| `nerva.api.session` at 0 for more than a window or two, or `/healthz` answering `503` | The gateway has no cluster session. It reconnects by itself, so a short 0 is normal; a long one means the cluster is out of reach or has no quorum |
| `tb.replica_commit_max` not advancing on any replica while clients write, or one replica's `tb.replica_commit_min` stuck behind the others' | The cluster has stopped committing, or one replica cannot catch up. Check how many replicas are up |
| A replica unit that is not `active`, or whose `NRestarts` rises, whatever its exit status | The unit does not restart statuses 2 to 8 and 70 (`RestartPreventExitStatus=2 3 4 5 6 7 8 70`, since a restart cannot fix them), so a crash can become permanent: 2 the disk or the kernel; 3 to 6 the data file's limits; 7 and 70 a bug (`NRV-B0003`, `NRV-B0004`); 8 a data file imported from another export (`NRV-E0711`). Exit 1 restarts (a flag or the data file, but also a restart that finds the dead process's lock still held, NRV-E0703, #294, or a `--statsd` collector with no route at start, NRV-E0010, #292): the unit restarts after 5 s, and twenty starts in 300 s stop it as `failed`, so a permanent exit 1 stops after about 100 s, a transient one (a route that appears within that time) is retried, and `NRestarts` shows it. Look up the code in `docs/ERRORS.md`. A disk failure (`NRV-E0708`, today a panic) is a crash, not an exit status the unit can name: it restarts every 5 s, and the same limit ends it as `failed` after about 100 s; a crash loop slower than every 15 s never reaches `failed`, and only `NRestarts` shows it |
| A gateway `/healthz` that does not answer `200` (refused, timed out or `503`), and the gateway unit's `NRestarts` rising or the unit not `active` | A gateway that cannot reach a quorum waits 30 s, exits 1 with `NRV-E0604`, and is restarted 1 s later: one start about every 31 s, never the 5 in 10 s that stops the unit, so it never reaches `failed`. During that loop `/healthz` refuses connections and `nerva.api.session` is never sent, so the rows above and `failed` do not fire. Exit 2 is not restarted |
| `nerva.api.refused` with `reason` `busy`, `displaced` or `queue_wait`; `nerva.api.requests` with status `503` or `504` | The gateway is saturated or the cluster is slow; add gateways beside clients, but count sessions first (below) |
| `nerva.api.statsd_dropped` above 0 | Your metrics are losing lines |
| Disk free on a replica's data disk below the larger of **5 GiB** and **14 days of the file's observed growth** (as a first estimate, about 340 bytes a row in the table above: 1 GiB is about 3 million rows of 80-byte values) | A full disk is NRV-E0706 and exit 2, which the unit will not restart. Every replica's file is identical and grows together, so replicas on disks of one size fill within minutes of each other, and the whole cluster stops and stays stopped. Backups, exports and drill files on the same disk count |
| A scheduled backup that failed, or a newest good backup older than your interval plus a margin | See "Backups": a refusal is a failed job, and nothing else notices |

Gateways send nothing when idle except the two gauges, and `nerva view` sends nothing. A
metric missing for several windows is itself an alert: for a replica, a gateway that stopped, or
a host that went away.

## The 64 client sessions

A cluster holds **64 client sessions**. Every `nerva api`, `nerva view`, `nerva export`,
`nerva backup`, `nerva recover` and Zig client takes one, and the 65th evicts the one that
committed least recently; that client's next request fails (a gateway reconnects on its own, and counts it in
`nerva.api.reconnects`). The eviction is quiet, so count before you add: one gateway per client
process, plus a few spare for the backup, the drill and an export or `recover` you may need in an
emergency. See README "Gateways beside their clients" and "Limits". Nothing alerts on the count in this
release.

## Where to go next

[INSTALL.md](./INSTALL.md) installs it and [QUICKSTART.md](./QUICKSTART.md) runs a first cluster.
[TROUBLESHOOTING.md](./TROUBLESHOOTING.md) says what to do when a command, a gateway or a replica
refuses, and [API.md](./API.md) is the gateway's route reference. [SECURITY.md](../SECURITY.md),
[MATURITY.md](./MATURITY.md) and [NON-GOALS.md](./NON-GOALS.md) say what the keys protect, what the
label promises and what Nerva does not do. The sources behind them are the README's "Limits",
[docs/ERRORS.md](./ERRORS.md) and [CHANGELOG.md](../CHANGELOG.md).
