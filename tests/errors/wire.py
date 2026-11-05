#!/usr/bin/env python3
"""Every code `nerva api` puts on the wire, from the real binary (P147c, P168b, R4 slice 2).

Runs one replica and a gateway, then provokes each failure the gateway can answer and checks the
status, `code` and `applied` of its reply, and that the `error` or `status` identifiers clients
match on keep their spelling:

- 01xx the transport and the request: a bare LF (E0101), a body past 4 MiB (413, E0102), no key
  (E0103), no such route or method (E0104), the JSON and its numbers, query, tables, hex, entries,
  lookups, sizes, layouts and values (E0105 to E0115), a request that never arrives whole (408,
  E0116);
- 02xx commit results: a replayed key (200, W0201), a stale read, a bound, an absent row, an
  unpaired move, a view's key field, a reused key, a row written twice (E0202 to E0210);
- 03xx declarations, 04xx reads, 05xx documents;
- 06xx a full gateway (E0602) and a cluster that does not answer: a commit in flight is
  `"applied": "unknown"` (E0601), the next request finds no session and was never sent (E0605).

Not provoked here, for the cost of the state they need: E0208 and E0209 (64-bit hash collisions),
E0211 and E0212 (a views budget spent), E0306 (64 ledgers), E0310, E0404 and E0405 (a view or
index still building, a failed view), E0407 (10,000 groups), E0504 (256 documents of 64 KiB).
`nerva view`'s codes (E1001, E1002) are in tests/views/.

Usage: wire.py <path to nerva>
"""
import json, os, signal, socket, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "api"))
from api import KEY, Cluster, request  # noqa: E402

ACCOUNTS, GROUPED, RECORDS = 5, 6, 0x8000_0007
seen = set()


def check(code, status, reply, expected_status, expected_applied, what):
    assert status == expected_status, (what, status, reply)
    assert reply.get("code") == code, (what, reply)
    assert reply.get("applied") == expected_applied, (what, reply)
    seen.add(code)


def expect(port, code, http_status, method, target, body=None, key=KEY, applied=False, **members):
    """The reply to a request is `http_status`, names `code`, and says whether it was applied."""
    got, reply = request(port, method, target, body, key=key)
    check(code, got, reply, http_status, applied, (method, target, body))
    for name, value in members.items():
        assert reply.get(name) == value, ((method, target, body), name, reply)
    return reply


def raw(port, data, wait=5, send_more=None):
    """What a connection that sent `data` reads back: (status, body)."""
    connection = socket.create_connection(("127.0.0.1", port))
    connection.sendall(data)
    if send_more:
        send_more(connection)
    connection.settimeout(wait)
    reply = b""
    while chunk := connection.recv(65536):
        reply += chunk
    connection.close()
    assert reply.startswith(b"HTTP/1.1 "), reply
    head, _, text = reply.partition(b"\r\n\r\n")
    return int(head.split()[1]), json.loads(text)


def put(port, table, id_, fields):
    return {"kind": "put", "table": table, "id": str(id_), "fields": fields}


def commit(port, entries, key=None):
    body = {"entries": entries}
    if key:
        body["key"] = key
    return request(port, "POST", "/v1/commit", body)


def transport(port):
    status, reply = raw(port, b"GET /healthz HTTP/1.1\n\n")
    check("NRV-E0101", status, reply, 400, False, "bare LF")
    status, reply = raw(port, b"POST /v1/commit HTTP/1.1\r\nContent-Length: 5242880\r\n\r\n")
    check("NRV-E0102", status, reply, 413, False, "body past 4 MiB")
    assert reply["error"] == "body too large", reply


