---
id: P374
date: 2026-11-12
area: Releases
amends: P147b
---

# The release commit pins the candidate's code

**Decision.** "Code pinned" (owner, 2026-11-12). The `main` commit that changes `VERSION` must be
identical to the candidate in every path whose content the soak and Jepsen exercised and that
`zig build` reads: `src/` (`@embedFile`s included), `build.zig`, `build.zig.zon` and `zig/`, the
toolchain; and `.gitmodules` and every `.gitattributes`, which can rewrite `src/` at checkout while
every blob stays the same. `VERSION` may change (it is only the version string). Packaging, docs,
tests and workflow changes after the candidate may ship.

The candidate is named on `main`, in `release/candidate`: its full SHA, one line. Choosing a
candidate means writing that file, in a commit **before** the `VERSION` commit.
`release_check.sh candidate <tag> <commit>` (NRV-E1158) reads the file at the release commit's
**first parent** and refuses a release commit that changes it at all, so the release commit cannot
repoint the candidate (a squash or a merge commit alike).

That alone is not enough: a **rebase merge** (this repository allows it) or a multi-commit push
lands a `repoint` commit and the `VERSION` bump in one push, and the bump's first parent already
holds the repoint. So `release.yml` also passes the push's `github.event.before` (main's head
before the push) as a fourth argument, and the check refuses when `release/candidate` differs
between `before` and the release commit, that is, when the same push changed it. It fails closed
when `before` is empty, all zeros, not in the checkout, or not an ancestor of the commit. A
`workflow_dispatch` of `release.yml` has no `before`: a release (no suffix) is refused then, and
must come from the push that merges the `VERSION` commit; a prerelease rehearsal is checked at the
first parent only, with a note. `release-finish.yml`'s `publish` has no push event and keeps the
first-parent rule; `release.yml`'s `version` job, which ran on the push that created the draft, is
the gate. Turning off rebase merging for the repository would close the shape at its source; it is
an owner setting, recommended here, and the check does not depend on it. It also refuses a missing or malformed
file, a candidate that is not an ancestor of the commit, and any difference under the pinned paths
(decided by `git diff --quiet`'s exit status, never by parsing names, so a quoted or non-ASCII path
or a git failure cannot pass; the names are listed only for the message). It runs in
`release.yml`'s `version` job before CI and any build (full history, `fetch-depth: 0`, no secrets,
as the job already is), and in `release-finish.yml`'s `publish` job on the draft's target before
the draft is published, so a hand-dispatched finish cannot publish an unpinned commit. A
prerelease whose parent has no file passes; with it, the check runs, so rehearsals exercise it.
`release/candidate` is set now to `5d7d8062ba932782457b5bace5a0d501cb77630e`, v0.7.1's candidate.

**What the pin does not cover.** The workflows. `release.yml` and `mac-sign.yml` run
`zig build` with flags (`-Drelease`, `-Dtarget`, and any `-D` a later edit adds, such as
`-Dconfig_verify` or `-Dgit-commit`); a workflow change after the candidate can change the build
without touching a pinned path. Only `-Dtest-commit-keys=off` is caught (`binary`, #271). Each
release reviewer therefore diffs the `zig build` lines of those two workflows against the
candidate's. Nor is the binary byte-identical to the candidate's: `build.zig` reads
`git rev-parse HEAD`, so the shipped binary names the release commit, not the candidate. A
`release/candidate` change merged in an earlier push than the bump is still possible (the release
reviewers review the candidate before the `VERSION` PR exists); the supervisor and the two
reviewers read that file's history, which now is one line in its own commit.

**P259e (revert release).** A revert release is N's tree with the next `release` string in
`build.zig`, so it differs from N in a pinned path. It names itself as the candidate: the revert
commit is written to `release/candidate` on `main` first, and the `VERSION` commit follows it with
no pinned path changed. The revert release still skips the soak, as P259e says; this decision only
asks that the file names the commit being released.

**Why.** #371: `main` had moved 22 commits past the soaked candidate, and nothing compared the
release commit with it. The brief's promised check (`release_pr_check.sh`) was never written. A
local `git diff` over full history was chosen over the compare API, which lists at most 300
files and so could hide a pinned path.

**Cost.** A `release/candidate` change costs one extra commit before the bump. A fix to `src/` after the candidate means a new candidate and a new soak and Jepsen
night, which is the intent. The finish check runs in `publish`, after the owner's `mac` approval,
so a hand-dispatched finish for an unpinned commit still spends that approval; nothing is
published. The area is spelled `Releases`, as P369's is.
