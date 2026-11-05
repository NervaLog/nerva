#!/usr/bin/env python3
"""`nerva api`'s documents against a model (docs/DECISIONS.md N41).

Runs one replica and two API gateways, then:

- random document transactions in two namespaces (reads at the version seen, sometimes stale;
  puts of 0 bytes to 64 KiB, so documents grow and shrink across chunk counts; deletes) through
  either gateway, each answer checked against an in-memory model: 200 committed with an
  increasing op, 409 conflict naming the first stale read's key and its current version;
  nothing applied unless committed;
- random reads of keys, latest and `as_of` random committed ops, against the model (a document
  that shrank leaves trailing chunks behind, which a read must ignore);
- each namespace's document feed, paged with random limits (some smaller than one document's
  chunks), equal to the model's list of writes;
- limits: keys of 1024 bytes and values of 512 KiB accepted, written in one transaction and read
  back, one byte more refused (#25); a commit too large for one request refused whole; a `get`
  of more chunks than 256 documents of 64 KiB answers 413, one just under answers 200; `as_of`
  not yet committed answers 504;
- document rows never appear in `/v1/changes`, and the documents table is refused by the row
  routes;
- eight threads incrementing one document with read-modify-write through both gateways,
  retrying on 409: no increment lost.

Usage: documents.py <path to nerva> [--seed=N] [--steps=N]
"""
import os, random, sys, threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from api import Cluster, plain, request  # noqa: E402

NAMESPACES = ("7", "8")
KEYS = ["a", "b", "cart/1", "cart/2", "δοκιμή", "k" * 300, "x" * 1024]
TABLE_DOCUMENTS = 0xFFFF0002


class Model:
    def __init__(self):
        self.documents = {}  # (namespace, key) -> (version, value_hex or None)
        self.writes = []     # (namespace, key, op, value_hex or None), in commit order
        self.ops = []

    def version(self, namespace, key):
        return self.documents.get((namespace, key), (0, None))[0]

    def as_of(self, namespace, key, op):
        state = (0, None)
        for write_namespace, write_key, write_op, value in self.writes:
            if (write_namespace, write_key) == (namespace, key) and write_op <= op:
                state = (write_op, value)
        return state

    def apply(self, op, namespace, writes):
        assert not self.ops or op > self.ops[-1], (op, self.ops[-1:])
        self.ops.append(op)
        for write in writes:
            value = None if write.get("delete") else write["value_hex"]
            self.documents[(namespace, write["key"])] = (op, value)
            self.writes.append((namespace, write["key"], op, value))


def random_value(rng):
    size = rng.choice([0, rng.randint(1, 50), rng.randint(51, 400), rng.randint(400, 3000)])
    if rng.random() < 0.02:
        size = 64 * 1024
    return rng.randbytes(size).hex()


def check_commit(port, rng, model, counts):
    namespace = rng.choice(NAMESPACES)
    keys = rng.sample(KEYS, rng.randint(1, 4))
    reads, writes = [], []
    for key in keys:
        if rng.random() < 0.6:
            version = model.version(namespace, key)
            if rng.random() < 0.15 and model.ops:
                version = rng.choice([0] + model.ops)
            reads.append({"key": key, "version": str(version)})
        if rng.random() < 0.7 or not reads:
            if rng.random() < 0.2:
                writes.append({"key": key, "delete": True})
            else:
                writes.append({"key": key, "value_hex": random_value(rng)})
    status, body = request(port, "POST", "/v1/documents/commit",
                           {"namespace": namespace, "reads": reads, "writes": writes})
    stale = next((r for r in reads if int(r["version"]) != model.version(namespace, r["key"])),
                 None)
    if stale is None:
        assert status == 200 and body["status"] == "committed", (status, body)
        model.apply(int(body["op"]), namespace, writes)
        counts["committed"] += 1
    else:
        assert status == 409, (status, body, stale)
        assert plain(body) == {"status": "conflict", "key": stale["key"],
                        "version": str(model.version(namespace, stale["key"]))}, (body, stale)
        counts["conflict"] += 1


def check_get(port, rng, model, as_of=None):
    namespace = rng.choice(NAMESPACES)
    keys = rng.sample(KEYS, rng.randint(1, len(KEYS)))
    request_body = {"namespace": namespace, "keys": keys}
    if as_of is not None:
        request_body["as_of"] = str(as_of)
    status, body = request(port, "POST", "/v1/documents/get", request_body)
    assert status == 200, body
    if as_of is None:
        assert not model.ops or int(body["op"]) > model.ops[-1]
    else:
        assert body["op"] == str(as_of)
    assert [d["key"] for d in body["documents"]] == keys
    for document in body["documents"]:
        if as_of is None:
            version, value = model.documents.get((namespace, document["key"]), (0, None))
        else:
            version, value = model.as_of(namespace, document["key"], as_of)
        assert document == {"key": document["key"], "exists": value is not None,
                            "version": str(version), "value_hex": value or ""}, (
            document["key"], as_of, document["version"], version)


def read_feed(port, rng, namespace):
    documents, cursor = [], "0"
    while True:
        status, body = request(port, "GET", f"/v1/documents/changes?namespace={namespace}"
                                            f"&cursor={cursor}&limit={rng.randint(1, 40)}")
        assert status == 200, body
        documents += body["documents"]
        cursor = body["cursor"]
        if not body["more"]:
            assert body["op"] is not None
            return documents


