# Review checklist

Adopted from Zigbox's `REVIEW.md` and fitted to Nerva (P147). Run it on your own diff before you
report, and say in the pull request which items the change touched and what you checked. An item
that does not apply needs no word. The release reviewers (CLAUDE.md, "Before every release") start
from it too.

## What others read

- **A wire format only grows.** A JSON reply or request from `nerva api` never loses, renames or
  retypes a member, and never changes what one means. Add members beside the old ones. A change
  that cannot be additive is a stop (CLAUDE.md, "Stop", item 1).
- **A data file is read by the next release.** An on-disk layout, `tree_ids` and `Operation`
  values never change without the stop. `test:release` proves an older release's file still opens
  or is refused with its code, using a file the older release really wrote.
- **Every new route, flag and error code** is in the README's JSON API section, `nerva --help` and
  [docs/ERRORS.md](./docs/ERRORS.md) in the same commit.

## The state machine

- **Deterministic.** Nothing in `prefetch` or `commit` reads a clock, a random source, a thread or
  hash-map iteration order, or allocates after startup. Time comes from the prepare timestamp.
- **`commit` does no IO.** Every read it needs was loaded in `prefetch`, and a missing one is an
  assertion, not a lookup.
- **A change here runs VOPR seeds** on both state machines (`-Dvopr-state-machine=nerva` and
  `testing`), and the PR names them.

## Reading what you wrote, and what you did not

- **Parse accepts only what render can write.** Every bound a writer asserts (a length, a count, a
  field width) is checked by the parser too, and refused with its code. Otherwise a damaged file or
  request reads as valid and crashes later.
- **A test fills memory with a known byte before checking that something wrote it.** Never rely on
  what `undefined` holds.
- **Two spellings of one thing are one thing:** ids in decimal strings and hex, a UUID with and
  without dashes, a table by number. Compare in one canonical form.

## Bounds and failures

- **Every bound is a named constant** with a test at the bound and one past it.
- **Every exit path is tested,** not only the clean one: a refusal, a timeout, a client that hangs
  up, SIGKILL of the gateway, SIGKILL of a replica. Anything held (a session, a connection slot, a
  file lock) is released on each.
- **Every failure is one coded diagnostic** (`docs/ERRORS.md`) that blames the right layer. An
  errno alone, a raw `error.Name`, an empty reason or a stack trace for an operator's own mistake
  is a bug.
- **An unknown outcome says it is unknown.** A reply that cannot say whether a write applied says
  so, and is never shaped like a refusal.

## Tests and gates

- **The exit criteria, on the exact commit you report** (CLAUDE.md, "Exit criteria"), with the
  commands you ran.
- **A test reachable from no test root never runs.** A new test file is imported from a root in
  `build.zig`, and you have seen it run.
- **A fixture is real output,** captured from a real run, not written from what the code is
  believed to print.
- **A failing VOPR seed, fuzzer seed or Jepsen run is a finding.** It is reproduced and fixed or
  filed, never re-run until it passes.
