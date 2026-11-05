---
id: N46
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Fuzzing runs again, and covers Nerva's own code.

`zig build fuzz -- smoke` had been failing since the vendoring: `lsm_scan`'s test groove uses
tree ids 1–15, and the trace's tree enum, derived from Nerva's four trees, panicked on the rest
(#6). No fuzzer ran in CI, so nothing noticed, and none covered Nerva's code.
- The tree enum stays exhaustive (its values index timing and metric slots, and traces print
  them by name) and names a placeholder `test_<id>` for every id up to 15 that Nerva does not
  use. A non-exhaustive enum would only have moved the panic to `@tagName`. Placeholders never
  receive events in a replica, and slots never set are never emitted, so metrics are unchanged.
  A vendored test with a higher id fails smoke, as this did.
- Three fuzzers for Nerva's code, cheap enough for smoke (each well under its 10 s budget in a
  Debug build), all pure functions, so no cluster is needed:
  - `nerva_adds`: `add_amount` and `add_apply` against a reference written from N42's text (a
    binary search for the largest amount that fits, rather than `add_amount`'s closed form), and
    properties of every applied amount (direction, magnitude, bounds, maximal clamping, exact
    application, the negated amount restoring the field); `entry_validate` on arbitrary
    parameters. The VOPR model shares `add_amount` with the state machine, so it cannot catch a
    mistake there; this does.
  - `nerva_http_head`: generated valid heads parse to exactly what was generated; mutated heads
    and random bytes never crash `head_parse`, and whatever it accepts keeps what the gateways
    rely on (CRLF lines only, a `/` target of visible bytes, a key without control bytes);
    `key_matches` is equality.
  - `nerva_documents`: encode and decode round-trip at sizes around chunk boundaries, with
    distinct row ids; random and damaged chunks decode within the limits or are `Corrupt`, and
    never from the wrong number of chunks.
- Each fuzzer asserts that its generators reach every outcome (applied, clamped, refused;
  accepted and refused heads; decoded and corrupt chunks), so a generator that rots fails
  rather than passing vacuously. Its first run found its own generator writing blank header
  lines.
- Mutation-tested on the smoke seed: an off-by-one clamp in `add_amount`, `chunks_decode`
  dropping a value's last byte, `head_parse` accepting control bytes in values, and
  `head_parse` accepting a repeated `X-Nerva-Key` each fail their fuzzer. (`head_parse`
  accepting a bare CR does not, and need not: a CR left after splitting on CRLF lands in a
  method, target, name or value, each of which refuses control bytes, so that check is a
  redundant guard. The last mutation was caught only after adding header-count properties.)
- `ci.yml` is unchanged while CI is re-wired; it should run `fuzz -- smoke`.