def expected_feed(model, namespace):
    feed = []
    for write_namespace, key, op, value in model.writes:
        if write_namespace != namespace:
            continue
        if value is None:
            feed.append({"key": key, "op": str(op), "kind": "delete"})
        else:
            feed.append({"key": key, "op": str(op), "kind": "put", "value_hex": value})
    return feed


def check_limits(port, model):
    def commit(writes, namespace="9"):
        return request(port, "POST", "/v1/documents/commit",
                       {"namespace": namespace, "writes": writes})

    largest = [{"key": "x" * 1024, "value_hex": "ab" * (512 * 1024)}]
    status, body = commit(largest)
    assert status == 200, body
    model.apply(int(body["op"]), "9", largest)
    status, body = request(port, "POST", "/v1/documents/get",
                           {"namespace": "9", "keys": ["x" * 1024]})
    assert status == 200 and body["documents"][0]["value_hex"] == largest[0]["value_hex"], status
    for writes in ([{"key": "x" * 1025, "value_hex": ""}],
                   [{"key": "a", "value_hex": "ab" * (512 * 1024 + 1)}],
                   [{"key": "", "value_hex": ""}]):
        status, body = commit(writes)
        assert status == 400, (status, body)
    # Twelve 64 KiB documents: more rows than one request carries. Refused whole.
    status, body = commit([{"key": f"big/{i}", "value_hex": "cd" * (64 * 1024)}
                           for i in range(12)])
    assert status == 400 and "too many" in body["error"], (status, body)
    status, body = request(port, "POST", "/v1/documents/get",
                           {"namespace": "9", "keys": ["big/0", "big/11"]})
    assert status == 200 and not any(d["exists"] for d in body["documents"]), body
    status, body = request(port, "POST", "/v1/documents/get",
                           {"namespace": "9", "keys": ["a"], "as_of": str(10**15)})
    assert status == 504 and "not yet committed" in body["error"], body
    # A get reads at most as many chunks as 256 documents of 64 KiB: 33 of 512 KiB are just
    # over, 32 just under.
    keys = [f"large/{i}" for i in range(33)]
    for key in keys:
        status, body = commit([{"key": key, "value_hex": "ef" * (512 * 1024)}], namespace="11")
        assert status == 200, (status, body)
    status, body = request(port, "POST", "/v1/documents/get", {"namespace": "11", "keys": keys})
    assert status == 413 and "fewer keys" in body["error"], (status, body)
    status, body = request(port, "POST", "/v1/documents/get",
                           {"namespace": "11", "keys": keys[:32]})
    assert status == 200 and all(d["exists"] for d in body["documents"]), (status, body if status != 200 else "")


def check_isolation(port):
    # Documents are not rows: not in the row feed, and their table is refused.
    status, body = request(port, "GET", "/v1/changes?cursor=0&limit=1024")
    while True:
        assert status == 200, body
        assert all(c["table"] < 0xFFFF0000 for c in body["changes"]), body
        if not body["more"]:
            break
        status, body = request(port, "GET", f"/v1/changes?cursor={body['cursor']}&limit=1024")
    status, body = request(port, "POST", "/v1/lookup",
                           {"rows": [{"table": TABLE_DOCUMENTS, "id": "1"}]})
    assert status == 400, body


def counter_race(ports, threads=8, increments=15):
    errors, conflicts = [], [0]

    def worker(index):
        port = ports[index % 2]
        try:
            for _ in range(increments):
                while True:
                    status, body = request(port, "POST", "/v1/documents/get",
                                           {"namespace": "10", "keys": ["counter"]})
                    document = body["documents"][0]
                    count = int(bytes.fromhex(document["value_hex"]) or b"0")
                    status, body = request(port, "POST", "/v1/documents/commit", {
                        "namespace": "10",
                        "reads": [{"key": "counter", "version": document["version"]}],
                        "writes": [{"key": "counter",
                                    "value_hex": str(count + 1).encode().hex()}]})
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
    status, body = request(ports[0], "POST", "/v1/documents/get",
                           {"namespace": "10", "keys": ["counter"]})
    count = int(bytes.fromhex(body["documents"][0]["value_hex"]))
    assert count == threads * increments, (count, threads * increments)
    assert conflicts[0] > 0, "no conflicts: the retry path was not exercised"
    return conflicts[0]


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    steps = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--steps=")), 400)
    rng = random.Random(seed)
    cluster = Cluster(nerva)
    try:
        ports = cluster.ports
        model = Model()
        counts = {"committed": 0, "conflict": 0}
        for _ in range(steps):
            port = rng.choice(ports)
            if rng.random() < 0.7:
                check_commit(port, rng, model, counts)
            else:
                check_get(port, rng, model)
        assert counts["committed"] > 0 and counts["conflict"] > 0, counts

        as_of_reads = 0
        for op in rng.sample(model.ops, min(60, len(model.ops))):
            check_get(rng.choice(ports), rng, model, as_of=op)
            as_of_reads += 1
        # Before the first commit, nothing existed.
        if model.ops[0] > 1:
            check_get(ports[0], rng, model, as_of=model.ops[0] - 1)

        check_limits(ports[0], model)
        feed_length = 0
        for namespace in NAMESPACES + ("9",):
            feed = read_feed(rng.choice(ports), rng, namespace)
            expected = expected_feed(model, namespace)
            assert feed == expected, (namespace, len(feed), len(expected))
            feed_length += len(feed)

        check_isolation(ports[0])
        conflicts = counter_race(ports)

        print(f"documents: PASSED ({steps} steps: {counts}; {as_of_reads} as-of reads; "
              f"feeds of {feed_length} writes; counter race with {conflicts} conflicts "
              f"retried; seed {seed})")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
