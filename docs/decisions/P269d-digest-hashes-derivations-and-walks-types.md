---
id: P269d
date: 2026-11-10
area: Releases
amends: P269c
---

# The digest hashes the pure derivations, and a test walks the listed types

**Decision.**

1. The digest text gains a `derivations:` section (`derivations_render` in
   `src/nerva/format_digest.zig`): the outputs, for fixed inputs, of `row_key`, `documents.row_id`
   and `tail_id`, `commit_key_id`, `record_key`, `index_entry_key`, `indexes.position_prefix`,
   `views.member_order_prefix`, `member_key`, `group_version_key` and `view_version_key`. They
   are pure and run at comptime, so a change to one moves the digest by itself. The inputs are the
   ones `format_test.zig` pinned against Python's hashlib.
2. The catalog's canonical layout and view JSON and `fields_encode` parse JSON and use an
   allocator, so they cannot run at comptime. `format_test.zig`'s "persisted derivations" test
   hashes their output and checks it against a ledger of `(epoch, hash)` entries: the last entry's
   epoch must equal `format_epoch`, and epochs must increase. A change to that output needs a new
   entry, so it needs a higher `format_epoch`. An epoch moved for another reason needs an entry
   with the same hash and the new epoch.
3. The vendored list gains `vsr.Header.Eviction.Reason`, `vsr.ReconfigurationResult`,
   `CompositeKeyType(u64)`, `CompositeKeyType(u128)`, `UniqueKeyType(u64)` and
   `UniqueKeyType(u128)` (the index trees' keys and the id trees' value, as `groove.zig`
   instantiates them).
4. A unit test (`the walk`) walks every field of every listed type at comptime, through arrays,
   optionals and pointers, and fails when a struct, enum or union field type is in no list. A
   type may be excluded in `walk_excluded` with a reason. It is empty: nothing is excluded.

**Why.** A field's type is rendered by name only, so an enum a listed header carries was covered
only if listed too: a reorder of `Eviction.Reason` would have left the digest alone while a
rolling upgrade mis-decoded evictions. And the derivation goldens were pinned without being tied
to the epoch: updating one with an explanation would have left the digest unchanged.

**The digest moved** because the vendored list grew by six types and the text gained the
`derivations:` section; nothing else. The test snapshot's digest and `commands.py`'s
`FORMAT_DIGEST` (the binary's, which differs from the test's by the cluster configuration) moved
for this reason alone.

**Cost.** More changes move the digest. The ledger is a small by-hand step when the catalog's
output changes, and the derivations' inputs are fixed in two places (the digest and the goldens).
