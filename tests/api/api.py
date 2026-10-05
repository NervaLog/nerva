#!/usr/bin/env python3
"""`nerva api` against a model (docs/DECISIONS.md N33).

Runs one replica and two API gateways, then:

- random transactions (reads at the version seen, sometimes stale; puts; deletes; sometimes a
  row written twice) through either gateway, each answer checked against an in-memory model:
  200 committed with an increasing op, 409 conflict with the stale entry and the row's version,
  400 for a row written twice; nothing applied unless committed;
- random lookups against the model;
- the change feed, paged with random limits, equal to the model's list of writes;
- every row's history, at random `op_max`, paged, equal to the model's;
- `/v1/row?as_of=` for random rows and ops, and a refusal for an op not yet committed;
- eight threads incrementing one counter with read-modify-write through both gateways,
  retrying on 409: no increment lost;
- layouts (N34): declaring, re-declaring, extending, refusing a change that does not append,
  two gateways declaring at once; puts by `fields`, read back as `fields` by lookup, the feed,
  history and `row`; reserved tables refused; catalog rows never in the feed;
- the gateway serves one request per connection and reads many at once: a client holding its
  connection open, one that connects and sends nothing, or one that sends a byte at a time does
  not hold up the next client (N37, N45);
- many idle connections do not hold up a request (#28); `start --trace` refuses an existing
  file (#29); after a cluster stall past the client's timeout the gateway reports itself
  unhealthy, then recovers on its own (#27);
- malformed request heads (a bare LF, folded lines, `Transfer-Encoding`, ...) answer 400 or are
  dropped, and the gateway serves the next request (N45);
- 401 without the key, 404 and 405.

Usage: api.py <path to nerva> [--seed=N] [--steps=N]
"""
import http.client, json, os, random, shutil, signal, socket, subprocess, sys, tempfile, threading, time

KEY = "api-test-key"
TABLES = (1, 2)
IDS = 12


def request(port, method, target, body=None, key=KEY):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    headers = {"X-Nerva-Key": key} if key else {}
    data = json.dumps(body) if body is not None else None
    if data is not None:
        headers["Content-Type"] = "application/json"
    connection.request(method, target, body=data, headers=headers)
    response = connection.getresponse()
    status, text = response.status, response.read().decode()
    connection.close()
    assert response.getheader("content-type") == "application/json", response.getheaders()
    return status, json.loads(text)


class Cluster:
    def __init__(self, nerva):
        self.nerva = nerva
        self.tmp = tempfile.mkdtemp(prefix="nerva-api-")
        self.processes = []
        data_file = os.path.join(self.tmp, "0_0.nerva")
        subprocess.run([nerva, "format", "--cluster=0", "--replica=0", "--replica-count=1",
                        "--development", data_file], check=True, capture_output=True)
        replica = self.spawn([nerva, "start", "--addresses=0", "--development", data_file])
        self.address = replica.stdout.readline().strip()
        self.ports = [self.gateway(), self.gateway()]

    def spawn(self, argv, env=None):
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=env, text=True)
        self.processes.append(process)
        return process

    def gateway(self):
        process = self.spawn([self.nerva, "api", "--cluster=0", f"--addresses={self.address}",
                              "--listen=127.0.0.1:0"], env={**os.environ, "NERVA_KEY": KEY})
        return int(process.stdout.readline())

    def close(self):
        for process in self.processes:
            process.kill()
            process.wait()
        shutil.rmtree(self.tmp, ignore_errors=True)


def pad(value):
    return value.hex().ljust(160, "0")


