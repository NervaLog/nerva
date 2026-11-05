---
id: N71
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# `--trace` writes through a buffered, bounded writer that never fails.

The vendored tracer writes each span with one `write(2)` on the replica's thread and panics if
it fails, and nothing bounded the file: with `--trace` (N50), a full trace disk killed the
replica, and the trace grew with the request rate (#30; measured at `03b3c93` with the trace on a
1 MiB tmpfs: `panic: Tracer.start: error.NoSpaceLeft` after 283 lookups). Rather than patch the
vendored tracer, Nerva hands it a writer that cannot fail (`src/nerva/trace_file.zig`): it
buffers spans and writes them 64 KiB at a time; on a write error, or once the file would pass
`--trace-size-max` (new, default 1 GiB, refused without `--trace`), it logs once
(`warning(trace_file): tracing stopped: …`) and drops what follows. `nerva start` flushes it on
exit. Up to 64 KiB of spans are lost if the replica crashes, an acceptable cost for a diagnostic
flag. Tests: unit (buffering, a failing writer, the size limit); `test:api` runs a replica with
`--trace-size-max=64KiB` under load (stopped at 65,503 bytes, still serving). Measured once on a
1 MiB tmpfs: the replica logs the stop and served 54,915 lookups in the time `main`'s panicked.
