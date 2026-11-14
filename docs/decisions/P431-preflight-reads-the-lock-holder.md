---
id: P431
date: 2026-11-14
area: Releases
amends: P290
---

# The pre-flight reads the lock's holder from `/proc/locks`: a live holder is refused at once

- **Decision:** when the pre-flight's `flock` fails, it reads `/proc/locks` (at most 64 KiB) for the
  `FLOCK` entry of the data file (matched by the file's device and inode, as `fstat` gives them).
  If a process with that pid has the file open (a descriptor in `/proc/<pid>/fd`, at most 4096
  scanned, with the same device and inode), it refuses NRV-E0703 on that attempt and the message
  ends in `(pid N)`. If the holder is gone, a
  zombie, in another pid namespace (pid 0), absent from the table, or the table cannot be used
  (macOS, unreadable, over the size bound, a block device, a file system whose device `/proc/locks`
  names differently), the 2 s bound of P290 stays, as does the message without a pid. The wait no
  longer sleeps after its last attempt. No new code: E0703's message is extended, and the test
  `tests/errors/commands.py` asserts `another process holds <data> (pid <its own>)` where `/proc/locks` names the file as
  `fstat` does, and the message without the pid elsewhere.
- **Reason:** #294. A killed process's lock lingers for up to a few hundred ms while the kernel
  tears down its ring, and the holder seen in `/proc/locks` was the dead pid in every case the
  review caught. A live holder is a running replica, and waiting 2 s for it helps no one. The
  operator is told which process to stop.
  `/proc/locks` keeps the pid a lock was taken by after that process is reaped, and the number can
  be reused, so a pid is named only if it holds the file; one namespace (`/proc`) is used for both
  steps, no `kill`.
- **Cost:** a lock held by a live process that exits within the 2 s is now refused, where P290
  would have waited for it; the supervisor restarts as it would for any E0703. A child that
  inherited the descriptor of a dead holder keeps the lock under the dead pid: it waits the 2 s and
  is refused without a pid. A holder that is exiting
  (`PF_EXITING` in `/proc/<pid>/stat`, still in `do_exit` before `exit_files`, or SIGKILL pending
  in `SigPnd` or `ShdPnd` of `/proc/<pid>/status`, which covers a holder in uninterruptible sleep
  or not yet scheduled) is not named, so
  `kill -9; start` waits as under P290. `status` is read line by line (at most 256 lines, a long
  `Groups:` line skipped), and a holder whose `stat` or `status` cannot be read (it vanished), or
  shows no signal masks, is not named either: only a process known to be running is. A holder run by another user is never named (its
  `/proc/<pid>/fd` is unreadable to this process, `hidepid` or not), and this process's own pid is
  never named. Each attempt costs up to 4096 `statx` calls with `AT_STATX_DONT_SYNC`, so a
  descriptor on a hung NFS or FUSE file does not block the scan; a live holder with that many
  descriptors makes the wait longer than 2 s. The exit status of E0703 (#294's second point) is for #292, not
  decided here.
