#!/usr/bin/env python3
"""Replicas imported from different exports refuse each other (docs/DECISIONS.md N84, #81).

Usage: origins.py <nerva> <nerva of release_client_min>

A cluster formatted by `nerva` commits a few transactions between three exports (A, B, C), all
before the first checkpoint, so that an import of each reaches the same checkpoint: before N84,
replicas imported from two of them met at that checkpoint and the odd one panicked in the
journal (#81). Now each data file records its export, and:
- replicas 1 and 2 from A, replica 0 (the first view's primary) from B: replica 0 exits with
  status 8 (`origin_mismatch`), naming both exports; replicas 1 and 2 ignore it and commit;
- each replica from another export: at least two exit with status 8 (the last may have heard
  neither before they stopped, and stays up alone);
- replicas 0 and 1 from A commit past a checkpoint, then replica 2 is imported from A and
  started: it joins, and counts toward the quorum once replica 1 stops;
- a `nerva api` of `release_client_min` (the second binary) commits and reads against them.
Nothing panics.
"""
import http.client
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

KEY = "origins-test-key"
TABLE = 3
EXPORT_COMMITS = 40  # Between exports: all three stay before the first checkpoint (op 959).
CHECKPOINT_COMMITS = 1100  # Past the next checkpoint.
STATUS_ORIGIN_MISMATCH = 8


def free_ports(count):
    sockets = [socket.socket() for _ in range(count)]
    for s in sockets:
        s.bind(("127.0.0.1", 0))
    ports = [s.getsockname()[1] for s in sockets]
    for s in sockets:
        s.close()
    return ports


def request(port, method, target, body=None, timeout=60):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request(method, target, body=None if body is None else json.dumps(body),
                           headers={"X-Nerva-Key": KEY})
        response = connection.getresponse()
        return response.status, json.loads(response.read() or b"null")
    finally:
        connection.close()


def put(port, id, deadline_seconds=180):
    """Commits one put, retrying while the cluster has no quorum; returns its op."""
    body = {"entries": [{"kind": "put", "table": TABLE, "id": str(id),
                         "value_hex": f"{id:016x}"}]}
    deadline = time.monotonic() + deadline_seconds
    while True:
        try:
            status, reply = request(port, "POST", "/v1/commit", body)
            if status == 200:
                return int(reply["op"])
            assert status == 503, (status, reply)
        except (TimeoutError, ConnectionError, http.client.HTTPException):
            pass
        assert time.monotonic() < deadline, f"put {id} never committed"
        time.sleep(0.2)


def run(nerva, args):
    return subprocess.run([nerva] + args, capture_output=True, text=True)


