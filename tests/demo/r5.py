#!/usr/bin/env python3
"""The R5 demo: recover, backup, restore (docs/briefs/r5.md, "The demo: `zig build demo-r5`").

Usage: r5.py <nerva>

Three replicas on loopback with a real cluster key, each sending its metrics (`--statsd`) to this
script's UDP socket, one `nerva api` and one `nerva view`. A writer sends keyed transactions
(a seat put and two ledger pairs each) without a pause from step 1 to step 8. Twelve steps, each
asserting; one line per step; the last line is `demo-r5: PASS` or `demo-r5: FAIL step N: ...`.

 1  format and start three replicas, declare layouts, a ledger and two views, start the writer
 2  commit past op 1,100, past the first checkpoint
 3  SIGKILL replica 2 and delete its data file
 4  `nerva recover` for replica 1, which still answers: NRV-E0713, nothing written
 5  `nerva recover` for replica 2: one `recover:` line, `0_2.nerva` exists, no `.recovering`
 6  start replica 2: `sync: done` in its log and its `replica_commit_min` gauge reaches the others'
 7  restart replicas 0 and 1 in turn until the `replica_view` gauge says replica 2 is primary
 8  stop the writer; every view, the ledger total and every acknowledged key read back
 9  `nerva backup`: the manifest equals step 8's view hashes and ledger total
 10 `nerva restore` into a one-replica drill cluster (cluster 1) while cluster 0 runs
 11 stop cluster 0, delete its data files, `nerva restore` each replica, start them, compare
 12 `nerva restore` from a backup with one byte changed: NRV-E0809 (or E0804), no data file

A failure is a finding, never re-run until it passes (CLAUDE.md).
"""
import hashlib
import http.client
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback

# Replicas authenticate each other with a real cluster key, never the development key (P102).
os.environ["NERVA_CLUSTER_KEY"] = os.urandom(32).hex()

KEY = "demo-r5-key"
SEATS, ACCOUNTS, SOURCES = 5, 40, 41
SEATS_LAYOUT = {"name": "seats", "fields": [{"name": "section", "type": "u8"},
                                            {"name": "price", "type": "u64"},
                                            {"name": "sold", "type": "bool"}]}
ACCOUNTS_LAYOUT = {"name": "accounts", "fields": [{"name": "available", "type": "i64"},
                                                  {"name": "held", "type": "i64"}]}
SOURCES_LAYOUT = {"name": "sources", "fields": [{"name": "balance", "type": "i64"}]}
VIEWS = {
    "revenue": {"table": SEATS, "where": [{"field": "sold", "op": "eq", "value": True}],
                "group_by": ["section"],
                "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"}]},
    "extremes": {"table": SEATS, "group_by": ["section"],
                 "aggregates": [{"fn": "count"}, {"fn": "min", "field": "price"},
                                {"fn": "max", "field": "price"}]},
}
SLOTS = {"revenue": ["sum_price"], "extremes": ["min_price", "max_price"]}
LEDGER = {"fields": [{"table": ACCOUNTS, "field": "available", "floor": "0"},
                     {"table": ACCOUNTS, "field": "held", "floor": "0"},
                     {"table": SOURCES, "field": "balance", "floor": None}]}
DRILL_CLUSTER = 1
PAST_CHECKPOINT = 1100  # Past the first checkpoint, op 959.
SYNC_SECONDS = 180
RESTARTS_MAX = 6
RECOVER_TIMEOUT_SECONDS = 60  # `recover_timeout` in src/nerva/recover.zig.

step_number = 0


def say(text, started=None):
    suffix = "" if started is None else f" ({time.monotonic() - started:.0f} s)"
    print(f"step {step_number}: {text}{suffix}", flush=True)


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


def ok(port, method, target, body=None, seconds=120):
    """A request that answers 200, retried while the cluster answers 503 or 504 or is busy."""
    deadline = time.monotonic() + seconds
    while True:
        try:
            status, reply = request(port, method, target, body)
        except (OSError, http.client.HTTPException):
            status, reply = 0, None
        if status == 200:
            return reply
        assert status in (0, 503, 504) and time.monotonic() < deadline, \
            (method, target, status, reply)
        time.sleep(0.3)


