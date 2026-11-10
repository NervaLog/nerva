---
id: P262
date: 2026-11-10
area: Releases
amends: P242j
---

# `--lazyfs-all-nodes` also needs 16 GiB available, and a refusal is one line

The decision.

1. `check-host-memory!` requires `MemAvailable` of at least 16 GiB beside `MemTotal` of 32 GiB. A
   64 GB host whose memory the simulation fleet still holds (its stop is `ExecStartPre=-`, which
   ignores a failure) passed on `MemTotal` alone. The check measures the harness host, which is the
   machine the replicas run on only because `run.sh` starts the nodes as containers there.
2. The 32 GiB `MemTotal` floor stays. A 32 GiB machine reports about 31.5 GiB, so it is refused;
   the rule is for the 64 GB R1 host, and lowering the floor would let a smaller host in, a change
   to P242j's rule that the owner makes.
3. A refusal (`ex-data` `:refusal`) reaching `nerva-test` through `-main` is one stderr line and
   exit 2, not Jepsen's fatal stack trace and exit 255. `core/refusing` wraps both `test`'s test
   function and `test-all`'s tests function (realised with `doall`, as `test-all` builds its tests
   outside its per-test `try`). `analyze` shares `test`'s function, so re-analysing a
   `--lazyfs-all-nodes` store on a small host is refused too: left as it is, because splitting it
   needs a Jepsen CLI change. Exit 2 is also Jepsen's `:valid? :unknown`; the nightly judges by
   whether a store exists, so the overlap is accepted. The refusal names its cause: the read error,
   or the `/proc/meminfo` field that is missing (`read-meminfo` uses `Files/readAllLines`, as
   `slurp` throws `Invalid argument` on procfs in some JVMs).
4. `jepsen.yml` refuses `unpatched-lazyfs` unless `args` has `--nemesis` naming
   `lose-unfsynced-writes` and `--lazyfs-strict-sync`: NRV-E0607 (the run is the harness's input
   error). Without strict mode the canary was green and proved nothing. Only the last `--nemesis`
   counts, as in tools.cli, so `--nemesis lose-unfsynced-writes --nemesis kill` is refused.

16 GiB is `ops/jepsen/README.md`'s measured 13.5 GiB for five replicas and five LazyFS mounts,
rounded up, plus part of the `-Xmx3g` JVM heap. It is not derived further. `MemAvailable` is read
once at test construction, before the mounts, so it is a floor and not a guarantee: a host at
exactly 16 GiB can still end with less than the hosted runner's 0.4 GiB (13.5 plus up to 3 GiB of
heap is about 16.5). The 64 GB host with the fleet stopped has the margin.

Cost: a host with plenty of memory but a busy neighbour is refused until it is stopped. Left to
the owner (#257 item 2): the OOM-kill attribution and the thin hosted margin.
