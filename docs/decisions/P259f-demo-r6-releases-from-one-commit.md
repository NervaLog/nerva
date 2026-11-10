---
id: P259f
date: 2026-11-10
area: Releases
---

# demo_r6's two releases are built from the same commit

Owner, 2026-11-10: `zig build demo-r6` builds both of its releases from the same commit (N, and N+1 = N's code under release +200), so it runs anywhere without network. The run with a real published N lives in `test:release` from vR+1.

**Why.** The demo must be green on every PR, and a fetched binary depends on GitHub's release assets and on the formats still matching.

**Cost.** The demo proves the mechanism, not that a published release upgrades into this commit; that proof waits for vR+1 in `test:release`.
