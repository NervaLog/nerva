---
id: N63
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Each release carries a software bill of materials (CycloneDX 1.5).

Owner's request after v0.3.0. Nerva has no package dependencies, so its bill of materials is
read from the repository's own pins rather than from a package manager:
- **Components.** Nerva (version, commit, protocol release from `build.zig`); TigerBeetle,
  vendored as source with local changes, at the commit pinned in UPSTREAM.md; the Zig standard
  library and compiler-rt, compiled into every binary (Linux binaries are static with no libc;
  macOS binaries link the system's libSystem, not shipped); and the Zig compiler that built
  them, `scope: excluded`, with the SHA-256 of the x86_64-linux archive that `zig/download.sh`
  pins and verifies, since every target is cross-compiled there.
- **Consistency.** `.github/scripts/sbom.py` refuses to write one when the Zig version in
  `zig/download.sh`, UPSTREAM.md and `build.zig` disagree, or a pin is missing.
- **Reproducible.** The serial number is a UUIDv5 of the tag and commit, and the timestamp is the
  commit's (UTC), so the same release always gives the same file.
- **Published** as `nerva-v<VERSION>.cdx.json` beside the binaries, in `SHA256SUMS`. The release
  workflow's `version` job writes it once before CI runs, so a broken pin stops a release early.
- **Not included: signed provenance.** GitHub artifact attestations need a public repository or
  Enterprise Cloud; signing with another tool (cosign) is a separate decision.
Tests: `.github/scripts/test_sbom.py` (CI's `system` job): the SBOM names this repository's pins,
is well formed and reproducible, and is refused for disagreeing Zig versions, a missing pin, or
a bad tag or commit. The output for v0.3.0's commit passed strict validation against the
CycloneDX 1.5 JSON schema (`cyclonedx-python-lib`, run once locally; not a CI dependency).
Mutation-tested: dropping the version cross-check, or citing another host's archive, fails it.
