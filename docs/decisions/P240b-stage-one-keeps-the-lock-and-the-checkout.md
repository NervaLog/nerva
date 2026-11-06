---
id: P240b
date: 2026-11-06
area: Releases
amends: P240
---

# Stage 1 keeps the lock and the checkout, runs the tip's script as a child, and reports its death

Found by the second review of #240, filed as #241. The unit runs `nightly.sh` from the checkout,
and the night moves the checkout to the tip of `main`. A tip whose script was broken therefore
stayed in the checkout: the next night ran the broken script, which could die while parsing,
before it fetched the fix, and posted nothing from then on. A tip that parsed but died at run time
(an unbound variable, a renamed variable stage 2 expects) ended its night with no status either.

- **The checkout stays on a good commit.** Stage 1 records the commit the checkout is on before it
  fetches. When the tip's script does not parse, or stage 2 exits without having reported, it
  checks that commit out again. By induction that commit's night ran to the end. A night that
  completes leaves the checkout on its tip.
- **Stage 2 is a child.** Stage 1 runs the tip's script with `bash`, not `exec`, and waits for it.
  Stage 2 writes `$night/reported` as its last step; without it, whatever the exit code, stage 1
  writes `repo-failure` (the exit code and the end of stage 2's stderr), puts the checkout back and
  reports with its own copy of the reporter: status `failure`, one issue (`nightly|script|died`,
  beside `nightly|script|unparsable`) and the tracker's line. If the reporter itself fails in
  stage 2, stage 1 also reports; a GitHub outage then fails the second report too, and the next
  night tries again.
- **The lock is stage 1's alone.** Stage 1 takes it once and holds it to its exit; stage 2 gets fd 9
  closed. There is no window between the stages, and no `JEPSEN_LOCK_HELD`: it is gone. Stage 2
  counts as stage 2 only if `JEPSEN_STAGE=2` and `JEPSEN_STAGE1_PID` equals its parent's pid;
  anything else is stage 1 and takes the lock, so a stray variable in `jepsen.env` skips nothing.
  A night that finds the lock held logs the pid from `nightly.pid`, written by the holder.
- **Why a failed build is the host's and an unparsable script the repository's.** `bash -n` fails
  the same way on every machine, so a failure is a fact about the commit. A failed build of
  `main` is not: CI builds `main` first, and what the night sees (a full disk, ziglang.org
  unreachable, Docker down, an out-of-memory kill) is nearly always the host. A build that really
  is broken on `main` shows as CI's failure, and the nightly's `error` with `build.log` stays the
  place to look for the host.
- **Unit files.** The night moves only the checkout. `jepsen.service` and `jepsen.timer` are
  copied to `/etc/systemd/system` by `setup.sh`, so a host picks up a change to them only when
  `setup.sh` runs again (the README says so).

Cost: a night whose tip's script dies is reported by the old script, with the tip's reporter not
used, so a bug that lives only in the tip's reporter shows as `died` too. A first night after this
merges still runs the previous stage 1, which re-execs and does not restore the checkout.
