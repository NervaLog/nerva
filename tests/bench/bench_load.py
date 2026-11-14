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
- Flag values out of range are refused with NRV-E0002; a failed write after the cluster started tears
  the cluster down first (no `nerva` process or cluster directory outlives any case).
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


def children():
    """The `nerva` processes (replicas, gateways) and the cluster directories that exist now."""
    found = set()
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as f:
                argv = f.read().decode(errors="replace").split("\0")
        except OSError:
            continue
        if argv[0].endswith("/nerva") or argv[0] == "nerva":
            found.add(int(entry))
    tmp = os.path.join(os.getcwd(), ".zig-cache", "tmp")
    directories = {d for d in os.listdir(tmp) if d.startswith("nerva-bench-")} if os.path.isdir(tmp) else set()
    return found, directories


BASELINE = None


def stray_files(cwd):
    """What a run left in its cwd, besides the .zig-cache its local cluster uses."""
    return [name for name in os.listdir(cwd) if name != ".zig-cache"]


def assert_clean(label):
    """No replica or gateway of this case survives it, and no cluster directory (it is torn down)."""
    deadline = time.time() + 5
    while True:
        found, directories = children()
        leaked = (found - BASELINE[0], directories - BASELINE[1])
        if not leaked[0] and not leaked[1]:
            return
        assert time.time() < deadline, (label, "left behind", leaked)
        time.sleep(0.2)


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
    assert_clean(label)
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
    assert_clean("botpike")
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
    """The file was made, then a write failed (/dev/full): one coded line, no raw Zig error, and the
    cluster (and the gateway) the run started is gone."""
    result = run(bench, argv, timeout=120)
    lines = [line for line in result.stderr.splitlines() if line.strip()]
    assert result.returncode == 1, (label, result.returncode, result.stderr[-500:])
    assert len(lines) == 1 and lines[0] == (
        f"error[NRV-E0728]: bench-load: {flag}: cannot write /dev/full: no space left on the device"
    ), (label, lines)
    assert not re.search(r"\berror\.[A-Z]|NoSpaceLeft", result.stderr), label
    assert_clean(label)
    print(f"ok {label}")


