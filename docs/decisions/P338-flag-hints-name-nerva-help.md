---
id: P338
date: 2026-11-11
area: Errors
---

# Flag refusals name `nerva --help`, not `nerva <command> --help`

**Decision.** The fix line of NRV-E0001 reads `run nerva --help, which lists every command and the flags it takes` (`cli.help_hint`); NRV-E0002 prefixes it with `the message names the bound; ` (`cli.range_hint`). No per-command help is added.

**Reason.** The vendored parser (`src/stdx/flags.zig`) answers `-h`/`--help` only as the first argument; `nerva start --help` is refused as an unexpected argument (#300). Per-command help would patch a vendored file, which CLAUDE.md makes a stop. `nerva --help` already documents every command and flag.

**Cost.** An operator reads the whole usage text for one command's flags. A later per-command help can restore the longer hint with its own decision.
