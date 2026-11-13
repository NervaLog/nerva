---
id: P359
date: 2026-11-12
area: Releases
---

# For v0.7.1, the fleet is pinned to the candidate at once, and the canary and the teeth night run during the soak

**Decision.** The owner decided on 2026-11-12 to compress the pre-soak steps in
`ops/sim-fleet/README.md` ("Before the soak counts") for v0.7.1:

- Step 4 (one full day on `main`) is skipped. The fleet and the Jepsen nightly are pinned to the
  candidate, `5d7d8062ba932782457b5bace5a0d501cb77630e`, as soon as the host is up.
- Step 5 (R2's canary) and step 6 (R1's teeth night) run while the soak is under way, not before
  it starts.

**Why.** The host came from a short-notice auction, and the release has waited on it for days.
Steps 4 to 6 prove the fleet and Jepsen would report a failure. That proof matters for the
result, not for when the soak starts, so it can come before the soak is graded rather than before
it begins.

**Cost.**
- The canary moves the fleet off the candidate for its rounds. The teeth night takes one Jepsen
  window on the keys-off build, so the candidate needs another clean night. Both add wall time to
  the roughly 27 hours.
- If either check shows that a failure would go unreported, every hour already soaked counts for
  nothing: fix the reporter, then start the soak again.
- The release PR quotes the canary's issue and the teeth night's issue beside the soak line and
  the Jepsen result.
- The README's order stays the default for later releases.
