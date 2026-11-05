---
id: P148b
date: 2026-11-04
area: Releases
amends: P147
---

# The cheapest model suited to the task, and one agent per new task

**Decision:** the owner set this for every repository on 2026-11-04.

- Every agent or session is started on the cheapest model that suits its task, and the model is
  named, never inherited by default:
  - **Haiku** for mechanical work and lookups;
  - **Sonnet** for implementing slices, writing their tests and fixing findings;
  - **Opus** for design, briefs, review, and judgments a cheaper model got wrong.
- Every new task gets a fresh agent. This widens P147's "one agent per slice" to fixes, lookups
  and reviews too.

**Why:** cost grows with the model and with the context an agent carries. Most of the work is
implementation against a written brief, which Sonnet does well when Opus reviews it.

**What it costs:** a cheaper model's mistakes are caught in review rather than avoided, and a
fresh agent re-reads the brief and the branch each time.
