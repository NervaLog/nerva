#!/usr/bin/env python3
"""A client of a newer release than its cluster is evicted with NRV-E0609 (#356).

Usage: eviction.py <nerva> <nerva of a higher release>

Run by `mixed.py` (so `build.zig` needs no step of its own), or alone.

A three-replica cluster of `nerva`, two replicas running; the other release's `export` and `recover` register, are
evicted (`client_release_too_high`) and must end `error[NRV-E0609]`, exit 1, naming both
releases and the fix: never `bug[NRV-B0004]`, never NRV-E0716's "fewer clients" and never a raw
Zig error name. The cluster's own release still exports.
"""
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

# Replicas authenticate each other with a real cluster key, never the development key (P102).
os.environ["NERVA_CLUSTER_KEY"] = os.urandom(32).hex()


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def check(result, command):
    """`result` ended with the one coded line NRV-E0609 for `command`, and nothing raw."""
    lines = [l for l in result.stderr.splitlines() if re.match(r"(error|bug)\[NRV-", l)]
    assert result.returncode == 1, (command, result.returncode, result.stderr[-2000:])
    assert len(lines) == 1 and lines[0].startswith(f"error[NRV-E0609]: {command}: the cluster "
                                                   "runs release "), result.stderr[-2000:]
    assert re.search(r"release \d+\.\d+\.\d+; this client, release \d+\.\d+\.\d+, is newer",
                     lines[0]), lines[0]
    assert "fix" in result.stderr and "B0004" not in result.stderr, result.stderr
    assert "E0716" not in result.stderr and "fewer clients" not in result.stderr, result.stderr
    unlogged = [l for l in result.stderr.splitlines() if not re.match(r"\d{4}-\d\d-\d\d ", l)]
    assert not re.search(r"\berror\.[A-Z]", "\n".join(unlogged)), result.stderr


def main():
    run(*(os.path.abspath(a) for a in sys.argv[1:3]))


def run(nerva, other):
    nerva, other = os.path.abspath(nerva), os.path.abspath(other)
    tmp = tempfile.mkdtemp(prefix="nerva-eviction-")
    replicas = []
    try:
        # Three replicas formatted, replicas 0 and 2 running: `recover` of replica 1 needs two
        # answering peers (NRV-E0712), and the cluster commits with two.
        ports = [free_port() for _ in range(3)]
        addresses = ",".join(f"127.0.0.1:{port}" for port in ports)
        address = f"--addresses={addresses}"
        for index in range(3):
            formatted = subprocess.run(
                [nerva, "format", "--cluster=0", f"--replica={index}", "--replica-count=3",
                 "--development", os.path.join(tmp, f"{index}.nerva")],
                capture_output=True, text=True)
            assert formatted.returncode == 0, formatted.stderr
        for index in (0, 2):
            data = os.path.join(tmp, f"{index}.nerva")
            replicas.append(subprocess.Popen(
                [nerva, "start", address, "--development", data],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                stderr=open(data + ".log", "w")))
        deadline = time.monotonic() + 120
        for index, replica in zip((0, 2), replicas):
            while True:
                assert replica.poll() is None, open(
                    os.path.join(tmp, f"{index}.nerva.log")).read()[-3000:]
                try:
                    socket.create_connection(("127.0.0.1", ports[index]), timeout=1).close()
                    break
                except OSError:
                    assert time.monotonic() < deadline, "a replica never listened"
                    time.sleep(0.2)

        good = subprocess.run([nerva, "export", "--cluster=0", address,
                               "--output=" + os.path.join(tmp, "good")],
                              capture_output=True, text=True, timeout=120)
        assert good.returncode == 0, good.stderr[-2000:]

        result = subprocess.run([other, "export", "--cluster=0", address,
                                 "--output=" + os.path.join(tmp, "x")],
                                capture_output=True, text=True, timeout=120)
        check(result, "export")

        # `recover` is evicted the same way: not "fewer clients" (NRV-E0716).
        result = subprocess.run(
            [other, "recover", "--cluster=0", "--replica=1", "--replica-count=3", address,
             "--origin=none", "--development", os.path.join(tmp, "recovered.nerva")],
            capture_output=True, text=True, timeout=180)
        check(result, "recover")
        logs = "".join(open(os.path.join(tmp, f"{i}.nerva.log")).read() for i in (0, 2))
        assert "client_release_too_high" in logs
        print("NRV-E0609 checked (export and recover)")
    finally:
        for replica in replicas:
            replica.kill()
            replica.wait()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
