#!/usr/bin/env python3
"""`bench-load`'s workloads against a real local cluster (R3 slice 1, P414).

Usage: ./zig/zig build bench:build && python3 tests/bench/bench_load.py zig-out/bin/bench-load

Not in `test:integration` yet: that wiring is a change to `build.zig`, a vendored file (UPSTREAM.md),
which the owner has to approve (PR #414's question).

- Every workload (closed loop, and an open loop) writes `warmup + seconds` timeline lines, the
  warm-up's flagged, one second apart, none empty (a run that drops the warm-up from its length
  leaves the last `warmup` lines empty), and the lines of the measured seconds add up to the
  summary.
- `botpike` with `--gateway-statsd` sends `nerva.api.*` datagrams to the socket, and its PID file
  names a live `nerva api` while the run lasts, and is gone after.
- `--gateway-stderr=inherit` passes the gateway's lines on; `t_us` is wall-clock time.
- A bad `--gateway-statsd` (too long, malformed, port 0) is refused at once with NRV-E0736.
- A bad `--timeline` or `--gateway-pid-file` path is refused at once with NRV-E0728, before any
  cluster starts; so is `--gateway-stderr` on a workload with no gateway.
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

WARMUP = 2
SECONDS = 3
CLOSED = ["c1", "c2", "c3", "c3_adds", "c4", "c5", "c7"]


def run(bench, argv, timeout=180):
    return subprocess.run([bench] + argv, capture_output=True, text=True, timeout=timeout)


def read_timeline(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def check_timeline(lines, summary, label):
    assert len(lines) == WARMUP + SECONDS, (label, len(lines))
    for index, line in enumerate(lines):
        assert line.get("warmup", False) == (index < WARMUP), (label, index, line)
        assert line["count"] > 0, (label, "an empty second", index)
        assert sum(count for _, count in line["buckets"]) == line["count"], (label, index)
        if index:
            assert line["t_us"] - lines[index - 1]["t_us"] == 1_000_000, (label, index)
    measured = sum(line["count"] for line in lines[WARMUP:])
    assert measured == summary["operations"], (label, measured, summary["operations"])
    assert summary["seconds"] == SECONDS and summary["warmup"] == WARMUP, (label, summary)
    assert summary["failures"] == 0, (label, summary)
    assert summary["latency_us"]["max"] == max(line["max_us"] for line in lines[WARMUP:]), label


def workload(bench, tmp, name, extra, label):
    timeline = os.path.join(tmp, label + ".jsonl")
    before = time.time()
    result = run(bench, ["--local", f"--workload={name}", "--clients=2", f"--warmup={WARMUP}",
                         f"--seconds={SECONDS}", f"--timeline={timeline}"] + extra)
    assert result.returncode == 0, (label, result.returncode, result.stdout, result.stderr[-2000:])
    after = time.time()
    lines = read_timeline(timeline)
    summary = json.loads(result.stdout)
    check_timeline(lines, summary, label)
    assert before * 1e6 <= lines[0]["t_us"] <= after * 1e6, (label, "t_us is not wall-clock")
    assert 0 <= summary["late_operations"] <= 2, (label, summary["late_operations"])
    print(f"ok {label}")


def botpike(bench, tmp):
    pid_file = os.path.join(tmp, "gateway.pid")
    timeline = os.path.join(tmp, "botpike.jsonl")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    sock.settimeout(0.2)
    statsd = f"127.0.0.1:{sock.getsockname()[1]}"
    before = time.time()
    process = subprocess.Popen(
        [bench, "--local", "--workload=botpike", "--clients=2", "--keys=100", f"--warmup={WARMUP}",
         f"--seconds={SECONDS + 3}", f"--timeline={timeline}", f"--gateway-statsd={statsd}",
         f"--gateway-pid-file={pid_file}", "--gateway-stderr=inherit"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        pid = None
        deadline = time.time() + 120
        while pid is None:
            assert process.poll() is None and time.time() < deadline, "no PID file"
            try:
                with open(pid_file) as f:  # Made empty before the run, filled at the spawn.
                    text = f.read().strip()
            except FileNotFoundError:  # The process has not started yet.
                text = ""
            if text:
                pid = int(text)
            else:
                time.sleep(0.05)
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            argv = f.read().decode().split("\0")
        assert "api" in argv and f"--statsd={statsd}" in argv, argv
        datagrams = []
        while process.poll() is None:
            try:
                datagrams.append(sock.recv(65535).decode())
            except socket.timeout:
                pass
        stdout, stderr = process.communicate(timeout=60)
    finally:
        process.kill()
        sock.close()
    assert process.returncode == 0, (process.returncode, stdout, stderr[-2000:])
    assert any("nerva.api." in datagram for datagram in datagrams), datagrams[:5]
    after = time.time()
    # Inherited: the gateway's own lines (`nerva api` logs the replica connections) reach our stderr.
    assert "message_bus" in stderr or "nerva" in stderr.lower(), ("no gateway stderr", stderr[-500:])
    assert not os.path.exists(pid_file), "the PID file outlives the gateway"
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            assert b"api" not in f.read(), "the gateway outlives the run"
    except FileNotFoundError:
        pass  # gone, or reaped between the check and the read: both are what we want
    lines = read_timeline(timeline)
    assert len(lines) == WARMUP + SECONDS + 3, len(lines)
    summary = json.loads(stdout)
    assert before * 1e6 <= lines[0]["t_us"] <= after * 1e6, ("t_us is not wall-clock", lines[0]["t_us"])
    assert 0 <= summary["late_operations"] <= 2, summary["late_operations"]
    assert all(line["count"] > 0 for line in lines), "an empty second"
    assert sum(line["count"] for line in lines[WARMUP:]) == json.loads(stdout)["operations"]
    print("ok botpike statsd and pid file")


def refusal(bench, argv, label, flag):
    started = time.time()
    result = run(bench, argv, timeout=30)
    lines = [line for line in result.stderr.splitlines() if line.strip()]
    assert result.returncode == 1, (label, result.returncode, result.stderr)
    assert result.stdout == "", (label, "it ran", result.stdout)
    assert time.time() - started < 15, (label, "slow: the cluster started")
    assert len(lines) == 1 and lines[0].startswith("error[NRV-E0728]: bench-load: " + flag), (label, lines)
    assert not re.search(r"\berror\.[A-Z]", result.stderr) and "FileNotFound" not in result.stderr, label
    print(f"ok {label}")


def write_failure(bench, argv, label, flag):
    """The file was made, then a write failed (/dev/full): one coded line, no raw Zig error."""
    result = run(bench, argv, timeout=120)
    lines = [line for line in result.stderr.splitlines() if line.strip()]
    assert result.returncode == 1, (label, result.returncode, result.stderr[-500:])
    assert lines and lines[-1] == (
        f"error[NRV-E0728]: bench-load: {flag}: cannot write /dev/full: no space left on the device"
    ), (label, lines[-3:])
    assert not re.search(r"\berror\.[A-Z]|NoSpaceLeft", result.stderr), label
    print(f"ok {label}")


def main():
    bench = os.path.abspath(sys.argv[1])
    with tempfile.TemporaryDirectory() as tmp:
        for name in CLOSED:
            workload(bench, tmp, name, [], name)
        workload(bench, tmp, "c1", ["--rate=100"], "c1 open loop")
        botpike(bench, tmp)
        missing = os.path.join(tmp, "no", "such", "dir", "x")
        refusal(bench, ["--local", "--workload=c1", "--seconds=1", f"--timeline={missing}"],
                "bad --timeline", "--timeline: cannot write " + missing)
        refusal(bench, ["--local", "--workload=botpike", "--seconds=1",
                        f"--gateway-pid-file={missing}"],
                "bad --gateway-pid-file", "--gateway-pid-file: cannot write " + missing)
        for value, label in [("a" * 130 + ":8125", "too long"), ("notanaddress", "malformed"),
                             ("127.0.0.1:0", "port 0")]:
            started = time.time()
            result = run(bench, ["--local", "--workload=botpike", "--seconds=1",
                                 f"--gateway-statsd={value}"], timeout=30)
            lines = [line for line in result.stderr.splitlines() if line.strip()]
            assert result.returncode == 1 and result.stdout == "", (label, result.returncode)
            assert time.time() - started < 15, (label, "slow: the cluster started")
            assert len(lines) == 1 and lines[0].startswith("error[NRV-E0736]: bench-load: --gateway-statsd"), (label, lines)
            assert "NoSpaceLeft" not in result.stderr and "GatewayNotReady" not in result.stderr, label
            print(f"ok --gateway-statsd {label} refused")
        for value in ["ignore", "inherit"]:
            result = run(bench, ["--local", "--workload=c1", "--seconds=1",
                                 f"--gateway-stderr={value}"], timeout=30)
            lines = [line for line in result.stderr.splitlines() if line.strip()]
            assert result.returncode == 1 and len(lines) == 1, (value, lines)
            assert lines[0].startswith("error[NRV-E0001]: bench-load: --gateway-stderr is only for the botpike workload"), lines
        print("ok --gateway-stderr refused for c1 (NRV-E0001)")
        result = run(bench, ["--local", "--workload=c1", "--warmup=2000", "--seconds=2000"], timeout=30)
        lines = [line for line in result.stderr.splitlines() if line.strip()]
        assert result.returncode == 1 and len(lines) == 1, lines
        assert lines[0].startswith("error[NRV-E0001]: bench-load: --warmup plus --seconds"), lines
        print("ok --warmup plus --seconds over 3600 refused (NRV-E0001)")
        # A write that fails after the file was made (/dev/full: ENOSPC) is one coded line too.
        write_failure(bench, ["--local", "--workload=c1", "--seconds=1", "--timeline=/dev/full"],
                      "timeline write fails", "--timeline")
        write_failure(bench, ["--local", "--workload=botpike", "--seconds=1",
                              "--gateway-pid-file=/dev/full"],
                      "PID file write fails", "--gateway-pid-file")


if __name__ == "__main__":
    main()
