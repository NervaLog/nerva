---
id: P269b
date: 2026-11-10
area: Releases
---

# The format digest, and `format_epoch`, as built

`src/nerva/format_digest.zig` computes, at comptime, the SHA-256 of one text: the layout of every
wire and storage type and persisted enum (`layout_types`, rendered by `layout_render`, the text
`format_test.zig` snapshots), the LSM tree ids, the cluster configuration, the superblock version
and `format_epoch: u32`. `nerva version` prints it as `format <hex>`, beside `release`,
`release_client_min` and `bundles none`; `--verbose` adds `format_epoch`, `superblock_version` and
the commit. `format_test.zig` snapshots the digest after the layouts, so a change to either fails
the same test.

- **`format_epoch`** (1) moves by hand, in the commit that makes a format change the layouts do
  not show: a key derivation, the meaning of a stored field, how a view's stored state is read.
  Updating the snapshot needs a decision that says what changed and whether the epoch moves. It
  never goes down.
- **The cluster configuration is rendered field by field**, not through
  `config.cluster.checksum()` as the brief says: that checksum is AEGIS and does not run at
  comptime (`std.once` in `vsr/checksum.zig`). The same fields feed it, so the digest moves when
  it does.
- **The digest depends on the build's configuration.** The unit tests run the test configuration
  and so snapshot a different digest from the release binary's; `tests/errors/commands.py` pins
  the binary's.
- **`release_client_min` is tied to the bundled release in `build.zig`**: at most `release`, and
  at most `release_bundled` once one exists (null now, so inert). A bundled release below
  `release_client_min` fails the build.
- **Nothing is persisted or sent.** The digest is only printed and compared: no format, wire
  layout or persisted identifier changes. It is what strict formats (P259c) compare.

**Why.** One number the release workflow and `start` can compare, that moves with any change to
what is on disk or on the wire, and that a hand-moved epoch covers where reflection cannot see.

**Cost.** Any layout change moves the digest, which per P259c means export and import for that
release. A layout snapshot update now touches the digest line and `commands.py`'s golden too.