class Cluster:
    """Three replicas of `nerva`; `prepare(index, path)` creates replica `index`'s data file."""

    def __init__(self, tmp, name, nerva, prepare, start=(0, 1, 2)):
        self.tmp, self.name, self.nerva, self.prepare = tmp, name, nerva, prepare
        self.addresses = ",".join(str(port) for port in free_ports(3))
        self.replicas = [None] * 3
        self.gateways = []
        for index in start:
            prepare(index, self.data_file(index))
        for index in start:
            self.start(index)

    def data_file(self, index):
        return os.path.join(self.tmp, f"{self.name}_{index}.nerva")

    def log(self, index):
        path = self.data_file(index) + ".log"
        if not os.path.exists(path):
            return ""
        with open(path, errors="replace") as f:
            return f.read()

    def start(self, index):
        assert self.replicas[index] is None
        self.replicas[index] = subprocess.Popen(
            [self.nerva, "start", f"--addresses={self.addresses}", "--development",
             self.data_file(index)],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=open(self.data_file(index) + ".log", "a"))

    def stop(self, index):
        self.replicas[index].kill()
        self.replicas[index].wait()
        self.replicas[index] = None

    def exit_status(self, index, timeout=60):
        try:
            return self.replicas[index].wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise AssertionError(f"replica {index} did not exit: {self.log(index)[-3000:]}")

    def gateway(self, nerva=None):
        process = subprocess.Popen(
            [nerva or self.nerva, "api", "--cluster=0", f"--addresses={self.addresses}",
             "--listen=127.0.0.1:0"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, env={**os.environ, "NERVA_KEY": KEY}, text=True)
        self.gateways.append(process)
        return int(process.stdout.readline())

    def check_running(self, indexes):
        for index in indexes:
            replica = self.replicas[index]
            assert replica is not None and replica.poll() is None, \
                f"replica {index} exited: {self.log(index)[-3000:]}"
        self.check_no_panic()

    def check_no_panic(self):
        for index in range(3):
            assert "panic" not in self.log(index), self.log(index)[-3000:]

    def close(self):
        for process in self.gateways + [r for r in self.replicas if r is not None]:
            process.kill()
            process.wait()
        self.gateways = []
        self.replicas = [None] * 3
        for index in range(3):  # Data files are large: remove them once done with.
            for path in (self.data_file(index), self.data_file(index) + ".log"):
                if os.path.exists(path):
                    os.remove(path)


def main():
    nerva, nerva_client = sys.argv[1], sys.argv[2]
    tmp = tempfile.mkdtemp(prefix="nerva-origins-")
    clusters = []
    try:
        started = time.monotonic()

        def format_(index, path):
            subprocess.run([nerva, "format", "--cluster=0", f"--replica={index}",
                            "--replica-count=3", "--development", path], check=True,
                           capture_output=True)

        source = Cluster(tmp, "source", nerva, format_)
        clusters.append(source)
        port = source.gateway()
        exports, names = [], []
        next_id = 1
        for name in "abc":
            for _ in range(EXPORT_COMMITS):
                op = put(port, next_id)
                next_id += 1
            assert op < 900, f"op {op}: the exports must reach the same checkpoint"
            path = os.path.join(tmp, f"{name}.nerva-export")
            exported = run(nerva, ["export", "--cluster=0", f"--addresses={source.addresses}",
                                   f"--output={path}"])
            assert exported.returncode == 0, exported.stderr[-3000:]
            match = re.search(r"export ([0-9a-f]{64})", exported.stderr)
            assert match, exported.stderr[-3000:]
            exports.append(path)
            names.append(match.group(1))
        assert len(set(names)) == 3, names
        source.close()
        clusters.remove(source)

        def importer(choose):
            def import_(index, path):
                imported = run(nerva, ["import", "--cluster=0", f"--replica={index}",
                                       "--replica-count=3", f"--input={exports[choose(index)]}",
                                       "--development", path])
                assert imported.returncode == 0, imported.stderr[-3000:]
                assert f"export={names[choose(index)]}" in imported.stderr, \
                    imported.stderr[-3000:]
            return import_

        # 1. #81: replica 0 (view 0's primary) from B, replicas 1 and 2 from A.
        split = Cluster(tmp, "split", nerva, importer(lambda index: 1 if index == 0 else 0))
        clusters.append(split)
        status = split.exit_status(0)
        assert status == STATUS_ORIGIN_MISMATCH, (status, split.log(0)[-3000:])
        log = split.log(0)
        assert f"imported from export {names[1]}" in log, log[-3000:]
        assert "import this one again" in log, log[-3000:]
        assert f"data file from export {names[1]}" in log, log[-3000:]
        split.replicas[0] = None
        port = split.gateway()
        for _ in range(20):
            put(port, next_id)
            next_id += 1
        split.check_running([1, 2])
        for index in (1, 2):
            assert f"replica 0 was imported from export {names[1]}" in split.log(index), \
                split.log(index)[-3000:]
        split.close()
        clusters.remove(split)

        # 2. Three exports: no replica can reach a quorum. A replica stops once it has heard two
        # peers of other exports, before it answers the second; so the last may have heard
        # neither before they stopped, and then stays up alone, committing nothing.
        apart = Cluster(tmp, "apart", nerva, importer(lambda index: index))
        clusters.append(apart)
        deadline = time.monotonic() + 60
        while sum(r.poll() is not None for r in apart.replicas) < 2:
            assert time.monotonic() < deadline, [apart.log(i)[-2000:] for i in range(3)]
            time.sleep(0.2)
        time.sleep(5)
        exited = 0
        for index, replica in enumerate(apart.replicas):
            status = replica.poll()
            if status is not None:
                assert status == STATUS_ORIGIN_MISMATCH, (index, status, apart.log(index)[-3000:])
                exited += 1
        assert exited >= 2
        apart.check_no_panic()
        apart.close()
        clusters.remove(apart)

        # 3. A replica imported later from the same export joins and counts toward the quorum.
        late = Cluster(tmp, "late", nerva, importer(lambda index: 0), start=(0, 1))
        clusters.append(late)
        port = late.gateway()
        for _ in range(CHECKPOINT_COMMITS):
            put(port, next_id)
            next_id += 1
        late.prepare(2, late.data_file(2))
        late.start(2)
        for _ in range(100):
            put(port, next_id)
            next_id += 1
        late.stop(1)  # Now nothing commits unless replica 2 counts.
        for _ in range(50):
            put(port, next_id)
            next_id += 1
        late.check_running([0, 2])

        # 4. A client of release_client_min commits and reads.
        port = late.gateway(nerva_client)
        op = put(port, next_id)
        status, reply = request(port, "POST", "/v1/lookup",
                                {"rows": [{"table": TABLE, "id": str(next_id)}]})
        assert status == 200 and reply["rows"][0]["exists"], (status, reply)
        assert int(reply["rows"][0]["op"]) == op, reply
        late.check_running([0, 2])
        late.close()
        clusters.remove(late)

        print(f"origins: PASSED (replicas of another export exit with status "
              f"{STATUS_ORIGIN_MISMATCH} and the rest commit on; of three exports, {exited} "
              f"exit; a "
              f"replica imported later from the same export joins past a checkpoint; a client of "
              f"release_client_min commits; {time.monotonic() - started:.0f} s)")
    finally:
        for cluster in clusters:
            cluster.close()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.default_int_handler)
    main()
