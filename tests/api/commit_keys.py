#!/usr/bin/env python3
"""Commit keys through `nerva api` (P123): a resent transaction commits at most once.

Runs one replica and two API gateways, then:

- a reservation (a clamped add and its `delta_from` partner) under a key commits; the same
  request again, through either gateway, answers `replayed` with the op it committed at, and
  moves nothing;
- other entries under a committed key answer 409 `key_reused`, with that op;
- a transaction that does not commit (a stale read) leaves its key free;
- thirty threads send one keyed transaction at once through both gateways: exactly one reply
  is not `replayed`, every reply names the same op, and the row moved once;
- requests whose replies are lost (the connection closed right after sending), then resent:
  each moves its amount exactly once;
- key rows are Nerva's own: refused as a table, and left out of `/v1/changes`;
- malformed keys are refused with 400;
- documents commit under a key too (`/v1/documents/commit`): a put resent answers `replayed` and
  leaves the document's version, other writes under the key answer `key_reused`, a stale read
  leaves the key free, and a lost reply resent applies once.

Usage: commit_keys.py <path to nerva> [--seed=N]
"""
import json, os, random, socket, sys, threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from api import KEY, Cluster, plain, request  # noqa: E402

TABLE = 31
TABLE_COMMIT_KEYS = 0xFFFF0003
LAYOUT = {"name": "budgets", "fields": [{"name": "available", "type": "u64"},
                                         {"name": "held", "type": "u64"}]}


def commit(port, entries, key=None):
    body = {"entries": entries}
    if key is not None:
        body["key"] = key
    return request(port, "POST", "/v1/commit", body)


def add(row, field, **options):
    entry = {"kind": "add", "table": TABLE, "id": str(row), "field": field}
    for name, value in options.items():
        entry[name] = str(value) if name in ("delta", "min", "max") else value
    return entry


def reserve(row, amount, index=0):
    """A clamped reservation whose first add is the request's entry at `index`."""
    return [add(row, "available", delta=-amount, min=0, clamp=True),
            add(row, "held", delta_from=index)]


def lookup(port, row):
    status, body = request(port, "POST", "/v1/lookup", {"rows": [{"table": TABLE, "id": str(row)}]})
    assert status == 200, body
    return body["rows"][0]


def fund(port, row, amount):
    status, body = commit(port, [add(row, "available", delta=amount, create=True)])
    assert status == 200, body


def key_of(rng):
    return "%032x" % rng.getrandbits(128)


def check_resend(ports, rng):
    fund(ports[0], 1, 100)
    key = key_of(rng)
    status, first = commit(ports[0], reserve(1, 30), key)
    assert status == 200 and "replayed" not in first, first
    # The partner's `delta_from` names the request's index 0, not the key entry.
    assert first["adds"] == [{"index": 0, "applied": "-30", "value": "70"},
                             {"index": 1, "applied": "30", "value": "30"}], first
    for port in ports:
        status, again = commit(port, reserve(1, 30), key)
        assert status == 200, again
        assert plain(again) == {"status": "committed", "op": first["op"], "replayed": True}, again
        assert again["code"] == "NRV-W0201", again
    assert lookup(ports[0], 1)["fields"] == {"available": "70", "held": "30"}

    status, reused = commit(ports[1], reserve(1, 31), key)
    assert status == 409 and plain(reused) == {"status": "key_reused", "op": first["op"]}, reused
    assert lookup(ports[0], 1)["fields"] == {"available": "70", "held": "30"}


def check_not_committed_leaves_key(port, rng):
    key = key_of(rng)
    version = lookup(port, 1)["op"]
    stale = [{"kind": "read", "table": TABLE, "id": "1", "op_seen": str(int(version) - 1)}]
    status, body = commit(port, stale + reserve(1, 5, index=1), key)
    assert status == 409 and body["status"] == "conflict" and body["index"] == 0, body
    fresh = [{"kind": "read", "table": TABLE, "id": "1", "op_seen": version}]
    status, body = commit(port, fresh + reserve(1, 5, index=1), key)
    assert status == 200 and "replayed" not in body, body
    assert lookup(port, 1)["fields"] == {"available": "65", "held": "35"}


def check_resend_race(ports, rng, threads=30):
    fund(ports[0], 2, 1000)
    key = key_of(rng)
    replies = []
    errors = []

    def worker(index):
        try:
            replies.append(commit(ports[index % 2], reserve(2, 7), key))
        except Exception as error:  # noqa: BLE001
            errors.append(error)

    workers = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
    for w in workers:
        w.start()
    for w in workers:
        w.join()
    assert not errors, errors
    assert all(status == 200 for status, _ in replies), replies
    committed = [body for _, body in replies if "replayed" not in body]
    assert len(committed) == 1, replies
    assert len({body["op"] for _, body in replies}) == 1, replies
    assert lookup(ports[0], 2)["fields"] == {"available": "993", "held": "7"}


def send_and_drop(port, body, path="/v1/commit"):
    """Sends a request and closes the connection without reading the reply: a lost reply."""
    data = json.dumps(body).encode()
    head = (f"POST {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Nerva-Key: {KEY}\r\n"
            f"Content-Type: application/json\r\nContent-Length: {len(data)}\r\n\r\n").encode()
    with socket.create_connection(("127.0.0.1", port), timeout=10) as connection:
        connection.sendall(head + data)


