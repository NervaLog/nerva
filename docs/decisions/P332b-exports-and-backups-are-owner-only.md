---
id: P332b
date: 2026-11-11
area: Security
---

# Exports, backups and manifests are created 0600

**Decision.** `nerva export`, `nerva backup` and the backup's manifest are created with mode 0600,
whatever the umask, as the data file is. The patch is two `createFile` calls in `src/nerva_main.zig`
(owner-approved, #302; UPSTREAM.md). Restore and import only read the files and need no wider mode.

**Why.** At 0644 any local user could read a full copy of the ledger (#302). The files hold what the
data file holds, so they get its mode.

**Cost.** An operator who relied on group or world read (a backup uploader under another user, a
shared directory) must run it as the `nerva` user or grant access explicitly, for example with an
ACL or `chmod` after the backup. Files made by v0.7.1 and earlier stay 0644 until `chmod 600`.