class Model:
    def __init__(self):
        self.rows = {}      # (table, id) -> (op, exists, value_hex)
        self.changes = []   # every applied write, in commit order
        self.ops = []       # every committed op, increasing

    def version(self, key):
        return self.rows.get(key, (0, False, "0" * 160))

    def expect(self, entries):
        """The expected answer: ("duplicate", index), ("conflict", index, op) or None."""
        written = set()
        for index, entry in enumerate(entries):
            key = (entry["table"], int(entry["id"]))
            if entry["kind"] != "read":
                if key in written:
                    return ("duplicate", index)
                written.add(key)
        for index, entry in enumerate(entries):
            if entry["kind"] == "read":
                op = self.version((entry["table"], int(entry["id"])))[0]
                if op != int(entry["op_seen"]):
                    return ("conflict", index, op)
        return None

    def apply(self, op, entries):
        assert not self.ops or op > self.ops[-1], (op, self.ops[-1:])
        self.ops.append(op)
        for entry in entries:
            key = (entry["table"], int(entry["id"]))
            if entry["kind"] == "put":
                value = entry["value_hex"].ljust(160, "0")
                self.rows[key] = (op, True, value)
                self.changes.append({"kind": "put", "table": key[0], "id": str(key[1]),
                                     "op": str(op), "value_hex": value})
            elif entry["kind"] == "delete" and self.version(key)[1]:
                self.rows[key] = (op, False, "0" * 160)
                self.changes.append({"kind": "delete", "table": key[0], "id": str(key[1]),
                                     "op": str(op)})

    def as_of(self, key, op):
        state = (0, False, "0" * 160)
        for change in self.changes:
            if (change["table"], int(change["id"])) == key and int(change["op"]) <= op:
                state = (int(change["op"]), change["kind"] == "put",
                         change.get("value_hex", "0" * 160))
        return state


def random_transaction(rng, model):
    entries = []
    for _ in range(rng.randint(1, 6)):
        table, row_id = rng.choice(TABLES), rng.randrange(IDS)
        kind = rng.choice(["read", "read", "put", "put", "delete"])
        if kind == "read":
            op = model.version((table, row_id))[0]
            if rng.random() < 0.15 and model.ops:
                op = rng.choice([0] + model.ops)
            entries.append({"kind": "read", "table": table, "id": str(row_id), "op_seen": str(op)})
        elif kind == "put":
            value = rng.randbytes(rng.randint(0, 80))
            entries.append({"kind": "put", "table": table, "id": str(row_id),
                            "value_hex": value.hex()})
        else:
            entries.append({"kind": "delete", "table": table, "id": str(row_id)})
    if rng.random() > 0.05:  # Usually no row written twice: that refuses the whole transaction.
        seen, kept = set(), []
        for entry in entries:
            key = (entry["table"], entry["id"])
            if entry["kind"] != "read" and key in seen:
                continue
            if entry["kind"] != "read":
                seen.add(key)
            kept.append(entry)
        entries = kept
    return entries


def check_commit(port, rng, model, counts):
    entries = random_transaction(rng, model)
    status, body = request(port, "POST", "/v1/commit", {"entries": entries})
    expected = model.expect(entries)
    if expected is None:
        assert status == 200 and body["status"] == "committed", (status, body, entries)
        model.apply(int(body["op"]), entries)
        counts["committed"] += 1
    elif expected[0] == "duplicate":
        assert status == 400 and body["index"] == expected[1], (status, body, expected)
        counts["duplicate"] += 1
    else:
        assert status == 409, (status, body, expected)
        assert body == {"status": "conflict", "index": expected[1], "op": str(expected[2])}, (
            body, expected)
        counts["conflict"] += 1


def check_lookup(port, rng, model):
    keys = [(rng.choice(TABLES), rng.randrange(IDS)) for _ in range(rng.randint(1, 8))]
    status, body = request(port, "POST", "/v1/lookup",
                           {"rows": [{"table": t, "id": str(i)} for t, i in keys]})
    assert status == 200, body
    assert not model.ops or int(body["op"]) > model.ops[-1]
    for key, row in zip(keys, body["rows"]):
        op, exists, value = model.version(key)
        assert row == {"table": key[0], "id": str(key[1]), "exists": exists, "op": str(op),
                       "value_hex": value}, (row, key, model.version(key))


