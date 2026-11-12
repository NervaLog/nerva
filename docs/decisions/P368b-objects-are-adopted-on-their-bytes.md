---
id: P368b
date: 2026-11-12
area: Releases
---

# A package object is adopted on its bytes, and junk at one name never stops the re-signing

**Decision.** `package_repos.sh` accepts an existing object (adopting it at a pending entry,
promoting it to `published`, or putting it in an index) only after it has downloaded the object and
hashed the bytes against the entry's SHA-256. `x-amz-meta-sha256` is what the uploader chose to say,
so it is never enough. This is `r2.py get-lenient`: `get`'s check against the stored hash, but a
mismatch is exit 4 and no NRV-E1143, so the script can decide.

- An object whose bytes are not the entry's (lying metadata included) is **noted**: the entry stays
  `pending`, the object is left out of the indexes, and the run ends red with NRV-E1142 after it has
  re-signed and uploaded every index from what does verify. `Valid-Until` never lapses for junk at a
  pending name. The same holds for a content-named index object, which is replaced as before.
- A listed, published object that fails the check is left out of the indexes the same way (the locks
  make it impossible; the red run is the alarm).
- `ready` replaces a tag's entries (its draft's assets changed) only when no entry of the tag is
  published **and** no object exists at any key of the tag's old entries (NRV-E1141 otherwise), as
  the spec says. Checking only the differing key left locked rpm objects with no matching entry.
- `ready … true` writes nothing: it skips the lock probe, which is a write attempt.

**Why.** The spec: "never trust an object for being there", and an unexpected object "never stops
it from re-signing". The alternative, refusing with NRV-E1143 at the first mismatch, let a token
holder wedge every later run with a lying header.

**Costs.** One download per pending or listed object that is adopted or indexed (at most four per
release for a pending tag, and a package is read once to build the indexes anyway). `r2.py` gains one
command.

**Correction to P368.** P368 says both keys sign every index. `InRelease` and `Release.gpg` carry
both signatures during a rotation; `repomd.xml.asc` is signed with the `current` key only, as the
spec's "Signing" table asks.

New code: NRV-B0006, a loop of `package_repos.sh` ran past its own bound (an assertion of the script,
exit 70).
