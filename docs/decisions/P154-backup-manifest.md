---
id: P154
date: 2026-11-05
area: Releases
---

# The backup manifest is canonical, strictly parsed JSON, version 1, beside the export

**Decision.**
- `nerva backup` writes `<output>.manifest.json`, one line of canonical JSON in the brief's field order.
  - Numbers of 64 bits and wider are decimal strings; ids and versions are bare numbers.
  - Hashes are lowercase hex.
  - The file is at most 64 KiB, with at most 64 views and 64 ledgers.
- `backup.parse` accepts only what `backup.render` writes: a number with a leading zero, `+` or `-0`, uppercase hex, or a view out of order is refused (NRV-E0808).
- The manifest has no checksum of its own. Its release and cluster id are informational, and `restore` does not compare them, because a drill restores into another cluster.
- A new manifest version is a new format.

**Why.** The brief's format has no checksum. Every field `restore` compares is checked against the export itself: size, SHA-256, op, version, every view hash and every ledger total (NRV-E0809). A strict parser leaves exactly one way to write each manifest.

**Cost.** A changed byte in the release or cluster field goes unnoticed. A changed byte anywhere else is either refused as malformed or caught as a difference from the export.
