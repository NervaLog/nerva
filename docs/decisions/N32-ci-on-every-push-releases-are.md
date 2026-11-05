---
id: N32
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# CI on every push; releases are tags; the binary's release string stays `0.0.1`.

`ci.yml` runs on every push and pull request to `main`: typecheck, format, unit tests, the
integration test, the gateway and demo suites, and the
VOPR on seeds 1, 2 and 5, plus one random seed written to the job summary. `release.yml` (as first
written; N40 changed the trigger) ran on a `v*` tag: it calls the same CI on that commit, then cross-compiles Linux and macOS binaries
(x86_64, aarch64) from one Linux runner and publishes them, with `SHA256SUMS`, as a GitHub
release. A tag containing `-` is a prerelease.
The tag names a release; the binary does not take its version from the tag. Its release string
(`0.0.1`) is what TigerBeetle's replication and data file format record and check (it is in the
formatted data file's golden checksum), so it changes only when the protocol or format does,
in a commit that says why. Binaries report `0.0.1+<commit>`, and the release workflow checks the
commit matches.
Not set: `kernel.perf_event_paranoid`. The perf test skips itself where permission is denied,
as on GitHub's runners (as upstream's CI relies on); allowing it without hardware counters is
what makes it fail in sandboxes.
