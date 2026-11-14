---
id: P417e
date: 2026-11-14
area: Releases
amends: P417c
---

# SHA256SUMS is checked whole before it is signed, and the pre-P417 set is accepted

**Decision.** `repos-ready` signs `SHA256SUMS` only after it has (1) required the lines to name exactly the
release's files (four tarballs, four packages, the two `.debug` files, the bill of materials: eleven), none
repeated, none extra, none malformed, (2) required each to have a 64-digit hash that is not zero, and
(3) downloaded each from the draft and hashed it. Any miss is NRV-E1140.

The pre-P417 set is accepted as it was, with no `.debug` files, nine lines and no signature, for a release
whose version is up to `v0.7.1` (its `-rc` builds included) and whose assets hold no `.debug` and no
`SHA256SUMS.asc`: `v0.7.1` is published before P417 merges, and a hand-run `release-finish` for it must not
fail with NRV-E1131 or NRV-E1165. `release_check.sh publish-ready` ignores `signed` for it, `repos-ready`
does not sign it, and `sums-verify` passes it with a notice. Any later version needs the full set and the
signature.

An `.asc` already on a draft is never replaced; NRV-E1165's fix now says to delete the asset first.

**Reason.** A signature over sums nobody had checked vouched for a zero or missing `.debug` line. The cutover
is the version and the absent assets together, so a later release that lost its `.debug` files is refused.
**Cost.** The check downloads every listed asset (the tarballs too) in `repos-ready`; the cutover is a
constant (`0.7.1`) in two scripts.