class Statsd(threading.Thread):
    """Receives the replicas' statsd packets; keeps each gauge's latest value and arrival time."""

    def __init__(self):
        super().__init__(daemon=True)
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("127.0.0.1", 0))
        self.port = self.socket.getsockname()[1]
        self.gauges = {}  # (replica, name) -> (value, arrival)
        self.lock = threading.Lock()

    def run(self):
        pattern = re.compile(r"tb\.(\w+):(\d+)\|g\|#cluster:[0-9a-f]+,replica:(\d+)")
        while True:
            data = self.socket.recv(65536).decode(errors="replace")
            now = time.monotonic()
            with self.lock:
                for line in data.splitlines():
                    match = pattern.match(line)
                    if match:
                        self.gauges[(int(match.group(3)), match.group(1))] = (
                            int(match.group(2)), now)

    def get(self, replica, name, after=0.0):
        """The gauge's latest value if it arrived after `after` (a monotonic time), else None."""
        sample = self.sample(replica, name, after)
        return None if sample is None else sample[0]

    def sample(self, replica, name, after=0.0):
        """The gauge's latest (value, arrival) if it arrived after `after`, else None."""
        with self.lock:
            value = self.gauges.get((replica, name))
        return value if value is not None and value[1] > after else None


def seat(n):
    return {"kind": "put", "table": SEATS, "id": str(n % 97),
            "fields": {"section": n % 5, "price": (n * 37) % 1000, "sold": n % 3 != 0}}


def commit_body(n):
    """Commit `n`: a seat put, then two ledger pairs: fund (sources to available) and reserve
    (available to held). The ledger's total stays zero."""
    fund = 1 + n % 7
    reserve = 1 + n % fund
    return {"key": f"{n:032x}", "entries": [
        seat(n),
        {"kind": "add", "table": SOURCES, "id": "1", "field": "balance", "delta": str(-fund),
         "pair": True},
        {"kind": "add", "table": ACCOUNTS, "id": "1", "field": "available", "delta_from": 1},
        {"kind": "add", "table": ACCOUNTS, "id": "1", "field": "available",
         "delta": str(-reserve), "pair": True},
        {"kind": "add", "table": ACCOUNTS, "id": "1", "field": "held", "delta_from": 3}]}


class Writer(threading.Thread):
    """Commits one keyed transaction after another, resending one under its key until it answers
    `committed` (a 503 or 504, or a lost connection, is resent). `acked` is n -> op."""

    def __init__(self, port):
        super().__init__(daemon=True)
        self.port = port
        self.acked = {}
        self.resent = 0
        self.stopping = False
        self.failure = None

    def run(self):
        try:
            n = 1
            while not self.stopping:
                while not self.stopping:
                    try:
                        status, reply = request(self.port, "POST", "/v1/commit", commit_body(n))
                    except (OSError, http.client.HTTPException):
                        status, reply = 0, None
                    if status == 200:
                        assert reply["status"] == "committed", (n, reply)
                        self.acked[n] = int(reply["op"])
                        n += 1
                        break
                    assert status in (0, 503, 504), (n, status, reply)
                    self.resent += 1
                    time.sleep(0.2)
                time.sleep(0.005)
        except BaseException as error:  # noqa: BLE001
            self.failure = error

    def op_max(self):
        return max(self.acked.values(), default=0)

    def wait_for(self, count, seconds=240):
        target = len(self.acked) + count
        deadline = time.monotonic() + seconds
        while len(self.acked) < target:
            assert self.failure is None, f"the writer failed: {self.failure!r}"
            assert time.monotonic() < deadline, f"only {len(self.acked)} of {target} commits"
            time.sleep(0.05)

    def wait_for_op(self, op, seconds=240):
        deadline = time.monotonic() + seconds
        while self.op_max() <= op:
            assert self.failure is None, f"the writer failed: {self.failure!r}"
            assert time.monotonic() < deadline, f"only op {self.op_max()} of {op}"
            time.sleep(0.05)

    def finish(self):
        self.stopping = True
        self.join(120)
        assert self.failure is None, f"the writer failed: {self.failure!r}"


