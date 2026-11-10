---
id: P291
date: 2026-11-10
area: Releases
amends: P284
---

# `mac-release`: the owner's identity as the default, the zip's name, and what the formula pins

**Decision.** v0.7.1 slice 3 settles five things the brief left open.

1. `-Dsign-identity` defaults to the owner's Developer ID Application identity, the one
   Zigbox's `mac-release` already uses, and `-Dnotary-profile` to `nerva-notary`. `-` signs ad hoc
   and is what CI runs (it skips the identity and notary-profile checks and passes
   `--timestamp=none`, since there is no timestamp server to ask for an ad hoc signature).
2. The step runs its tool twice. `preflight` runs before either thin binary is compiled and
   refuses a dirty tree, a `HEAD` that is not tag `v<VERSION>`, an identity the keychain does not
   list and a notary profile `notarytool history` cannot use. `package` runs after: `lipo`, sign,
   verify, run, zip, CDHash comparison, checksum, optional notarization, formula.
3. `lipo -archs` is accepted as exactly the two names in either order; `lipo` decides the order.
4. `nerva version`'s new last line is `version <VERSION>`, placed after `bundles none` and before
   the `--verbose` lines, so the existing lines keep their order and text (Botpike/app#160). The
   format digest is unchanged.

5. The step is run as `zig build -Drelease mac-release`, the build `release.yml` uses, and refuses
   otherwise: the thin binaries share the build's options, and `config_verify` is on in every
   mode but `-Drelease`. The tool also checks each architecture slice's signature and CDHash,
   and the zip's listing.

**Reason.** A refusal before compiling saves a long build and cannot leave a half-signed output.
The identity is already public in Zigbox's repository and is not a secret; the keychain holds the
credential. Not pinning the `lipo` order avoids a release that fails on a tool's choice.

**Cost.** `-Dnotary-profile` is checked with a network call (`notarytool history`), so an
offline `-Dnotarize=false` release still needs the network unless it signs ad hoc. The tool runs
only on macOS and its calls are tested only there (CI's ad hoc run, and the owner's first notarize
run); its pure parts are unit-tested on Linux.
