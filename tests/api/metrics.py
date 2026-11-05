#!/usr/bin/env python3
"""A gateway's statsd metrics against what a client saw (R4 slice 4, P168e).

Runs one replica and one gateway with `--statsd` to this script's UDP listener, then makes one
request of each kind: commits that answer 200 and 409, a group of waiting commits, 503 busy
(sixteen connections that have sent bytes and one more), 408 (a drip), and a commit in flight
when the replica stops (`"unknown"`, then a reconnect). Every counter shows in the listener's
lines within 25 s of the last event, and `nerva.api.refused{reason:busy}`, summed over windows,
equals the busy replies the script read. A second gateway whose `--statsd` has nothing listening
must stay alive through all of it: its refused packets are dropped, never a panic (M1).

Usage: metrics.py <path to nerva>
"""
import json, os, signal, socket, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from api import Cluster, request  # noqa: E402

BUSY_ATTEMPTS = 3
DRIPPERS = 16
GROUP = 8


class Listener:
    """Collects a gateway's lines: counters summed over windows, gauges as the last and greatest."""

    def __init__(self):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.settimeout(0.2)
        self.port = self.socket.getsockname()[1]
        self.lock = threading.Lock()
        self.sums = {}      # (name, tags) -> total of a counter
        self.gauges = {}    # (name, tags) -> (last, greatest)
        self.packets = []   # sizes
        self.stop = threading.Event()
        self.failure = None  # why the listener thread stopped, if it did
        self.thread = threading.Thread(target=self.run)
        self.thread.start()

    def run(self):
        try:
            while not self.stop.is_set():
                try:
                    data = self.socket.recv(65535)
                except socket.timeout:
                    continue
                with self.lock:
                    self.packets.append(len(data))
                    for line in data.decode().split("\n"):
                        self.add(line)
        except Exception as error:  # noqa: BLE001
            # A line the script cannot read is a failure of the test, with its own message.
            self.failure = f"the listener could not read a packet: {error!r}"

    def check(self):
        if self.failure:
            raise AssertionError(self.failure)

    def add(self, line):
        head, kind, tags = line.split("|")
        name, value = head.rsplit(":", 1)
        assert tags.startswith("#cluster:"), line
        pairs = dict(pair.split(":", 1) for pair in tags[1:].split(","))
        assert "listen" in pairs, line
        key = (name, tuple(sorted((k, v) for k, v in pairs.items() if k not in ("cluster", "listen"))))
        value = int(value)
        if kind == "c":
            self.sums[key] = self.sums.get(key, 0) + value
        else:
            assert kind == "g", line
            self.gauges[key] = (value, max(value, self.gauges.get(key, (0, 0))[1]))

    def total(self, name, **tags):
        """The counter's sum over every series that has these tags."""
        with self.lock:
            return sum(v for (n, t), v in self.sums.items()
                       if n == name and all((k, x) in t for k, x in tags.items()))

    def gauge(self, name, **tags):
        with self.lock:
            return self.gauges.get((name, tuple(sorted(tags.items()))))

    def wait_for(self, what, test, seconds=25):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.check()
            if test():
                return
            time.sleep(0.25)
        self.check()
        with self.lock:
            seen = sorted(self.sums.items())
        raise AssertionError(f"not seen within {seconds} s: {what}; counters {seen}")

    def close(self):
        self.stop.set()
        self.thread.join()
        self.socket.close()


def raw(port, data, read=True):
    connection = socket.create_connection(("127.0.0.1", port), timeout=30)
    connection.sendall(data)
    if not read:
        return connection
    reply = b""
    while chunk := connection.recv(4096):
        reply += chunk
    connection.close()
    status = int(reply.split(b" ", 2)[1])
    return status, json.loads(reply.split(b"\r\n\r\n", 1)[1])


def commit(port, entries, key=None):
    body = {"entries": entries}
    if key:
        body["key"] = key
    return request(port, "POST", "/v1/commit", body)