def main():
    global BASELINE
    bench = os.path.abspath(sys.argv[1])
    BASELINE = children()
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
        assert lines[0].startswith("error[NRV-E0002]: bench-load: --warmup plus --seconds"), lines
        print("ok --warmup plus --seconds over 3600 refused (NRV-E0002)")
        # A write that fails after the file was made (/dev/full: ENOSPC) is one coded line too.
        write_failure(bench, ["--local", "--workload=c1", "--seconds=1", "--timeline=/dev/full"],
                      "timeline write fails", "--timeline")
        write_failure(bench, ["--local", "--workload=botpike", "--seconds=1",
                              "--gateway-pid-file=/dev/full"],
                      "PID file write fails", "--gateway-pid-file")
        # A bad value out of range is NRV-E0002, and nothing starts.
        for argv, label in [(["--clients=0"], "--clients 0"), (["--batch=0"], "--batch 0"),
                            (["--keys=1", "--batch=2"], "--keys under --batch"),
                            (["--hot=0"], "--hot 0")]:
            result = run(bench, ["--local", "--workload=c1", "--seconds=1"] + argv, timeout=30)
            lines = [line for line in result.stderr.splitlines() if line.strip()]
            assert result.returncode == 1 and len(lines) == 1, (label, lines)
            assert lines[0].startswith("error[NRV-E0002]: bench-load: --"), (label, lines)
        print("ok out-of-range flags refused (NRV-E0002)")
        # Every output is opened before any is emptied: an earlier result at --timeline survives a
        # refused --gateway-pid-file or --output, and no file of the refused run is left. The
        # statsd address is valid, so the run gets as far as the PID file (without the fix the
        # timeline is truncated first).
        for flag, label in [("--gateway-pid-file", "PID file"), ("--output", "output")]:
            keep = os.path.join(tmp, "keep.jsonl")
            with open(keep, "w") as handle:
                handle.write("previous-result\n")
            bad = os.path.join(tmp, "no-such-dir", "out")
            result = run(bench, ["--local", "--workload=botpike", "--seconds=1", f"--timeline={keep}",
                                 f"{flag}={bad}", "--gateway-statsd=127.0.0.1:8125"], timeout=30)
            lines = [line for line in result.stderr.splitlines() if line.strip()]
            assert result.returncode == 1 and len(lines) == 1, (label, lines)
            assert lines[0].startswith(f"error[NRV-E0728]: bench-load: {flag}: cannot write "), lines
            assert "error." not in lines[0] and not result.stdout, (label, lines, result.stdout)
            with open(keep) as handle:
                assert handle.read() == "previous-result\n", f"{label}: the earlier timeline was emptied"
            assert_clean(f"refused {label}")
        print("ok a refused output leaves an earlier timeline untouched (NRV-E0728)")
        # A plain-opened output (a hard-linked file is written in place, not renamed) is changed only
        # once the run has succeeded, as on main (P414c): a refused later flag leaves it as it was.
        hard = os.path.join(tmp, "hard.json")
        with open(hard, "w") as handle:
            handle.write("previous-result\n")
        os.link(hard, hard + ".twin")
        result = run(bench, ["--local", "--workload=botpike", "--seconds=1", f"--output={hard}",
                             f"--gateway-pid-file={os.path.join(tmp, 'no-such-dir', 'pid')}",
                             "--gateway-statsd=127.0.0.1:8125"], timeout=30)
        assert result.returncode == 1 and "NRV-E0728" in result.stderr, result.stderr
        with open(hard) as handle:
            assert handle.read() == "previous-result\n", "a hard-linked --output was emptied by a refused run"
        assert_clean("refused run with a hard-linked output")
        print("ok a plain-opened output is untouched by a refused run (P414c)")
        # A bad --output is refused before the run, one coded line, with no timeline made.
        timeline = os.path.join(tmp, "fresh.jsonl")
        result = run(bench, ["--local", "--workload=c1", "--seconds=1", f"--timeline={timeline}",
                             "--output=/no/such/dir/out.json"], timeout=30)
        lines = [line for line in result.stderr.splitlines() if line.strip()]
        assert result.returncode == 1 and len(lines) == 1 and lines[0].startswith(
            "error[NRV-E0728]: bench-load: --output: cannot write /no/such/dir/out.json"), lines
        assert not os.path.exists(timeline), "a timeline is left by a refused run"
        assert_clean("bad --output")
        # A finished timeline survives a failed --output write (/dev/full is a device: not removed).
        timeline = os.path.join(tmp, "survives.jsonl")
        result = run(bench, ["--local", "--workload=c1", "--seconds=1", f"--timeline={timeline}",
                             "--output=/dev/full"], timeout=60)
        lines = [line for line in result.stderr.splitlines() if line.strip()]
        assert result.returncode == 1 and len(lines) == 1 and lines[0].startswith(
            "error[NRV-E0728]: bench-load: --output: cannot write /dev/full"), lines
        assert os.path.getsize(timeline) > 0, "the finished timeline was lost"
        assert_clean("failed --output write")
        print("ok --output refused up front; a finished timeline survives (NRV-E0728)")
        # An earlier --timeline / --output survives any later failure: a PID file that cannot be
        # written, a gateway that does not start, a timeline that cannot be written.
        for label, extra in [
            ("PID file on /dev/full", ["--workload=botpike", "--gateway-pid-file=/dev/full"]),
            ("--nerva=/bin/false", ["--workload=botpike", "--nerva=/bin/false"]),
            ("timeline on /dev/full", ["--workload=c1"]),
        ]:
            keep = os.path.join(tmp, "earlier.json")
            with open(keep, "w") as handle:
                handle.write("previous-result\n")
            if label.startswith("timeline"):
                argv = ["--workload=c1", "--timeline=/dev/full", f"--output={keep}"]
            else:
                argv = [f"--timeline={keep}"] + extra
            result = run(bench, ["--local", "--seconds=1"] + argv, timeout=120)
            assert result.returncode == 1, (label, result.returncode, result.stderr[-300:])
            with open(keep) as handle:
                assert handle.read() == "previous-result\n", f"{label}: the earlier file was emptied"
            assert [n for n in os.listdir(tmp) if n.endswith(".tmp")] == [], label
            assert_clean(label)
        print("ok a later failure leaves an earlier output file as it was")
        # A pipe is written in place: /dev/stdout, /dev/fd/N (process substitution) and
        # /dev/stdout twice reach the reader, and no `pipe:[N]` file is made in the cwd.
        piped_cwd = os.path.join(tmp, "pipecwd")
        os.makedirs(piped_cwd)
        for label, flags, timeline in [
            ("--output=/dev/stdout", ["--output=/dev/stdout"], False),
            ("--timeline=/dev/stdout", ["--timeline=/dev/stdout"], True),
            ("--timeline and --output both /dev/stdout",
             ["--timeline=/dev/stdout", "--output=/dev/stdout"], True),
        ]:
            result = subprocess.run(
                [bench, "--local", "--workload=c1", "--seconds=1"] + flags,
                cwd=piped_cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
            assert result.returncode == 0, (label, result.returncode, result.stderr[-300:])
            # The timeline is one JSON object per line (second 0 first); the summary is JSON too.
            if timeline:
                first = json.loads(result.stdout.splitlines()[0])
                assert "t_us" in first, (label, "no timeline line on the pipe", first)
            else:
                assert "t_us" not in result.stdout, (label, "a timeline on the pipe, none asked")
                json.loads(result.stdout)
            assert stray_files(piped_cwd) == [], (label, stray_files(piped_cwd))
        # The output file is a pipe made by the shell (process substitution, /dev/fd/N).
        captured = os.path.join(tmp, "captured.out")
        subprocess.run(
            ["bash", "-c", f'"$0" --local --workload=c1 --seconds=1 --output=>(cat > "{captured}")',
             bench], cwd=piped_cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
            check=True)
        for _ in range(50):
            if os.path.exists(captured) and os.path.getsize(captured) > 0:
                break
            time.sleep(0.1)
        assert os.path.getsize(captured) > 0, "nothing reached the process substitution"
        assert stray_files(piped_cwd) == [], stray_files(piped_cwd)
        # A path that cannot be looked at is one coded line, not a panic (NRV-E0728).
        result = run(bench, ["--local", "--workload=c1", "--seconds=1",
                             "--timeline=/dev/stdout", "--output=" + "a" * 5000], timeout=30)
        lines = [line for line in result.stderr.splitlines() if line.strip()]
        assert result.returncode == 1 and len(lines) == 1 and lines[0].startswith(
            "error[NRV-E0728]: bench-load: --output: cannot write "), (result.returncode, lines)
        assert lines[0].endswith("the path is too long"), lines
        assert_clean("unreadable path")
        print("ok a pipe is written in place; an unreadable path is refused in one line")
        # Two output flags may not name one file (same path, or the same inode): NRV-E0728.
        same = os.path.join(tmp, "same.out")
        link = os.path.join(tmp, "same.link")
        with open(same, "w") as handle:
            handle.write("previous-result\n")
        os.link(same, link)
        # Dangling links: the target is not made yet, and a plain open would make it.
        dangling = os.path.join(tmp, "dangling.target")
        link_a = os.path.join(tmp, "dangling.a")
        link_b = os.path.join(tmp, "dangling.b")
        os.symlink("dangling.target", link_a)
        os.symlink(dangling, link_b)
        for label, argv, flag in [
            ("--timeline = --gateway-pid-file", [f"--timeline={same}", f"--gateway-pid-file={same}"],
             "--gateway-pid-file"),
            ("--timeline = --output", [f"--timeline={same}", f"--output={same}"], "--output"),
            ("--output = --timeline by hard link", [f"--timeline={same}", f"--output={link}"],
             "--output"),
            ("one path not made yet", [f"--timeline={tmp}/new.out", f"--output={tmp}/./new.out"],
             "--output"),
            ("a dangling link and its target", [f"--timeline={link_a}", f"--output={dangling}"],
             "--output"),
            ("two dangling links to one file", [f"--timeline={link_a}", f"--output={link_b}"],
             "--output"),
        ]:
            result = run(bench, ["--local", "--workload=botpike", "--seconds=1"] + argv, timeout=30)
            lines = [line for line in result.stderr.splitlines() if line.strip()]
            assert result.returncode == 1 and len(lines) == 1, (label, lines)
            assert lines[0].startswith(f"error[NRV-E0728]: bench-load: {flag}: cannot write "), lines
            assert lines[0].endswith("another output flag names the same file"), lines
            assert not result.stdout, label
            with open(same) as handle:
                assert handle.read() == "previous-result\n", label
            assert not os.path.exists(os.path.join(tmp, "new.out")), label
            assert not os.path.exists(dangling), label
            assert_clean(label)
        print("ok two output flags naming one file are refused (NRV-E0728)")


if __name__ == "__main__":
    main()
