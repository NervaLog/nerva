---
id: P149d
date: 2026-11-05
area: Releases
---

# A backup carries a separate manifest, version 1

`nerva backup` writes a JSON manifest beside the export, with its SHA-256, the cluster and the
release. `nerva restore` checks the manifest before any data file exists. The export format is
unchanged.

**Why:** an export's own checksum travels inside the file it vouches for.

**What it costs:** a backup is two files, and losing the manifest means restoring by hand.
