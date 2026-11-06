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

1. takes `flock` (a second start leaves quietly) and a whole-night deadline of 3 h
   (`JEPSEN_NIGHT_SECONDS`); a run past it is killed and counted as the host's;
2. fetches `main`, builds `nerva` in ReleaseSafe at the tip (`./zig/zig build -Drelease`);
3. runs `retry` and then `bank`, each `--nemesis kill,partition,gateway --time-limit 3600` and a
   fresh `--seed` (about 2.5 h with setup and checking), each into its own `store/<n>/`, with one
   line in `store/runs` (`<n> <exit code> <seconds> <arguments>`);
4. archives the night's `store/` as `/var/lib/jepsen/archive/<date>.tar.zst`, kept 90 days;
5. calls `python3 -I jepsen_report.py ingest`.

The script runs from a private copy of itself: the checkout it moves to the tip of `main` is the
one it started from.

## What the reporter does

`jepsen_report.py ingest --store DIR --commit SHA --state FILE [--runs FILE] [--archive PATH]
[--tracker N] [--expect-invalid] [--dry-run] [--repo OWNER/NAME --token-file FILE]`. Python 3,
standard library only (P147i). For each run:

| Run | Status `jepsen/nightly` | Issue |
| --- | --- | --- |
| valid | `success` | none |
| invalid or unknown (`results.edn`) | `failure` | one per fingerprint |
| the host's (exit 124, 125, 126 or 137, a build that failed, Docker down, no `results.edn`, graphs that did not draw) | `error` | **never** |

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
  every run was invalid with a `duplicate`; a run that saw none is `failure` ("canary blind").
  Its fingerprints are its own.
- **`--dry-run`:** prints what it would write and writes nothing to GitHub.

The token is read from a file and never printed or put in an error. Redirects are not followed.
Tests: `python3 -I ops/jepsen/test_jepsen_report.py`.

## The host

The R2 Hetzner box, shared with the fleet. **The owner provisions it** (rents it, installs the
OS, creates the token and the tracker issue, runs `setup.sh` as root).

| Need | What |
| --- | --- |
| Machine | x86_64, 8 cores / 16 threads, 64 GB, NVMe; **KVM exposed** (`/dev/kvm`, for slice 10 only) |
| OS | Ubuntu 24.04 LTS, cgroup v2, systemd |
| Memory for Jepsen | 16 GB during its window: 5 replicas at about 1.33 GiB, 10 gateways, a 4 GB JVM. The fleet is stopped for the window |
| Time | about 2.5 h a night (two 3,600 s runs, setup, checking), the fleet stopped meanwhile |
| Docker | Docker Engine, **privileged containers** (iptables in the nodes), the `owner` iptables match, `/dev/fuse` passed to the nodes (slice 9) |
| Tools | OpenJDK 21, Leiningen 2.12.0 (sha256 pinned by `tests/jepsen/tools.sh`), gnuplot (else every result is `:unknown`), git, python3, zstd; Zig from `./zig/download.sh` |
| sshd | The host's own sshd for the owner: keys only. The nodes' sshd lives inside the Docker network and is never exposed |
| Users | `jepsen`, in the `docker` group (root-equivalent: the host is single-purpose, and the fleet's `simfleet` user and token stay apart) |
| Disk | 100 GB free for `store/` archives (90 days) and images |
| Network out | github.com and api.github.com, clojars.org and Maven Central, ziglang.org, Docker Hub and deb.debian.org |
| GitHub token | A fine-grained PAT on `NervaLog/nerva` only: **Issues read/write, Commit statuses read/write**, metadata read; nothing else. Not the fleet's. Its expiry noted on the tracker issue |

## Deploy

On the host, as root:

```sh
git clone https://github.com/NervaLog/nerva.git /tmp/nerva && cd /tmp/nerva
sh ops/jepsen/setup.sh --token-file /root/jepsen-token      # then delete the file
$EDITOR /etc/jepsen/jepsen.env                              # JEPSEN_TRACKER=<issue number>
systemctl start jepsen.service                              # a night now; journalctl -u jepsen -f
```

`setup.sh` installs the packages, creates the user, copies the token to `/etc/jepsen/token`
(0600; the unit hands the service a private copy through `LoadCredential`), clones the repository
to `/var/lib/jepsen/nerva`, fetches the toolchain and Leiningen, runs the reporter's tests, and
enables the timer. It does not touch the fleet. To see a night without writing to GitHub:
`JEPSEN_DRY_RUN=1 sudo -u jepsen JEPSEN_HOME=/var/lib/jepsen /var/lib/jepsen/nerva/ops/jepsen/nightly.sh`
(it still stops nothing: stop the fleet by hand first).

## Limits

- Not run on a host yet (slice 7). Verified in a cloud session: the reporter's tests, a dry run
  against the stores of two hosted runs, `shellcheck`, and `systemd-analyze verify`.
- A run cannot be replayed from its seed: the seed steers Jepsen's generators and the faults
  interleave with real time (N82, P215c).
