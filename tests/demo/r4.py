#!/usr/bin/env python3
"""The R4 demo: gateway (docs/briefs/r4.md, "The demo: `zig build demo-r4`").

Usage: r4.py <nerva>

Three replicas on loopback with a real cluster key, and two clients, A and B (8 caller threads
each), each with its own `nerva api` on 127.0.0.1 (GA, GB) with `--request-timeout=3000` and
`--statsd` to this script's UDP socket. A ledger of four floored accounts and a source, and a
`sum` view over the accounts. Callers send keyed transfers (a pair each) and resend under the
same key after a refusal or an "unknown". Eleven steps, each asserting; one line per step; the
last line is `demo-r4: PASS` or `demo-r4: FAIL step N: ...`.

 1  format and start the replicas; start GA and GB; declare the ledger and the view; fund
 2  `nerva api --listen=0.0.0.0:0` (NRV-E0009); a second gateway on GA's port (NRV-E0007)
 3  A and B transfer for 20 s: every reply 200 or a 409 result, no transport error
 4  16 connections on GA that have sent half a head; A's 8 callers get 503 busy within 1 s
 5  32 callers on A for 30 s, drippers held for 2 s every 10 s: every refusal resent, applied once
 6  the statsd listener: refused{reason:busy} equals the busy replies seen; the series are present
 7  SIGKILL GA while A's callers are mid-commit: only A sees transport errors
 8  a new GA on the same port; A resends every unknown under its key
 9  SIGSTOP all three replicas for 10 s with B sending: 503 unknown within 4 s, healthz 503 within
    8.5 s, both answer again within 10 s, B resends (none answers 409)
10  a 4 MiB + 1 body (413), a future as_of (504), a drip (408), each with "applied": false
11  every acknowledged key resent through GB answers replayed; the ledger and the view agree

A failure is a finding, never re-run until it passes (CLAUDE.md).
"""
import http.client
import json
import os
import random
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

# Replicas authenticate each other with a real cluster key, never the development key (P102).
os.environ["NERVA_CLUSTER_KEY"] = os.urandom(32).hex()

KEY = "demo-r4-key"
ACCOUNTS, SOURCES = 40, 41
ACCOUNT_ROWS = 4
FUNDED = 1_000_000  # Per account.
CLIENT_THREADS = 8
REQUEST_TIMEOUT_MS = 3000
SLOTS = 16  # Connections a gateway holds at once.
BODY_MAX = 4 * 1024 * 1024
STEP3_SECONDS, STEP5_SECONDS, STALL_SECONDS = 20, 30, 10
WINDOW_SECONDS = 11  # A statsd window is 10 s.

DEADLINE_SECONDS = 20 * 60  # CI allows 30 minutes; a hang prints a FAIL line well before it.
step_number = 0


class StepFailed(AssertionError):
    pass


def say(text, started=None):
    suffix = "" if started is None else f" ({time.monotonic() - started:.0f} s)"
    print(f"step {step_number}: {text}{suffix}", flush=True)


def check(condition, message):
    if not condition:
        raise StepFailed(message)


def free_ports(count):
    sockets = [socket.socket() for _ in range(count)]
    for s in sockets:
        s.bind(("127.0.0.1", 0))
    ports = [s.getsockname()[1] for s in sockets]
    for s in sockets:
        s.close()
    return ports


class NotSent(OSError):
    """The connection was never made: the request reached nobody, so it did not apply."""