def requests(port):
    expect(port, "NRV-E0103", 401, "GET", "/v1/views", key=None, error="invalid key")
    expect(port, "NRV-E0104", 404, "GET", "/v1/nope", error="not found")
    expect(port, "NRV-E0104", 405, "POST", "/v1/changes", {}, error="method not allowed")
    expect(port, "NRV-E0105", 400, "POST", "/v1/lookup", {"rows": [{"table": 1, "id": 1}]})
    expect(port, "NRV-E0106", 400, "POST", "/v1/lookup", {"rows": [{"table": 1, "id": "x"}]})
    expect(port, "NRV-E0107", 400, "GET", "/v1/changes?limit=5&bogus=1")
    expect(port, "NRV-E0108", 400, "POST", "/v1/lookup", {"rows": [{"table": 0, "id": "1"}]})
    expect(port, "NRV-E0109", 400, "POST", "/v1/commit", {"entries": [
        {"kind": "put", "table": 1, "id": "1", "value_hex": "zz"}]})
    expect(port, "NRV-E0110", 400, "POST", "/v1/commit", {"entries": [
        {"kind": "put", "table": 1, "id": "1"}]})
    expect(port, "NRV-E0111", 400, "POST", "/v1/lookup", {"rows": []})
    expect(port, "NRV-E0112", 400, "POST", "/v1/commit", {"entries": [
        {"kind": "put", "table": 1, "id": "1", "value_hex": "01"}] * 9000})
    depth = 2 * 1024 * 1024 - 64
    body = ('{"entries":[{"kind":"put","table":1,"id":"1","fields":' + "[" * depth + "]" * depth +
            "}]}").encode()
    status, reply = raw(port, b"POST /v1/commit HTTP/1.1\r\nX-Nerva-Key: " + KEY.encode() +
                        b"\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
    check("NRV-E0113", status, reply, 413, False, "a request too complex")
    expect(port, "NRV-E0114", 400, "POST", "/v1/commit", {"entries": [
        put(port, ACCOUNTS, 1, {"zz": "1"})]})
    expect(port, "NRV-E0115", 400, "POST", "/v1/commit", {"entries": [
        put(port, ACCOUNTS, 1, {"available": "x"})]})


def commits(port):
    status, first = commit(port, [put(port, ACCOUNTS, 1, {"available": "10", "held": "0"})])
    assert status == 200, first
    key = "00000000000000000000000000000abc"
    status, first = commit(port, [put(port, ACCOUNTS, 2, {"available": "1"})], key)
    assert status == 200, first
    status, again = commit(port, [put(port, ACCOUNTS, 2, {"available": "1"})], key)
    assert status == 200 and again["replayed"] is True and again["code"] == "NRV-W0201", again
    seen.add("NRV-W0201")
    status, reused = commit(port, [put(port, ACCOUNTS, 2, {"available": "2"})], key)
    check("NRV-E0207", status, reused, 409, False, "key reused")
    assert reused["status"] == "key_reused", reused
    status, stale = commit(port, [{"kind": "read", "table": ACCOUNTS, "id": "1", "op_seen": "1"},
                                  put(port, ACCOUNTS, 3, {"available": "1"})])
    check("NRV-E0202", status, stale, 409, False, "stale read")
    assert stale["status"] == "conflict", stale
    status, bound = commit(port, [{"kind": "add", "table": ACCOUNTS, "id": "1",
                                   "field": "available", "delta": "-11", "min": "0"}])
    check("NRV-E0203", status, bound, 409, False, "bound")
    assert bound["status"] == "out_of_bounds", bound
    status, absent = commit(port, [{"kind": "add", "table": ACCOUNTS, "id": "99",
                                    "field": "available", "delta": "1"}])
    check("NRV-E0204", status, absent, 409, False, "absent row")
    assert absent["status"] == "row_absent", absent
    status, twice = commit(port, [put(port, ACCOUNTS, 4, {"available": "1"}),
                                  put(port, ACCOUNTS, 4, {"available": "2"})])
    check("NRV-E0210", status, twice, 400, False, "a row written twice")

    status, ledger = request(port, "PUT", "/v1/ledgers/1", {"fields": [
        {"table": ACCOUNTS, "field": "available"}, {"table": ACCOUNTS, "field": "held"}]})
    assert status == 200, ledger
    status, unpaired = commit(port, [{"kind": "add", "table": ACCOUNTS, "id": "1",
                                      "field": "held", "delta": "5"}])
    check("NRV-E0205", status, unpaired, 409, False, "unpaired")
    assert unpaired["status"] == "unpaired", unpaired

    status, view = request(port, "PUT", "/v1/views/by_kind", {
        "table": GROUPED, "group_by": ["kind"], "aggregates": [{"fn": "count"}]})
    assert status == 200 and view["maintained"], view
    status, grouped = commit(port, [put(port, GROUPED, 1, {"kind": "1", "amount": "1"})])
    assert status == 200, grouped
    status, keyed = commit(port, [{"kind": "add", "table": GROUPED, "id": "1",
                                   "field": "kind", "delta": "1"}])
    check("NRV-E0206", status, keyed, 409, False, "a view's key field")


def declarations(port):
    expect(port, "NRV-E0301", 400, "PUT", "/v1/tables/9", {"name": "x", "fields": [
        {"name": "a", "type": "u64"}, {"name": "a", "type": "u64"}]})
    expect(port, "NRV-E0303", 404, "GET", "/v1/tables/9")
    expect(port, "NRV-E0302", 409, "PUT", f"/v1/tables/{ACCOUNTS}", {"name": "accounts", "fields": [
        {"name": "other", "type": "i64"}]})
    expect(port, "NRV-E0304", 400, "PUT", "/v1/ledgers/0", {})
    expect(port, "NRV-E0305", 409, "PUT", "/v1/ledgers/1", {"fields": [
        {"table": ACCOUNTS, "field": "available", "floor": "0"},
        {"table": ACCOUNTS, "field": "held"}]}, status="ledger_immutable")
    expect(port, "NRV-E0307", 400, "PUT", "/v1/views/empty", {"table": GROUPED, "aggregates": []})
    expect(port, "NRV-E0308", 409, "PUT", "/v1/views/by_kind", {
        "table": GROUPED, "group_by": ["amount"], "aggregates": [{"fn": "count"}]})
    expect(port, "NRV-E0309", 409, "PUT", "/v1/views/funded", {
        "table": ACCOUNTS, "where": [{"field": "available", "op": "gt", "value": 0}],
        "aggregates": [{"fn": "count"}]})
    status, layout = request(port, "PUT", f"/v1/tables/{RECORDS}", {"name": "executions", "fields": [
        {"name": "agent", "type": "bytes", "size": 16}, {"name": "status", "type": "u8"},
        {"name": "created", "type": "u64"}]})
    assert status == 200, layout
    reaper = {"table": RECORDS, "order": "created",
              "where": [{"field": "status", "op": "eq", "value": 1}]}
    assert request(port, "PUT", "/v1/indexes/reaper", reaper)[0] == 200
    expect(port, "NRV-E0312", 409, "PUT", "/v1/indexes/reaper", {
        "table": RECORDS, "eq": ["agent"], "order": "created"}, status="different")
    expect(port, "NRV-E0311", 400, "PUT", "/v1/indexes/rows", {"table": 41, "order": "available"})


def reads(port):
    expect(port, "NRV-E0401", 504, "GET", f"/v1/row?table={ACCOUNTS}&id=1&as_of=999")
    expect(port, "NRV-E0401", 504, "GET", "/v1/views/by_kind?as_of=999")
    expect(port, "NRV-E0402", 404, "GET", "/v1/views/nope", error="no such view")
    expect(port, "NRV-E0402", 404, "GET", "/v1/ledgers/77")
    expect(port, "NRV-E0402", 404, "GET", "/v1/indexes/nope")
    expect(port, "NRV-E0403", 404, "GET", "/v1/views/by_kind?as_of=1")
    expect(port, "NRV-E0410", 400, "GET", "/v1/views/by_kind?min_op=1&as_of=1")
    expect(port, "NRV-E0409", 400, "POST", "/v1/indexes/reaper/scan", {"eq": {"agent": "00"}})


def documents(port):
    expect(port, "NRV-E0501", 400, "POST", "/v1/documents/get", {"namespace": "1", "keys": [""]})
    expect(port, "NRV-E0502", 400, "POST", "/v1/documents/get", {"namespace": "1", "keys": []})
    document = {"namespace": "1", "reads": [], "writes": [{"key": "a", "value_hex": "01"}]}
    assert request(port, "POST", "/v1/documents/commit", document)[0] == 200
    stale = {"namespace": "1", "reads": [{"key": "a", "version": "0"}],
             "writes": [{"key": "a", "value_hex": "02"}]}
    expect(port, "NRV-E0503", 409, "POST", "/v1/documents/commit", stale, status="conflict")
    expect(port, "NRV-E0401", 504, "POST", "/v1/documents/get",
           {"namespace": "1", "keys": ["a"], "as_of": "999"})


def full(port):
    # No byte for 10 s: told so (408) and not applied.
    drip = socket.create_connection(("127.0.0.1", port))
    drip.sendall(b"GET /healthz HTTP/1.1\r\n")
    # Sixteen half-sent requests and a seventeenth: busy, never read.
    partial = []
    for _ in range(15):
        connection = socket.create_connection(("127.0.0.1", port))
        connection.sendall(b"GET /healthz HTTP/1.1\r\n")
        partial.append(connection)
    time.sleep(0.2)
    status, reply = raw(port, b"GET /healthz HTTP/1.1\r\n\r\n")
    check("NRV-E0602", status, reply, 503, False, "a full gateway")
    assert reply["error"] == "busy", reply
    for connection in partial:
        connection.close()
    drip.settimeout(15)
    answer = b""
    while chunk := drip.recv(4096):
        answer += chunk
    drip.close()
    head, _, text = answer.partition(b"\r\n\r\n")
    check("NRV-E0116", int(head.split()[1]), json.loads(text), 408, False, "a drip")


def cluster_lost(cluster, port):
    replica = cluster.processes[0]
    replica.send_signal(signal.SIGSTOP)
    try:
        # A write in flight when the cluster stops answering: it may have committed.
        key = "00000000000000000000000000000def"
        expect(port, "NRV-E0601", 503, "POST", "/v1/commit", {"key": key, "entries": [
            put(port, ACCOUNTS, 7, {"available": "1"})]}, applied="unknown",
               error="cluster unavailable")
        # The session is broken: nothing is sent.
        expect(port, "NRV-E0605", 503, "POST", "/v1/commit", {"entries": [
            put(port, ACCOUNTS, 8, {"available": "1"})]}, error="cluster unavailable")
        status, health = request(port, "GET", "/healthz", key=None)
        assert status == 503 and health["code"] == "NRV-E0605", health
    finally:
        replica.send_signal(signal.SIGCONT)


def main():
    cluster = Cluster(sys.argv[1])
    try:
        port = cluster.ports[0]
        for table, name, fields in (
                (ACCOUNTS, "accounts", [("available", "i64"), ("held", "i64")]),
                (GROUPED, "grouped", [("kind", "u64"), ("amount", "u64")])):
            status, reply = request(port, "PUT", f"/v1/tables/{table}", {"name": name, "fields": [
                {"name": field, "type": kind} for field, kind in fields]})
            assert status == 200, reply
        transport(port)
        requests(port)
        commits(port)
        declarations(port)
        reads(port)
        documents(port)
        full(port)
        cluster_lost(cluster, port)
        print(f"wire: {len(seen)} codes checked: {' '.join(sorted(c[4:] for c in seen))}")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
