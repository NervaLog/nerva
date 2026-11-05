---
id: P167
date: 2026-11-05
area: Releases
amends: P150
---

# Flag-parser errors are NRV-E0001, through a hook in the vendored parser

**Decision.** `stdx.flags` gets `fatal_hook`. When it is set, `fatal` formats its message and passes
it to the hook instead of printing `error: …`. `nerva` sets the hook in `cli.parse_args`. Every
failure of the parser (unknown or missing subcommand, unknown flag, missing value, bad integer,
duplicate flag, missing required flag, unexpected positional) then prints P150's three-line
`error[NRV-E0001]` diagnostic and exits with status 1. Status 1 is operator input, and it is the
status these failures had before.

No new code is added: NRV-E0001's summary already covers a command or flag that is unknown,
repeated or malformed. The owner approved the vendored patch on 2026-11-05.

**Why.** It is the smallest vendored change (8 lines). With the hook unset, the parser behaves
exactly as upstream's, so its own tests and its other callers are unchanged. And it leaves no
command failure without a code.

**Cost.**
- One more patch to carry in a vendored file, recorded in `UPSTREAM.md`.
- Every parser failure shares one code, so a script tells them apart only by the message text.
- A message longer than 512 bytes is truncated.
