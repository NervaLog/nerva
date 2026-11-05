#!/usr/bin/env python3
"""`nerva recover` replaces a lost replica of a running cluster (docs/briefs/r5.md, P149).

Usage: recover.py <nerva> [repair|sync|refusals]...   (default: all three, in that order)

Three real replicas with a real cluster key, and a writer that sends keyed transactions without
stopping. Two recoveries, each followed by the failures the cluster must survive:
- repair: replica 2 is lost (killed, its data file destroyed) within the first checkpoint, and
  recovered; it catches up from the log;
- state sync: replica 2 is lost after 1,100 commits, past the first checkpoint, and recovered; its
  log shows `sync: done`.
After each: the other backup stops, so the commits need the recovered replica; then the primary
is killed with SIGKILL. No acknowledged commit key is lost: each key resent answers `replayed`
with the op it first committed at.

And each refusal, in the brief's format `error[NRV-E…]`, exit status 1, no data file written: the
replica still running (E0713), two replicas down (E0712, at once), a cluster of one (E0714), a
path that exists (E0005), a `.recovering` left (E0715), and the cluster not answering (E0712,
after `recover_timeout`). A recover killed with SIGKILL leaves only `<path>.recovering`.
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

KEY = "recover-test-key"
TABLE = 3
RECOVER_TIMEOUT_SECONDS = 60  # `recover_timeout` in src/nerva/recover.zig.


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

    def __init__(self, port):
        super().__init__(daemon=True)
        self.port = port
        self.acked = {}  # id -> (key, op)
        self.delay = 0.0
        self.stopping = False
        self.failure = None

    def run(self):
        try:
            id = 1
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
    """Three replicas of `nerva`, formatted, and one gateway."""

    def __init__(self, tmp, name, nerva):
        self.tmp, self.name, self.nerva = tmp, name, nerva
        self.ports = free_ports(3)
        self.addresses = ",".join(str(port) for port in self.ports)
        self.replicas = [None] * 3
        self.gateway_process = None
        for index in range(3):
            subprocess.run([nerva, "format", "--cluster=0", f"--replica={index}",
                            "--replica-count=3", "--development", self.data_file(index)],
                           check=True, capture_output=True)
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

    def lose(self, index):
        """The replica is gone: killed, and its data file destroyed."""
        self.kill(index)
        os.remove(self.data_file(index))

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
        assert line, f"the gateway exited: {open(log, errors='replace').read()[-3000:]}"
        return int(line)

    def primary(self):
        """The primary of the latest view any replica logged (view 0 if none changed)."""
        view = 0
        for index in range(3):
            for match in re.finditer(
                    r"transition_to_normal_from_view_change_status: view=\d+\.\.(\d+)",
                    self.log(index)):
                view = max(view, int(match.group(1)))
        return view % 3

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


def check_refusal(result, code, started=None, limit=None):
    """A refusal is one coded line, its cause and its fix; exit status 1; no raw error name."""
    assert result.returncode == 1, (result.returncode, result.stderr[-2000:])
    lines = result.stderr.strip().splitlines()
    # Log lines (timestamped, from the message bus and the IO layer) may come first; the
    # diagnostic is the last three lines.
    assert all(re.match(r"\d{4}-\d\d-\d\d", line) for line in lines[:-3]), result.stderr
    lines = lines[-3:]
    assert lines[0].startswith(f"error[NRV-{code}]: "), result.stderr
    assert lines[1].startswith("  cause  ") and lines[2].startswith("  fix    "), result.stderr
    assert "error." not in "".join(lines) and "panic" not in result.stderr, result.stderr
    if limit is not None:
        assert time.monotonic() - started < limit, f"took {time.monotonic() - started:.1f} s"


def check_nothing_written(path):
    assert not os.path.exists(path), path
    assert not os.path.exists(path + ".recovering"), path + ".recovering"


def acknowledged_commits_survive(writer, port):
    """Every acknowledged key, resent, answers `replayed` with the op it first committed at."""
    for id, (key, op) in sorted(writer.acked.items()):
        status, reply = request(port, "POST", "/v1/commit", put_body(id, key), timeout=60)
        assert status == 200, (id, status, reply)
        assert reply == {"status": "committed", "op": str(op), "replayed": True,
                         "code": "NRV-W0201"}, (id, op, reply)


def recovery(tmp, nerva, name, commits_before, sync):
    """Loses replica 2 after `commits_before` commits, recovers it and kills the primary."""
    cluster = Cluster(tmp, name, nerva)
    writer = None
    try:
        port = cluster.gateway()
        writer = Writer(port)
        writer.start()
        writer.wait_for(commits_before)
        assert max(op for _, op in writer.acked.values()) > 959 if sync else \
            max(op for _, op in writer.acked.values()) < 700

        # The refusals that need a running cluster come first, while all three are up.
        started = time.monotonic()
        running = cluster.recover(2, path=os.path.join(tmp, f"{name}_running.nerva"))
        check_refusal(running, "E0713", started, limit=10)
        assert "replica 2 still answers at 127.0.0.1:" in running.stderr, running.stderr
        check_nothing_written(os.path.join(tmp, f"{name}_running.nerva"))

        cluster.lose(2)
        writer.delay = 0.02  # Slow enough that the repair run stays inside the checkpoint.
        before = len(writer.acked)
        result = cluster.recover(2)
        assert result.returncode == 0, result.stderr[-3000:]
        assert re.search(r"recover: replica 2 of cluster 0 formatted at view (\d+) \(the cluster "
                         r"was at view (\d+)\), export none \(formatted\); start it with "
                         r"nerva start", result.stderr), result.stderr
        view, view_was = re.search(r"at view (\d+) \(the cluster was at view (\d+)\)",
                                   result.stderr).groups()
        assert int(view) == int(view_was) + 2, result.stderr
        assert "must never start again" in result.stderr, result.stderr
        assert os.path.exists(cluster.data_file(2))
        assert not os.path.exists(cluster.data_file(2) + ".recovering")
        assert len(writer.acked) > before, "the writer stopped while recover ran"
        if not sync:
            assert max(op for _, op in writer.acked.values()) < 959, "past the checkpoint"

        cluster.start(2)
        cluster.wait_listening([2])
        writer.delay = 0.005
        writer.wait_for(50)

        # Catch-up: with the other backup gone, commits need the recovered replica.
        primary = cluster.primary()
        other = next(i for i in (0, 1) if i != primary) if primary != 2 else 1
        assert other != 2
        cluster.kill(other)
        writer.wait_for(50, seconds=240)
        cluster.start(other)
        writer.wait_for(50)

        # Now the primary is killed: the recovered replica and the other backup carry on.
        primary = cluster.primary()
        cluster.kill(primary)
        writer.wait_for(50, seconds=240)
        writer.finish()
        acknowledged_commits_survive(writer, port)

        if sync:
            assert "sync: done" in cluster.log(2), cluster.log(2)[-4000:]
        else:
            assert "sync: done" not in cluster.log(2), cluster.log(2)[-4000:]
        cluster.check_no_panic()
        return len(writer.acked)
    finally:
        if writer is not None:
            writer.stopping = True
        cluster.close()


def refusals(tmp, nerva):
    cluster = Cluster(tmp, "refuse", nerva)
    try:
        # A cluster of one or two (E0714), before any connection.
        started = time.monotonic()
        small = subprocess.run(
            [nerva, "recover", "--cluster=0", "--replica=1", "--replica-count=2",
             f"--addresses={cluster.ports[0]},{cluster.ports[1]}", "--origin=none",
             "--development", os.path.join(tmp, "small.nerva")],
            capture_output=True, text=True)
        check_refusal(small, "E0714", started, limit=5)
        check_nothing_written(os.path.join(tmp, "small.nerva"))

        # A path that exists (E0005), and an earlier recover's leftover (E0715): both before any
        # connection, so with all three replicas still running.
        exists = cluster.data_file(0)
        started = time.monotonic()
        check_refusal(cluster.recover(0, path=exists), "E0005", started, limit=5)
        left = os.path.join(tmp, "left.nerva")
        with open(left + ".recovering", "wb") as f:
            f.write(b"left")
        started = time.monotonic()
        check_refusal(cluster.recover(2, path=left), "E0715", started, limit=5)
        assert not os.path.exists(left)
        with open(left + ".recovering", "rb") as f:
            assert f.read() == b"left"  # Never touched.
        os.remove(left + ".recovering")

        # Two replicas down: the one to replace and another. Refused at once, not after the
        # timeout.
        cluster.lose(2)
        cluster.kill(1)
        started = time.monotonic()
        two_down = cluster.recover(2)
        check_refusal(two_down, "E0712", started, limit=10)
        assert "only 1 of the other 2 replicas answer" in two_down.stderr, two_down.stderr
        check_nothing_written(cluster.data_file(2))
        cluster.start(1)
        cluster.wait_listening([1])

        # Stopped (SIGSTOP) replicas still accept connections, so the probe passes and recover
        # waits. Killed with SIGKILL mid-way, it leaves only `<path>.recovering`.
        for index in (0, 1):
            cluster.replicas[index].send_signal(signal.SIGSTOP)
        path = cluster.data_file(2)
        process = subprocess.Popen(
            [nerva, "recover", "--cluster=0", "--replica=2", "--replica-count=3",
             f"--addresses={cluster.addresses}", "--origin=none", "--development", path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 30
        while not os.path.exists(path + ".recovering"):
            assert process.poll() is None, process.communicate()
            assert time.monotonic() < deadline, "recover never started"
            time.sleep(0.05)
        time.sleep(1)
        process.kill()
        process.communicate()
        assert not os.path.exists(path), "a killed recover left a data file"
        assert os.path.exists(path + ".recovering")
        started = time.monotonic()
        check_refusal(cluster.recover(2), "E0715", started, limit=5)
        os.remove(path + ".recovering")

        # The cluster never answers: E0712 after `recover_timeout`, and nothing is left.
        started = time.monotonic()
        silent = cluster.recover(2)
        elapsed = time.monotonic() - started
        check_refusal(silent, "E0712")
        assert RECOVER_TIMEOUT_SECONDS - 1 <= elapsed < RECOVER_TIMEOUT_SECONDS + 30, elapsed
        assert f"within {RECOVER_TIMEOUT_SECONDS} seconds" in silent.stderr, silent.stderr
        check_nothing_written(path)
        for index in (0, 1):
            cluster.replicas[index].send_signal(signal.SIGCONT)
        cluster.check_no_panic()
    finally:
        cluster.close()


def main():
    nerva = os.path.abspath(sys.argv[1])
    parts = sys.argv[2:] or ["repair", "sync", "refusals"]
    tmp = tempfile.mkdtemp(prefix="nerva-recover-")
    try:
        for part in parts:
            started = time.monotonic()
            if part == "repair":
                count = recovery(tmp, nerva, "repair", commits_before=40, sync=False)
                what = f"replica 2 recovered inside the first checkpoint; {count} commits " \
                    "acknowledged and kept"
            elif part == "sync":
                count = recovery(tmp, nerva, "sync", commits_before=1100, sync=True)
                what = f"replica 2 recovered past the first checkpoint; {count} commits " \
                    "acknowledged and kept"
            else:
                assert part == "refusals", part
                refusals(tmp, nerva)
                what = "E0714 E0005 E0715 E0712 (twice) and E0713, each one coded line"
            print(f"{part}: {what} ({time.monotonic() - started:.0f} s)", flush=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("recover: ok")


if __name__ == "__main__":
    main()