def read_feed(port, rng):
    changes, cursor = [], "0"
    while True:
        status, body = request(port, "GET", f"/v1/changes?cursor={cursor}&limit={rng.randint(1, 9)}")
        assert status == 200, body
        changes += body["changes"]
        cursor = body["cursor"]
        if not body["more"]:
            assert body["op"] is not None
            return changes


def read_history(port, rng, key, op_max):
    changes, cursor = [], None
    while True:
        target = f"/v1/history?table={key[0]}&id={key[1]}&op_max={op_max}&limit={rng.randint(1, 5)}"
        if cursor is not None:
            target += f"&cursor={cursor}"
        status, body = request(port, "GET", target)
        assert status == 200, body
        changes += body["changes"]
        if not body["more"]:
            assert body["cursor"] is None
            return changes
        cursor = body["cursor"]


def counter_race(ports, threads=8, increments=15):
    errors, conflicts = [], [0]

    def worker(index):
        port = ports[index % 2]
        try:
            for _ in range(increments):
                while True:
                    status, body = request(port, "POST", "/v1/lookup",
                                           {"rows": [{"table": 9, "id": "1"}]})
                    row = body["rows"][0]
                    count = int.from_bytes(bytes.fromhex(row["value_hex"])[:8], "little")
                    status, body = request(port, "POST", "/v1/commit", {"entries": [
                        {"kind": "read", "table": 9, "id": "1", "op_seen": row["op"]},
                        {"kind": "put", "table": 9, "id": "1",
                         "value_hex": (count + 1).to_bytes(8, "little").hex()}]})
                    if status == 200:
                        break
                    assert status == 409, (status, body)
                    conflicts[0] += 1
        except Exception as error:  # Reported below.
            errors.append(repr(error))

    pool = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
    for thread in pool:
        thread.start()
    for thread in pool:
        thread.join()
    assert not errors, errors
    status, body = request(ports[0], "POST", "/v1/lookup", {"rows": [{"table": 9, "id": "1"}]})
    count = int.from_bytes(bytes.fromhex(body["rows"][0]["value_hex"])[:8], "little")
    assert count == threads * increments, (count, threads * increments)
    assert conflicts[0] > 0, "no conflicts: the retry path was not exercised"
    return conflicts[0]


SEATS = {"name": "seats", "fields": [{"name": "section", "type": "u8"},
                                     {"name": "price", "type": "u64"},
                                     {"name": "holder", "type": "bytes", "size": 8}]}


