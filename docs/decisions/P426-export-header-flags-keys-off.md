---
id: P426
date: 2026-11-14
area: Releases
---

# The export header's reserved word is a flags word; bit 0 marks a keys-off export

**Decision.** The export header's reserved u32 (bytes 12 to 16) becomes a flags word. Bit 0
(`export_file.flag_keys_off`) marks **the exporting binary's build**, not the cluster: it is set
only by a `nerva export` built with commit-key deduplication off (`-Dtest-commit-keys=off`); a release build writes 0, so a release export is byte-identical to
before. The format version does not change. A reader refuses any other set bit as corrupt (NRV-E0804),
as it refused any non-zero word. A release build that reads bit 0 refuses with NRV-E0812 (`import` and
`restore`, after pass 1 and before the data file is created); a keys-off build accepts it (#357).

**Owner's answer (2026-11-14).** Option (a) of the question on #426, over a version 3 with a build-mark
record (b) and a manifest-only mark (c).

**Why.** A keys-off cluster's log differs from a release's, and an export could say nothing of it, so
a release could import it silently (#357). This closes only the case where the export itself was made
by a keys-off build; #357 stays open for the cluster's own mode. One word that was already reserved and checked costs no
version bump and keeps every release export readable by every earlier release.

**Cost.** A release from before this change refuses a keys-off export as corrupt (NRV-E0804, "the
header's reserved bytes are not zero"), not by name. Keys-off builds are test builds, never installed,
so no operator meets it. The export's SHA-256 covers the header, so a keys-off export's digest
differs from a release's of the same log.
The bit does not follow the cluster: a release `nerva export` of a keys-off cluster writes 0, and a
release import accepts it (#357's own repro still succeeds). Without #354, a keys-off export of a
release cluster succeeds, carries the bit, and import then refuses it with E0812. Marking the cluster's mode needs the cluster to report it over the wire,
which this decision does not do. A future flag that older releases must refuse comes with a
`format_version` bump, so they report NRV-E0805 (version not read), not NRV-E0804 (corrupt).
