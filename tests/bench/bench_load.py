#!/usr/bin/env python3
"""`bench-load`'s workloads against a real local cluster (R3 slice 1, P414).

Usage: bench_load.py <bench-load>

- Every workload (closed loop, and an open loop) writes `warmup + seconds` timeline lines, the
  warm-up's flagged, one second apart, none empty (a run that drops the warm-up from its length
  leaves the last `warmup` lines empty), and the lines of the measured seconds add up to the
  summary.
- `botpike` with `--gateway-statsd` sends `nerva.api.*` datagrams to the socket, and its PID file
  names a live `nerva api` while the run lasts, and is gone after.
- A bad `--timeline` or `--gateway-pid-file` path is refused at once with NRV-E0727, before any
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
    result = run(bench, ["--local", f"--workload={name}", "--clients=2", f"--warmup={WARMUP}",
                         f"--seconds={SECONDS}", f"--timeline={timeline}"] + extra)
    assert result.returncode == 0, (label, result.returncode, result.stdout, result.stderr[-2000:])
    check_timeline(read_timeline(timeline), json.loads(result.stdout), label)
    print(f"ok {label}")


def botpike(bench, tmp):
    pid_file = os.path.join(tmp, "gateway.pid")
    timeline = os.path.join(tmp, "botpike.jsonl")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    sock.settimeout(0.2)
    statsd = f"127.0.0.1:{sock.getsockname()[1]}"
    process = subprocess.Popen(
        [bench, "--local", "--workload=botpike", "--clients=2", "--keys=100", f"--warmup={WARMUP}",
         f"--seconds={SECONDS + 3}", f"--timeline={timeline}", f"--gateway-statsd={statsd}",
         f"--gateway-pid-file={pid_file}"],
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
    assert not os.path.exists(pid_file), "the PID file outlives the gateway"
    assert not os.path.exists(f"/proc/{pid}") or b"api" not in open(f"/proc/{pid}/cmdline", "rb").read()
    lines = read_timeline(timeline)
    assert len(lines) == WARMUP + SECONDS + 3, len(lines)
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
    assert len(lines) == 1 and lines[0].startswith("error[NRV-E0727]: bench-load: " + flag), (label, lines)
    assert not re.search(r"\berror\.[A-Z]", result.stderr) and "FileNotFound" not in result.stderr, label
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
        for value in ["ignore", "inherit"]:
            result = run(bench, ["--local", "--workload=c1", "--seconds=1",
                                 f"--gateway-stderr={value}"], timeout=30)
            assert result.returncode == 1 and "only for the botpike workload" in result.stderr, value
        print("ok --gateway-stderr refused for c1")


if __name__ == "__main__":
    main()