def check_layouts(ports):
    table = 5
    status, body = request(ports[0], "GET", "/v1/changes?limit=1024")
    while body["more"]:
        status, body = request(ports[0], "GET", f"/v1/changes?cursor={body['cursor']}&limit=1024")
    cursor = body["cursor"]

    # Two gateways declare at once: one creates it, the other finds it unchanged.
    results = [None, None]

    def declare(index):
        results[index] = request(ports[index], "PUT", f"/v1/tables/{table}", SEATS)

    pool = [threading.Thread(target=declare, args=(i,)) for i in range(2)]
    for thread in pool:
        thread.start()
    for thread in pool:
        thread.join()
    outcomes = sorted(body["layout"] for status, body in results)
    assert [status for status, _ in results] == [200, 200], results
    assert outcomes == ["created", "unchanged"], outcomes
    status, body = request(ports[1], "GET", f"/v1/tables/{table}")
    assert (status, body) == (200, SEATS), (status, body)

    extended = {"name": "seats", "fields": SEATS["fields"] + [{"name": "row", "type": "u16"}]}
    assert request(ports[0], "PUT", f"/v1/tables/{table}", extended)[1]["layout"] == "extended"
    assert request(ports[1], "PUT", f"/v1/tables/{table}", SEATS)[0] == 409
    assert request(ports[0], "PUT", f"/v1/tables/{table}",
                   {"name": "x", "fields": [{"name": "price", "type": "u32"}]})[0] == 409
    assert request(ports[0], "PUT", "/v1/tables/4294901761", SEATS)[0] == 400
    assert request(ports[0], "GET", "/v1/tables/6")[0] == 404

    fields = {"section": 3, "price": "18446744073709551615", "holder": "00112233", "row": 12}
    status, body = request(ports[0], "POST", "/v1/commit", {"entries": [
        {"kind": "put", "table": table, "id": "1", "fields": fields}]})
    assert status == 200, body
    op = body["op"]
    expected = {**fields, "holder": "0011223300000000"}
    status, body = request(ports[1], "POST", "/v1/lookup", {"rows": [{"table": table, "id": "1"}]})
    assert body["rows"][0]["fields"] == expected, body
    status, body = request(ports[1], "GET", f"/v1/history?table={table}&id=1&limit=5")
    assert [c["fields"] for c in body["changes"]] == [expected], body
    status, body = request(ports[0], "GET", f"/v1/row?table={table}&id=1&as_of={op}")
    assert body["fields"] == expected, body
    for bad in ({"price": -1}, {"nope": 1}, {"section": 256}):
        status, body = request(ports[0], "POST", "/v1/commit", {"entries": [
            {"kind": "put", "table": table, "id": "2", "fields": bad}]})
        assert status == 400, (bad, status, body)
    assert request(ports[0], "POST", "/v1/commit", {"entries": [
        {"kind": "put", "table": 6, "id": "1", "fields": {}}]})[0] == 400

    # The feed since the layouts were declared: the one put, with fields; no catalog rows.
    status, body = request(ports[0], "GET", f"/v1/changes?cursor={cursor}&limit=1024")
    assert [(c["table"], c["fields"]) for c in body["changes"]] == [(table, expected)], body


def check_connections(port):
    # A client that keeps its connection: the server closes it after one reply, so the next
    # client is served at once.
    held = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    held.request("POST", "/v1/lookup", body=json.dumps({"rows": [{"table": 1, "id": "0"}]}),
                 headers={"X-Nerva-Key": KEY})
    response = held.getresponse()
    assert response.status == 200 and response.getheader("connection") == "close"
    response.read()
    started = time.monotonic()
    assert request(port, "POST", "/v1/lookup", {"rows": [{"table": 1, "id": "0"}]})[0] == 200
    assert time.monotonic() - started < 2, "a held connection held up the next client"
    held.close()

    # A client that connects and sends nothing holds up nobody (N45).
    silent = socket.create_connection(("127.0.0.1", port))
    started = time.monotonic()
    assert request(port, "POST", "/v1/lookup", {"rows": [{"table": 1, "id": "0"}]})[0] == 200
    waited = time.monotonic() - started
    assert waited < 2, f"a silent connection held up the next client for {waited:.1f} s"

    # Nor does one that sends a byte at a time: the deadline is for the whole request (N45).
    drip = socket.create_connection(("127.0.0.1", port))
    drip.sendall(b"GET /healthz HTTP/1.1\r\n")
    started = time.monotonic()
    for _ in range(6):
        drip.sendall(b"x")
        before = time.monotonic()
        assert request(port, "POST", "/v1/lookup", {"rows": [{"table": 1, "id": "0"}]})[0] == 200
        assert time.monotonic() - before < 2, "a dripping connection held up the next client"
        time.sleep(2)
    # It is closed at the deadline, 10 s after it connected, though it kept sending.
    drip.settimeout(5)
    try:
        closed = drip.recv(1) == b""
    except ConnectionResetError:
        closed = True
    assert closed and time.monotonic() - started < 16, "a dripping connection outlived the deadline"
    drip.close()
    silent.close()


