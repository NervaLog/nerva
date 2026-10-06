#!/usr/bin/env python3
"""Replicas and `nerva api` over IPv6 loopback, `--listen=[::1]:0` included.

Usage: ipv6.py <nerva>

Three replicas on `[::1]` and a gateway listening on `[::1]`: a put commits and reads back
through HTTP over IPv6. Fly's private network is IPv6 only, so this is how a cluster there
runs. On a host without IPv6 (no `/proc/net/if_inet6`, or `[::1]` cannot be bound) the test
says why and passes without running.
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

KEY = "ipv6-test-key"


def ipv6_missing():
    """Why IPv6 cannot be tested here, or None."""
    if not os.path.exists("/proc/net/if_inet6"):
        return "no /proc/net/if_inet6"
    try:
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as s:
            s.bind(("::1", 0))
    except OSError as error:
        return f"[::1] cannot be bound: {error}"
    return None


def free_ports(count):
    sockets = [socket.socket(socket.AF_INET6) for _ in range(count)]
    for s in sockets:
        s.bind(("::1", 0))
    ports = [s.getsockname()[1] for s in sockets]
    for s in sockets:
        s.close()
    return ports


def request(port, method, target, body=None):
    connection = http.client.HTTPConnection("::1", port, timeout=60)
    try:
        connection.request(method, target, body=None if body is None else json.dumps(body),
                           headers={"X-Nerva-Key": KEY})
        response = connection.getresponse()
        return response.status, json.loads(response.read() or b"null")
    finally:
        connection.close()


def main():
    nerva = sys.argv[1]
    missing = ipv6_missing()
    if missing:
        print(f"ipv6: SKIPPED (no IPv6 on this host: {missing})")
        return
    started = time.monotonic()
    tmp = tempfile.mkdtemp(prefix="nerva-ipv6-")
    processes = []
    try:
        addresses = ",".join(f"[::1]:{port}" for port in free_ports(3))
        for index in range(3):
            path = os.path.join(tmp, f"{index}.nerva")
            subprocess.run([nerva, "format", "--cluster=0", f"--replica={index}",
                            "--replica-count=3", "--development", path],
                           check=True, capture_output=True)
            processes.append(subprocess.Popen(
                [nerva, "start", f"--addresses={addresses}", "--development", path],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                stderr=open(path + ".log", "w")))
        gateway = subprocess.Popen(
            [nerva, "api", "--cluster=0", f"--addresses={addresses}", "--listen=[::1]:0"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env={**os.environ, "NERVA_KEY": KEY}, text=True)
        processes.append(gateway)
        port = int(gateway.stdout.readline())

        status, reply = request(port, "POST", "/v1/commit", {"entries": [
            {"kind": "put", "table": 1, "id": "7", "value_hex": "c0ffee"}]})
        assert status == 200 and reply["status"] == "committed", (status, reply)
        op = reply["op"]
        status, reply = request(port, "POST", "/v1/lookup", {"rows": [{"table": 1, "id": "7"}]})
        assert status == 200, (status, reply)
        row = reply["rows"][0]
        assert row["exists"] and row["op"] == op and row["value_hex"].startswith("c0ffee"), row
        for index, process in enumerate(processes[:3]):
            assert process.poll() is None, f"replica {index} exited"
        print(f"ipv6: PASSED (three replicas and a gateway on [::1]; a put committed at op {op} "
              f"and read back; {time.monotonic() - started:.0f} s)")
    finally:
        for process in processes:
            process.kill()
            process.wait()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
