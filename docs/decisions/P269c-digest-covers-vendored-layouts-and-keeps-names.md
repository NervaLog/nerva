---
id: P269c
date: 2026-11-10
area: Releases
amends: P269b
---

# The format digest covers the vendored layouts, and keeps names

**Decision.** The digest also hashes, in a `vendored:` section after `format_epoch`
(`vendored_types` and `vendored_headers` in `src/nerva/format_digest.zig`), the layouts of what
the vendored code puts on the wire and on disk: `vsr.Header`, the header of every command (Ping,
Pong, PeerHello, PeerChallenge, PeerProof, Prepare, Block and the rest), `vsr.Command`,
`vsr.Operation`, `vsr.Release`, the request bodies of `vsr.zig`, `SuperBlockHeader`, `VSRState`,
`CheckpointState`, and the LSM block metadata, manifest entry and label of `lsm/schema.zig`.
Vendored files are read, not edited. The same text is in `format_test.zig`'s snapshot, appended
after the existing lines (none of them moves). The digest in `commands.py` and the snapshot move
because of this and nothing else.

**Not covered, so only `format_epoch` covers it.** How bytes are computed (checksums, the peer
MAC, key derivations), what a field means, the encoding of keys and values a tree stores as bytes,
and the layouts that are generic over a storage type. A vendored patch that changes one of those
moves `format_epoch`, with a decision.

**Names stay in the hashed text.** A rename of a type, a field or a file (`@typeName` follows the
path) moves the digest, so under P259c that release takes export and import, not a rolling
upgrade. The alternative, hashing sizes, offsets and enum values only, would let two same-typed
fields trade names, or two enum values trade meanings, with no change to the digest, which is the
worse error: a silent rolling upgrade across a change of meaning. A reviewer of a refactor that
renames something persisted-shaped should expect the digest to move.

**Why.** P90 added `origin` to Ping and Pong without moving anything the first
digest listed; that change would have been offered as a rolling upgrade.

**Cost.** More changes move the digest, including renames. The snapshot is about 700 lines longer.
