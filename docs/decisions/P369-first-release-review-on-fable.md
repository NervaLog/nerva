---
id: P369
date: 2026-11-12
area: Releases
amends: P148b
---

# v0.7.1's first release review runs on Fable

**Decision.** The first of the two adversarial release reviews of v0.7.1 (P147b) runs on Fable,
not Opus (owner, 2026-11-12). It reviews candidate `5d7d806`, where the soak and Jepsen run,
against `v0.7.0`. The second reviewer is still a fresh session that does not see the first's
findings. Changes merged after `5d7d806` that ship in the release (the package repositories,
which touch no code under `src/`) get a short review of their own before the tag. Every other
review keeps P148b's tiers.

**Why.** The owner had Fable credits to spend, and the release review is the review whose
misses cost the most. It is required work anyway, so a stronger reviewer adds depth at no
extra cost to the release.

**Cost.** One review runs on a model the tier rule does not name. Its findings are handled as any
review's are: `release-review` issues, each fixed or waived in writing before the tag.
