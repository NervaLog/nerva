---
id: N81
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Export refuses what import would refuse; import names its file only once its checks pass.

The v0.4.0 hardening of export and import (N80) found that a failed import could leave a data
file `nerva start` runs, and that an export could succeed and then be refused by import, after
the old cluster was stopped.
- **Import:** pass 2 writes `<path>.importing`, and after its checks pass, flushes, links it to
  `<path>` (`linkat`, which never replaces a file), removes the temporary name and syncs the
  directory. On any error it flushes before tearing down (a failed check used to abort on
  `Storage.deinit`'s `unflushed == 0`, leaving the file) and removes the temporary file. A
  killed import leaves only `<path>.importing`, which the next import names and refuses (#78).
  Rejected: withholding the final superblock until the checks pass, which needs a change to
  vendored format code for the same result.
- **Pass 1 refuses** what pass 2 would trip on: view and ledger checks that name another
  declaration (they were asserted), a change timestamp past 2^62 (versions and checkpoints
  after it must stay below `TimestampRange.timestamp_max`), and an export op past 2^48 (the loop
  to the final checkpoint did not end at `maxInt(u64)`). Pass 2 logs progress every 2^20 ops;
  it restores about 38,000 empty ops a second (#80).
- **Export** runs import's own view-definition check against the catalog rows it exported, and
  the same limit of 2^16 catalog rows, and refuses before writing its summary. The usual cause
  is a gateway between declaring a view and writing its document (`api.zig`), so its message
  says to export again, or to PUT the view again if that gateway stopped (#79). Import counts a
  catalog row once however often it is written.
- Not done, recorded for later: replicas imported from two different exports that reach the
  same checkpoint stop on an assertion when they meet, not a message (#81).
