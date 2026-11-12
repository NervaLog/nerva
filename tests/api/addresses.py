#!/usr/bin/env python3
"""Processes given a replica address they cannot open a socket for report it and retry (#92).

Usage: addresses.py <nerva>

Both cases need a host without IPv6, where a socket for `[::1]` cannot be opened
(`AddressFamilyNotSupported`): with IPv6 the dial is only refused, which never reached the bug,
so on such a host each case says so and is skipped.

1. `nerva api` with its only replica at `[::1]` used to abort on the message bus's assertion in
   `tick_connect`. Now it says the error once, dials again each tick, and exits 1 when its
   registration times out (30 s), as for any cluster it cannot reach.
2. A cluster whose replica 2 is at `[::1]`: replicas 0 and 1 (on 127.0.0.1) dial it and used to
   abort the same way. Now they run on (replica 2 itself cannot listen, and exits), and a
   gateway given all three addresses registers and commits through 0 and 1.
"""
import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

KEY = "addresses-test-key-0123456789abcdef0123456789"


def ipv6_present():
    if not os.path.exists("/proc/net/if_inet6"):
        return False
    try:
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM):
            return True
    except OSError:
        return False


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def said_once(log):
    lines = [line for line in log.splitlines()
             if "error(message_bus)" in line and "init_tcp error=" in line]
    return len(lines) == 1 and "AddressFamilyNotSupported" in lines[0]


def gateway_alone(nerva):
    result = subprocess.run(
        [nerva, "api", "--cluster=0", "--addresses=[::1]:3", "--listen=127.0.0.1:0"],
        capture_output=True, text=True, timeout=120, env={**os.environ, "NERVA_KEY": KEY})
    log = result.stderr
    assert "panic" not in log, log[-3000:]
    assert result.returncode == 1, (result.returncode, log[-3000:])
    assert "error[NRV-E0604]" in log, log[-3000:]
    assert said_once(log), log[-3000:]  # Said once, though retried every tick.


def mixed_cluster(nerva):
    tmp = tempfile.mkdtemp(prefix="nerva-addresses-")
    processes = []
    try:
        addresses = f"127.0.0.1:{free_port()},127.0.0.1:{free_port()},[::1]:{free_port()}"
        logs = []
        for index in range(3):
            path = os.path.join(tmp, f"{index}.nerva")
            subprocess.run([nerva, "format", "--cluster=0", f"--replica={index}",
                            "--replica-count=3", "--development", path],
                           check=True, capture_output=True)
            logs.append(path + ".log")
            processes.append(subprocess.Popen(
                [nerva, "start", f"--addresses={addresses}", "--development", path],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=open(logs[-1], "w")))
        gateway = subprocess.Popen(
            [nerva, "api", "--cluster=0", f"--addresses={addresses}", "--listen=127.0.0.1:0"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env={**os.environ, "NERVA_KEY": KEY}, text=True)
        processes.append(gateway)
        port = int(gateway.stdout.readline())
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        connection.request("POST", "/v1/commit", body=json.dumps({"entries": [
            {"kind": "put", "table": 1, "id": "7", "value_hex": "c0ffee"}]}),
            headers={"X-Nerva-Key": KEY})
        response = connection.getresponse()
        reply = json.loads(response.read())
        connection.close()
        assert response.status == 200 and reply["status"] == "committed", reply
        for index in (0, 1):
            with open(logs[index], errors="replace") as f:
                log = f.read()
            assert processes[index].poll() is None, f"replica {index} exited: {log[-3000:]}"
            assert "panic" not in log, log[-3000:]
            assert said_once(log), (index, log[-3000:])
        assert processes[2].wait(timeout=30) != 0  # It cannot listen on [::1].
    finally:
        for process in processes:
            process.kill()
            process.wait()
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    nerva = sys.argv[1]
    if ipv6_present():
        print("addresses: SKIPPED (this host has IPv6: a socket for [::1] opens, so the "
              "unopened-socket path cannot be reached here)")
        return
    started = time.monotonic()
    gateway_alone(nerva)
    mixed_cluster(nerva)
    print(f"addresses: PASSED (without IPv6: a gateway at [::1] said it once, retried and "
          f"exited 1 on its timeout; replicas dialing a peer at [::1] ran on and a gateway "
          f"committed through them; no panic; {time.monotonic() - started:.0f} s)")


if __name__ == "__main__":
    main()
