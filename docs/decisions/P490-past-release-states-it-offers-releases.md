---
id: P490
date: 2026-11-18
area: Releases
amends: P417
---

# The packer refuses a past release that does not state it offers releases (NRV-E0728)

**Decision.** `nerva version --verbose` ends with one more line, `multiversion offers_from_binary`,
printed when `start` opens the binary's own bundle (`MultiversionOS`) and so offers the releases the
file at its path holds. `bundle.Facts.parse` reads it from the past binary, and `bundle.refusal`
returns `not_multiversion` for one without it, after the checks of release, format and clients. The
packer reports it as NRV-E0728 (its own code: the cure is to bundle another release, not a rebuild
of the same one). v0.7.1 and v0.7.0 print no such line, so they are refused.

**Why it is the capability and not a flag.** A past release is re-executed from the outer binary's
memfd with `argv[0]` set to the outer path (`self_exe_path`). It advertises the next release only
because its own `start` opens a `MultiversionOS` on that path and polls it; a `.single_release`
`start` (v0.7.1's) advertises only itself, so `quorum_upgrade` is never reached. The line is written
by `version_write` under the constant `multiversion_start`, the same one `command_start` tests
before it opens the bundle: the line and the behaviour have one switch. `tests/release/bundle.py`
shows the behaviour, not the line: it starts the packed binary on the past release's data file, and
the replica switches to the past release, offers the next one (`on_upgrade_timeout: upgrading from
release=past..next`) and executes it.

**A build without it.** `nerva_executable` takes `multiversion_start` (default true); `test:release`
builds `nerva_past_single` with it false, whose `start` runs as one release and whose `version` omits
the line, as v0.7.1's do. A build option is not given a command-line flag, so no release can lack
the capability, and the unit and `bundle.py` refusal cases use the real build as well as a stub.
One checkout cannot build v0.7.1's behaviour any other way (the same reason as `-Dtest-commit-keys=off`).

**Does not change.** No existing line of `version` or its order (Botpike/app#160): the line is
appended last. No on-disk or wire format. No vendored file beyond UPSTREAM.md's `build.zig` and
`src/nerva_main.zig` rows, which are updated.

**Costs.** A line a binary prints does not prove the code at run time: a later change that
removes the opening of the bundle from `start` while leaving `multiversion_start` true would pass
the packer's check; `bundle.py`'s switch test fails it. A past release that does not print the line (v0.7.1 and earlier
among them) can no longer be bundled: its clusters upgrade by export and import (README,
"Upgrading a cluster"; P259g: v0.7.x to v0.8 is that route, and the first rolling upgrade is vR to
vR+1). The first
release the packer accepts as a past release is the first that prints the line.
`release.yml` does not yet require the line in a shipped binary.