def check_lost_replies(ports, rng, count=20):
    fund(ports[0], 3, 10_000)
    held = 0
    for index in range(count):
        amount = rng.randint(1, 50)
        key = key_of(rng)
        send_and_drop(ports[index % 2], {"key": key, "entries": reserve(3, amount)})
        status, body = commit(ports[(index + 1) % 2], reserve(3, amount), key)
        assert status == 200, body
        held += amount
    assert lookup(ports[0], 3)["fields"] == {"available": str(10_000 - held), "held": str(held)}


def check_reserved(port, rng):
    status, body = commit(port, [{"kind": "put", "table": TABLE_COMMIT_KEYS, "id": "1",
                                  "value_hex": "00"}])
    assert status == 400, body
    status, body = request(port, "POST", "/v1/lookup",
                           {"rows": [{"table": TABLE_COMMIT_KEYS, "id": "1"}]})
    assert status == 400, body
    cursor = "0"
    while True:
        status, body = request(port, "GET", f"/v1/changes?cursor={cursor}&limit=100")
        assert status == 200, body
        assert all(change["table"] != TABLE_COMMIT_KEYS for change in body["changes"]), body
        cursor = body["cursor"]
        if not body["more"]:
            break
    for key in ["0" * 32, "abc", "0" * 34, "g" * 32, 5]:
        status, body = request(port, "POST", "/v1/commit",
                               {"key": key, "entries": reserve(1, 1)})
        assert status == 400, (key, body)
    assert lookup(port, 1)["fields"] == {"available": "65", "held": "35"}


def documents_commit(port, body, key=None):
    if key is not None:
        body = dict(body, key=key)
    return request(port, "POST", "/v1/documents/commit", body)


def document(port, name):
    status, body = request(port, "POST", "/v1/documents/get",
                           {"namespace": "9", "keys": [name]})
    assert status == 200, body
    return body["documents"][0]


def check_documents(ports, rng):
    port = ports[0]
    put = {"namespace": "9", "reads": [{"key": "a", "version": "0"}],
           "writes": [{"key": "a", "value_hex": "0102"}]}
    key = key_of(rng)
    status, first = documents_commit(port, put, key)
    assert status == 200 and plain(first) == {"status": "committed", "op": first["op"]}, first
    version = document(port, "a")["version"]
    assert version == first["op"], (version, first)
    # The same request again, through either gateway: replayed, and the version does not move.
    for other in ports:
        status, again = documents_commit(other, put, key)
        assert status == 200, again
        assert plain(again) == {"status": "committed", "op": first["op"], "replayed": True}, again
        assert again["code"] == "NRV-W0201", again
    assert document(port, "a") == {"key": "a", "exists": True, "version": version,
                                   "value_hex": "0102"}
    # The same key for other writes never commits.
    other = {"namespace": "9", "writes": [{"key": "a", "value_hex": "ff"}]}
    status, reused = documents_commit(ports[1], other, key)
    assert status == 409, reused
    assert plain(reused) == {"status": "key_reused", "op": first["op"]}, reused
    assert reused["code"] == "NRV-E0207", reused
    assert document(port, "a")["value_hex"] == "0102"
    # A stale read leaves its key free.
    key = key_of(rng)
    stale = {"namespace": "9", "reads": [{"key": "a", "version": "0"}],
             "writes": [{"key": "a", "value_hex": "03"}]}
    status, body = documents_commit(port, stale, key)
    assert status == 409 and body["status"] == "conflict" and body["key"] == "a", body
    fresh = dict(stale, reads=[{"key": "a", "version": version}])
    status, body = documents_commit(port, fresh, key)
    assert status == 200 and "replayed" not in body, body
    assert document(port, "a")["value_hex"] == "03"
    # A lost reply, resent: one application (the second would conflict without the key).
    for index in range(10):
        name = f"lost{index}"
        key = key_of(rng)
        body = {"namespace": "9", "reads": [{"key": name, "version": "0"}],
                "writes": [{"key": name, "value_hex": "%02x" % index}]}
        send_and_drop(ports[index % 2], dict(body, key=key), "/v1/documents/commit")
        status, again = documents_commit(ports[(index + 1) % 2], body, key)
        assert status == 200, again
        found = document(port, name)
        assert found["exists"] and found["value_hex"] == "%02x" % index, found
        status, again = documents_commit(port, body, key)
        assert status == 200 and again.get("replayed") is True, again
        assert document(port, name)["version"] == found["version"], (found, again)
    for key in ["0" * 32, "abc", "0" * 34, "g" * 32, 5]:
        status, body = documents_commit(port, put, key)
        # A string that is not 32 nonzero hex digits is NRV-E0109; a number is not a string,
        # so it is malformed JSON, NRV-E0105.
        code = "NRV-E0105" if isinstance(key, int) else "NRV-E0109"
        assert status == 400 and body.get("applied") is False, (key, body)
        assert body.get("code") == code, (key, body)


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    rng = random.Random(seed)
    cluster = Cluster(nerva)
    try:
        ports = cluster.ports
        status, body = request(ports[0], "PUT", f"/v1/tables/{TABLE}", LAYOUT)
        assert status == 200, body
        check_resend(ports, rng)
        check_not_committed_leaves_key(ports[1], rng)
        check_resend_race(ports, rng)
        check_lost_replies(ports, rng)
        check_reserved(ports[0], rng)
        check_documents(ports, rng)
        print(f"commit_keys: PASSED (resends, a race of 30 resends, 20 lost replies, documents; seed {seed})")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