def request(port, method, target, body=None, key=KEY, timeout=60):
    """One request on a connection of its own: (status, body). `NotSent` if the connect fails."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        try:
            connection.connect()
        except OSError as error:
            raise NotSent(repr(error)) from error
        headers = {"X-Nerva-Key": key} if key else {}
        connection.request(method, target, body=None if body is None else json.dumps(body),
                           headers=headers)
        response = connection.getresponse()
        return response.status, json.loads(response.read() or b"null")
    finally:
        connection.close()


def raw(port, data, seconds=30):
    """Bytes sent, the connection read to its end: (status, body)."""
    connection = socket.create_connection(("127.0.0.1", port), timeout=seconds)
    try:
        connection.sendall(data)
        return read_reply(connection)
    finally:
        connection.close()


def read_reply(connection):
    reply = b""
    while chunk := connection.recv(65536):
        reply += chunk
        head, _, rest = reply.partition(b"\r\n\r\n")
        if rest and b"content-length" in head.lower():
            length = int([line for line in head.lower().split(b"\r\n")
                          if line.startswith(b"content-length")][0].split(b":")[1])
            if len(rest) >= length:
                break
    check(reply.startswith(b"HTTP/1.1 "), f"no status line: {reply[:200]!r}")
    return int(reply.split(b" ", 2)[1]), json.loads(reply.split(b"\r\n\r\n", 1)[1] or b"null")


def is_busy(status, body):
    return status == 503 and body.get("code") == "NRV-E0602" and body.get("applied") is False


class Listener(threading.Thread):
    """Receives the gateways' statsd lines; counters are summed over windows per series."""

    def __init__(self):
        super().__init__(daemon=True)
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("127.0.0.1", 0))
        self.port = self.socket.getsockname()[1]
        self.lock = threading.Lock()
        self.sums = {}  # (name, tags) -> total
        self.failure = None

    def run(self):
        try:
            while True:
                data = self.socket.recv(65535).decode()
                with self.lock:
                    for line in data.split("\n"):
                        self.add(line)
        except Exception as error:  # noqa: BLE001
            self.failure = repr(error)

    def add(self, line):
        head, kind, tags = line.split("|")
        name, value = head.rsplit(":", 1)
        pairs = dict(pair.split(":", 1) for pair in tags[1:].split(","))
        key = (name, tuple(sorted((k, v) for k, v in pairs.items() if k != "cluster")))
        if kind == "c":
            self.sums[key] = self.sums.get(key, 0) + int(value)
        else:
            self.sums.setdefault(key, 0)
            self.sums[key] += 0  # A gauge: present, not summed.

    def total(self, name, listen, **tags):
        """The counter's sum over every series of this gateway that has these tags."""
        wanted = {"listen": f"127.0.0.1:{listen}", **tags}
        with self.lock:
            return sum(v for (n, t), v in self.sums.items()
                       if n == name and all((k, x) in t for k, x in wanted.items()))

    def present(self, name, listen):
        with self.lock:
            return any(n == name and ("listen", f"127.0.0.1:{listen}") in t
                       for (n, t) in self.sums)


def first_line(process, seconds):
    """The first line `process` prints; a process that prints nothing in time is a failure."""
    box = []
    reader = threading.Thread(target=lambda: box.append(process.stdout.readline()), daemon=True)
    reader.start()
    reader.join(seconds)
    if reader.is_alive():
        process.kill()
        process.wait()
        raise StepFailed(f"a gateway printed no port in {seconds} s")
    return box[0]


