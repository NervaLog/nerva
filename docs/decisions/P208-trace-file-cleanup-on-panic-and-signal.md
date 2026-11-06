---
id: P208
date: 2026-11-06
area: Errors
---

# `start --trace` also removes its file on a panic and on SIGINT or SIGTERM

**Decision.** The `nerva` binary's root file declares `pub const panic = std.debug.FullPanic(...)`
over `diagnostic.panic`, which runs the registered cleanup once and then calls
`std.debug.defaultPanic` unchanged, so the message and trace are as before. A flag makes a panic
inside the cleanup, or a second panic, go straight to the default handler. While a file is
registered (from `cleanup_register` to `cleanup_clear`), SIGINT and SIGTERM have a handler that
unlinks the registered path with raw system calls on the fixed buffer (after the same inode check),
restores the default action and re-raises, so the exit status still reports the signal. A signal
that was ignored before (`nohup`, a shell's `&`) gets no handler. `cleanup_clear` puts the earlier
actions back. `cleanup_run` keeps the registration until the removal is done, so a signal that
interrupts it still removes the file.

**Reason.** #206, options 1 and 3: the next start with the same `--trace` is refused with NRV-E0004,
which hides the real cause (#197). The cleanup these changes extend came with #197 (#202), which has no decision file. Nothing vendored installs a handler for these signals on the
`nerva` binary's path (`src/stdx/unshare.zig` does, for SIGTERM, but only the vortex supervisor
calls it), so there is nothing to fight.

**Cost.** A signal arriving after `replica.open` returns is not covered, by design: the file is the
operator's then. Vendored `vsr.fatal` exits (NRV-E0707) still leave the file; that is #206's option
2, a vendored patch, and stays with the owner. SIGKILL cannot be handled. The handlers and the
panic hook are tested in forked children that raise SIGTERM, SIGINT and a panic with a registered
file (the file is gone, the exit status reports the signal or SIGABRT). No test sends a signal
during `replica.open` itself: that window is too short to hit deterministically.
