---
id: N66
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# `nerva api` serves views whole, as `nerva view` answers them; `nerva view` becomes the check.

The third step of N52 (design approved by the owner). Applications read views where
they write, from replicated state, and `nerva view` stays as an independent recomputation.
- **Routes.** `GET /v1/views/<name>` is now the view (it was the declaration, now at
  `/definition`; before 1.0 anything may break): every group, sorted by key, rendered by the
  same code as `nerva view` (`declared.render`, shared), so the answer, and `hash`, the SHA-256
  of its `groups` JSON, are `nerva view`'s byte for byte. `view_hash` (the replicated hash, N52)
  and `declared_op` come with it; `/groups` names the replicated hash `view_hash` too (it
  said `hash` until #66, renamed before v0.4.0 shipped), so `hash` always means `nerva
  view`'s. `as_of` and `min_op` mean what they mean in `nerva view`, and
  an op not yet committed answers 504 as there; a view still building or failed answers 503
  rather than part of an answer. `GET /v1/views` lists the views the state machine maintains;
  the `get_view` header now carries the view's name in `group_key` for it.
- **One op.** The gateway reads the first page at the latest op (or `as_of`), and every later
  page as of the first's op, so a whole answer is one op's even while writes go on. More than
  10,000 groups is refused (400): such a view is read in pages from `/groups`.
- **Reads as of an op scan only what changed.** `Group.op` (from `reserved`) is the last op that
  changed a group. A read as of `a` takes a group whose `op <= a` as it stands, and scans for the
  version of the others. A page as of an op ends before the group that would take more than 128
  scans (`view_as_of_scans_max`; fewer with tests' small messages, so that pages end early), not
  at 128 groups as in N62: a whole canvas (4,096 groups) as of an op costs 4 pages, and scans
  only the pixels painted since.
- **Demos.** The seat and canvas demos read their views from `nerva api`; the agreement panel
  compares its hash with a `nerva view` process's at the same op ("maintained" and
  "recomputed").
- **Tests.** `tests/views/maintained.py` compares `GET /v1/views/<name>` with `nerva view`, byte
  for byte, at every op it checks, latest and as of past ops; and checks 504 for `min_op` and
  `as_of` past the log, 400 for both together, 404 before the declaration, `/definition`, the
  listing, and the refusal past 10,000 groups. The randomized state machine test reads pages of
  3 groups with 1 scan each, so pages end early. Mutation-tested: skipping the scan for a group
  changed after `as_of`, and resuming the next page one group late, each fail it.
- **Found.** The canvas test fails about three runs in four on `main` since N62, before this
  change: a replica killed while another syncs stalls the cluster past `nerva view`'s 30 s
  client timeout, and the process then exits (#42; #49 carries the fix). N62's heavier commits
  for the canvas's per-pixel `max` view make such stalls longer.
