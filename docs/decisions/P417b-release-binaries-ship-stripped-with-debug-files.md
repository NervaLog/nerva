---
id: P417b
date: 2026-11-13
area: Releases
amends: P361
---

# Linux release binaries ship stripped, and their debug info is a file apart

**Decision** (owner, 2026-11-13, answering #417's question). A ReleaseSafe `nerva` with debug info is
about 34 MiB, so a binary bundling a past release is over `multiversion_binary_platform_size_max`
(64 MiB). Release binaries ship stripped, the vendored `config.zig` bound is unchanged, and each
release publishes the debug info as a separate file.

- `zig build -Dstrip=true` installs `nerva` stripped after linking (`zig objcopy`) and the linked
  build as `nerva.debug`. Stripping at compile time changes the code (measured: `.text` and
  `.rodata` differ), so a debug file from a second build would not match the shipped binary.
  `-Dbundle` packs the stripped binary: a pair is about 10 MiB.
- `release.yml` builds the Linux targets with `-Dstrip=true`, publishes
  `nerva-<tag>-<target>.debug` beside each tarball, and checks that its `.text` and `.rodata` equal
  the shipped binary's. `SHA256SUMS` lists them (eleven files); the draft holds twelve assets and the
  release fourteen with the Mac zip. This amends P361's counts.
- "Signed like the other release files" is read as: covered by `SHA256SUMS`, which is how every
  release file except the Mac zip is protected today (P284b). The bill of materials is unchanged.

**Not covered: macOS (owner, 2026-11-13).** The pinned Zig's `objcopy` cannot strip a Mach-O file,
and Apple's `strip` and `dsymutil` need the macOS runner that `mac-sign.yml` uses. v0.7.1 ships the
Mac binaries unstripped, with their debug info and no `.debug` file. A macOS stripping step is its
own later slice, and the first release that bundles a past release on macOS needs it
(https://github.com/NervaLog/nerva/pull/417#issuecomment-6867906442).

**Reason.** The smallest change that keeps the platform bound and upstream's code. **Cost.** A
second 34 MiB file per Linux target in every release.
