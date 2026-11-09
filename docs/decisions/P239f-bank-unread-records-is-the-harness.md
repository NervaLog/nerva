---
id: P239f
date: 2026-11-09
area: Releases
amends: P239e
---

# Keyed `bank`: an unread record set is the harness's NRV-E0607; the records deadline is a total

**Decision.**
- `invoke-records`' deadline (`records-deadline-ms`, 180 s) is a true total. Every page of every
  scan and the count view check it, and each request's timeout is the time left (at most
  `http/timeout-ms`). The read ends within 180 s plus one health probe (3 s).
- When no record read answered, the `keys` checker is `:valid? :unknown` and now carries
  `:code "NRV-E0607"`, only when no fault was found (a broken run stays `false`, without a code).
  The reporter already drops a checker verdict with that code as the host's: the run is counted,
  never filed as a Nerva `jepsen` issue, and never turns the nightly red for it. Tested in
  `test_jepsen_report.py` on a fake store (with and without the code).
- `docs/ERRORS.md` extends NRV-E0607's entry with this case instead of registering a new code.
- A comment on `duplicates-by-conflict` says the canary's `duplicate` comes from dropped replies.

**Reason.** The fifth review (PR #239): the deadline was only checked between scans, and an
uncoded `:unknown` outranked the gateway's NRV-E0607 and filed an issue against Nerva, which
contradicted P239e.

**Cost.** Keys left unresolved while the records were read stay uncoded `:unknown` (the retry
workload's pattern). A harness that cannot read the records hides a real key bug in that run.
