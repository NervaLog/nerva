---
id: P244f
date: 2026-11-06
area: Releases
amends: P244e
---

# A canary that produced no duplicate is blind, whether or not the harness failed

**Decision.** Under `--expect-invalid`, a run whose only failure is an NRV-E0607 verdict (the
Jepsen harness failed, `:valid? :unknown`) is classed blind, not `host`: the status is `failure`
(`canary blind: ...`) and a "canary is blind" issue is filed under the canary's own fingerprint,
its body naming the harness failure and telling the reader to check `jepsen.log`. A harness
failure beside a real finding that is not a `duplicate` is blind too; beside a `duplicate` the
canary saw what it expects and is `success`. The nightly (non-canary) rule of P244e is unchanged:
NRV-E0607 alone is the host's, status `error`, never filed. The canary's one question is whether
Jepsen sees a duplicate; a run that cannot answer it must not pass or hide as `error`.

**Why.** Fourth review of #244: with the `gateways` checker unknown and the workload clean, the
canary was `error` and no issue was opened, so a blind canary could stay unnoticed behind an ssh
hiccup in the final phase.

**Costs.** A harness hiccup on the canary's one run now opens a "blind" issue that may be
spurious; the body names the harness failure so triage starts in `jepsen.log`, and the issue is
closed by hand like every canary issue.
