---
id: P149
date: 2026-11-05
area: Releases
---

# R5's brief is approved, with the owner's answers to its six questions

The owner approved `docs/briefs/r5.md` on 2026-11-05 and took the brief's choice on each question:

1. `nerva start`'s runtime exit statuses 2 to 8 stay as they are, because supervisors and P90
   already match them. Their messages gain codes. Other commands exit 1, 2 or 70.
2. The backup manifest is a separate JSON file (P149d).
3. The two vendored strings that name `--limit-storage` (`src/vsr/grid.zig:660`,
   `src/vsr/superblock.zig:1395`) are corrected. This is a text-only vendored patch, recorded in
   UPSTREAM.md in the commit that makes it. The owner names it here, so it is not a stop.
4. A replica is recovered only at its old address. A new address is documented, not automated.
5. Slice 5, the VOPR starting from an imported state, is built last and may be cut if it does not
   fit. A cut is recorded in `docs/demos/r5.md`, and PRODUCTION's acceptance line is corrected.
6. Recover checks that the old replica is gone with a TCP connect. A hook in vendored `client.zig`
   comes only if review finds the connect insufficient.

**Why:** each is the brief's recommendation, and none changes a persisted format.
