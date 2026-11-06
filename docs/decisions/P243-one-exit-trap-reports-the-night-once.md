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
  it only if no run had finished when it started: a line in `runs`, **or** the in-flight run's
  `run_code` already set (it returned, its line was not yet written; the trap writes that line
  with its own code). Otherwise the findings are reported as they are (`failure` outranks
  `error`). This keeps P240's rule.
- **An interrupted night is never `success`** (fifth-and-a-half review). When a run had finished,
  the trap writes a 143 line for every workload in `$JEPSEN_WORKLOADS` with no line in `runs`
  (a TERM between two runs), which the reporter reads as the host's. As a second guard
  `nightly.sh` passes `--expect-workloads "$JEPSEN_WORKLOADS"` to the reporter, which returns
  `error` ("no run of bank") instead of `success` when an expected workload has no run; a finding
  still outranks it. The guard costs one argument and a set difference.
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
  message, while a night runs (exit 75 is flock's alone: any failure inside is mapped to 1, so a 75
  from git or `download.sh` is not read as a night running). It copies `ops/jepsen/` before the
  checkout step and tests and installs that copy, so the commit installed is the commit tested. It creates `/opt/jepsen` and `/opt/jepsen/bin` with
  `install -d -m 755`, installs the unit files with `install -m 644`, and runs the reporter's
  tests as `jepsen` from a readable copy of `ops/jepsen/`, so a hardened umask cannot make the
  night fail with 203/EXEC.

Cost: a stop during the final report loses that report (the unit shows 143 and the journal says
so; the tracker has no line that day, which is the alarm). With no commit known the trap says so in
the journal and reports nothing. A hand-run `setup.sh` waits for the
night's end to move the checkout, by being run again.
