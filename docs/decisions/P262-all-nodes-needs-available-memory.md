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
   exit 2 (`core/refusing-test`), not Jepsen's fatal stack trace and exit 255.
4. `jepsen.yml` refuses `unpatched-lazyfs` unless `args` has `--nemesis` naming
   `lose-unfsynced-writes` and `--lazyfs-strict-sync`: NRV-E0607 (the run is the harness's input
   error). Without strict mode the canary was green and proved nothing.

Cost: a host with plenty of memory but a busy neighbour is refused until it is stopped. Left to
the owner (#257 item 2): the OOM-kill attribution and the thin hosted margin.
