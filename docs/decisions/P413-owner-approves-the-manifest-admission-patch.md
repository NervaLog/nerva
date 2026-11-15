---
id: P413
date: 2026-11-13
area: Storage
---

# The owner approves a `src/vsr/replica.zig` patch for manifest admission (#334)

**Decision.** `Replica.on_request` drops a request while the LSM manifest has less headroom than
`nerva/manifest_admission.zig` derives (free pool nodes or table-count headroom below the tables that
the ops in flight can still insert). The owner approved the vendored patch on 2026-11-13.

**Reason.** The manifest node pool (8192 nodes) and the per-tree table limit are fixed, and
exhausting either exits the replica (exit 3, exit 6), breaking "everything is bounded". Admission is
local policy of the primary: it changes no log entry and no persisted value; a dropped request is
resent by the client.

**Cost.** One vendored file patched (UPSTREAM.md). The reserve is derived, not measured: exits 3 and 6
were not reproduced, so the bound is conservative and unvalidated against a real exhaustion. Under
sustained pressure the primary stops admitting until compaction frees nodes.
