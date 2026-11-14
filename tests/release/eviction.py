#!/usr/bin/env python3
"""A client of a newer release than its cluster is evicted with NRV-E0731 (#356).

Usage: eviction.py <nerva> <nerva of a higher release>

A one-replica cluster of `nerva`; the other release's `export` and `recover` register, are
evicted (`client_release_too_high`) and must end `error[NRV-E0731]`, exit 1, naming both
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


def main():
    nerva, other = (os.path.abspath(a) for a in sys.argv[1:3])
    tmp = tempfile.mkdtemp(prefix="nerva-eviction-")
    replica = None
    try:
        port = free_port()
        data = os.path.join(tmp, "0.nerva")
        formatted = subprocess.run(
            [nerva, "format", "--cluster=0", "--replica=0", "--replica-count=1", "--development",
             data], capture_output=True, text=True)
        assert formatted.returncode == 0, formatted.stderr
        replica = subprocess.Popen(
            [nerva, "start", f"--addresses={port}", "--development", data],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=open(data + ".log", "w"))
        address = f"--addresses=127.0.0.1:{port}"
        deadline = time.monotonic() + 120
        while True:
            assert replica.poll() is None, open(data + ".log").read()[-3000:]
            try:
                socket.create_connection(("127.0.0.1", port), timeout=1).close()
                break
            except OSError:
                assert time.monotonic() < deadline, "the replica never listened"
                time.sleep(0.2)

        good = subprocess.run([nerva, "export", "--cluster=0", address,
                               "--output=" + os.path.join(tmp, "good")],
                              capture_output=True, text=True, timeout=120)
        assert good.returncode == 0, good.stderr[-2000:]

        result = subprocess.run([other, "export", "--cluster=0", address,
                                 "--output=" + os.path.join(tmp, "x")],
                                capture_output=True, text=True, timeout=120)
        lines = [l for l in result.stderr.splitlines() if re.match(r"(error|bug)\[NRV-", l)]
        assert result.returncode == 1, (result.returncode, result.stderr[-2000:])
        assert len(lines) == 1 and lines[0].startswith("error[NRV-E0731]: export: the cluster "
                                                       "runs release "), result.stderr[-2000:]
        assert re.search(r"release \d+\.\d+\.\d+; this client, release \d+\.\d+\.\d+, is newer",
                         lines[0]), lines[0]
        assert "fix" in result.stderr and "B0004" not in result.stderr, result.stderr
        unlogged = [l for l in result.stderr.splitlines()
                    if not re.match(r"\d{4}-\d\d-\d\d ", l)]
        assert not re.search(r"\berror\.[A-Z]", "\n".join(unlogged)), result.stderr
        assert "client_release_too_high" in open(data + ".log").read()
        print("NRV-E0731 checked")
    finally:
        if replica is not None:
            replica.kill()
            replica.wait()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
