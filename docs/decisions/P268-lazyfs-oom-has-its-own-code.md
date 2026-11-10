---
id: P268
date: 2026-11-10
area: Releases
amends: P242j
---

# A LazyFS out-of-memory kill is NRV-E0611, the host's, not NRV-E0608 or NRV-E0604

The owner's answer of 2026-11-10 to item 2 of #257: when the host's memory kills LazyFS, the
harness reports it as its own verdict with its own code, `NRV-E0611`, and P242j's memory rule
(32 GiB total, 16 GiB available for `--lazyfs-all-nodes`) stays as it is.

1. The `lazyfs` verdict is `:valid? :unknown` with `:code "NRV-E0611"`, `:oom-killed` (the nodes)
   and a `:reason`, when the kernel's log shows a new OOM kill of a process named `lazyfs` that
   names that node's own container and that node's `lazyfs` process is seen gone, and no finding
   stands. It excuses only that node's replica, whose data file is on the dead
   mount (`:replica-down`). Its gateways do not use the mount (`nerva api` runs in `/opt/nerva` and
   reaches the cluster through every replica), so a gateway `:down` or `:pending` there is still
   NRV-E0604, as is anything on another node (`:valid? false`, the kill beside it as `:oom-reason`; another
   node's sentinel-survived `:reason` is kept as `:harness-reason`), and a
   final recovery that threw has no node, so it is never excused. It never outranks NRV-E0608: lost
   bytes are LazyFS's own report, made while it was alive, so the kill, which came after, did not
   cause them. It outranks NRV-E0607 only.
2. The signal is the kernel's own line (`oom-kill:...,task_memcg=/docker/<id>,task=lazyfs,...`),
   read with `dmesg` (the nodes are privileged containers; no `journalctl` is installed in them,
   so there is no fallback: an unreadable log claims nothing). The ring buffer is the host's, so
   every node reads every node's kills: a line counts for a node only when it names the container
   id from the node's own `/proc/self/mountinfo`. The lines are kept as a set at setup and a new
   one is a line not in it; a count would go down when the buffer rotates and hide a kill. It was
   chosen over `docker inspect`'s `OOMKilled` (it flags a container's init process, and the nodes
   have no memory limit) and over "process gone" alone (a crash is not memory). A process that
   cannot be asked about claims nothing.
   The probe runs after each fault, in the fault's failure path too (a dead LazyFS makes `lose!`
   throw), and at the final recovery on every mounted node, in its failure path too. What it sees
   is kept, so a kill seen once is still reported when a later probe cannot ask. Nothing restarts
   a killed LazyFS (`lazyfs/mount!` runs only in `db/setup!`), so it stays dead to the end of the
   run. `lazyfs-running?` says gone only on `pgrep` exit 1; a timeout or error claims nothing. A final recovery that threw after a
   kill is returned as the op's `:exception` with the evidence.
3. The nightly's reporter classes NRV-E0611 with NRV-E0607 (`HOST_VERDICT_CODES`): the host's,
   counted as `error` and never filed; a real finding elsewhere still outranks it.
4. Registered in docs/ERRORS.md. (E0609 and E0610 are R6 slice 1's.)

Cost: a kill with no kernel line naming the container (a different process name, a log that
rotated it out before the probe, a node whose container id cannot be read) is still
NRV-E0607's unchecked sentinel, and one between the last fault and teardown is seen only if the
final recovery sees it. A final recovery that throws without an `:oom-killed` node attached, or beside another
node's finding, stays NRV-E0604: a throw cannot be tied to a node, and a Nerva finding wrongly
excused costs more than a host failure wrongly filed. Nothing here has met a real OOM kill.
