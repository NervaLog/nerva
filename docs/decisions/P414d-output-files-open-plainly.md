---
id: P414d
date: 2026-11-14
area: Testing
---

# `bench-load` opens its output files plainly, as `main` does

**Decision.** `--timeline`, `--gateway-pid-file` and `--output` are opened with a plain
create-or-truncate (`OutFile.open`), the same open as `main`'s `--output`, but made before the run
rather than after it (see Cost). There is no temporary
file, no rename, no check that two flags name different files, and no symbolic-link or inode
analysis. The files are opened before anything starts, so a path that cannot be opened is one
NRV-E0728 line and costs no measurement; the timeline and the summary are written when the run
ends. The PID file is removed when the gateway stops, only if it is a regular file.

This is the owner's choice (option b, 2026-11-14), after two review rounds on an atomic `OutFile`
(P414b, P414c, never merged and now withdrawn) kept finding new cases.

**Reason.** `bench-load` is a benchmark tool, not a store. Atomic replacement needed an
identity, ownership and link policy larger than the feature it protected.

**Cost.** A failed run can leave an existing `--output` empty, which `main` did not: `main` wrote
it only after the run (`writeFile`), so a run that failed first left the old file intact. This is
the one behaviour change for `--output`; `--timeline` and the PID file are new. Two flags naming one file overwrite each other, and a
later flag that cannot be opened leaves the earlier flags' files truncated. A write that fails
leaves the file short.
