---
id: P183
date: 2026-11-05
area: Releases
amends: P168
---
`--listen-remote` and NRV-E0009 apply to `nerva view` as well as `nerva api`.

**Decision.** Both commands refuse a `--listen` that is not plain loopback unless `--listen-remote`
is given, and both log the same one warning when it is.

**Why.** The brief (P168, owner question 2) names only `nerva api`, but `nerva view` takes the same
`--listen`, serves plain HTTP and checks the same `NERVA_KEY`. The reason for refusing (the key and
plain HTTP never cross a network, P147g) applies to it unchanged; one rule for both is also simpler
to document.

**Owner.** On 2026-11-05 the owner answered yes to extending the refusal to `nerva view`.

**Cost.** Anyone running `nerva view` on `0.0.0.0` or `[::]` must also add `--listen-remote` on
upgrade; the next release's CHANGELOG upgrade step names both commands.
The step is tracked in CHANGELOG.md, "Unreleased".