MALFORMED = [
    b"POST /v1/lookupaa HTTP/1.1\r\n\n\r\n",  # A bare LF ends the head (issue #8).
    b"GET /healthz HTTP/1.1\n\n",
    b"GET /healthz HTTP/1.1\r\nA: b\rc\r\n\r\n",
    b"GET /healthz HTTP/1.1\r\nA: b\x00c\r\n\r\n",
    b"GET /healthz HTTP/1.1\r\nA: b\r\n folded\r\n\r\n",
    b"GET /healthz HTTP/1.1\r\nno colon\r\n\r\n",
    b"POST /v1/lookup HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
    b"POST /v1/lookup HTTP/1.1\r\nContent-Length: +2\r\n\r\n{}",
    b"POST /v1/lookup HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n",
    b"GET /healthz HTTP/1.1\r\nX-Nerva-Key: a\r\nX-Nerva-Key: b\r\n\r\n",
    b"GET /healthz HTTP/2.0\r\n\r\n",
    b"GET /healthz HTTP/1.1\r\nA: " + b"a" * 20000 + b"\r\n\r\n",
    b"POST /v1/lookup HTTP/1.1\r\nContent-Length: 4294967295\r\n\r\n",
]


def check_malformed(port):
    # Each is refused with 400 (or the connection is dropped), and the gateway still serves.
    for raw in MALFORMED:
        connection = socket.create_connection(("127.0.0.1", port), timeout=10)
        try:
            connection.sendall(raw)
            reply = connection.recv(4096)
        except (ConnectionResetError, BrokenPipeError):
            reply = b""
        finally:
            connection.close()
        assert reply == b"" or reply.startswith(b"HTTP/1.1 400 "), (raw[:60], reply)
        assert request(port, "GET", "/healthz", key=None)[0] == 200, raw[:60]


def check_multiline_body(port):
    # A pretty-printed body sent in one write with its head, as `curl -d` sends it, is served
    # (#36; it was refused as a bare LF in the head).
    body = b'{"rows":[\n  {"table":1,"id":"42"}\n]}\n'
    head = (b"POST /v1/lookup HTTP/1.1\r\nX-Nerva-Key: " + KEY.encode() +
            b"\r\nContent-Length: %d\r\n\r\n" % len(body))
    connection = socket.create_connection(("127.0.0.1", port), timeout=30)
    try:
        connection.sendall(head + body)
        reply = b""
        while chunk := connection.recv(4096):
            reply += chunk
    finally:
        connection.close()
    assert reply.startswith(b"HTTP/1.1 200 "), reply[:200]
    assert b'"id":"42"' in reply, reply[:400]


def check_idle_flood(port):
    # Idle connections cannot lock others out: with every slot busy, a new connection displaces
    # the oldest one still sending its request (#28; it took 85 s before).
    idle = []
    for _ in range(200):
        try:
            idle.append(socket.create_connection(("127.0.0.1", port), timeout=5))
        except OSError:
            break
    started = time.monotonic()
    assert request(port, "GET", "/healthz", key=None)[0] == 200
    waited = time.monotonic() - started
    for connection in idle:
        connection.close()
    assert waited < 3, f"{len(idle)} idle connections held /healthz up for {waited:.1f} s"


def check_trace_refuses_existing(nerva, tmp):
    # `--trace` never truncates an existing file, such as a data file named by mistake (#29).
    victim = os.path.join(tmp, "existing.bin")
    with open(victim, "wb") as f:
        f.write(b"x" * 100_000)
    result = subprocess.run([nerva, "start", "--addresses=0", "--development", f"--trace={victim}",
                             os.path.join(tmp, "0_0.nerva")], stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=60)
    assert result.returncode != 0, "start --trace=<existing file> did not refuse"
    with open(victim, "rb") as f:
        assert f.read() == b"x" * 100_000, "start --trace=<existing file> changed the file"


