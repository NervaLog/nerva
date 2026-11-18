---
id: P461
date: 2026-11-14
area: CI
amends: N68
---

# A Markdown-only change starts no workflow, except where a required check forbids it.

Decision: every push and pull_request trigger except `ci.yml`'s pull_request ignores Markdown at the trigger (`packages.yml`, `jepsen.yml`), so GitHub starts no run. `docs/INSTALL.md` stays an input of `packages.yml`. `ci.yml`'s pull_request keeps its `changes` job.

Reason: the owner's rule is that Markdown must not take a CI machine. N68 said no check is required on main; the "To Auto-merge" ruleset now requires nine ci.yml checks, so a path-filtered pull_request run would leave them pending and block merging.

Cost: a Markdown-only pull request still takes one runner for the `changes` job, until the owner decides the question on #461.
