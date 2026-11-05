---
id: N79
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# Still short of disk, CI removes other repositories' workspaces from the runner.

The runner volume is shared with other repositories' jobs (N65's warning showed it: after the Zig
caches were emptied, 2.7 GB of 9.8 GB was free, the rest other checkouts and their caches), so
emptying Nerva's own caches no longer always reaches `FREE_MIN_GIB`. When it does not,
`free_disk.sh` now removes every directory beside this job's workspace in the runner's work
directory (`dirname $RUNNER_WORKSPACE`), except the runner's own (`_temp`, `_actions`, `_tool`,
anything starting with `_`), logging each with its size. It is safe because a Machine runs one
job at a time and every job checks out afresh; another repository's next job only clones again.
It runs only under Actions (`GITHUB_ACTIONS=true`, `RUNNER_WORKSPACE` set), never on a
developer's machine. Other repositories' caches under `$HOME` are left alone: they are theirs to
prune. Chosen by the owner over raising the threshold or a larger volume.
