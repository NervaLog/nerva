---
id: P406f
date: 2026-11-13
area: Testing
amends: P406b, P406c
---

# R3's local mode skips the host checks and never counts; `same.py` compares `allocated` only

R3's scope is cut after the brief's second review, rather than adding design:

- **`--hosts=local` checks the harness, not the hosts.** Its preflight records the kernel,
  `nproc`, `MemTotal`, the data directory's file system, mount options and free space, and that
  `nerva version` runs. It does not run `fio`, the clock check or the pings: it records each as
  `skipped` in the preflight facts and in `report.md`, whether or not the tools are installed.
  A local run never counts toward delivery, which stays a green `perf-r3.yml` on the owner's four
  VMs (P406b). The `demo_r3` CI job installs nothing for it.
- **Demo step 5** (the cgroup refusal under `systemd-run`) runs only on CI's runner, which has
  systemd as PID 1 and `sudo`. A session runs `--steps=1-4` and reports `PARTIAL`, never a passed
  demo.
- **`same.py`'s memory check** (amends P406c's "each replica's allocation and RSS") compares each
  replica's `allocated <n>MiB` line only, within 1%. RSS (`VmRSS`, `VmHWM`, every sample) and the
  gateway's memory are printed, not checked.
- **The address check** in slice 4's tests covers the results files (`report.md`,
  `results.json`, the preflight facts, `same.py`'s output) for any inventory address, and every
  output for SSH targets. Replica and gateway logs may name private addresses (`listening on`);
  those are not secret.
- **Slice 2's patch to `src/nerva_main.zig`** (the `command_start` budget wrap, NRV-E0723) is
  named in the brief, with the sentence it adds to that file's `UPSTREAM.md` row (P284b), so
  the slice does not stop on CLAUDE.md's stop item 2.

The reason: CI's runner and session containers have no `fio`, `chronyc` or `ping`, and a
container's PID 1 is not systemd, so a local preflight that ran them could never pass and
`demo-r3` could never go green. RSS moves with THP and the kernel, and the gateway's few tens of
MiB make a 1% bound smaller than its arena's own movement; `allocated` is fixed at start.

What it costs: CI never exercises the disk, clock and ping checks; they first run on the owner's
hosts, in `perf-r3.yml`'s first dispatch. RSS repeatability is reported but not enforced. Private
addresses can reach `perf-results` in replica logs.
