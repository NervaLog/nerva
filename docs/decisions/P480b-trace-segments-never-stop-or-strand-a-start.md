---
id: P480b
date: 2026-11-18
area: Releases
amends: P480
---

# A re-executed `start --trace` never stops the replica, and an interrupted one leaves no file

**Decision.** Two rules amend P480, whose segment naming (`<path>.n`, created exclusively) stands.

1. **A start that switches down while it opens removes its own file before the re-execution.**
   When `release_execute` runs while the trace file is still registered for removal (the start has
   not returned from `replica.open`, #197, P208), `MultiversionTraced` removes it
   (`diagnostic.cleanup_now`) instead of flushing it. The process after it carries on the same
   start and writes `<path>.1`. So `<path>` does not exist after a switch at open, an interrupt
   (SIGTERM, SIGINT) during that open removes the segment it made, and the retry with the same
   `--trace` is not refused. A switch after the open (the upgrade) is unchanged: the file is the
   operator's by then, and its spans are written out.
2. **A re-executed start that cannot create its segment warns and runs untraced.** It logs
   `NRV-W0012` once (the directory is gone or unwritable, every one of `.1` to `.1024` exists, the
   name is too long, the disk is full) and the replica runs on, as it does when writing a trace
   fails (N71). A first start keeps the refusal (NRV-E0004, or the file's own error): the operator
   is there. The NRV-E0004 message for exhausted segments is dropped from ERRORS.md.

The re-execution is also detected from the marker `self_exe_path` tests (the multiversion uuid in
the kernel's path for the binary), not from a second read of `/proc/self/exe` compared with the
first.

**Whose code makes the segment (consequence).** At a switch down, `exec_release` runs the bundled
past release's own binary, so that release's `start` creates `<path>.1`. A past release without
P480 would still exit with NRV-E0004 (#479). Checked: no tag bundles another release. v0.7.0 and
v0.7.1 run one (`single_release`), so no released binary is a past release yet; the first release
with a bundled `start` (vR, R6) is the first that can be one, and it carries P480 and this decision
if they merge before it is cut. `bundle.py` builds its past release from the same tree, so it
cannot catch a vR cut without them. What an operator must do: on the first rolling upgrade, vR to
vR+1, a replica on a vR cut without P480 must not be started with `--trace` at vR+1 (leave the
flag out for the upgrade restart). The release check for vR includes that P480 is in it, and any
later change to the segment naming must work when the two processes run different releases' code.
By reading only, a past release that creates `<path>` itself (without P480) now finds it free at a
switch down at open (rule 1); this is not tested.

**Why.** Rule 1 gives the cleanup a single file to remove at all times and keeps the registry at
one path, where removing earlier segments afterwards would need a way to tell this run's files
from an operator's. Rule 2 is N71's: a diagnostic flag does not take the replica down in the
middle of an upgrade.

**What it costs.**
- The spans a start buffered before a switch at open are lost with its file. That process has
  traced only the open, and no span of it had ended before the switch in the release check.
- `<path>` is absent after a switch at open, so an operator opening the path they gave finds
  nothing until the next switch; the README says so.
- Tracing stops silently (one warning) in a re-executed start that cannot create a segment.
