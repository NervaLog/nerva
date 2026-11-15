---
id: P333
date: 2026-11-11
area: Errors
---

# The coded texts of vendored fatal exits live in `src/nerva/fatal_messages.zig`

**Decision.** Exits 2, 3 and 6 of `nerva start` print NRV-E0706, NRV-E0721 and NRV-E0722. Their
texts are constants in `src/nerva/fatal_messages.zig`, which `vsr.zig` re-exports; the vendored
call sites (`storage.zig`, `node_pool.zig`, `manifest_log.zig`) name the constant. Statuses are
unchanged. E0721 and E0722 say there is no flag to raise the limit: the cluster has reached a limit
of this build. Their fix is to report it with the replica's log (#334) and not to delete data
files; export and import cannot help, since the cluster cannot run and no build with other limits
exists. Their blame is `internal`: a missing bound (the primary should refuse before the exit), not
an operator's mistake (#334).

**Why.** `vsr.fatal` exits the process, so no unit test can trigger it; a constant can be held to
the register and to a list of banned flags by a test. The vendored patch stays one line per site.

**Cost.** Two more vendored lines of text are Nerva's to carry (UPSTREAM.md). Exits 3 and 6 are
still not triggered end to end.