def check_stall_recovery(cluster, port):
    # A cluster stall past the client's timeout (30 s) breaks the gateway's client; the gateway
    # replaces it once the cluster is back, and /healthz says so meanwhile (#27). It recovers
    # with only /healthz polled, as a load balancer would, and no request for the cluster (#44).
    replica = cluster.processes[0]
    replica.send_signal(signal.SIGSTOP)
    try:
        status, body = request(port, "POST", "/v1/lookup", {"rows": [{"table": 1, "id": "0"}]})
        assert status == 503, (status, body)
        assert request(port, "GET", "/healthz", key=None)[0] == 503
    finally:
        replica.send_signal(signal.SIGCONT)
    deadline = time.monotonic() + 120
    while request(port, "GET", "/healthz", key=None)[0] != 200:
        assert time.monotonic() < deadline, "/healthz did not recover after the cluster did"
        time.sleep(1)
    status, body = request(port, "POST", "/v1/lookup", {"rows": [{"table": 1, "id": "0"}]})
    assert status == 200, (status, body)


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    steps = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--steps=")), 600)
    rng = random.Random(seed)
    cluster = Cluster(nerva)
    try:
        ports = cluster.ports
        model = Model()
        counts = {"committed": 0, "conflict": 0, "duplicate": 0}
        for _ in range(steps):
            port = rng.choice(ports)
            if rng.random() < 0.7:
                check_commit(port, rng, model, counts)
            else:
                check_lookup(port, rng, model)
        # A row written twice is refused whole, at the second write, whatever the dice did.
        twice = [{"kind": "put", "table": 1, "id": "0", "value_hex": "01"},
                 {"kind": "delete", "table": 2, "id": "0"},
                 {"kind": "delete", "table": 1, "id": "0"}]
        status, body = request(ports[0], "POST", "/v1/commit", {"entries": twice})
        assert status == 400 and body["index"] == 2, (status, body)
        assert counts["committed"] > 0 and counts["conflict"] > 0, counts

        feed = read_feed(rng.choice(ports), rng)
        assert feed == model.changes, (len(feed), len(model.changes))

        keys = sorted({(c["table"], int(c["id"])) for c in model.changes})
        as_of_reads = 0
        for key in keys:
            op_max = rng.choice(model.ops + ["latest"])
            bound = model.ops[-1] if op_max == "latest" else op_max
            expected = [c for c in model.changes
                        if (c["table"], int(c["id"])) == key and int(c["op"]) <= bound][::-1]
            assert read_history(rng.choice(ports), rng, key, op_max) == expected, key
            for op in rng.sample(model.ops, min(5, len(model.ops))):
                status, body = request(rng.choice(ports), "GET",
                                       f"/v1/row?table={key[0]}&id={key[1]}&as_of={op}")
                assert status == 200, body
                version, exists, value = model.as_of(key, op)
                assert body == {"table": key[0], "id": str(key[1]), "as_of": str(op),
                                "exists": exists, "op": str(version), "value_hex": value}, (
                    body, key, op)
                as_of_reads += 1
        status, body = request(ports[0], "GET", f"/v1/row?table=1&id=0&as_of={10**15}")
        assert status == 400 and "not yet committed" in body["error"], body

        conflicts = counter_race(ports)
        check_connections(ports[0])
        check_malformed(ports[0])
        check_multiline_body(ports[0])
        check_idle_flood(ports[0])
        check_trace_refuses_existing(nerva, cluster.tmp)
        check_stall_recovery(cluster, ports[1])
        check_layouts(ports)

        assert request(ports[0], "POST", "/v1/lookup", {"rows": []}, key=None)[0] == 401
        assert request(ports[0], "POST", "/v1/lookup", {"rows": []}, key="wrong")[0] == 401
        assert request(ports[0], "GET", "/v1/nothing")[0] == 404
        assert request(ports[0], "GET", "/v1/commit")[0] == 405

        print(f"api: PASSED ({steps} steps: {counts}; feed of {len(feed)} changes; "
              f"{len(keys)} histories; {as_of_reads} as-of reads; counter race with "
              f"{conflicts} conflicts retried; seed {seed})")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
