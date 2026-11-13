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
import hashlib
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

# Replicas authenticate each other with a real cluster key, never the development key (P102).
os.environ["NERVA_CLUSTER_KEY"] = os.urandom(32).hex()

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
    def __init__(self, binaries, gateway_binary=None):
        self.binaries = binaries
        self.gateway_binary = gateway_binary or binaries[0]
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

    def wait_listening(self):
        """Waits until each running replica accepts connections on its port. A replica takes a
        while to open its data file before it listens, and a gateway gives up on a port that is
        not open yet (#155)."""
        deadline = time.monotonic() + 120
        ports = [int(port) for port in self.addresses.split(",")]
        for index, replica in enumerate(self.replicas):
            if replica is None:
                continue
            while True:
                assert replica.poll() is None, self.log(index)[-3000:]
                try:
                    socket.create_connection(("127.0.0.1", ports[index]), timeout=1).close()
                    break
                except OSError:
                    assert time.monotonic() < deadline, self.log(index)[-3000:]
                    time.sleep(0.1)

    def gateway(self):
        """A `nerva api` of the first release; returns its port once it has registered."""
        self.wait_listening()
        process = subprocess.Popen(
            [self.gateway_binary, "api", "--cluster=0", f"--addresses={self.addresses}",
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


def refuses_other_release(nerva, cluster):
    """#95: `nerva start` on a data file of another release is refused with NRV-E0701, and the
    file is not touched (it used to panic with `multiversion unsupported`)."""
    cluster.stop(2)
    copy = os.path.join(cluster.tmp, "other-release.nerva")
    shutil.copy(cluster.data_file(2), copy)

    def digest():
        with open(copy, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()

    before = digest()
    result = subprocess.run(
        [nerva, "start", f"--addresses={cluster.addresses}", "--development", copy],
        capture_output=True, text=True, timeout=60)
    first = result.stderr.splitlines()[0] if result.stderr else ""
    assert result.returncode == 1, (result.returncode, result.stderr[-2000:])
    assert first.startswith("error[NRV-E0701]: start: "), result.stderr[-2000:]
    assert "release 0.0.200" in first, first
    assert "panic" not in result.stderr and "multiversion" not in result.stderr, result.stderr
    assert digest() == before, "the data file changed"


def restarts_beside_other_primary(nerva, nerva_other):
    """#358: replica 0 (the first view's primary) runs the other release, replicas 1 and 2 run
    `nerva`. A replica that restarts beside it hears the primary's prepares before its first ping
    and pong; it must not handle them (a prepare received from its maker counts only once that
    connection has announced the release). Replicas 1 and 2 form the cluster without the primary;
    each restart round must leave it committing, with no panic or divergence on any replica."""
    cluster = Cluster([nerva_other, nerva, nerva], gateway_binary=nerva)
    try:
        port = cluster.gateway()
        assert commit(port, 5000, timeout=90) == 200
        for round in range(3):
            victim = 1 + round % 2
            cluster.stop(victim)
            cluster.start(victim)
            cluster.wait_listening()
            port = cluster.gateway()
            status = commit(port, 5100 + round, timeout=90)
            assert status == 200, f"round {round}: commit answered {status}"
            for index, replica in enumerate(cluster.replicas):
                assert replica.poll() is None, f"replica {index} exited: " \
                    f"{cluster.log(index)[-2000:]}"
                log = cluster.log(index)
                assert "panic" not in log and "checkpoint diverged" not in log, log[-2000:]
        print("mixed releases: PASSED (replicas restarting beside an other-release primary)")
    finally:
        cluster.close()


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
        refuses_other_release(nerva, cluster)
        print(f"mixed releases: PASSED (replica 2 on another release ignored; {CHECKPOINT_OPS} "
              f"commits past the first checkpoint in {time.monotonic() - started:.0f} s)")
    finally:
        cluster.close()
    restarts_beside_other_primary(nerva, nerva_other)


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.default_int_handler)
    main()
