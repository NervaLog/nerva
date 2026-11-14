---
id: P429
date: 2026-11-14
area: Operations
amends: P147h
---

# The simulation fleet re-execs the run.sh it builds, and alarms after 3 failing rounds

The decision, for #424:

- **Re-exec.** `run.sh` takes the SHA-256 of itself at start. After `follow_main` builds a commit,
  if that checkout's `ops/sim-fleet/run.sh` has another checksum, it `exec`s it (`bash <new>
  <same arguments>`, same environment, fd 9 (the lock) closed first), at most once per built
  commit: `SIM_FLEET_REEXEC=<commit>` is exported and a `run.sh` that finds its own commit there
  does not exec again. A bounded `SIM_FLEET_ROUNDS` carries over what is left.
- **Alarm.** `SIM_FLEET_ALARM_ROUNDS` (default 3) consecutive failing rounds raise NRV-E0730.
  A failing round is one `settle` ends with `ingest` non-zero or unrecorded, or refused for a dead
  worker. The streak is `state/failing-rounds` (`<count> <alarmed>`), so a restart keeps it, and a
  round that counts deletes it. At the threshold `run.sh` logs one `ALARM` line and runs
  `sim_fleet.py alarm`, which opens the open `sim-fleet` issue marked
  `<!-- vopr-fleet alarm: rounds failing -->` or comments on it. Once per streak; if filing fails
  it is tried again at the next failing round.
- **Why 3.** A round is 15 minutes. One failing round is a flaky disk or a GitHub blip; 3 is
  45 minutes, short against the 13 hours #424 lost, and rare by chance.

The reason: the loop that ran was the one systemd started, and it passed no `--round-id` to a
`sim_fleet.py` that required it, for 13 hours, silently. `alarm` reads no state file and lives in
the built reporter, so it works when `ingest`'s interface does not.

The cost: a `run.sh` change takes effect after the next build instead of the next restart (which is
what the README said); a one-round gap while it re-execs. The fleet pinned to c886c9f
(`SIM_FLEET_BRANCH`) runs its own old `run.sh` and is unchanged by this: the fix reaches it
only at the next pin.
