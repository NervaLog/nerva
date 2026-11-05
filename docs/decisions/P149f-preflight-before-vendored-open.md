---
id: P149f
date: 2026-11-05
area: Releases
---

# Operator input is checked in Nerva's code before the vendored open

Nerva's own code checks for these before the vendored storage opens the file: a missing or damaged
file, a held lock, another release's file, no direct IO, or an old kernel. Each is refused with
its code. The vendored panics stay as a backstop.

**Why:** an operator's mistake must never end in a stack trace (CLAUDE.md, "Errors").
