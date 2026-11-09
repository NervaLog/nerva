---
id: P250
date: 2026-11-06
area: Releases
amends: P148b
---

# Efficiency rules for agents and Jepsen work

**Decision.** Nine rules, from the review rounds on #238, #239, #242, #244 and #249.

a. A Jepsen harness change runs `tests/jepsen/CHECKLIST.md` before its first review. (#244 took
   five fix rounds and #239 three reviews, mostly on the same kinds of finding.)
b. When a fault injector gives a surprising result, prove it against a minimal standalone
   reproduction before reviewing or fixing code built on it. (#242 was reviewed and fixed while
   LazyFS lost `O_DIRECT|O_DSYNC` writes, issue #246.)
c. Slices are cut so concurrent pull requests do not edit the same files. When they must, the
   shared part merges first. (#242 waited on #244 for `db.clj` and `docs/ERRORS.md`.)
d. A supervisor checks a brief's factual premises, such as what is merged (`git log`), before it
   hands the brief to an agent. (A gap check was briefed that B1 slices 1 to 6 were merged in
   Zigcube; main had 1 to 4.)
e. A pull request leaves draft as soon as it is coherent, so CI runs. (#249's CI did not start
   while it was a draft.)
f. Iterations on a Jepsen harness change dispatch `jepsen.yml` with a short smoke (`args` with
   for example `--time-limit 60`). The full default run is for the head that will merge. (A hosted
   run takes about 14 minutes.)
g. Agents write downloads, builds of third-party code and scratch files outside the repository
   tree, in the session scratchpad. (A stray wheel landed in the repository root.)
h. Watching CI, auto-merge of a pull request and other polling go to a Haiku agent, not to the
   supervisor's model. (Supervisor turns were spent on status checks.) This amends P148b's list of
   what Haiku does.
i. Agents that run at once never share a checkout: each gets its own `git worktree` and Zig cache,
   and adds files by path, never `git add -A`. (Two agents shared one checkout and one swept the
   other's files into its commit.)

**Reason.** Each is in parentheses. The cost of a review round is a fresh session and a hosted run.

**Cost.** Rule a adds a pass over a short list before every harness review. Rule c can delay a
slice until the shared part merges. Rule f means the last hosted run is the only full one, so a
break that only shows in a long run is found late. Rule h adds a hand-off to another agent.
