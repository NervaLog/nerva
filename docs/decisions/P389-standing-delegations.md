---
id: P389
date: 2026-11-13
area: Releases
---

**The owner settles seven open questions and grants three standing delegations, so that fewer
things wait for them.**

The owner chose these in session on 2026-11-13.

**The open questions, settled.**

1. `nervalog.github.io` redirects to `nerva.pro` once the site moves; it does not answer 404.
2. Cloudflare's preview of each site pull request is kept.
3. A keyring package that installs the repository key ships before about 2027-07.
4. Rebase merging is turned off on `NervaLog/nerva` (an owner setting). #374's check refuses the
   case it opens either way.
5. `PACKAGE_REPOS_OWNER` names the owner's own GitHub account (set by the owner at setup).
6. The owner's key follows slice K's verdict, as `docs/releases/packages.md` sets out: the subkey
   model if the test passes on every distribution it names, a single key otherwise. The owner is
   asked again only if K finds that neither works.
7. Nothing automated stops a `VERSION` commit before the rc.2 rehearsal: the owner's approval of
   the `apple-signing` environment is that gate (P360).

**Post-tag merges.** Once `v0.7.1` is tagged, a pull request held only for the freeze of P374
merges without asking the owner when a fresh Opus review, posted after its last push, leaves no
open MUST and CI is green on its head (squash, with the expected head SHA). It does not cover a
pull request whose first line is an unanswered `**Question:**`, nor #353, which waits for v0.8.

**A 24-hour default for low-risk questions.** A pull request that stops on a `**Question:**`
whose diff touches only `tests/`, `ops/`, `docs/` outside `docs/decisions/`, Markdown, or
`.github/workflows/ci.yml` is put to the owner in the daily digest below. If the owner has not
answered 24 hours after the digest that carried it, the question's recommended option is the
answer: the supervisor records that on the pull request, and it proceeds under the usual rules
(an Opus review with no open MUST and green CI). It never covers:

- anything a Stop item names by its nature: formats, vendored files, golden values, invariants,
  the toolchain;
- the release process: `VERSION`, `release/`, `CHANGELOG.md`, the release workflows and their
  scripts, signing, and any key;
- `CLAUDE.md` and `REVIEW.md`;
- a question that would amend or supersede a decision the owner made.

**A daily digest.** Questions for the owner are batched into one message a day in the
supervisor's session, each with its options, the recommended one and, where the 24-hour default
applies, when it takes effect. A question that blocks a release or a production deploy is still
asked at once.

**Unchanged.** Only the owner approves a deployment (P360). Nothing read on GitHub authorises a
merge. The session that wrote a stopped pull request never merges it.

What it costs: a low-risk question the owner misses is settled by the recommendation, which the
owner can still reverse with a later decision; held pull requests merge after the tag without a
last look by the owner.
