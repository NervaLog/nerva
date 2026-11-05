#!/usr/bin/env python3
"""`nerva recover` on a cluster that was imported (docs/briefs/r5.md, P90, P149).

Usage: recover.py <nerva>

A formatted cluster commits a few transactions and is exported; three replicas are imported from
the export (the cluster's origin is the export's SHA-256) and run under a writer that sends keyed
transactions without stopping, past a checkpoint. Then:
- a replica is lost and recovered with `--origin=none`, the wrong origin: it starts, exits with
  status 8 and NRV-E0711 naming the export its peers announce, and the peers log that they ignore
  it and commit on;
- each replica in turn is lost (the primary once) and recovered with the export's SHA-256, and
  catches up: with another backup stopped, commits need it;
- P90's scenario: after the last recovery, the backup that would lead the next view stops while the
  recovered one and the primary commit on; then the primary is killed with SIGKILL, so that the
  recovered replica must be in the view-change quorum.
No acknowledged commit key is lost (each resent answers `replayed` with the op it first committed
at), and nothing panics.
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
import threading
import time

# Replicas authenticate each other with a real cluster key, never the development key (P102).
os.environ["NERVA_CLUSTER_KEY"] = os.urandom(32).hex()

KEY = "recover-origin-test-key"
TABLE = 3
RECOVER_TIMEOUT_SECONDS = 60  # `recover_timeout` in src/nerva/recover.zig.
STATUS_ORIGIN_MISMATCH = 8
EXPORT_COMMITS = 40  # Before the first checkpoint (op 959).
COMMITS_BEFORE_LOSS = 1100  # Past the next checkpoint: the first replacement needs state sync.


def free_ports(count):
    sockets = [socket.socket() for _ in range(count)]
    for s in sockets:
        s.bind(("127.0.0.1", 0))
    ports = [s.getsockname()[1] for s in sockets]
    for s in sockets:
        s.close()
    return ports


def request(port, method, target, body=None, timeout=20):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request(method, target, body=None if body is None else json.dumps(body),
                           headers={"X-Nerva-Key": KEY})
        response = connection.getresponse()
        return response.status, json.loads(response.read() or b"null")
    finally:
        connection.close()


def put_body(id, key):
    return {"key": key, "entries": [{"kind": "put", "table": TABLE, "id": str(id),
                                     "value_hex": f"{id:016x}"}]}


class Writer(threading.Thread):
    """Commits one keyed put after another, resending a put under its key until acknowledged."""

    def __init__(self, port, first_id=1):
        super().__init__(daemon=True)
        self.port = port
        self.first_id = first_id
        self.acked = {}  # id -> (key, op)
        self.delay = 0.0
        self.stopping = False
        self.failure = None

    def run(self):
        try:
            id = self.first_id
            while not self.stopping:
                key = f"{id:032x}"
                while not self.stopping:
                    try:
                        status, reply = request(self.port, "POST", "/v1/commit",
                                                put_body(id, key))
                    except (OSError, http.client.HTTPException):
                        time.sleep(0.2)
                        continue
                    if status == 200:
                        self.acked[id] = (key, int(reply["op"]))
                        id += 1
                        break
                    assert status in (409, 503, 504), (status, reply)
                    assert status != 409 or reply.get("status") != "key_reused", reply
                    time.sleep(0.2)
                time.sleep(self.delay)
        except BaseException as error:  # noqa: BLE001
            self.failure = error

    def wait_for(self, count, seconds=180):
        """Waits until `count` more puts are acknowledged."""
        target = len(self.acked) + count
        deadline = time.monotonic() + seconds
        while len(self.acked) < target:
            assert self.failure is None, self.failure
            assert time.monotonic() < deadline, f"only {len(self.acked)} of {target} commits"
            time.sleep(0.05)

    def finish(self):
        self.stopping = True
        self.join(60)
        assert self.failure is None, self.failure


class Cluster:
    """Three replicas of `nerva`, prepared by `prepare(index, path)`, and one gateway."""

    def __init__(self, tmp, name, nerva, prepare):
        self.tmp, self.name, self.nerva = tmp, name, nerva
        self.ports = free_ports(3)
        self.addresses = ",".join(str(port) for port in self.ports)
        self.replicas = [None] * 3
        self.gateway_process = None
        for index in range(3):
            prepare(index, self.data_file(index))
        for index in range(3):
            self.start(index)
        self.wait_listening(range(3))

    def wait_listening(self, indexes):
        """A replica opens its data file for a while before it accepts connections."""
        deadline = time.monotonic() + 120
        for index in indexes:
            while True:
                assert self.replicas[index].poll() is None, self.log(index)[-3000:]
                try:
                    socket.create_connection(("127.0.0.1", self.ports[index]), timeout=1).close()
                    break
                except OSError:
                    assert time.monotonic() < deadline, self.log(index)[-3000:]
                    time.sleep(0.1)

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

    def kill(self, index):
        self.replicas[index].kill()
        self.replicas[index].wait()
        self.replicas[index] = None
        # The kernel releases a killed process's listening socket a moment after it is reaped
        # (io_uring tears its ring down in a workqueue): wait until nothing accepts.
        deadline = time.monotonic() + 30
        while True:
            try:
                socket.create_connection(("127.0.0.1", self.ports[index]), timeout=1).close()
            except OSError:
                break
            assert time.monotonic() < deadline, f"replica {index} still accepts after SIGKILL"
            time.sleep(0.05)

    def lose(self, index):
        """The replica is gone: killed, and its data file and log destroyed."""
        if self.replicas[index] is not None:
            self.kill(index)
        for suffix in ("", ".log"):
            if os.path.exists(self.data_file(index) + suffix):
                os.remove(self.data_file(index) + suffix)

    def recover(self, index, *flags, path=None, origin="none", replica_count=3):
        return subprocess.run(
            [self.nerva, "recover", "--cluster=0", f"--replica={index}",
             f"--replica-count={replica_count}", f"--addresses={self.addresses}",
             f"--origin={origin}", "--development", *flags, path or self.data_file(index)],
            capture_output=True, text=True, timeout=RECOVER_TIMEOUT_SECONDS + 60)

    def gateway(self):
        log = os.path.join(self.tmp, f"{self.name}_api.log")
        self.gateway_process = subprocess.Popen(
            [self.nerva, "api", "--cluster=0", f"--addresses={self.addresses}",
             "--listen=127.0.0.1:0"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=open(log, "w"), env={**os.environ, "NERVA_KEY": KEY}, text=True)
        line = self.gateway_process.stdout.readline()
        if not line:
            replicas = "\n".join(
                f"replica {index}: " + ("not started" if replica is None else
                                        f"exit status {replica.poll()}") +
                f"\n{self.log(index)[-3000:]}"
                for index, replica in enumerate(self.replicas))
            raise AssertionError(f"the gateway exited: {open(log, errors='replace').read()[-1500:]}"
                                 f"\n{replicas}")
        return int(line)

    def view(self):
        """The latest view any replica logged (view 0 if none changed)."""
        view = 0
        for index in range(3):
            for match in re.finditer(
                    r"transition_to_normal_from_view_change_status: view=\d+\.\.(\d+)",
                    self.log(index)):
                view = max(view, int(match.group(1)))
        return view

    def primary(self):
        return self.view() % 3

    def check_running_others(self, index):
        for other in range(3):
            if other != index:
                assert self.replicas[other].poll() is None, self.log(other)[-3000:]

    def check_no_panic(self):
        for index in range(3):
            assert "panic" not in self.log(index), self.log(index)[-3000:]

    def close(self):
        for process in [self.gateway_process] + self.replicas:
            if process is not None:
                try:
                    process.send_signal(signal.SIGCONT)
                except OSError:
                    pass
                process.kill()
                process.wait()
        self.replicas = [None] * 3
        for index in range(3):  # Data files are large: remove them once done with.
            for suffix in ("", ".log", ".recovering"):
                path = self.data_file(index) + suffix
                if os.path.exists(path):
                    os.remove(path)


def acknowledged_commits_survive(writer, port):
    """Every acknowledged key, resent, answers `replayed` with the op it first committed at."""
    for id, (key, op) in sorted(writer.acked.items()):
        status, reply = request(port, "POST", "/v1/commit", put_body(id, key), timeout=60)
        assert status == 200, (id, status, reply)
        assert reply == {"status": "committed", "op": str(op), "replayed": True}, (id, op, reply)


def run(nerva, args):
    return subprocess.run([nerva] + args, capture_output=True, text=True)


def export_cluster(tmp, nerva):
    """A formatted cluster commits, and is exported; returns (path, sha256)."""
    def format_(index, path):
        subprocess.run([nerva, "format", "--cluster=0", f"--replica={index}",
                        "--replica-count=3", "--development", path], check=True,
                       capture_output=True)

    source = Cluster(tmp, "source", nerva, format_)
    try:
        writer = Writer(source.gateway())
        writer.start()
        writer.wait_for(EXPORT_COMMITS)
        writer.finish()
        assert max(op for _, op in writer.acked.values()) < 900
        path = os.path.join(tmp, "cluster.nerva-export")
        exported = run(nerva, ["export", "--cluster=0", f"--addresses={source.addresses}",
                               f"--output={path}"])
        assert exported.returncode == 0, exported.stderr[-3000:]
        match = re.search(r"export ([0-9a-f]{64})", exported.stderr)
        assert match, exported.stderr[-3000:]
        return path, match.group(1)
    finally:
        source.close()


def recover_imported(tmp, nerva):
    export, origin = export_cluster(tmp, nerva)

    def import_(index, path):
        imported = run(nerva, ["import", "--cluster=0", f"--replica={index}",
                               "--replica-count=3", f"--input={export}", "--development", path])
        assert imported.returncode == 0, imported.stderr[-3000:]
        assert f"export={origin}" in imported.stderr, imported.stderr[-3000:]

    cluster = Cluster(tmp, "imported", nerva, import_)
    writer = None
    synced = 0

    def recover_right(index):
        """Loses `index` and recovers it with the export's origin; returns once it listens."""
        cluster.lose(index)
        result = cluster.recover(index, origin=origin)
        assert result.returncode == 0, result.stderr[-3000:]
        assert f"export {origin}; start it with nerva start" in result.stderr, result.stderr
        cluster.start(index)
        cluster.wait_listening([index])
        writer.wait_for(50)

    def caught_up(victim):
        """With another backup stopped, commits need the recovered replica."""
        primary = cluster.primary()
        other = next(i for i in range(3) if i not in (victim, primary))
        cluster.kill(other)
        writer.wait_for(50, seconds=240)
        cluster.start(other)
        cluster.wait_listening([other])
        writer.wait_for(50)

    try:
        port = cluster.gateway()
        writer = Writer(port, first_id=10_000)
        writer.start()
        writer.wait_for(COMMITS_BEFORE_LOSS)

        # The wrong origin: the recovered replica exits with NRV-E0711; its peers run on.
        primary = cluster.primary()
        first = next(i for i in range(3) if i != primary)
        cluster.lose(first)
        result = cluster.recover(first, origin="none")
        assert result.returncode == 0, result.stderr[-3000:]
        assert "export none (formatted); start it with nerva start" in result.stderr, \
            result.stderr
        cluster.start(first)
        status = cluster.replicas[first].wait(timeout=120)
        assert status == STATUS_ORIGIN_MISMATCH, (status, cluster.log(first)[-3000:])
        cluster.replicas[first] = None
        log = cluster.log(first)
        assert "NRV-E0711" in log and f"announce another" in log, log[-3000:]
        assert f"(replica " in log and f" announces {origin})" in log, log[-3000:]
        writer.wait_for(50)
        cluster.check_running_others(first)
        for index in range(3):
            if index != first:
                assert f"replica {first} was imported from export none (formatted)" in \
                    cluster.log(index), cluster.log(index)[-3000:]

        # Each replica in turn, the primary once, each caught up before the next.
        order = [first, cluster.primary()]
        order.append(next(i for i in range(3) if i not in order))
        for victim in order:
            recover_right(victim)
            caught_up(victim)
            synced += "sync: done" in cluster.log(victim)
        assert synced >= 1, "no recovered replica used state sync"
        last = order[-1]

        # P90: the recovered replica must be in the view-change quorum. The backup that would
        # lead the next view stops (unless that is the recovered one); the primary and the
        # recovered replica commit on; then the primary is killed.
        primary = cluster.primary()
        next_leader = (cluster.view() + 1) % 3
        backup = next_leader if next_leader not in (last, primary) else \
            next(i for i in range(3) if i not in (last, primary))
        cluster.kill(backup)
        writer.wait_for(50, seconds=240)
        cluster.kill(primary)
        cluster.start(backup)
        cluster.wait_listening([backup])
        writer.wait_for(100, seconds=240)
        writer.finish()
        acknowledged_commits_survive(writer, port)
        cluster.check_no_panic()
        return len(writer.acked), synced
    finally:
        if writer is not None:
            writer.stopping = True
        cluster.close()


def main():
    nerva = os.path.abspath(sys.argv[1])
    tmp = tempfile.mkdtemp(prefix="nerva-recover-origin-")
    try:
        started = time.monotonic()
        count, synced = recover_imported(tmp, nerva)
        print(f"recover (imported): the wrong origin exits with status {STATUS_ORIGIN_MISMATCH} "
              f"and NRV-E0711; each replica recovered in turn ({synced} by state sync), and the "
              f"view-change quorum of the last one keeps all {count} acknowledged commits "
              f"({time.monotonic() - started:.0f} s)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("recover: ok")


if __name__ == "__main__":
    main()