class Cluster:
    """`count` replicas of cluster `cluster`, from data files that `prepare(index, path)` makes."""

    def __init__(self, tmp, nerva, statsd, count, cluster, prepare):
        self.tmp, self.nerva, self.statsd = tmp, nerva, statsd
        self.count, self.cluster = count, cluster
        self.ports = free_ports(count)
        self.addresses = ",".join(str(port) for port in self.ports)
        self.replicas = [None] * count
        self.others = []  # The gateway and the view process.
        try:
            for index in range(count):
                prepare(self, index, self.data_file(index))
            for index in range(count):
                self.start(index)
            self.wait_listening(range(count))
        except BaseException:
            self.close()
            raise

    def data_file(self, index):
        return os.path.join(self.tmp, f"{self.cluster}_{index}.nerva")

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
             f"--statsd=127.0.0.1:{self.statsd.port}", self.data_file(index)],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=open(self.data_file(index) + ".log", "a"))

    def wait_listening(self, indexes):
        """A replica opens its data file for a while before it accepts connections."""
        deadline = time.monotonic() + 180
        for index in indexes:
            while True:
                assert self.replicas[index].poll() is None, \
                    f"replica {index} exited: {self.log(index)[-2000:]}"
                try:
                    socket.create_connection(("127.0.0.1", self.ports[index]), timeout=1).close()
                    break
                except OSError:
                    assert time.monotonic() < deadline, self.log(index)[-2000:]
                    time.sleep(0.1)

    def kill(self, index):
        """SIGKILL; returns once the port refuses connections."""
        self.replicas[index].kill()
        self.replicas[index].wait()
        self.replicas[index] = None
        deadline = time.monotonic() + 30
        while True:
            try:
                socket.create_connection(("127.0.0.1", self.ports[index]), timeout=1).close()
            except OSError:
                return
            assert time.monotonic() < deadline, f"replica {index} still answers after SIGKILL"
            time.sleep(0.1)

    def serve(self, command):
        """`nerva api` or `nerva view` on the cluster; returns its port."""
        log = os.path.join(self.tmp, f"{self.cluster}_{command}.log")
        process = subprocess.Popen(
            [self.nerva, command, f"--cluster={self.cluster}", f"--addresses={self.addresses}",
             "--listen=127.0.0.1:0"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=open(log, "w"), env={**os.environ, "NERVA_KEY": KEY}, text=True)
        self.others.append(process)
        line = process.stdout.readline()
        assert line, f"nerva {command} exited: {open(log, errors='replace').read()[-2000:]}"
        return int(line)

    def recover(self, index, path, origin="none"):
        return subprocess.run(
            [self.nerva, "recover", f"--cluster={self.cluster}", f"--replica={index}",
             f"--replica-count={self.count}", f"--addresses={self.addresses}",
             f"--origin={origin}", "--development", path],
            capture_output=True, text=True, timeout=RECOVER_TIMEOUT_SECONDS + 60)

    def check_no_panic(self):
        for index in range(self.count):
            assert "panic" not in self.log(index), self.log(index)[-2000:]

    def stop(self):
        for process in self.others + self.replicas:
            if process is not None:
                process.kill()
                process.wait()
        self.others = []
        self.replicas = [None] * self.count

    def close(self):
        self.stop()
        for index in range(self.count):  # Data files are large: remove them once done with.
            for suffix in ("", ".log", ".log.lost", ".recovering", ".importing"):
                path = self.data_file(index) + suffix
                if os.path.exists(path):
                    os.remove(path)


def format_prepare(cluster, index, path):
    subprocess.run([cluster.nerva, "format", f"--cluster={cluster.cluster}", f"--replica={index}",
                    f"--replica-count={cluster.count}", "--development", path],
                   check=True, capture_output=True)


def check_refusal(result, codes, *, files=()):
    """A refusal is one coded line, its cause and its fix; exit status 1; nothing written."""
    assert result.returncode == 1, (result.returncode, result.stderr[-2000:])
    lines = result.stderr.strip().splitlines()
    # Log lines (timestamped) may come first; the diagnostic is the last three lines.
    assert all(re.match(r"\d{4}-\d\d-\d\d", line) for line in lines[:-3]), result.stderr
    lines = lines[-3:]
    assert any(lines[0].startswith(f"error[NRV-{code}]: ") for code in codes), result.stderr
    assert lines[1].startswith("  cause  ") and lines[2].startswith("  fix    "), result.stderr
    assert "error." not in "".join(lines) and "panic" not in result.stderr, result.stderr
    for path in files:
        assert not os.path.exists(path), f"{path} was written"
    return lines[0]


def view_hash(view_id, name, groups):
    """The replicated hash recomputed from the groups as served (`views.group_digest`, N52)."""
    total = 0
    for group in groups:
        key = bytes([group["section"]]) + bytes(63)
        sums = struct.pack("<qq", 0, 0)
        for slot in SLOTS[name]:
            value = int(group[slot]) % (1 << 128)
            sums += struct.pack("<QQ", value & ((1 << 64) - 1), value >> 64)
        sums += bytes(16 * (5 - len(SLOTS[name])))
        digest = hashlib.sha256(b"nerva.view.digest.v1" + struct.pack("<Q", view_id) + key +
                                struct.pack("<Q", int(group["count"])) + sums).digest()
        total = (total + int.from_bytes(digest, "little")) % (1 << 256)
    return total.to_bytes(32, "little").hex()


def view_header(port, name, as_of=None):
    target = f"/v1/views/{name}/groups?limit=1" + ("" if as_of is None else f"&as_of={as_of}")
    body = ok(port, "GET", target)
    return {"state": body["state"], "id": body["id"], "view_hash": body["view_hash"],
            "groups": str(body["group_count"])}


def wait_views_ready(port):
    deadline = time.monotonic() + 180
    for name in VIEWS:
        while view_header(port, name)["state"] != "ready":
            assert time.monotonic() < deadline, f"view {name} never became ready"
            time.sleep(0.2)


def ledger_total(port, op):
    """The ledger's fields summed over its rows, as of `op`."""
    rows = [ok(port, "GET", f"/v1/row?table={table}&id=1&as_of={op}")
            for table in (ACCOUNTS, SOURCES)]
    return sum(int(v) for row in rows for v in row["fields"].values())


def read_state(api, op):
    """Every view's header and the ledger's total, as of `op`."""
    wait_views_ready(api)
    return ({name: view_header(api, name, op) for name in VIEWS}, ledger_total(api, op))


def check_against_view(api, view_port, op):
    """`nerva view`'s answer for every view as of `op`, byte for byte `nerva api`'s, and the
    replicated hash recomputed from its groups."""
    for name in VIEWS:
        deadline = time.monotonic() + 120
        while True:  # `nerva view` follows the feed; it may be behind.
            status, answer = request(view_port, "GET", f"/v1/views/{name}?min_op={op}")
            if status == 200:
                break
            assert status in (503, 504) and time.monotonic() < deadline, (name, status, answer)
            time.sleep(0.3)
        status, oracle = request(view_port, "GET", f"/v1/views/{name}?as_of={op}")
        assert status == 200, (name, status, oracle)
        whole = ok(api, "GET", f"/v1/views/{name}?as_of={op}")
        assert whole["groups"] == oracle["groups"] and whole["hash"] == oracle["hash"], \
            (name, "nerva api and nerva view differ")
        header = view_header(api, name, op)
        assert whole["view_hash"] == header["view_hash"], (name, whole, header)
        assert view_hash(header["id"], name, oracle["groups"]) == header["view_hash"], \
            (name, "the replicated view_hash is not the groups' digest")


def acknowledged_keys_survive(writer, api):
    """Every acknowledged key, resent, answers `replayed` with the op it first committed at."""
    for n, op in sorted(writer.acked.items()):
        status, reply = request(api, "POST", "/v1/commit", commit_body(n))
        assert status == 200, (n, status, reply)
        assert reply == {"status": "committed", "op": str(op), "replayed": True}, (n, op, reply)


def primary_view(statsd, since, indexes):
    """The highest view among the fresh `replica_view` gauges of `indexes` (None if none)."""
    views = [statsd.get(index, "replica_view", since) for index in indexes]
    views = [view for view in views if view is not None]
    return max(views) if views else None


def wait_primary_gauge(statsd, since, indexes, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        view = primary_view(statsd, since, indexes)
        if view is not None and statsd.get(2, "replica_view", since) is not None:
            return view
        time.sleep(0.5)
    return primary_view(statsd, since, indexes)


def manifest_of(path):
    with open(path, "rb") as f:
        return json.load(f)


def restore_command(nerva, cluster, index, count, backup, manifest, path):
    return subprocess.run(
        [nerva, "restore", f"--cluster={cluster}", f"--replica={index}",
         f"--replica-count={count}", f"--input={backup}", f"--manifest={manifest}",
         "--development", path], capture_output=True, text=True, timeout=600)


class Demo:
    def __init__(self, tmp, nerva):
        self.tmp, self.nerva = tmp, nerva
        self.statsd = Statsd()
        self.statsd.start()
        self.cluster = None
        self.restored = None
        self.writer = None

    def run(self):
        global step_number
        steps = [self.step1, self.step2, self.step3, self.step4, self.step5, self.step6,
                 self.step7, self.step8, self.step9, self.step10, self.step11, self.step12]
        for number, step in enumerate(steps, 1):
            step_number = number
            started = time.monotonic()
            say(step(), started)

    def close(self):
        if self.writer is not None:
            self.writer.stopping = True
        for cluster in (self.cluster, self.restored):
            if cluster is not None:
                cluster.close()

    def step1(self):
        self.cluster = Cluster(self.tmp, self.nerva, self.statsd, 3, 0, format_prepare)
        self.api = self.cluster.serve("api")
        self.view = self.cluster.serve("view")
        for table, layout in ((SEATS, SEATS_LAYOUT), (ACCOUNTS, ACCOUNTS_LAYOUT),
                              (SOURCES, SOURCES_LAYOUT)):
            ok(self.api, "PUT", f"/v1/tables/{table}", layout)
        for name, definition in VIEWS.items():
            assert ok(self.api, "PUT", f"/v1/views/{name}", definition)["maintained"]
        assert ok(self.api, "PUT", "/v1/ledgers/1", LEDGER)["declared"] == "created"
        ok(self.api, "POST", "/v1/commit", {"entries": [
            {"kind": "add", "table": SOURCES, "id": "1", "field": "balance",
             "delta": "-100000", "pair": True, "create": True},
            {"kind": "add", "table": ACCOUNTS, "id": "1", "field": "available",
             "delta_from": 0, "create": True}]})
        wait_views_ready(self.api)
        self.writer = Writer(self.api)
        self.writer.start()
        self.writer.wait_for(50)
        return ("three replicas formatted and started, 3 layouts, a ledger and 2 views declared, "
                f"the writer started: {len(self.writer.acked)} commits so far")

    def step2(self):
        self.writer.wait_for_op(PAST_CHECKPOINT)
        return f"committed past op {PAST_CHECKPOINT}: the writer is at op {self.writer.op_max()}"

    def step3(self):
        cluster = self.cluster
        cluster.kill(2)
        path = cluster.data_file(2)
        os.remove(path)
        if os.path.exists(path + ".log"):  # Keep the old log apart: `sync: done` must be new.
            os.rename(path + ".log", path + ".log.lost")
        before = len(self.writer.acked)
        self.writer.wait_for(30)
        return (f"replica 2 killed (SIGKILL) and its data file deleted; the writer went on "
                f"({len(self.writer.acked) - before} more commits)")

    def step4(self):
        cluster = self.cluster
        path = os.path.join(self.tmp, "1_probe.nerva")
        result = cluster.recover(1, path)
        line = check_refusal(result, ["E0713"], files=(path, path + ".recovering"))
        assert "replica 1 still answers at 127.0.0.1:" in line, line
        return f"recover for replica 1 refused: `{line}`, exit 1, no file written"

    def step5(self):
        cluster = self.cluster
        path = cluster.data_file(2)
        before = len(self.writer.acked)
        result = cluster.recover(2, path)
        assert result.returncode == 0, result.stderr[-3000:]
        # The line is logged: `<timestamp> info(recover): recover: replica 2 of cluster 0 ...`.
        lines = [line.split("info(recover): ", 1)[1]
                 for line in (result.stdout + result.stderr).splitlines()
                 if "info(recover): recover: " in line]
        assert len(lines) == 1, (lines, result.stderr[-2000:])
        match = re.fullmatch(r"recover: replica 2 of cluster 0 formatted at view (\d+) \(the "
                             r"cluster was at view (\d+)\), export none \(formatted\); start it "
                             r"with nerva start", lines[0])
        assert match, lines[0]
        assert int(match.group(1)) == int(match.group(2)) + 2, lines[0]
        assert os.path.exists(path) and not os.path.exists(path + ".recovering")
        assert len(self.writer.acked) > before, "the writer stopped while recover ran"
        return lines[0]

    def step6(self):
        cluster, statsd, writer = self.cluster, self.statsd, self.writer
        cluster.start(2)
        cluster.wait_listening([2])
        deadline = time.monotonic() + SYNC_SECONDS
        while "sync: done" not in cluster.log(2):
            assert cluster.replicas[2].poll() is None, cluster.log(2)[-2000:]
            assert time.monotonic() < deadline, \
                f"no `sync: done` in {SYNC_SECONDS} s: {cluster.log(2)[-2000:]}"
            time.sleep(0.5)
        synced = time.monotonic()
        # Gauges are sent every 10 seconds: wait for a sample of each replica taken after the
        # sync; replica 2's must reach the writer's newest acknowledged op as of the sync, and
        # so must the others'.
        target = writer.op_max()
        deadline = time.monotonic() + 120
        while True:
            gauges = [statsd.get(i, "replica_commit_min", synced) for i in (2, 0, 1)]
            if None not in gauges and gauges[0] >= target:
                break
            assert time.monotonic() < deadline, \
                f"replica_commit_min of replicas 2, 0, 1 after the sync: {gauges}, wanted {target}"
            time.sleep(0.5)
        others = gauges[1:]
        assert all(v >= target for v in others), (others, target)
        # Replica 2 reaches the others': a sample of its own, taken after theirs, is not below
        # the highest of theirs.
        bar = max(others)
        taken = max(statsd.sample(i, "replica_commit_min")[1] for i in (0, 1))
        deadline = time.monotonic() + 120
        while True:
            sample = statsd.sample(2, "replica_commit_min", taken)
            if sample is not None and sample[0] >= bar:
                break
            assert time.monotonic() < deadline, \
                f"replica 2's commit_min {sample} never reached the others' {bar}"
            time.sleep(0.5)
        own = sample[0]
        return (f"replica 2 started: `sync: done` in its log, replica_commit_min {own} against "
                f"{others[0]} and {others[1]} (the writer was at op {target})")

    def step7(self):
        cluster, statsd, writer = self.cluster, self.statsd, self.writer
        restarted = []
        since = 0.0  # Gauges must be newer than the last restart.
        while True:
            view = wait_primary_gauge(statsd, since, (0, 1, 2))
            if view is not None and view % 3 == 2:
                break
            assert len(restarted) < RESTARTS_MAX, \
                f"after {RESTARTS_MAX} restarts the replica_view gauge is {view}, not 2 mod 3"
            index = len(restarted) % 2
            cluster.kill(index)
            cluster.start(index)
            cluster.wait_listening([index])
            since = time.monotonic()
            restarted.append(index)
            writer.wait_for(30, seconds=240)  # Each restart commits again before the next.
        writer.wait_for(30)
        return (f"replicas restarted in turn: {restarted}; the replica_view gauge is {view}, so "
                "replica 2 leads, and the writer went on")

    def step8(self):
        cluster, statsd, writer = self.cluster, self.statsd, self.writer
        writer.finish()
        op = writer.op_max()
        since = time.monotonic()
        view = wait_primary_gauge(statsd, since, (0, 1, 2), seconds=40)
        assert view is not None and view % 3 == 2, f"replica 2 is not the primary: view {view}"
        self.state = read_state(self.api, op)
        headers, total = self.state
        assert total == 0, f"the ledger's total is {total}"
        check_against_view(self.api, self.view, op)
        acknowledged_keys_survive(writer, self.api)
        cluster.check_no_panic()
        self.op = op
        names = ", ".join(f"{name} {headers[name]['view_hash'][:12]}" for name in VIEWS)
        return (f"writer stopped at op {op} ({len(writer.acked)} commits, {writer.resent} resent); "
                f"view {view}, replica 2 primary; views {names}, ledger total {total}; nerva "
                f"api and nerva view agree; {len(writer.acked)} keys replayed with their ops")

    def step9(self):
        self.backup_path = os.path.join(self.tmp, "b.nerva-backup")
        self.manifest_path = self.backup_path + ".manifest.json"
        result = subprocess.run(
            [self.nerva, "backup", "--cluster=0", f"--addresses={self.cluster.addresses}",
             f"--output={self.backup_path}"], capture_output=True, text=True, timeout=300)
        assert result.returncode == 0, result.stderr[-3000:]
        match = re.fullmatch(r"backup (\S+): op (\d+), sha256 ([0-9a-f]{64})\nmanifest (\S+)\n",
                             result.stdout)
        assert match, result.stdout
        self.sha256 = match.group(3)
        manifest = self.manifest = manifest_of(self.manifest_path)
        assert manifest["export_sha256"] == self.sha256 and int(manifest["op"]) >= self.op
        headers, total = self.state
        self.check_manifest(manifest, headers, total)
        return (f"backup at op {manifest['op']}, sha256 {self.sha256[:12]}; the manifest's view "
                "hashes and ledger total equal step 8's")

    @staticmethod
    def check_manifest(manifest, headers, total):
        assert [v["name"] for v in manifest["views"]] == sorted(VIEWS, key=lambda n: headers[n]["id"]), \
            manifest
        for view in manifest["views"]:
            header = headers[view["name"]]
            assert (view["state"], view["view_hash"], view["groups"]) == (
                "ready", header["view_hash"], header["groups"]), (view, header)
        assert manifest["ledgers"] == [{"id": 1, "total": str(total)}], manifest

    def compare_restored(self, cluster, what):
        """A restored cluster: every view hash and the ledger total equal the manifest's."""
        api = cluster.serve("api")
        op = int(self.manifest["op"])
        wait_views_ready(api)
        headers = {name: view_header(api, name) for name in VIEWS}
        assert ledger_total(api, op) == int(self.manifest["ledgers"][0]["total"]), what
        self.check_manifest(self.manifest, headers, 0)
        return api

    def step10(self):
        sha, op = self.sha256, self.manifest["op"]

        def restore_prepare(drill, index, path):
            result = restore_command(self.nerva, DRILL_CLUSTER, index, 1, self.backup_path,
                                     self.manifest_path, path)
            assert result.returncode == 0, result.stderr[-3000:]
            assert result.stdout.strip() == (
                f"restored replica 0 from backup {sha} at op {op}: "
                f"{len(VIEWS)} views and 1 ledger match the manifest"), result.stdout

        drill = Cluster(self.tmp, self.nerva, self.statsd, 1, DRILL_CLUSTER, restore_prepare)
        try:
            self.compare_restored(drill, "drill")
            drill.check_no_panic()
        finally:
            drill.close()
        assert all(p.poll() is None for p in self.cluster.replicas), "cluster 0 stopped"
        return (f"restored into a one-replica drill cluster (cluster {DRILL_CLUSTER}) while "
                "cluster 0 ran: every view hash and the ledger total equal the manifest's")

    def step11(self):
        sha, op = self.sha256, self.manifest["op"]
        self.cluster.close()  # Stops the cluster and deletes its three data files.
        for index in range(3):
            assert not os.path.exists(self.cluster.data_file(index))

        def restore_prepare(cluster, index, path):
            result = restore_command(self.nerva, 0, index, 3, self.backup_path,
                                     self.manifest_path, path)
            assert result.returncode == 0, result.stderr[-3000:]
            assert result.stdout.strip() == (
                f"restored replica {index} from backup {sha} at op {op}: "
                f"{len(VIEWS)} views and 1 ledger match the manifest"), result.stdout

        self.restored = Cluster(self.tmp, self.nerva, self.statsd, 3, 0, restore_prepare)
        api = self.compare_restored(self.restored, "restored cluster")
        view = self.restored.serve("view")
        check_against_view(api, view, int(op))
        ok(api, "POST", "/v1/commit", commit_body(10_000_000))  # It takes writes again.
        self.restored.check_no_panic()
        return ("cluster 0 stopped and its data files deleted; three replicas restored and "
                "started: every view hash and the ledger total equal the manifest's, through "
                "nerva api and nerva view")

    def step12(self):
        with open(self.backup_path, "rb") as f:
            data = f.read()
        changed = os.path.join(self.tmp, "changed.nerva-backup")
        middle = len(data) // 2
        with open(changed, "wb") as f:
            f.write(data[:middle] + bytes([data[middle] ^ 0x01]) + data[middle + 1:])
        path = os.path.join(self.tmp, "refused.nerva")
        result = restore_command(self.nerva, 0, 0, 3, changed, self.manifest_path, path)
        line = check_refusal(result, ["E0809", "E0804"], files=(path, path + ".importing"))
        return f"restore from a backup with one byte changed refused: `{line}`, exit 1, no data file"


def main():
    nerva = os.path.abspath(sys.argv[1])
    tmp = tempfile.mkdtemp(prefix="nerva-demo-r5-")
    demo = Demo(tmp, nerva)
    try:
        demo.run()
    except BaseException as error:  # noqa: BLE001
        traceback.print_exc()
        message = (str(error) or type(error).__name__).strip().splitlines()
        print(f"demo-r5: FAIL step {step_number}: {message[0][:300] if message else ''}",
              flush=True)
        sys.exit(1)
    finally:
        demo.close()
        shutil.rmtree(tmp, ignore_errors=True)
    print("demo-r5: PASS", flush=True)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
