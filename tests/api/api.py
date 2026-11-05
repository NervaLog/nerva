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
- sixteen clients firing commits and lookups at one gateway at once, so that it answers several
  with one cluster request (P143): each checks its own rows exactly (committed, conflict, 400,
  commit keys resent and reused), and all add to one counter, whose answers are 1 to N each once;
- layouts (N34): declaring, re-declaring, extending, refusing a change that does not append,
  two gateways declaring at once; puts by `fields`, read back as `fields` by lookup, the feed,
  history and `row`; reserved tables refused; catalog rows never in the feed;
- the gateway serves one request per connection and reads many at once: a client holding its
  connection open, one that connects and sends nothing, or one that sends a byte at a time does
  not hold up the next client (N37, N45);
- a connection is never closed without a status line: one that drips is answered 408 at the
  deadline (NRV-E0116); with sixteen requests half sent, a seventeenth reads 503 busy (NRV-E0602,
  "applied": false) and none of the sixteen is cut (#120), nor is a refused client's reply lost
  while it sends a body; a second gateway on a running gateway's port exits with NRV-E0007
  (#112);
- many idle connections do not hold up a request (#28); `start --trace` refuses an existing
  file (#29); after a cluster stall past the client's timeout the gateway reports itself
  unhealthy, then recovers on its own (#27);
- malformed request heads (a bare LF, folded lines, `Transfer-Encoding`, ...) answer 400 or are
  dropped, and the gateway serves the next request (N45);
- a 4 MiB body of nested or long arrays to answer 413 and leave the gateway's memory near
  where it was (#31), and the largest valid `documents/get` (256 keys of 64 KiB) to answer 200
  (#60);
- `--trace` to stop at `--trace-size-max` with the replica still serving (#30);
- 401 without the key, 404 and 405;
- a gateway given `NERVA_KEY` and `NERVA_KEY_NEXT` accepts either and answers 401 to any other
  key; a `NERVA_KEY_NEXT` that is empty or equals `NERVA_KEY` is refused at start, without
  printing a key (P96).

Usage: api.py <path to nerva> [--seed=N] [--steps=N]
"""
import http.client, json, os, random, select, shutil, signal, socket, subprocess, sys, tempfile, threading, time

# Replicas authenticate each other with a real cluster key, never the development key (P102).
os.environ["NERVA_CLUSTER_KEY"] = os.urandom(32).hex()

KEY = "api-test-key"
KEY_NEXT = "api-test-key-next"
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

    def gateway(self, env=None):
        env = env if env is not None else {"NERVA_KEY": KEY}
        process = self.spawn([self.nerva, "api", "--cluster=0", f"--addresses={self.address}",
                              "--listen=127.0.0.1:0"], env={**os.environ, **env})
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


def check_coalesced(port, threads=16, rounds=14):
    """Many clients at one gateway, which answers those waiting together with one cluster
    request (P143). Each client owns its rows, so its model is exact whatever the interleaving;
    the shared counter is the only place the clients meet."""
    errors, counter_values, ops = [], [], []
    lock = threading.Lock()
    zero = "0" * 160
    counter_key = {"table": 8, "id": "2"}

    def worker(index):
        try:
            base = 100 * index
            rows = [base, base + 1, base + 2]   # Ids in table 3.
            state = {row: (0, False, zero) for row in rows}
            mine = []
            for round_ in range(rounds):
                status, body = request(port, "POST", "/v1/lookup", {"rows": [
                    {"table": 3, "id": str(row)} for row in rows]})
                assert status == 200, body
                for row, found in zip(rows, body["rows"]):
                    op, exists, value = state[row]
                    assert found == {"table": 3, "id": str(row), "exists": exists, "op": str(op),
                                     "value_hex": value}, (found, state[row])

                # A read at the version seen, and two writes.
                value = bytes([index, round_]).hex()
                entries = [
                    {"kind": "read", "table": 3, "id": str(rows[0]), "op_seen": str(state[rows[0]][0])},
                    {"kind": "put", "table": 3, "id": str(rows[0]), "value_hex": value},
                    {"kind": "put", "table": 3, "id": str(rows[1]), "value_hex": value}]
                status, body = request(port, "POST", "/v1/commit", {"entries": entries})
                assert status == 200 and body["status"] == "committed", (status, body)
                op = int(body["op"])
                mine.append(op)
                for row in rows[:2]:
                    state[row] = (op, True, value.ljust(160, "0"))

                # A stale read: conflict at index 0, with the row's version.
                stale = {"kind": "read", "table": 3, "id": str(rows[0]), "op_seen": "1"}
                status, body = request(port, "POST", "/v1/commit", {"entries": [
                    stale, {"kind": "put", "table": 3, "id": str(rows[2]), "value_hex": "ff"}]})
                assert status == 409 and body == {
                    "status": "conflict", "index": 0, "op": str(state[rows[0]][0])}, (status, body)

                # Refused as it would alone.
                status, body = request(port, "POST", "/v1/commit", {"entries": [
                    {"kind": "delete", "table": 3, "id": str(rows[2]), "value_hex": "00"}]})
                assert status == 400, (status, body)

                # A key: committed once, the same request again replayed at the same op, other
                # entries under it refused with that op.
                key = bytes([index + 1, round_ + 1]).hex().ljust(32, "0")
                keyed = {"key": key, "entries": [
                    {"kind": "put", "table": 3, "id": str(rows[2]), "value_hex": value}]}
                status, body = request(port, "POST", "/v1/commit", keyed)
                assert status == 200 and body["status"] == "committed", (status, body)
                op_keyed = int(body["op"])
                mine.append(op_keyed)
                state[rows[2]] = (op_keyed, True, value.ljust(160, "0"))
                status, body = request(port, "POST", "/v1/commit", keyed)
                assert (status, body) == (200, {
                    "status": "committed", "op": str(op_keyed), "replayed": True}), (status, body)
                other = {"key": key, "entries": [
                    {"kind": "put", "table": 3, "id": str(rows[2]), "value_hex": "aa"}]}
                status, body = request(port, "POST", "/v1/commit", other)
                assert (status, body) == (409, {
                    "status": "key_reused", "op": str(op_keyed)}), (status, body)

                # The meeting place: add one to the counter.
                status, body = request(port, "POST", "/v1/commit", {"entries": [
                    {"kind": "add", **counter_key, "offset": 0, "type": "u64", "delta": "1",
                     "create": True}]})
                assert status == 200 and body["status"] == "committed", (status, body)
                (added,) = body["adds"]
                assert added["applied"] == "1", added
                mine.append(int(body["op"]))
                with lock:
                    counter_values.append(int(added["value"]))
            with lock:
                ops.extend(mine)
        except Exception as error:  # Reported below.
            errors.append(repr(error))

    pool = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
    for thread in pool:
        thread.start()
    for thread in pool:
        thread.join()
    assert not errors, errors
    total = threads * rounds
    assert sorted(counter_values) == list(range(1, total + 1)), sorted(counter_values)
    status, body = request(port, "POST", "/v1/lookup", {"rows": [
        {"table": 8, "id": counter_key["id"]}]})
    assert int.from_bytes(bytes.fromhex(body["rows"][0]["value_hex"])[:8], "little") == total
    # Some were answered together: more than one committed request at one op.
    together = len(ops) - len(set(ops))
    assert together > 0, "no two requests committed at one op: nothing was combined"
    return together


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
    reply = b""
    while True:
        drip.sendall(b"x")
        before = time.monotonic()
        assert request(port, "POST", "/v1/lookup", {"rows": [{"table": 1, "id": "0"}]})[0] == 200
        assert time.monotonic() - before < 2, "a dripping connection held up the next client"
        assert time.monotonic() - started < 16, "a dripping connection outlived the deadline"
        # It is answered 408 at the deadline, 10 s after it connected, though it kept sending:
        # never closed without a status line (NRV-E0116).
        if select.select([drip], [], [], 2)[0]:
            while chunk := drip.recv(4096):
                reply += chunk
            break
    assert 9 < time.monotonic() - started < 16, "the drip was answered at the wrong time"
    assert reply.startswith(b"HTTP/1.1 408 "), reply
    body = json.loads(reply.split(b"\r\n\r\n", 1)[1])
    assert body["code"] == "NRV-E0116" and body["applied"] is False, body
    drip.close()
    silent.close()


def check_busy(nerva, cluster, port):
    # Issue #120: sixteen clients have sent the start of a request each, and a seventeenth asks
    # for /healthz. The seventeenth reads 503 busy, "applied": false, NRV-E0602, at once; none
    # of the sixteen is cut: all finish and are answered.
    partial = []
    for _ in range(16):
        connection = socket.create_connection(("127.0.0.1", port))
        connection.sendall(b"GET /healthz HTTP/1.1\r\n")
        partial.append(connection)
    time.sleep(0.2)
    started = time.monotonic()
    status, body = request(port, "GET", "/healthz", key=None)
    assert status == 503, (status, body)
    assert body == {"error": "busy", "applied": False, "code": "NRV-E0602"}, body
    assert time.monotonic() - started < 1, "the busy reply was not immediate"
    for connection in partial:
        connection.sendall(b"\r\n")
    for connection in partial:
        connection.settimeout(10)
        reply = b""
        while chunk := connection.recv(4096):
            reply += chunk
        assert reply.startswith(b"HTTP/1.1 200 "), reply
        connection.close()

    # A refused client that is still sending a body reads its 503 (lingering close).
    partial = []
    for _ in range(16):
        connection = socket.create_connection(("127.0.0.1", port))
        connection.sendall(b"GET /healthz HTTP/1.1\r\n")
        partial.append(connection)
    time.sleep(0.2)
    refused = socket.create_connection(("127.0.0.1", port))
    head = b"POST /v1/commit HTTP/1.1\r\nContent-Length: 60000\r\n\r\n"
    refused.sendall(head + b"x" * (64 * 1024 - len(head)))
    refused.settimeout(10)
    reply = b""
    while chunk := refused.recv(4096):
        reply += chunk
    assert reply.startswith(b"HTTP/1.1 503 ") and b"NRV-E0602" in reply, reply
    refused.close()
    for connection in partial:
        connection.close()

    # A second gateway on a running gateway's port does not bind silently and share its
    # connections (#112): it exits with NRV-E0007, and the first still answers.
    second = subprocess.run(
        [nerva, "api", "--cluster=0", f"--addresses={cluster.address}",
         f"--listen=127.0.0.1:{port}"],
        env={**os.environ, "NERVA_KEY": KEY}, capture_output=True, text=True, timeout=60)
    assert second.returncode == 1 and "NRV-E0007" in second.stderr, (second.returncode,
                                                                    second.stderr)
    assert request(port, "GET", "/healthz", key=None)[0] == 200


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


def rss_mib(pid):
    with open(f"/proc/{pid}/status") as status:
        for line in status:
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) // 1024
    raise AssertionError("no VmRSS")


def check_request_memory(cluster):
    # A 4 MiB body of nested or long arrays answers 413 rather than growing the gateway, and the
    # gateway gives back what it took (#31: such bodies used to pin 0.5 to 0.8 GB for good).
    port, pid = cluster.ports[0], cluster.processes[1].pid
    baseline = rss_mib(pid)
    depth = 2 * 1024 * 1024 - 64
    bodies = {
        "nested arrays": "[" * depth + "]" * depth,
        "a long array": "[" + "0," * (depth - 1) + "0]",
    }
    for name, fields in bodies.items():
        body = ('{"entries":[{"kind":"put","table":1,"id":"1","fields":' + fields + '}]}').encode()
        assert len(body) <= 4 * 1024 * 1024, len(body)
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        connection.request("POST", "/v1/commit", body=body,
                           headers={"X-Nerva-Key": KEY, "Content-Type": "application/json"})
        response = connection.getresponse()
        text = response.read().decode()
        connection.close()
        assert response.status == 413 and "too complex" in text, (name, response.status, text)
        # Given back just after the reply is written (#60).
        deadline = time.monotonic() + 5
        while (after := rss_mib(pid)) >= baseline + 100 and time.monotonic() < deadline:
            time.sleep(0.1)
        assert after < baseline + 100, f"{name}: RSS {baseline} MiB before, {after} MiB after"
    assert request(port, "GET", "/healthz", key=None)[0] == 200
    return baseline, rss_mib(pid)


def check_documents_get_max(port):
    # The largest valid `documents/get` (`keys_max` keys of 64 KiB) is answered (#60: the
    # request budget refused it).
    value = "ab" * (64 * 1024)
    keys = [f"max-{i:03}" for i in range(256)]
    for start in range(0, len(keys), 8):
        writes = [{"key": key, "value_hex": value} for key in keys[start:start + 8]]
        status, body = request(port, "POST", "/v1/documents/commit",
                               {"namespace": "60", "reads": [], "writes": writes})
        assert status == 200, (status, body)
    status, body = request(port, "POST", "/v1/documents/get", {"namespace": "60", "keys": keys})
    assert status == 200, (status, body)
    assert all(d["value_hex"] == value for d in body["documents"]), "a document differs"


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


def check_trace_bounded(nerva, tmp):
    # `--trace` stops at `--trace-size-max` and the replica runs on (#30; it used to grow
    # without bound, and to panic when a write failed).
    data_file = os.path.join(tmp, "traced.nerva")
    trace = os.path.join(tmp, "traced.json")
    subprocess.run([nerva, "format", "--cluster=0", "--replica=0", "--replica-count=1",
                    "--development", data_file], check=True, capture_output=True)
    log = open(os.path.join(tmp, "traced.log"), "w+")
    replica = subprocess.Popen([nerva, "start", "--addresses=0", "--development",
                                f"--trace={trace}", "--trace-size-max=64KiB", data_file],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                               text=True)
    gateway = None
    try:
        address = replica.stdout.readline().strip()
        gateway = subprocess.Popen([nerva, "api", "--cluster=0", f"--addresses={address}",
                                    "--listen=127.0.0.1:0"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   env={**os.environ, "NERVA_KEY": KEY}, text=True)
        port = int(gateway.stdout.readline())
        deadline = time.monotonic() + 60
        while "tracing stopped" not in open(log.name).read():
            assert time.monotonic() < deadline, "the trace never reached --trace-size-max"
            status, body = request(port, "POST", "/v1/lookup",
                                   {"rows": [{"table": 1, "id": "0"}]})
            assert status == 200, (status, body)
        assert "reached --trace-size-max" in open(log.name).read()
        for _ in range(20):  # Still serving, with tracing stopped.
            assert request(port, "POST", "/v1/lookup",
                           {"rows": [{"table": 1, "id": "0"}]})[0] == 200
        assert replica.poll() is None, "the replica exited"
        size = os.path.getsize(trace)
        assert 0 < size <= 64 * 1024, size
        return size
    finally:
        for process in (gateway, replica):
            if process is not None:
                process.kill()
                process.wait()
        log.close()
        os.remove(data_file)


def check_key_rotation(cluster):
    # During a key rotation a gateway accepts both keys, and nothing else (P96).
    port = cluster.gateway({"NERVA_KEY": KEY, "NERVA_KEY_NEXT": KEY_NEXT})
    lookup = {"rows": [{"table": 1, "id": "0"}]}
    assert request(port, "POST", "/v1/lookup", lookup, key=KEY)[0] == 200
    assert request(port, "POST", "/v1/lookup", lookup, key=KEY_NEXT)[0] == 200
    for key in (None, "wrong", KEY + "x", KEY_NEXT[:-1], KEY_NEXT.upper()):
        status, body = request(port, "POST", "/v1/lookup", lookup, key=key)
        assert status == 401 and body == {"error": "invalid key"}, (key, status, body)
    # The current key alone: the next one is refused.
    assert request(cluster.ports[0], "POST", "/v1/lookup", lookup, key=KEY_NEXT)[0] == 401

    # Keys that cannot be used stop the gateway before it listens, and it never prints them.
    for env, reason in (({"NERVA_KEY": KEY, "NERVA_KEY_NEXT": KEY}, "equals NERVA_KEY"),
                        ({"NERVA_KEY": KEY, "NERVA_KEY_NEXT": ""}, "set but empty"),
                        ({"NERVA_KEY": "", "NERVA_KEY_NEXT": KEY_NEXT}, "set NERVA_KEY")):
        result = subprocess.run([cluster.nerva, "api", "--cluster=0",
                                 f"--addresses={cluster.address}", "--listen=127.0.0.1:0"],
                                env={**os.environ, **env}, capture_output=True, text=True,
                                timeout=60)
        assert result.returncode != 0 and result.stdout == "", (env, result)
        assert reason in result.stderr, (env, result.stderr)
        assert KEY not in result.stderr and KEY_NEXT not in result.stderr, result.stderr


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
        together = check_coalesced(ports[0])
        check_connections(ports[0])
        check_malformed(ports[0])
        rss = check_request_memory(cluster)
        check_documents_get_max(ports[0])
        check_multiline_body(ports[0])
        check_idle_flood(ports[0])
        check_busy(nerva, cluster, ports[0])
        check_trace_refuses_existing(nerva, cluster.tmp)
        trace_size = check_trace_bounded(nerva, cluster.tmp)
        check_stall_recovery(cluster, ports[1])
        check_layouts(ports)

        assert request(ports[0], "POST", "/v1/lookup", {"rows": []}, key=None)[0] == 401
        assert request(ports[0], "POST", "/v1/lookup", {"rows": []}, key="wrong")[0] == 401
        check_key_rotation(cluster)
        assert request(ports[0], "GET", "/v1/nothing")[0] == 404
        assert request(ports[0], "GET", "/v1/commit")[0] == 405

        print(f"api: PASSED ({steps} steps: {counts}; feed of {len(feed)} changes; "
              f"{len(keys)} histories; {as_of_reads} as-of reads; counter race with "
              f"{conflicts} conflicts retried; {together} requests committed at an op shared "
              f"with another; gateway RSS {rss[0]} MiB, {rss[1]} MiB after "
              f"4 MiB nested bodies; trace stopped at {trace_size} bytes; NERVA_KEY_NEXT "
              f"accepted; seed {seed})")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
