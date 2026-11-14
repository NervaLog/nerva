---
id: P431
date: 2026-11-14
area: Releases
amends: P290
---

# The pre-flight reads the lock's holder from `/proc/locks`: a live holder is refused at once

- **Decision:** when the pre-flight's `flock` fails, it reads `/proc/locks` (at most 64 KiB) for the
  `FLOCK` entry of the data file (matched by the file's device and inode, as `fstat` gives them).
  If the holder's pid is a live process (`kill(pid, 0)`, and not a zombie in `/proc/<pid>/stat`),
  it refuses NRV-E0703 on that attempt and the message ends in `(pid N)`. If the holder is gone, a
  zombie, in another pid namespace (pid 0), absent from the table, or the table cannot be used
  (macOS, unreadable, over the size bound, a block device, a file system whose device `/proc/locks`
  names differently), the 2 s bound of P290 stays, as does the message without a pid. The wait no
  longer sleeps after its last attempt. No new code: E0703's message is extended, and the test
  `tests/errors/commands.py` still matches "another process holds".
- **Reason:** #294. A killed process's lock lingers for up to a few hundred ms while the kernel
  tears down its ring, and the holder seen in `/proc/locks` was the dead pid in every case the
  review caught. A live holder is a running replica, and waiting 2 s for it helps no one. The
  operator is told which process to stop.
- **Cost:** a lock held by a live process that exits within the 2 s is now refused, where P290
  would have waited for it; the supervisor restarts as it would for any E0703. A child that
  inherited the descriptor of a dead holder keeps the lock under the dead pid: it waits the 2 s and
  is refused without a pid. The exit status of E0703 (#294's second point) is for #292, not
  decided here.
