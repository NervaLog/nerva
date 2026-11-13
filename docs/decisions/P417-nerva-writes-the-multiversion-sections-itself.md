---
id: P417
date: 2026-11-13
area: Releases
amends: P259d
---

# Nerva's packer appends the two sections and keeps the linked executable as a prefix

Upstream's `build_multiversion.zig` calls `llvm-objcopy`, so P259d applies: Nerva writes the packer. It
appends the past release (`.tb_mvb`) and upstream's `MultiversionHeader` (`.tb_mvh`) after the linked
executable and rewrites the section table and the section names; the sections are not loaded, so the
kernel runs the outer binary as linked. The header is upstream's, used as is. Because releases up to
0.15.4 must leave `current_git_commit` and `current_release_client_min` zero in it, Nerva's own
release and client minimum are not recorded there; `nerva version` and `vsr_options` carry them.

**Why.** No new dependency, and the result is checked by upstream's own `parse_elf` and header
verification. Appending keeps the packed binary reproducible from the two inputs.

**Costs.** The packer runs both binaries (`version --verbose`) for their facts, so a pack is native.
`header.reserved` holds a 16-byte record of the original section table, so `strip` can give back the
linked executable; nothing else reads it. Linux ELF only (macOS and Windows are not packed).
