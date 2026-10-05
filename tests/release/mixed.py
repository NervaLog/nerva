#!/usr/bin/env python3
"""Replicas of two releases do not form one cluster (docs/DECISIONS.md N61, #34).

Usage: mixed.py <nerva> <nerva of another release>

Replicas 0 and 1 run `nerva`, replica 2 runs the other release, each formatted by its own binary.
Before N61 replica 2 joined the cluster, counted toward quorums while it executed the log with
other code, and panicked with "checkpoint diverged" at the first checkpoint. Now:
- both sides log that they ignore the other's release;
- the cluster commits on replicas 0 and 1;
- with replica 1 stopped nothing commits, since replica 2 does not count;
- replica 1 back, it commits again, past the first checkpoint, and replica 2 never panics.
"""
import http.client
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

KEY = "release-test-key"
CHECKPOINT_OPS = 1000  # Past the first checkpoint (op 960 in the production config).


def free_ports(count):
    sockets = [socket.socket() for _ in range(count)]
    for s in sockets:
        s.bind(("127.0.0.1", 0))
    ports = [s.getsockname()[1] for s in sockets]
    for s in sockets:
        s.close()
    return ports


def commit(port, id, timeout=60):
    """The status of one commit, or None if no reply came within `timeout`."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    body = json.dumps({"entries": [{"kind": "put", "table": 1, "id": str(id), "value_hex": "01"}]})
    try:
        connection.request("POST", "/v1/commit", body=body, headers={"X-Nerva-Key": KEY})
        response = connection.getresponse()
        response.read()
        return response.status
    except (TimeoutError, socket.timeout):
        return None
    finally:
        connection.close()


class Cluster:
    def __init__(self, binaries):
        self.binaries = binaries
        self.tmp = tempfile.mkdtemp(prefix="nerva-release-")
        self.addresses = ",".join(str(port) for port in free_ports(len(binaries)))
        self.replicas = [None] * len(binaries)
        self.gateways = []
        for index, nerva in enumerate(binaries):
            subprocess.run([nerva, "format", "--cluster=0", f"--replica={index}",
                            f"--replica-count={len(binaries)}", "--development",
                            self.data_file(index)], check=True, capture_output=True)
        for index in range(len(binaries)):
            self.start(index)

    def data_file(self, index):
        return os.path.join(self.tmp, f"{index}.nerva")

    def log(self, index):
        with open(os.path.join(self.tmp, f"{index}.log"), errors="replace") as f:
            return f.read()

    def start(self, index):
        assert self.replicas[index] is None
        self.replicas[index] = subprocess.Popen(
            [self.binaries[index], "start", f"--addresses={self.addresses}", "--development",
             self.data_file(index)],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=open(os.path.join(self.tmp, f"{index}.log"), "a"))

    def stop(self, index):
        self.replicas[index].kill()
        self.replicas[index].wait()
        self.replicas[index] = None

    def gateway(self):
        """A `nerva api` of the first release; returns its port once it has registered."""
        process = subprocess.Popen(
            [self.binaries[0], "api", "--cluster=0", f"--addresses={self.addresses}",
             "--listen=127.0.0.1:0"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, env={**os.environ, "NERVA_KEY": KEY}, text=True)
        self.gateways.append(process)
        return int(process.stdout.readline())

    def close(self):
        for process in self.gateways + [r for r in self.replicas if r is not None]:
            process.kill()
            process.wait()
        shutil.rmtree(self.tmp, ignore_errors=True)


def wait_for(condition, seconds, what):
    deadline = time.monotonic() + seconds
    while not condition():
        assert time.monotonic() < deadline, f"timed out waiting for {what}"
        time.sleep(0.1)


def main():
    nerva, nerva_other = sys.argv[1], sys.argv[2]
    cluster = Cluster([nerva, nerva, nerva_other])
    try:
        port = cluster.gateway()
        statuses = [commit(port, i) for i in range(20)]
        assert statuses == [200] * 20, statuses

        # Each side says it ignores the other.
        wait_for(lambda: "replica 2 runs release 0.0.200" in cluster.log(0), 10, "replica 0's log")
        wait_for(lambda: "replica 0 runs release " in cluster.log(2) and
                 "replica 1 runs release " in cluster.log(2), 10, "replica 2's log")

        # Replica 2 does not count toward a quorum: without replica 1, nothing commits.
        cluster.stop(1)
        status = commit(port, 100, timeout=10)
        assert status is None, f"a commit answered {status} without replica 1"
        assert cluster.replicas[2].poll() is None, "replica 2 exited"

        # Replica 1 back: the cluster commits again, past the first checkpoint, and replica 2 runs.
        cluster.start(1)
        port = cluster.gateway()
        started = time.monotonic()
        statuses = {}
        for i in range(CHECKPOINT_OPS):
            status = commit(port, 1000 + i)
            statuses[status] = statuses.get(status, 0) + 1
        assert statuses == {200: CHECKPOINT_OPS}, statuses
        time.sleep(2)
        for index, replica in enumerate(cluster.replicas):
            assert replica.poll() is None, f"replica {index} exited: {cluster.log(index)[-2000:]}"
            assert "panic" not in cluster.log(index), cluster.log(index)[-2000:]
        print(f"mixed releases: PASSED (replica 2 on another release ignored; {CHECKPOINT_OPS} "
              f"commits past the first checkpoint in {time.monotonic() - started:.0f} s)")
    finally:
        cluster.close()


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.default_int_handler)
    main()