def put(row, value="01"):
    return {"kind": "put", "table": 1, "id": str(row), "value_hex": value}


def main():
    nerva = sys.argv[1]
    listener = Listener()
    cluster = Cluster(nerva)
    try:
        port = cluster.gateway(args=[f"--statsd=127.0.0.1:{listener.port}", "--request-timeout=1000"])
        replica = cluster.processes[0]
        # A collector that is not there: bound, then closed.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as closed:
            closed.bind(("127.0.0.1", 0))
            closed_port = closed.getsockname()[1]
        mute_port = cluster.gateway(args=[f"--statsd=127.0.0.1:{closed_port}"])
        mute = cluster.processes[-1]

        # 200 and 409.
        status, body = commit(port, [put(1)])
        assert status == 200, (status, body)
        status, body = commit(port, [{"kind": "read", "table": 1, "id": "1", "op_seen": "1"}, put(2)])
        assert status == 409, (status, body)
        assert request(port, "GET", "/healthz", key=None)[0] == 200

        # Commits waiting together are answered with one cluster request.
        errors = []

        together = threading.Barrier(16, timeout=60)

        def burst(index):
            try:
                for round_ in range(30):
                    together.wait()
                    status, body = commit(port, [put(1000 + index * 100 + round_)])
                    assert status == 200, (status, body)
            except Exception as error:  # noqa: BLE001
                errors.append(repr(error))

        threads = [threading.Thread(target=burst, args=(i,)) for i in range(16)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        assert not errors, errors[:3]

        # 503 busy: sixteen connections have sent bytes, so a newcomer is refused.
        held = [raw(port, b"GET /healthz HTTP/1.1\r\n", read=False) for _ in range(DRIPPERS)]
        time.sleep(0.3)
        busy_seen = 0
        for _ in range(BUSY_ATTEMPTS):
            status, body = raw(port, b"GET /healthz HTTP/1.1\r\nconnection: close\r\n\r\n")
            assert status == 503 and body["code"] == "NRV-E0602" and body["applied"] is False, (status, body)
            busy_seen += 1
        for connection in held:
            connection.close()

        # 408: a head that never ends, answered at the deadline (10 s), in the background.
        drip_reply = []

        def drip():
            connection = raw(port, b"GET /healthz HTTP/1.1\r\n", read=False)
            reply = b""
            while chunk := connection.recv(4096):
                reply += chunk
            drip_reply.append(reply)

        dripper = threading.Thread(target=drip)
        dripper.start()

        # A commit in flight when the replica stops: "unknown", E0601, then a new session.
        time.sleep(0.5)
        status, body = commit(port, [put(5)])
        assert status == 200, (status, body)
        replica.send_signal(signal.SIGSTOP)
        try:
            status, body = commit(port, [put(6)], key="1" * 32)
            assert status == 503 and body["code"] == "NRV-E0601" and body["applied"] == "unknown", (status, body)
        finally:
            replica.send_signal(signal.SIGCONT)
        started = time.monotonic()
        while request(port, "GET", "/healthz", key=None)[0] != 200:
            assert time.monotonic() - started < 15, "the gateway did not recover"
            time.sleep(0.25)
        status, body = commit(port, [put(6)], key="1" * 32)
        assert status == 200, (status, body)
        dripper.join()
        assert drip_reply and drip_reply[0].startswith(b"HTTP/1.1 408 "), drip_reply

        # Everything shows within 25 s of the last event (a window is 10 s).
        def counter(name, **tags):
            return lambda: listener.total(name, **tags) >= 1

        listener.wait_for("requests commit 200", counter("nerva.api.requests", route="commit", status="200"))
        listener.wait_for("requests commit 409", counter("nerva.api.requests", route="commit", status="409"))
        listener.wait_for("requests healthz 200", counter("nerva.api.requests", route="healthz", status="200"))
        listener.wait_for("requests other 503", counter("nerva.api.requests", route="other", status="503"))
        listener.wait_for("requests other 408", counter("nerva.api.requests", route="other", status="408"))
        listener.wait_for("requests commit 503", counter("nerva.api.requests", route="commit", status="503"))
        listener.wait_for("refused deadline", counter("nerva.api.refused", reason="deadline"))
        listener.wait_for("unknown commit", counter("nerva.api.unknown", route="commit"))
        listener.wait_for("reconnect ok", counter("nerva.api.reconnects", result="ok"))
        listener.wait_for("cluster_request_us commit",
                          counter("nerva.api.cluster_request_us.count", operation="commit"))
        listener.wait_for("queue_wait_us", counter("nerva.api.queue_wait_us.count"))
        listener.wait_for("busy replies", lambda: listener.total("nerva.api.refused", reason="busy") >= busy_seen)

        # A group: one cluster request answered several waiting requests.
        assert listener.total("nerva.api.group_size.count") > 0
        greatest = listener.gauge("nerva.api.group_size.max")
        assert greatest is not None and greatest[1] >= GROUP, f"no group of {GROUP}: {greatest}"
        # Sum of group sizes is at least as large as its count.
        assert listener.total("nerva.api.group_size.sum") >= listener.total("nerva.api.group_size.count")

        # Gauges: the session is back, and sixteen connections were in use at once.
        listener.wait_for("session 1", lambda: listener.gauge("nerva.api.session") is not None
                          and listener.gauge("nerva.api.session")[0] == 1)
        connections = listener.gauge("nerva.api.connections")
        assert connections is not None and connections[1] >= DRIPPERS, connections
        listener.check()

        # Round trips timed before a reconnect that fails are still reported (review of #176):
        # the replica stays stopped past the reconnect interval (5 s), so the first attempt to
        # replace the session fails, and the samples taken before it are not lost with the client.
        time.sleep(11)
        samples = lambda: listener.total("nerva.api.cluster_request_us.count", operation="commit")  # noqa: E731
        failed_before = listener.total("nerva.api.reconnects", result="failed")
        samples_before = samples()
        status, body = commit(port, [put(7)])
        assert status == 200, (status, body)
        replica.send_signal(signal.SIGSTOP)
        try:
            status, body = commit(port, [put(8)], key="2" * 32)
            assert status == 503 and body["code"] == "NRV-E0601", (status, body)
            listener.wait_for("a failed reconnect",
                              lambda: listener.total("nerva.api.reconnects", result="failed")
                              > failed_before, seconds=40)
        finally:
            replica.send_signal(signal.SIGCONT)
        started = time.monotonic()
        while request(port, "GET", "/healthz", key=None)[0] != 200:
            assert time.monotonic() - started < 30, "the gateway did not recover"
            time.sleep(0.25)
        listener.wait_for("both round trips timed, across the failed reconnect",
                          lambda: samples() - samples_before >= 2)

        # A window later nothing more was refused busy: the sum equals what the script read.
        time.sleep(11)
        assert listener.total("nerva.api.refused", reason="busy") == busy_seen, (
            listener.total("nerva.api.refused", reason="busy"), busy_seen)
        assert listener.total("nerva.api.refused", reason="displaced") == 0
        assert listener.total("nerva.api.refused", reason="queue_wait") == 0
        # Several windows of refused sends later the mute gateway still serves.
        assert mute.poll() is None, f"the gateway with no collector exited {mute.poll()}"
        assert request(mute_port, "GET", "/healthz", key=None)[0] in (200, 503)
        with listener.lock:
            assert listener.packets and max(listener.packets) <= 1400, listener.packets
        print(f"metrics: {busy_seen} busy replies counted, "
              f"{listener.total('nerva.api.requests')} requests, "
              f"{listener.total('nerva.api.group_size.count')} cluster requests grouped, "
              f"largest group {greatest[1]}")
    finally:
        listener.close()
        cluster.close()


if __name__ == "__main__":
    main()
