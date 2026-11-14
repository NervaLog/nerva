---
id: P414c
date: 2026-11-14
area: Testing
amends: P414b
---

# `bench-load` creates its temporary file exclusively, truncates a plain open late, and keeps a result it could not place

**Decision.** (1) `OutFile` creates the temporary file with `O_CREAT|O_EXCL`, under the name
`.nerva-<hash>.<pid>.<random>.tmp`. A name already taken (a file, or a symbolic link, which
`O_EXCL` never follows) is retried with a new random suffix, at most 8 times (asserted); then the
path is refused with NRV-E0728 ("every temporary file name next to it is taken"). (2) The content
is handed over at the end (`OutFile.finish(content)`); a path opened as a plain open is created if
missing but not truncated, and is truncated and written only in `finish`, as `main` wrote
`--output` only after a successful run. A run that fails leaves such a file as it was. (3) If the
rename is refused at `finish` and the copy into the path fails too, the temporary file is kept,
NRV-E0728 names it (`; the result is kept in <file>`) and `deinit` does not remove it. (4) A plain
open resolves a symbolic link when it opens the file, so that `stop` of a PID file deletes the
file that was written, for a renamed and a plain-opened path alike; a dangling link's target is
deleted and the link left.

**Reason.** The predictable name without `O_EXCL` let another user plant a link that a root run
followed, overwriting and chmod-ing its target. Truncating at open made a failed run empty a
hard-linked or read-only-directory output, which `main` never did. A failed fallback copy lost the
earlier content and the result both.

**Cost.** The content is held in memory until `finish` (it already was). A rename that is refused
and a copy that fails leave a temporary file the operator must delete. A plain open that fails in
the middle of its write after the truncation still leaves a short file. A missing path that is a
dangling link, or a plain-opened missing file, is created empty when the run starts. The random
suffix makes the name differ between runs, so a killed run's leftover is not reused.
