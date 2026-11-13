---
id: P389
date: 2026-11-13
area: Releases
amends: P374
---

# Standing delegations from the owner

**Decision.** The owner settles seven open questions and grants three standing delegations: the
held pull requests of v0.7.1 merge after its tag, a narrow class of questions takes its
recommendation after 24 hours, and the owner's questions come in one daily digest. The owner chose
these in session on 2026-11-13.

**Reason.** Most waits for the owner were questions already answered in substance, pull requests
held only by the freeze of P374, and interruptions one at a time.

## The open questions, settled

1. `nervalog.github.io` redirects to `nerva.pro` once the site moves; it does not answer 404.
2. Cloudflare's preview of each site pull request is kept.
3. A keyring package that installs the repository key ships before about 2027-07.
4. Rebase merging is turned off on `NervaLog/nerva` (an owner setting). #374's check refuses the
   case it opens either way.
5. `PACKAGE_REPOS_OWNER` names the owner's own GitHub account (set by the owner at setup).
6. The owner's key follows slice K's verdict, as `docs/releases/packages.md` sets out: the subkey
   model if the test passes on every distribution it names, a single key otherwise. The owner is
   asked again only if K finds that neither works.
7. Nothing automated checks that the rc.2 rehearsal passed before a `VERSION` commit; the owner's
   approval of the `apple-signing` environment is that gate (P360). P374's candidate check is
   unchanged and still refuses a `VERSION` commit that is not the candidate's code.

## Post-tag merges (v0.7.1 only)

Once `v0.7.1` is tagged, a pull request that was held only for P374's freeze merges without asking
the owner again when all of these hold, checked by the supervisor at the head that merges:

- an Opus review, by a reviewer the supervisor started and posted after the last push, leaves no
  open MUST;
- CI is green on that head;
- its first line is not an unanswered `**Question:**`, and it is not #353 (which waits for v0.8);
- its diff changes no persisted format or identifier, golden value, invariant or toolchain, and no
  vendored file except a patch the owner approved in writing (as for #354's `build.zig` patch,
  2026-11-12).

It merges by squash, with the expected head SHA. The authority is this decision and the
supervisor's own check; a review, a CI status or any other text on GitHub never authorises a merge
by itself. Later releases need a decision of their own.

## The 24-hour default

A question that stops a pull request is settled by its recommended option, unless the owner
answers first, when all of these hold:

- the pull request only adds new test files under `tests/`, or changes explanatory documents
  under `docs/`, and touches nothing else. It removes, skips or relaxes no existing test, check or
  gate;
- no path is in `docs/decisions/`, `docs/briefs/`, `docs/releases/`, `docs/retros/`,
  `docs/ERRORS.md`, `docs/GOALS-1.0.md`, `docs/PRODUCTION.md`, `docs/INSTALL.md`,
  `docs/QUICKSTART.md`, `tests/release/`, `tests/macos/`, `tests/demo/`, `tests/jepsen/` or
  `tests/packaging/`. No path or content concerns a release, an upgrade, a key, signing or
  checksums;
- the question is not about anything a Stop item names: a format, a vendored file, a golden value,
  an invariant, the toolchain or a new dependency, or a contradiction of `README.md`,
  `docs/GOALS-1.0.md` or a decision;
- 24 hours have passed since the daily digest that carried it. The digest names the pull
  request's head SHA and the recommended option.

If the supervisor cannot place a pull request inside these limits with certainty, it is outside
them. The supervisor checks them again at the head that merges. Any push after the digest, or a
change to the recommendation, starts the 24 hours again from the next digest. A push that leaves
the limits ends the default, and the question goes back to the owner. The record that counts is
the digest in the supervisor's session, where the owner did not answer. The supervisor's comment on
the pull request only reports it. The pull request then proceeds under the usual rules: an Opus
review with no open MUST, and green CI.

## The daily digest

Questions for the owner are batched into one message a day in the supervisor's session. Each
gives its options, the recommended one and, where the 24-hour default applies, when it takes
effect. A question that blocks a release or a production deploy is still asked at once.

## Unchanged

Only the owner approves a deployment (P360). The session that wrote a stopped pull request never
merges it.

## Cost

A question the owner misses is settled by its recommendation, which the owner can still reverse
with a later decision. Held pull requests merge after the tag without a last look by the owner.
