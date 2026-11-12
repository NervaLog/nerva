---
id: P374
date: 2026-11-12
area: Releases
amends: P147b
---

# The release commit pins the candidate's code

**Decision.** "Code pinned" (owner, 2026-11-12). The `main` commit that changes `VERSION` must be
identical to the candidate in every path the soak and Jepsen exercised: `src/`, `build.zig`,
`build.zig.zon` and `zig/`. Those are the paths that go into the binary (`build.zig` reads only
`VERSION`, which may change, and sources under `src/`, `@embedFile`s included) and the toolchain
that builds it. Packaging, docs, tests and workflow changes after the candidate may ship.

The candidate is named on `main`, in `release/candidate`: its full SHA, one line. Choosing a
candidate means writing that file. `release_check.sh candidate <tag> <commit>` (NRV-E1158) reads it
at the release commit and refuses a missing or malformed file, a candidate that is not an ancestor
of the commit, and any pinned path in `git diff --name-only <candidate> <commit>`, which it prints.
It runs in `release.yml`'s `version` job before CI and any build (full history, `fetch-depth: 0`,
no secrets, as the job already is), and in `release-finish.yml`'s `publish` job on the draft's
target before the draft is published, so a hand-dispatched finish cannot publish an unpinned
commit. A prerelease without the file passes; with it, the check runs, so rehearsals exercise it.
`release/candidate` is set now to `5d7d8062ba932782457b5bace5a0d501cb77630e`, v0.7.1's candidate.

**Why.** #371: `main` had moved 22 commits past the soaked candidate, and nothing compared the
release commit with it. The brief's promised check (`release_pr_check.sh`) was never written. A
local `git diff` over full history was chosen over the compare API, which lists at most 300
files and so could hide a pinned path.

**Cost.** A fix to `src/` after the candidate means a new candidate and a new soak and Jepsen
night, which is the intent. The finish check runs in `publish`, after the owner's `mac` approval,
so a hand-dispatched finish for an unpinned commit still spends that approval; nothing is
published. The area is spelled `Releases`, as P369's is.
