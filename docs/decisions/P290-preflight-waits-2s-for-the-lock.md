---
id: P290
date: 2026-11-10
area: Releases
amends: P152
---

# `nerva start` waits up to 2 s for the data-file lock before refusing NRV-E0703

- **Decision:** the pre-flight (`src/nerva/preflight.zig`) retries its non-blocking `flock` every
  50 ms for at most 2 s (`lock_wait_ms`, asserted to be a whole number of attempts), where P152
  copied the vendored open's 5 x 50 ms. A lock still held after 2 s is refused as before: same
  code, same message, same exit status. The vendored open is unchanged; it runs after the
  pre-flight has dropped the lock.
- **Reason:** #288. A replica started right after a reaped SIGKILL failed once in CI with
  NRV-E0703. The kernel tears a dead process's io_uring down asynchronously and the ring can keep
  the file, and its lock, alive for longer than 250 ms on a loaded host. A supervisor that
  restarts at once gets the same refusal. The cause is the hypothesis in #288; it did not
  reproduce on a quiet 6.18 kernel (0 in 280 start/kill/start cycles), so the bound is a margin,
  not a measurement.
- **Cost:** a genuinely held lock now takes 2 s to refuse instead of 250 ms. The unit test of a
  held lock takes that long too.
