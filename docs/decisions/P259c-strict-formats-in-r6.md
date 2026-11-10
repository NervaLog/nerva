---
id: P259c
date: 2026-11-10
area: Releases
---

# Formats are strict: any format-digest change means export and import

Owner, 2026-11-10: in R6 any change to the format digest (a new `Operation` value, a new tree, a new field, a moved `format_epoch`) means export and import, never a rolling upgrade. Additive changes are not allowed through the rolling path.

**Why.** An additive rule needs its own proof that N+1 opens N's checkpoint. Strict equality keeps the R6 proof small: nothing persisted changed.

**Cost.** An additive release cannot roll. An additive rule can be filed as a decision after R6, with its proof.
