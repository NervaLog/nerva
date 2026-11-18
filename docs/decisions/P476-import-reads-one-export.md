---
id: P476
date: 2026-11-18
area: Errors
amends: N80
---

# An import's two passes read one descriptor and must end in one SHA-256

**Decision.** `nerva import` and `nerva restore` open the export's path once. `import.plan` takes
that open file and `ImporterType.run` reads it again from its start (`import.Input.file`; the
VOPR's start passes `Input.bytes`), so the path is never resolved a second time; `restore`
compares the manifest's size with that descriptor's `stat`, not the path's. Pass 2 then compares
the SHA-256 its reader verified with pass 1's (`Plan.origin`) before the checks run, and refuses a
difference with `error.ExportChanged`, NRV-E0813 (exit 1, `<path>.importing` removed, nothing
named). `backup` reads its own export back the same way.

**Reason.** The data file records pass 1's SHA-256 as its origin (P90), and pass 2 is what writes
the history. Pass 2 only checked the SHA-256 of whatever file it read, and the final checks come
from pass 1's plan, so another valid export with the same final rows (a backup job replacing or
rewriting the file between the passes) restored another history under the first export's identity
(#475). One descriptor stops a rename over the path; the digest comparison also stops a rewrite in
place and keeps the `bytes` input honest.

**Cost.** A new code and one more error-set member. An operator whose export is rewritten during an
import now gets a refusal instead of a replica, and must run it again. No format changes.
