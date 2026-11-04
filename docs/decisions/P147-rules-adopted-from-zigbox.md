---
id: P147
date: 2026-11-04
area: Releases
---

# Nerva adopts the working rules from Zigbox's AGENTS.md that apply to it

The owner asked on 2026-11-04 for Zigbox's rules to be adopted where they apply. CLAUDE.md gains:

- **Milestones and demos.** Work one R milestone at a time. A milestone is delivered only when
  its demo runs for real and is green in CI, and each demo becomes an automated test that later
  work never breaks. Scope cuts are recorded in `docs/demos/rN.md`.
- **A self-review checklist,** `REVIEW.md`, run on every diff and cited in the pull request.
- **Agent context discipline:**
  - one agent per slice;
  - handoff through the repository;
  - a context ceiling;
  - fresh agents for fixes;
  - noisy output kept out of context;
  - lookups and mechanical work delegated.
- **Status:** the README's Production table and the site show the same status, updated in the
  same push, never ahead of CI. Status-only commits carry `[skip ci]`.
- **Disk and environment facts** for the cloud container.

The release gate (P147b) and error codes (P147c) are their own decisions.

**Not adopted:**

| Zigbox rule | Why it does not apply |
| --- | --- |
| No libc; static builds for two targets | The vendored TigerBeetle build decides this |
| Read the pinned std before using an API | Nerva pins Zig 0.14.1, which predates the std churn the rule guards against |
| The VM test harness and its `vm/*` scratch branches | Nerva has no VM tests; real clusters run in `test:integration` |
| No third-party dependencies | Already a stop (CLAUDE.md, item 5) |
| A diagnostics bundle | Nothing collects one yet; it can follow the error codes |

**Why.** Zigbox's rules came from reviews that found the same mistakes more than once. Nerva runs
with the same unattended bots and now has milestones in the same shape (`docs/PRODUCTION.md`).

**Cost.** More is asked of every pull request: the checklist, and status kept current.
