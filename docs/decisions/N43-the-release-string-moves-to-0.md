---
id: N43
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# The release string moves to `0.0.2`; data files from v0.1.0 must be reformatted.

Adds changed the client protocol (`EntryResult` is 32 bytes, N42), and N32 ties the release
string to the protocol. Owner's decision: bump it, accepting that existing data files are not
carried over (nothing real is stored in Nerva). `release` and `release_client_min` in
`build.zig` are both `0.0.2`, so replicas refuse clients built before the change instead of
misreading their replies. Data files formatted by v0.1.0 are refused at open ("found
incompatible superblock version 0"), for a reason beyond the release number: TigerBeetle treats
release `0.0.1` (`Release.minimum`) as a development build and writes its data files with
superblock version 0, while every other release writes version 2. So `0.0.1` files cannot be
upgraded, only reformatted. (A replica opening a file of another non-development release would
look for that release among those bundled in its binary; Nerva bundles only its own.) Verified
with the v0.1.0 binary: it formats a file and opens it; the new binary refuses it. The golden
checksum of a formatted data file changes with the release string (UPSTREAM.md). The release
workflow now writes the binary's own version string into the release notes.
