---
id: P150
date: 2026-11-05
area: Releases
amends: P149e
---

# Command diagnostics: what exit 2 means, two new codes, and E0007 widened

Taken while building R5's slice 1 (`docs/briefs/r5.md`).

- **Exit 2 means the environment, not usage,** as the brief says: the disk is full (E0706) or
  the disk failed (E0708). P149e's text says "usage". A usage error is the operator's own
  mistake, so it exits 1 with the other operator errors. Exit 70 means an internal error
  (`bug[NRV-B0004]`).
- **Two new codes:**
  - NRV-E0604: a gateway or view server cannot reach the cluster within the client's
    registration timeout. Before this it printed a raw `Timeout`.
  - NRV-E0810: an export or import file cannot be opened, read or written.
- **NRV-E0007 is widened** from "A gateway or view server cannot listen" to "A replica, gateway
  or view server cannot listen". It is the same failure, so it needs no second code.
- **The vendored flag parser (`src/stdx/flags.zig`) still prints its own uncoded errors** for
  unknown subcommands, duplicate flags and empty values. Changing them is a vendored patch,
  which P149 did not approve. `docs/ERRORS.md` and the README say so.

**What it costs:** an operator still sees a few uncoded lines from the flag parser until a
vendored patch is approved.
