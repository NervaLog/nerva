---
id: P480
date: 2026-11-18
area: Releases
amends: N71
---

# `start --trace` writes one segment per release transition

**Decision.** At a release transition, a bundled `start` re-executes itself with the same
arguments. The re-executed process does not open the trace file again. Instead:
- It writes its spans to the first `<path>.n` that does not exist, n from 1 to 1024
  (`trace_segments_max`), created exclusively like the first file.
- It knows it was re-executed because it runs from the bundle's memfd: the kernel's path for
  the running binary is not the binary's real path, which `self_exe_path` reads from `argv[0]`.
  An operator cannot start a process from that memfd.
- If all 1024 segments exist, it is refused with NRV-E0004.

Before the binary is re-executed, the replica's `release_execute` (`MultiversionTraced` in
`nerva_main`) flushes the spans it has buffered. Each segment is a whole trace: the tracer's
`[` and its spans, with its own `--trace-size-max`.

**Why.** The brief gave two options.

Keeping the open file across the re-execution needs these changes:
- the trace descriptor must not be close-on-exec;
- its number must reach the new process, which needs an environment variable or argument
  that the vendored `MultiversionOS` passes through unchanged;
- the new tracer must not write its `[` a second time, or the file is no longer one JSON trace.

A segment per transition needs none of that, and it keeps #29's rule as it is: every trace
file is created exclusively, and no file is ever opened for writing that the process did not
create. An operator's file at `<path>.n` is skipped, never truncated. No vendored file changes.

**What it costs.**
- A trace of a rolling upgrade is several files, one per process, that are read side by side.
- The first transition's log line names the segment (`tracing to <path>.1: segment 1, after a
  release transition`).
- `--trace-size-max` bounds each segment, not their total. A replica switches a handful of
  times, and segments stop at 1024.
- Spans the replica buffered after the flush and before `execveat` cannot exist: the
  re-execution follows the flush directly.