class Demo:
    def __init__(self, nerva):
        self.nerva = nerva
        self.tmp = tempfile.mkdtemp(prefix="nerva-r4-")
        self.ports = free_ports(3)
        self.addresses = ",".join(str(p) for p in self.ports)
        self.replicas = [None] * 3
        self.gateways = {}  # "A"/"B" -> Popen
        self.gateway_ports = {}
        self.listener = Listener()
        self.listener.start()

    def data_file(self, index):
        return os.path.join(self.tmp, f"0_{index}.nerva")

    def log(self, path):
        try:
            with open(path, errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    def start_replicas(self):
        for index in range(3):
            subprocess.run([self.nerva, "format", "--cluster=0", f"--replica={index}",
                            "--replica-count=3", "--development", self.data_file(index)],
                           check=True, capture_output=True)
        for index in range(3):
            self.replicas[index] = subprocess.Popen(
                [self.nerva, "start", f"--addresses={self.addresses}", "--development",
                 self.data_file(index)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                stderr=open(self.data_file(index) + ".log", "a"))
        deadline = time.monotonic() + 180
        for index in range(3):
            while True:
                check(self.replicas[index].poll() is None,
                      f"replica {index} exited: {self.log(self.data_file(index) + '.log')[-1500:]}")
                try:
                    socket.create_connection(("127.0.0.1", self.ports[index]), timeout=1).close()
                    break
                except OSError:
                    check(time.monotonic() < deadline, f"replica {index} never listened")
                    time.sleep(0.1)

    def gateway_command(self, listen):
        return [self.nerva, "api", "--cluster=0", f"--addresses={self.addresses}",
                f"--listen={listen}", f"--request-timeout={REQUEST_TIMEOUT_MS}",
                f"--statsd=127.0.0.1:{self.listener.port}"]

    def start_gateway(self, name, port=None):
        """Starts a gateway; with `port`, on that port, retried while the port is still held."""
        log = os.path.join(self.tmp, f"gateway_{name}.log")
        deadline = time.monotonic() + 60
        while True:
            process = subprocess.Popen(
                self.gateway_command(f"127.0.0.1:{port or 0}"), stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=open(log, "a"),
                env={**os.environ, "NERVA_KEY": KEY}, text=True)
            line = first_line(process, 60)
            if line:
                self.gateways[name] = process
                self.gateway_ports[name] = int(line)
                return int(line)
            process.wait()
            check(port is not None and time.monotonic() < deadline,
                  f"gateway {name} exited: {self.log(log)[-1500:]}")
            time.sleep(0.5)

    def wait_healthy(self, name, seconds=60):
        deadline = time.monotonic() + seconds
        while True:
            try:
                status, body = request(self.gateway_ports[name], "GET", "/healthz", key=None,
                                       timeout=15)
            except (OSError, http.client.HTTPException):
                status, body = 0, None
            if status == 200 and body.get("session") == "ready":
                return
            check(time.monotonic() < deadline, f"gateway {name} never ready: {status} {body}")
            time.sleep(0.2)

    def close(self):
        for process in list(self.gateways.values()) + self.replicas:
            if process is not None:
                try:
                    process.send_signal(signal.SIGCONT)
                except OSError:
                    pass
                process.kill()
                process.wait()
        shutil.rmtree(self.tmp, ignore_errors=True)


def move(table, row, field, **options):
    entry = {"kind": "add", "table": table, "id": str(row), "field": field}
    for name, value in options.items():
        entry[name] = str(value) if name in ("delta",) else value
    return entry


def transfer(source, target, amount):
    """Account `source` to account `target`: a pair, so the ledger's total stays put."""
    return [move(ACCOUNTS, source, "balance", delta=-amount, pair=True),
            move(ACCOUNTS, target, "balance", delta_from=0)]


class Client:
    """One client process's callers: keyed transfers through one gateway. A key is `unresolved`
    after a reply that does not say whether it applied, and `acked` (key -> op) once it answers
    200; `conflicts` holds keys a 409 settled; `effects` is each key's (source, target, amount)."""

    def __init__(self, name, demo):
        self.name, self.demo = name, demo
        self.lock = threading.Lock()
        self.effects, self.acked, self.conflicts = {}, {}, set()
        self.unresolved = {}  # key -> entries, never answered 200 or 409
        self.counts = {"busy": 0, "other_503": 0}
        self.seen_busy = 0  # Every busy reply any of this client's sockets read.
        self.failures = []
        self.drips = 0  # Dripper rounds completed.
        self.cut = self.not_sent = 0  # Transport errors after a request was sent / at connect.
        self.resent = {}
        self.next_worker = 0
        self.threads = []
        self.stop = threading.Event()

    @property
    def port(self):
        return self.demo.gateway_ports[self.name]

    def settle(self, key, status, body):
        """Records a final answer; returns True when the key is settled."""
        if status == 200:
            check(body["status"] == "committed", (key, body))
            with self.lock:
                self.acked[key] = int(body["op"])
                self.unresolved.pop(key, None)
            return True
        if status == 409:
            with self.lock:
                self.conflicts.add(key)
                self.unresolved.pop(key, None)
            return True
        return False

    def start(self, count, mode):
        """`mode`: "strict" (anything but 200 or 409 is a failure), "resend" (a refusal is resent
        under its key; a transport error is a failure) or "once" (a reply that is neither is
        recorded in `unresolved` and the caller moves on; a transport error ends the caller)."""
        self.stop = threading.Event()
        self.threads = []
        for _ in range(count):
            worker = self.next_worker
            self.next_worker += 1
            thread = threading.Thread(target=self.run, args=(worker, mode, self.stop), daemon=True)
            self.threads.append(thread)
            thread.start()

    def run(self, worker, mode, stop):
        rng = random.Random(f"{self.name}{worker}")
        number = 0
        try:
            while not stop.is_set():
                number += 1
                key = f"{ord(self.name):02x}{worker:06x}{number:024x}"
                source = rng.randrange(ACCOUNT_ROWS)
                target = (source + 1 + rng.randrange(ACCOUNT_ROWS - 1)) % ACCOUNT_ROWS
                amount = rng.randint(1, 5)
                entries = transfer(source, target, amount)
                with self.lock:
                    self.effects[key] = (source, target, amount)
                if not self.send(key, entries, mode, rng, stop):
                    return
        except BaseException as error:  # noqa: BLE001
            self.failures.append(f"{self.name} worker {worker}: {error!r}")
            stop.set()

    def send(self, key, entries, mode, rng, stop):
        """Sends until settled (resend mode) or once. False ends the caller."""
        while True:
            try:
                status, body = request(self.port, "POST", "/v1/commit",
                                       {"key": key, "entries": entries})
            except (OSError, http.client.HTTPException) as error:
                check(mode == "once", f"transport error for {key}: {error!r}")
                with self.lock:
                    self.unresolved[key] = entries
                    if isinstance(error, NotSent):
                        self.not_sent += 1
                    else:
                        self.cut += 1
                return False
            if self.settle(key, status, body):
                return True
            check(status == 503 and body.get("code", "").startswith("NRV-E06"),
                  f"neither committed nor refused: {status} {body}")
            check(body.get("applied") in (False, "unknown"), body)
            check((body["applied"] == "unknown") == (body["code"] == "NRV-E0601"), body)
            with self.lock:
                if body["code"] == "NRV-E0602":
                    self.counts["busy"] += 1
                else:
                    self.counts["other_503"] += 1
                self.unresolved[key] = entries
            check(mode != "strict", f"a refusal in a strict run: {status} {body}")
            if mode == "once":
                time.sleep(0.05)
                return True
            time.sleep(rng.uniform(0.01, 0.05))

    def finish(self, seconds=120):
        self.stop.set()
        deadline = time.monotonic() + seconds  # For all the threads together.
        for thread in self.threads:
            thread.join(max(0.0, deadline - time.monotonic()))
            check(not thread.is_alive(), f"a caller of {self.name} never finished")
        check(not self.failures, self.failures[:3])

    def resend_unresolved(self, port, threads=8):
        """Each unresolved key resent under itself until 200 or 409 (retrying refusals). Returns
        the number of keys; `self.resent` counts the answers: first-time, replayed, conflict."""
        pending = sorted(self.unresolved.items())
        problems = []
        self.resent = {"first": 0, "replayed": 0, "conflict": 0}
        verified = [0]

        def work(share):
            try:
                for key, entries in share:
                    deadline = time.monotonic() + 120
                    while True:
                        status, body = request(port, "POST", "/v1/commit",
                                               {"key": key, "entries": entries})
                        if self.settle(key, status, body):
                            break
                        if time.monotonic() > deadline or status != 503:
                            problems.append((key, status, body))
                            return
                        time.sleep(0.05)
                    kind = ("conflict" if status == 409 else
                            "replayed" if body.get("replayed") is True else "first")
                    with self.lock:
                        self.resent[kind] += 1
                        verified[0] += 1
            except BaseException as error:  # noqa: BLE001
                problems.append(repr(error))

        pool = [threading.Thread(target=work, args=(pending[i::threads],), daemon=True)
                for i in range(threads)]
        for thread in pool:
            thread.start()
        for thread in pool:
            thread.join(240)
            check(not thread.is_alive(), "a resend thread never finished")
        check(not problems, problems[:3])
        check(verified[0] == len(pending), f"{verified[0]} of {len(pending)} keys resent")
        check(not self.unresolved, f"{len(self.unresolved)} keys still unresolved")
        return len(pending)


def declare_and_fund(port):
    layouts = ((ACCOUNTS, {"name": "accounts", "fields": [{"name": "bucket", "type": "u8"},
                                                          {"name": "balance", "type": "i64"}]}),
               (SOURCES, {"name": "sources", "fields": [{"name": "balance", "type": "i64"}]}))
    for table, layout in layouts:
        status, body = request(port, "PUT", f"/v1/tables/{table}", layout)
        check(status == 200, body)
    status, body = request(port, "PUT", "/v1/ledgers/1", {"fields": [
        {"table": SOURCES, "field": "balance", "floor": None},
        {"table": ACCOUNTS, "field": "balance", "floor": "0"}]})
    check(status == 200, body)
    status, body = request(port, "PUT", "/v1/views/sum", {
        "table": ACCOUNTS, "group_by": ["bucket"],
        "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "balance"}]})
    check(status == 200, body)
    for row in range(ACCOUNT_ROWS):
        status, body = request(port, "POST", "/v1/commit", {"entries": [
            move(SOURCES, 1, "balance", delta=-FUNDED, pair=True, create=True),
            move(ACCOUNTS, row, "balance", delta_from=0, create=True)]})
        check(status == 200, body)


def lookup(port):
    """(source balance, [account balances]) read now."""
    rows = [{"table": SOURCES, "id": "1"}] + [{"table": ACCOUNTS, "id": str(r)}
                                              for r in range(ACCOUNT_ROWS)]
    status, body = request(port, "POST", "/v1/lookup", {"rows": rows})
    check(status == 200, body)
    source, *accounts = [row["fields"] for row in body["rows"]]
    return int(source["balance"]), [int(a["balance"]) for a in accounts]


def view_sum(port):
    deadline = time.monotonic() + 60
    while True:
        status, body = request(port, "GET", "/v1/views/sum")
        if status == 200:
            check(len(body["groups"]) == 1, body)
            return int(body["groups"][0]["count"]), int(body["groups"][0]["sum_balance"])
        check(status == 503 and time.monotonic() < deadline, (status, body))
        time.sleep(0.2)


def step1(demo):
    demo.start_replicas()
    ga = demo.start_gateway("A")
    gb = demo.start_gateway("B")
    demo.wait_healthy("A")
    demo.wait_healthy("B")
    declare_and_fund(ga)
    check(lookup(gb) == (-FUNDED * ACCOUNT_ROWS, [FUNDED] * ACCOUNT_ROWS), lookup(gb))
    say(f"3 replicas, GA :{ga} and GB :{gb} ready, 4 accounts funded with {FUNDED}")


def step2(demo):
    env = {**os.environ, "NERVA_KEY": KEY}
    result = subprocess.run(demo.gateway_command("0.0.0.0:0"), capture_output=True, text=True,
                            env=env, timeout=120)
    check(result.returncode == 1 and "error[NRV-E0009]" in result.stderr,
          (result.returncode, result.stderr[-500:]))
    first = [line for line in result.stderr.splitlines() if "error[" in line][0]
    port = demo.gateway_ports["A"]
    result = subprocess.run(demo.gateway_command(f"127.0.0.1:{port}"), capture_output=True,
                            text=True, env=env, timeout=120)
    check(result.returncode == 1 and "error[NRV-E0007]" in result.stderr,
          (result.returncode, result.stderr[-500:]))
    demo.wait_healthy("A", 15)
    say(f"{first.split(':')[0]} on 0.0.0.0, error[NRV-E0007] on GA's port, GA still ready")


def step3(demo, a, b):
    started = time.monotonic()
    a.start(CLIENT_THREADS, "strict")
    b.start(CLIENT_THREADS, "strict")
    time.sleep(STEP3_SECONDS)
    a.finish()
    b.finish()
    check(a.acked and b.acked, (len(a.acked), len(b.acked)))
    check(not a.unresolved and not b.unresolved, "a key was left unresolved")
    say(f"A {len(a.acked)} and B {len(b.acked)} transfers committed, "
        f"{len(a.conflicts) + len(b.conflicts)} 409, no transport error", started)


def hold(port, count):
    """`count` connections that have sent half a head."""
    held = []
    for _ in range(count):
        connection = socket.create_connection(("127.0.0.1", port), timeout=30)
        connection.sendall(b"GET /healthz HTTP/1.1\r\n")
        held.append(connection)
    return held


def step4(demo, a):
    port = a.port
    held = hold(port, SLOTS)
    time.sleep(0.3)
    replies, errors = [], []

    def caller(index):
        started = time.monotonic()
        try:
            entries = transfer(0, 1, 1)
            status, body = request(port, "POST", "/v1/commit",
                                   {"key": f"{0x41:02x}f{index:07x}{'0' * 22}", "entries": entries})
            replies.append((status, body, time.monotonic() - started))
        except Exception as error:  # noqa: BLE001
            errors.append(repr(error))

    threads = [threading.Thread(target=caller, args=(i,), daemon=True) for i in range(CLIENT_THREADS)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(30)
        check(not thread.is_alive(), "a busy-probe caller never finished")
    check(not errors, errors[:3])
    check(len(replies) == CLIENT_THREADS, len(replies))
    for status, body, seconds in replies:
        check(is_busy(status, body), (status, body))
        check(seconds < 1.0, f"a busy reply took {seconds:.2f} s")
    a.seen_busy += len(replies)
    # The sixteen finish, and each is answered.
    for connection in held:
        connection.sendall(b"connection: close\r\n\r\n")
    for connection in held:
        status, body = read_reply(connection)
        check(status == 200 and body.get("session") == "ready", (status, body))
        connection.close()
    say(f"{len(replies)} busy replies (applied false, NRV-E0602) within "
        f"{max(r[2] for r in replies):.2f} s; the {SLOTS} held connections answered 200")


def drip(a, stop):
    """Sixteen connections that have sent half a head for 2 s of every 10; busy replies counted.
    Any transport error is a failure; `a.drips` counts the rounds that completed."""
    try:
        while not stop.is_set():
            held, refused = [], 0
            for _ in range(SLOTS):
                connection = socket.create_connection(("127.0.0.1", a.port), timeout=30)
                held.append(connection)
                connection.sendall(b"GET /healthz HTTP/1.1\r\n")
            stop.wait(2)
            for connection in held:
                try:
                    connection.sendall(b"connection: close\r\n\r\n")
                    status, body = read_reply(connection)
                    if is_busy(status, body):
                        refused += 1
                    else:
                        check(status == 200, (status, body))
                finally:
                    connection.close()
            with a.lock:
                a.seen_busy += refused
                a.drips += 1
            stop.wait(8)
    except BaseException as error:  # noqa: BLE001
        with a.lock:
            a.failures.append(f"a dripper: {error!r}")


def step5(demo, a):
    started = time.monotonic()
    before = len(a.acked)
    a.start(32, "resend")
    dripper = threading.Thread(target=drip, args=(a, a.stop), daemon=True)
    dripper.start()
    time.sleep(STEP5_SECONDS)
    a.finish()
    dripper.join(60)
    check(not dripper.is_alive(), "the dripper never finished")
    check(not a.failures, a.failures[:3])
    check(a.drips >= 2, f"the dripper completed {a.drips} rounds")
    check(a.counts["other_503"] == 0, a.counts)
    check(a.counts["busy"] > 0, f"the gateway was never busy: {a.counts}")
    check(not a.unresolved, f"{len(a.unresolved)} keys never settled")
    a.seen_busy += a.counts["busy"]
    a.counts["busy"] = 0
    say(f"{len(a.acked) - before} transfers committed, {a.seen_busy} busy replies in all "
        f"({a.drips} drip rounds), every one resent and settled, no transport error", started)


def step6(demo, a, b):
    listener = demo.listener
    ga, gb = demo.gateway_ports["A"], demo.gateway_ports["B"]
    names = ("nerva.api.requests", "nerva.api.group_size.count", "nerva.api.cluster_request_us.count")
    # Counters arrive once per 10 s window: poll for up to three windows, never one fixed sleep.
    deadline = time.monotonic() + 3 * WINDOW_SECONDS
    while True:
        check(listener.failure is None, listener.failure)
        busy = listener.total("nerva.api.refused", ga, reason="busy")
        waited = listener.total("nerva.api.refused", ga, reason="queue_wait")
        displaced = listener.total("nerva.api.refused", ga, reason="displaced")
        # Every connection this script opens sends bytes at once, so none may be displaced (#120).
        check(displaced == 0, f"{displaced} connections displaced that had sent bytes")
        check(busy + waited <= a.seen_busy,
              f"refused busy {busy} + queue_wait {waited} exceed the {a.seen_busy} busy replies seen")
        missing = [(n, p) for n in names for p in (ga, gb) if not listener.present(n, p)]
        if busy + waited == a.seen_busy and busy > 0 and not missing:
            break
        check(time.monotonic() < deadline,
              f"refused busy {busy} + queue_wait {waited} != {a.seen_busy} busy replies seen; "
              f"missing series {missing}")
        time.sleep(0.5)
    check(listener.total("nerva.api.refused", gb, reason="busy") == 0, "GB refused busy")
    say(f"refused{{reason:busy}} {busy} (+{waited} queue_wait, 0 displaced) equals the "
        f"{a.seen_busy} busy replies seen; requests, group_size and cluster_request_us present "
        f"for GA and GB")


def step7(demo, a, b):
    a.start(CLIENT_THREADS, "once")
    b.start(CLIENT_THREADS, "strict")
    time.sleep(1.5)
    b_before = len(b.acked)
    demo.gateways["A"].kill()
    demo.gateways["A"].wait()
    time.sleep(3)
    b_after = len(b.acked)
    b.finish()
    for thread in a.threads:
        thread.join(30)
        check(not thread.is_alive(), "a caller of A is stuck")
    check(not a.failures, a.failures[:3])
    check(a.unresolved, "A saw no transport error")
    check(a.cut > 0, f"no request of A was cut mid-flight ({a.not_sent} connects refused)")
    check(a.cut + a.not_sent <= len(a.unresolved), (a.cut, a.not_sent, len(a.unresolved)))
    check(b_after > b_before, f"B committed nothing after GA died ({b_before} -> {b_after})")
    check(not b.unresolved and not b.failures, (b.unresolved, b.failures[:3]))
    say(f"GA killed: A has {len(a.unresolved)} unresolved keys ({a.cut} cut mid-flight, unknown; "
        f"{a.not_sent} refused at connect); B committed {b_after - b_before} more with no error")


def step8(demo, a):
    port = demo.gateway_ports["A"]
    demo.start_gateway("A", port)
    check(demo.gateway_ports["A"] == port, "GA moved")
    demo.wait_healthy("A")
    count = a.resend_unresolved(a.port)
    check(a.resent["conflict"] == 0, f"a resend answered 409: {a.resent}")
    check(a.resent["first"] + a.resent["replayed"] == count, (a.resent, count))
    say(f"new GA on :{port}; {count} keys resent, each answered 200: {a.resent['first']} "
        f"first-time, {a.resent['replayed']} replayed")


def step9(demo, a, b):
    started = time.monotonic()
    ga = demo.gateway_ports["A"]
    records = []  # (sent at, answered at, status, body)
    stop = threading.Event()
    errors = []

    def caller(worker):
        rng = random.Random(f"stall{worker}")
        number = 0
        while not stop.is_set():
            number += 1
            key = f"5b{worker:06x}{number:024x}"  # Apart from B's keys.
            source, target = 0, 1 + rng.randrange(3)
            entries = transfer(source, target, 1)
            with b.lock:
                b.effects[key] = (source, target, 1)
            sent = time.monotonic()
            try:
                status, body = request(b.port, "POST", "/v1/commit",
                                       {"key": key, "entries": entries}, timeout=30)
            except Exception as error:  # noqa: BLE001
                errors.append(repr(error))
                return
            records.append((sent, time.monotonic(), status, body))
            try:
                settled = b.settle(key, status, body)
            except StepFailed as error:
                errors.append(repr(error))
                return
            if not settled:
                with b.lock:
                    b.unresolved[key] = entries
                time.sleep(0.1)

    threads = [threading.Thread(target=caller, args=(i,), daemon=True) for i in range(CLIENT_THREADS)]
    for thread in threads:
        thread.start()
    time.sleep(1)
    for replica in demo.replicas:
        replica.send_signal(signal.SIGSTOP)
    stopped = time.monotonic()  # After the last SIGSTOP: nothing commits from here on.
    health = {}
    try:
        while time.monotonic() - stopped < STALL_SECONDS:
            probe = time.monotonic()
            try:
                status, body = request(ga, "GET", "/healthz", key=None, timeout=15)
            except (OSError, http.client.HTTPException):
                status, body = 0, None
            if status == 503 and "answered" not in health:
                health["answered"] = time.monotonic() - stopped
                health["body"] = body
            time.sleep(max(0, 0.25 - (time.monotonic() - probe)))
    finally:
        for replica in demo.replicas:
            replica.send_signal(signal.SIGCONT)
    resumed = time.monotonic()
    check("answered" in health, "GA's /healthz never said 503 during the stall")
    check(health["body"].get("code") == "NRV-E0605", health["body"])
    check(health["answered"] <= 8.5, f"GA's /healthz said 503 after {health['answered']:.1f} s")
    # Both answer again within 10 s.
    for name in ("A", "B"):
        demo.wait_healthy(name, 10)
    recovered = time.monotonic() - resumed
    check(recovered <= 10.0, f"GA and GB answered {recovered:.1f} s after SIGCONT")
    time.sleep(1)
    stop.set()
    for thread in threads:
        thread.join(60)
        check(not thread.is_alive(), "a step 9 caller never finished")
    check(not errors, errors[:3])
    inflight = [r for r in records if r[0] < stopped < r[1]]  # Sent before, answered after.
    check(inflight, "no request was in flight when the replicas stopped")
    worst = 0.0
    unknown = 0
    refused = 0
    for sent, answered, status, body in inflight:
        if status in (200, 409):  # Answered while the signals were still being delivered.
            check(answered - stopped < 0.5, f"{status} answered {answered - stopped:.2f} s after the stop")
            continue
        # A request sent to the cluster is unknown (E0601); one still waiting to be sent is not.
        check(status == 503 and (
            (body.get("code") == "NRV-E0601" and body.get("applied") == "unknown")
            or (body.get("code") in ("NRV-E0605", "NRV-E0602", "NRV-E0606") and body.get("applied") is False)),
            (status, body))
        unknown += body.get("applied") == "unknown"
        refused += body.get("code") == "NRV-E0606"
        worst = max(worst, answered - stopped)
    check(unknown > 0, "no in-flight request was answered unknown")
    check(worst <= 4.0, f"an in-flight request waited {worst:.1f} s after the stop")
    for sent, answered, status, body in records:
        check(status in (200, 409) or (status == 503 and body.get("code") in
              ("NRV-E0601", "NRV-E0605", "NRV-E0602", "NRV-E0606")), (status, body))
        if status == 503:  # Unknown exactly when the request may have reached the cluster.
            check(body.get("applied") in (False, "unknown")
                  and (body["applied"] == "unknown") == (body["code"] == "NRV-E0601"), (status, body))
    count = b.resend_unresolved(b.port)
    check(not b.unresolved, f"{len(b.unresolved)} keys unresolved after the resend")
    check(b.resent["conflict"] == 0, f"a resend answered 409: {b.resent}")
    say(f"{len(inflight)} in-flight requests answered 503 ({unknown} unknown, NRV-E0601; {refused} refused, NRV-E0606) within {worst:.1f} s; "
        f"GA /healthz 503 (NRV-E0605) after {health['answered']:.1f} s; both ready {recovered:.1f} s "
        f"after SIGCONT; {count} keys resent, none answered 409", started)


def step10(demo, a):
    port = demo.gateway_ports["A"]
    head = (f"POST /v1/commit HTTP/1.1\r\nx-nerva-key: {KEY}\r\n"
            f"content-length: {BODY_MAX + 1}\r\nconnection: close\r\n\r\n").encode()
    connection = socket.create_connection(("127.0.0.1", port), timeout=60)
    sender_error = []

    def send():
        try:
            connection.sendall(head)
            chunk = b" " * 65536
            for _ in range((BODY_MAX + 1) // len(chunk) + 1):
                connection.sendall(chunk)
        except OSError as error:  # The reply may close the connection first.
            sender_error.append(error)

    sender = threading.Thread(target=send, daemon=True)
    sender.start()
    try:
        status, body = read_reply(connection)
    finally:
        sender.join(60)
        stuck = sender.is_alive()
        connection.close()
    check(not stuck, "the oversized-body sender never finished")
    check(status == 413 and body.get("code") == "NRV-E0102" and body.get("applied") is False,
          (status, body))
    status, body = request(port, "GET", f"/v1/row?table={ACCOUNTS}&id=1&as_of={10 ** 12}")
    check(status == 504 and body.get("code") == "NRV-E0401" and body.get("applied") is False,
          (status, body))
    started = time.monotonic()
    connection = socket.create_connection(("127.0.0.1", port), timeout=60)
    connection.sendall(b"GET /healthz HTTP/1.1\r\n")
    status, body = read_reply(connection)
    connection.close()
    check(status == 408 and body.get("code") == "NRV-E0116" and body.get("applied") is False,
          (status, body))
    say(f"413 NRV-E0102, 504 NRV-E0401 and 408 NRV-E0116 ({time.monotonic() - started:.0f} s drip), "
        f"each with applied false")


def step11(demo, a, b):
    started = time.monotonic()
    gb = demo.gateway_ports["B"]
    keys = [(k, op, c) for c in (a, b) for k, op in c.acked.items()]
    problems = []

    verified = [0]

    def work(share):
        try:
            for key, op, client in share:
                entries = transfer(*client.effects[key][:2], client.effects[key][2])
                deadline = time.monotonic() + 60
                while True:
                    status, body = request(gb, "POST", "/v1/commit", {"key": key, "entries": entries})
                    if status != 503 or time.monotonic() > deadline:
                        break
                    time.sleep(0.05)
                if not (status == 200 and body.get("replayed") is True and int(body["op"]) == op
                        and body.get("code") == "NRV-W0201"):
                    problems.append((key, op, status, body))
                    return
                with b.lock:
                    verified[0] += 1
        except BaseException as error:  # noqa: BLE001
            problems.append(repr(error))

    pool = [threading.Thread(target=work, args=(keys[i::16],), daemon=True) for i in range(16)]
    for thread in pool:
        thread.start()
    for thread in pool:
        thread.join(300)
        check(not thread.is_alive(), "a replay thread never finished")
    check(not problems, problems[:3])
    check(verified[0] == len(keys), f"{verified[0]} of {len(keys)} keys replayed")
    # Each key applied once: every account holds its funding plus the unique effects.
    expected = [FUNDED] * ACCOUNT_ROWS
    for client in (a, b):
        for key in client.acked:
            source, target, amount = client.effects[key]
            expected[source] -= amount
            expected[target] += amount
    source, accounts = lookup(gb)
    check(accounts == expected, f"accounts {accounts} != {expected}")
    check(source + sum(accounts) == 0 and source == -FUNDED * ACCOUNT_ROWS, (source, accounts))
    count, total = view_sum(gb)
    check(count == ACCOUNT_ROWS and total == FUNDED * ACCOUNT_ROWS, (count, total))
    say(f"{verified[0]} of {len(keys)} acknowledged keys replayed with their ops; ledger total 0 and the view's sum "
        f"{total} equal the funding", started)


def main():
    global step_number
    demo = Demo(sys.argv[1])

    def overdue():
        print(f"demo-r4: FAIL step {step_number}: no end after {DEADLINE_SECONDS // 60} minutes",
              flush=True)
        demo.close()
        os._exit(1)

    watchdog = threading.Timer(DEADLINE_SECONDS, overdue)
    watchdog.daemon = True
    watchdog.start()
    try:
        a, b = Client("A", demo), Client("B", demo)
        steps = [lambda: step1(demo), lambda: step2(demo), lambda: step3(demo, a, b),
                 lambda: step4(demo, a), lambda: step5(demo, a), lambda: step6(demo, a, b),
                 lambda: step7(demo, a, b), lambda: step8(demo, a),
                 lambda: step9(demo, a, b), lambda: step10(demo, a), lambda: step11(demo, a, b)]
        for step_number, step in enumerate(steps, start=1):
            step()
        print("demo-r4: PASS", flush=True)
    except BaseException as error:  # noqa: BLE001
        traceback.print_exc()
        message = str(error).replace("\n", " ")[:400] or repr(error)
        print(f"demo-r4: FAIL step {step_number}: {message}", flush=True)
        sys.exit(1)
    finally:
        watchdog.cancel()
        demo.close()


if __name__ == "__main__":
    main()
