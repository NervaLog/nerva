---
id: P243
date: 2026-11-06
area: Releases
amends: P240
---

# One EXIT trap reports an abnormal night once; setup.sh takes the night's lock

Found by the fourth review of #240. It also amends P235b: its "a run that is past the deadline or
stopped is the host's" holds as before, and the statement that a stopped night is reported by the
TERM/INT trap alone (P240) is replaced by this.

- **One handler, on EXIT.** `nightly.sh` reports any end that is not the end of the script from a
  single `EXIT` trap: TERM and INT (`exit 143`), a `set -e` abort (a full disk) and an unset
  variable. It posts the night once, with the tracker's line. A stop
  during the final report is **not** reported again (`reporting=1`): the reporter may already
  have opened an issue, and a second report would open it twice.
- **A host failure only when no run had finished.** `host-failure` makes the night `error` and the
  reporter skips every finding (P235: a host failure does not hide a finding). So the trap writes
  it only if `runs` was empty when the trap started; with a run already on record, the interrupted
  run is recorded (143, or its own code) and the findings are reported as they are (`failure`
  outranks `error`). This keeps P240's rule, which the first version of this trap broke.
- **Where the trap starts.** It is installed after the lock, `nightly.pid`, the night's
  directories and the variables it reads (`commit`, `fetched`, `archive`, assigned first, as
  `set -u` is on in the trap). An end before that (a full disk at `nightly.pid` or `mkdir`) is
  **not** reported: the unit fails and the journal says why, and there is no tracker line that
  day, which is the alarm. The disk case cannot be reported from a full disk anyway.
- **A finished run keeps its code.** The trap records 143 only while the run's process is still
  running; if `supervise` had returned, it records that code (a crash stays a crash). A run
  already in `runs` is not written twice. A half-written `<date>.tar.zst.new` is removed.
- **`docker info` is bounded** (`timeout 60`, supervised), so a wedged dockerd is "Docker is not
  answering" at once, not a 3.5 h hold of the lock and the stopped fleet.
- **A real night that finds the lock held exits 75** (the unit fails, the journal names the pid)
  instead of 0.
- **`setup.sh` moves the checkout under `flock -n -o` (the lock's fd is not passed to git, whose detached gc could hold it past setup) on the night's lock** and refuses, with a
  message, while a night runs. It creates `/opt/jepsen` and `/opt/jepsen/bin` with
  `install -d -m 755`, installs the unit files with `install -m 644`, and runs the reporter's
  tests as `jepsen` from a readable copy of `ops/jepsen/`, so a hardened umask cannot make the
  night fail with 203/EXEC.

Cost: a stop during the final report loses that report (the unit shows 143 and the journal says
so; the tracker has no line that day, which is the alarm). A hand-run `setup.sh` waits for the
night's end to move the checkout, by being run again.
