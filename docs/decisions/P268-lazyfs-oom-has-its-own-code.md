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
   and a `:reason`, when the kernel's log shows an OOM kill of a process named `lazyfs` since the
   count taken at setup and that node's `lazyfs` process is gone. It is checked after each fault
   and at the final recovery, and it outranks NRV-E0604 and NRV-E0608: a dead LazyFS takes the
   mount and the replica's data file with it, so a down replica or lost bytes after it are its
   doing, not Nerva's.
2. The signal is the kernel's own line (`Out of memory: Killed process N (lazyfs)`), read with
   `dmesg` (the nodes are privileged containers), else `journalctl -k`. It was chosen over
   `docker inspect`'s `OOMKilled` (it flags a container's init process, and the nodes have no
   memory limit: the kernel kills on the host's shortage) and over "process gone" alone (a crash
   is not memory). The ring buffer is the host's and keeps earlier runs' lines, so the count is
   taken at setup and only a new line counts; an unreadable log claims nothing.
3. The nightly's reporter classes NRV-E0611 with NRV-E0607 (`HOST_VERDICT_CODES`): the host's,
   counted as `error` and never filed; a real finding elsewhere still outranks it.
4. Registered in docs/ERRORS.md. (E0609 and E0610 are R6 slice 1's.)

Cost: a kill with no kernel line (an unreadable log, a different process name) is still
NRV-E0607's unchecked sentinel, and one between the last fault and teardown is seen only if the
final recovery sees it. Nothing here has met a real OOM kill.
