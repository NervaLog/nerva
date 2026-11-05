---
id: N73
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# The op's `min`/`max` scratch holds two keys per member.

`extremes_gather` gives each touched member up to two (group, slot) keys: the group it left, when
it held that group's value as stored, and the group it entered. `extremes_scratch` was sized for
one per member, so one admitted transaction moving the holders of many groups' values to new
groups (about 1,640 rows, each alone in its group, under four slots) overflowed it: every replica
panicked (`integer overflow` in `getOrPutAssumeCapacity`), and again replaying the op after a
restart (#62; reproduced at `8c206f2`, found by the 0.0.4 hardening pass). It is now sized for
`2 * members_limit`, the most admission lets an op reach. Other scratch structures were checked
against admission and are sized right. Tests: a state-machine test moves every holder the op's
member limit admits to new groups in one transaction (it panicked; it now commits and every new
group holds its row's values); at production limits, 2,047 rows moved in one transaction commit
and the replica serves on.
