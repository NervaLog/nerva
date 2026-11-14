---
id: P414b
date: 2026-11-14
area: Testing
amends: P414
---

# `bench-load` renames an output into place only where that keeps a plain open's semantics

**Decision.** `OutFile` (`--timeline`, `--gateway-pid-file`, `--output`) writes a temporary file
and renames it only when the path does not exist, or names a regular file with one link that the
process owns and can write. The temporary file gets that file's permission bits (`fchmod`) and its
group (best effort). In every other case (another owner, several links, a directory that cannot be
written, a dangling symbolic link, anything that is not a regular file) the target is opened as a
plain open for writing, exactly as before `OutFile`: not atomic, and a regular file is truncated
when opened. If the rename is refused at `commit` anyway, the content is copied into the path in
place, so the run's result is not lost. The PID file is removed on `stop` whenever it is a regular
file, however it was written. The race between looking at a path and opening it is accepted
(documented in the code): the tool writes into directories its own operator controls.

**Reason.** Replacing a file by rename changes what a plain open does: a 0600 file became 0664, a
hard link was broken, a file of another user in a sticky directory passed `access` and then failed
at the rename after the whole run, and a writable file in a read-only directory was written in
place yet documented as surviving a failure. Using the rename only where none of that can differ
makes the code, the doc comment, README and `docs/ERRORS.md` say the same thing.

**Cost.** Atomicity is promised only for the common case. A file in a read-only directory, a hard
link or another user's file is emptied at open, so a later failure leaves it empty. ACLs and
extended attributes of a renamed file are not copied. A FIFO blocks the start until a reader
appears.
