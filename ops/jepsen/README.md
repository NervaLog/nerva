# The Jepsen nightly

One host runs [tests/jepsen](../../tests/jepsen/README.md) every night against the tip of `main`
and reports what it finds on GitHub (R1, slice 6; `docs/briefs/r1.md`). A valid night is a green
commit status; a failure is an issue with the seed, the command, the verdict and the history. It
shares the host with the [simulation fleet](../sim-fleet/README.md), which it stops for its
window.

## What runs

`jepsen.timer` starts `jepsen.service` at **01:17 UTC** (`Persistent=true`: a host that was off
runs the night when it comes up). The unit stops `sim-fleet.service`, runs `nightly.sh` as the
user `jepsen`, and starts the fleet again whatever happened (`ExecStartPre=+` and
`ExecStopPost=+`, root, outside the unit's sandbox). `nightly.sh`:

1. takes `flock` once (a second start, by hand say, logs the holder's pid and exits 75, so the unit shows as failed) and a whole-night deadline of 3 h
   (`JEPSEN_NIGHT_SECONDS`); a run past it is killed and counted as the host's;
2. fetches `main`, builds `nerva` in ReleaseSafe at the tip (`./zig/zig build -Drelease`);
3. runs `retry` and then `bank`, each `--nemesis kill,partition,gateway --time-limit 3600` and a
   fresh `--seed` (about 2.5 h with setup and checking), each into its own `store/<n>/`, with one
   line in `store/runs` (`<n> <exit code> <seconds> <arguments>`);
4. archives the night's `store/` as `/var/lib/jepsen/archive/<date>.tar.zst`, kept 90 days;
5. calls `python3 -I jepsen_report.py ingest`.

**The runner is never the tip's (P240).** `setup.sh` installs `nightly.sh` and `jepsen_report.py`
into `/opt/jepsen/bin` (root-owned, readable by `jepsen`, read-only inside the unit) and the unit
runs that copy. The night fetches `main` into `/var/lib/jepsen/nerva` and builds and tests that
checkout, the code under test; it never runs the `ops/jepsen/` in it. So a broken `nightly.sh` or
`jepsen_report.py` on `main` cannot silence a night, and no checkout can wedge the next one. **A
change to the runner (`nightly.sh`, `jepsen_report.py`, `jepsen.service`, `jepsen.timer`) reaches the
host only when `setup.sh` runs again**, as root, from a checkout of the commit to install.

Any end that is not the end of the script (a systemd stop or the unit's timeout, which send TERM;
a Ctrl-C; a `set -e` abort such as a full disk) goes through one `EXIT` trap: it records the run in
flight (as exit 143 only if it was still running) and gives every workload that never ran a 143
line, so the night is never `success`. It writes a `host-failure` only when no run had finished (a
finished run's finding is reported as it is: `failure` and its issue), and posts `jepsen/nightly`
(`error`, or `failure`) and the tracker's line within about 80 s, once;
`TimeoutStopSec=120` leaves room for that. A stop during the final report is not reported again
(the reporter may have filed an issue; a second report could file it twice). `docker info` is
bounded to 60 s. A second night that finds the lock held logs the pid in `nightly.pid` and exits
75; `setup.sh` takes the same lock for the checkout and refuses while a night runs. With no token, `nightly.sh` exits at once with
one journal line; the unit runs `nightly.sh --check-token` before it stops the fleet.

## What the reporter does

`jepsen_report.py ingest --store DIR --commit SHA --state FILE [--runs FILE] [--archive PATH]
[--tracker N] [--expect-workloads "W1 W2"] [--expect-invalid] [--no-status] [--dry-run] [--repo OWNER/NAME --token-file FILE]`. Python 3,
standard library only (P147i). For each run:

| Run | Status `jepsen/nightly` | Issue |
| --- | --- | --- |
| valid | `success` | none |
| invalid or unknown (`results.edn`) | `failure` | one per fingerprint |
| the test threw: a `jepsen.log` and no `results.edn`, and no host exit code, and no host failure (ssh refused, out of heap, disk full, Docker) at the log's end (`nerva` died at setup, say) | `failure` | one per workload (checker `run`, class `crashed`), with the log's end |
| the host's (exit 124, 125, 126, 137 or 143 with no verdict written, a build that failed, Docker down, Jepsen never started, graphs that did not draw) | `error` | **never** |

`failure` outranks `error` outranks `success`: a night with one real finding and one host
failure is `failure`, and the finding is filed. A night that did not run at all (`host-failure`
in the store) is `error`.

- **Fingerprint:** workload, the failing checker key and its anomaly class (`duplicate`,
  `balance`, `applied-lie`, `conservation`, `record`, `unknown-result`, ...). Never the seed, the
  commit or the time. It is a hidden marker in the issue; the state file
  (`/var/lib/jepsen/state/state.json`) is rebuilt from the issues labelled `jepsen` if it is lost.
- **Issue:** labelled `jepsen`: the commit, the seed, the exact command (machine options left
  out), the verdict (`results.edn`, at most 6 KiB), the anomalous operations of `history.edn` with
  50 operations of context each side (at most 48 KiB; the context shrinks to fit), and the
  archive's path on the host. The checker's verdict is a hint: reproduce it as a VOPR seed or a
  unit test before fixing (N82).
- **Known failure:** a comment for a commit not yet reported, at most 4 a day per failure, and
  at most 16 distinct failures looked at a UTC day.
- **Tracker:** one comment a day on `JEPSEN_TRACKER`: what ran, on which commit, the verdict.
  **A day without one is the alarm.**
- **`--expect-invalid`:** the canary (slice 8). The status is `jepsen/canary`, `success` only if
  every run was invalid with a `duplicate`; a run that saw none is `failure` ("canary blind"), and a run that threw before a verdict is `failure` ("canary crashed", filed as a crash with the canary's own fingerprint, not as blind).
  Its fingerprints are its own.
- **`--dry-run`:** prints what it would write and writes nothing to GitHub. The state file it is
  given is written, so `nightly.sh` gives a dry run one of its own (`state/dry-run.json`).
- **Statuses only move up** (P235b): error, then success, then failure, per commit and context.
  A later night on the same commit never turns a `failure` green, and a night that could not run
  never turns a `success` into `error`. The rank is the higher of the state file's and GitHub's own
  status for the commit (read before posting); if that read fails, nothing is posted and the tracker
  line says so (P235b). A night that failed to fetch posts no status (`--no-status`):
  it tested nothing, and the commit it knew is the previous night's. The tracker line says so.

The token is read from a file and never printed or put in an error. Redirects are not followed.
Tests: `python3 -I ops/jepsen/test_jepsen_report.py`.

## The host

The R2 Hetzner box, shared with the fleet. **The owner provisions it** (rents it, installs the
OS, creates the token and the tracker issue, runs `setup.sh` as root).

| Need | What |
| --- | --- |
| Machine | x86_64, 8 cores / 16 threads, 64 GB, NVMe (P147h's suggestion); **KVM exposed** (`/dev/kvm`, for slice 10 only) |
| OS | Ubuntu 24.04 LTS, cgroup v2, systemd |
| Memory for Jepsen | 16 GB during its window: 5 replicas at about 1.33 GiB, 10 gateways, a 4 GB JVM. The fleet is stopped for the window, so its `MemoryMax=56G` never overlaps |
| Time | about 2.5 h a night (two 3,600 s runs, setup, checking), the fleet stopped meanwhile |
| Docker | Docker Engine, **privileged containers** (iptables in the nodes), the `owner` iptables match, `/dev/fuse` passed to the nodes (slice 9) |
| Tools | OpenJDK 21 (Ubuntu's), Leiningen 2.12.0 (script and standalone jar, sha256 pinned), gnuplot (else every result is `:unknown`, #106), git, python3, zstd; Zig from `./zig/download.sh` |
| sshd | The host's own sshd for the owner: keys only. The nodes' sshd lives inside the Docker network and is never exposed; their `authorized_keys` comes from slice 2's `docker exec` |
| Users | `jepsen`, in the `docker` group (root-equivalent: the host is single-purpose, and the fleet's `simfleet` user and token stay apart) |
| Disk | 100 GB free for `store/` archives (90 days) and images |
| Network out | github.com and api.github.com, clojars.org and Maven Central (first `lein deps`), ziglang.org, Docker Hub and deb.debian.org (the node image, by digest) |
| GitHub token | A fine-grained PAT on `NervaLog/nerva` only: **Issues read/write, Commit statuses read/write**, metadata read; nothing else (the repository is public, so it clones without one). Delivered by systemd `LoadCredential`; its expiry noted on the tracker issue |

## Deploy

On the host, as root:

```sh
git clone https://github.com/NervaLog/nerva.git /tmp/nerva && cd /tmp/nerva
sh ops/jepsen/setup.sh --token-file /root/jepsen-token      # then delete the file
$EDITOR /etc/jepsen/jepsen.env                              # JEPSEN_TRACKER=<issue number>
systemctl start jepsen.service                              # a night now; journalctl -u jepsen -f
```

To change the runner later (a merged fix to `nightly.sh`, `jepsen_report.py` or the unit): pull
the commit and run `sh ops/jepsen/setup.sh` again. Nothing else updates it; the night does not.

`setup.sh` installs the packages, creates the user, installs the runner (`nightly.sh`,
`jepsen_report.py`) into `/opt/jepsen/bin` and the unit and timer into `/etc/systemd/system` from
the checkout it is run in, copies the token to `/etc/jepsen/token`
(0600; the unit hands the service a private copy through `LoadCredential`), clones the repository
to `/var/lib/jepsen/nerva`, fetches the toolchain and Leiningen, runs the reporter's tests, and
enables the timer only if a token was installed (with none it says so; a timer with no token runs a night that cannot report). It does not touch the fleet. To see a night without writing to GitHub:
`sudo -u jepsen /opt/jepsen/bin/nightly.sh --dry-run` (sudo drops
`JEPSEN_DRY_RUN` from the environment; `sudo -u jepsen env JEPSEN_DRY_RUN=1 ...` also works). A dry
run has a night directory (`nights/<date>-dry`), an archive and a state file of its own, so it
never touches a real night's. It still runs both workloads (about 2.5 h) and stops nothing: stop
the fleet by hand first.

## Limits

- Not run on a host yet (slice 7). **A runner change needs `setup.sh` run again on the host**
  (P240): merging it changes nothing there until then. Verified in a cloud session: the reporter's tests, a dry run
  against the stores of two hosted runs, `shellcheck`, and `systemd-analyze verify`. Bank's `results.edn` shape in the tests is built from `bank.clj`'s checker composition: no
  hosted run of `bank` existed to copy it from.
- A run cannot be replayed from its seed: the seed steers Jepsen's generators and the faults
  interleave with real time (N82, P215c).
