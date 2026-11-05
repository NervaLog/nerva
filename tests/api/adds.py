#!/usr/bin/env python3
"""Adds through `nerva api` (docs/DECISIONS.md N42).

Runs one replica and two API gateways, then:

- fifty threads reserve and release against one budget row (`available` and `held` fields) with
  adds only, through both gateways: no request conflicts or fails, every reply's values add up,
  and at the end available plus held is exactly what was funded, held is what the threads
  reserved and did not release, and the row equals the replies;
- bounds: out_of_bounds (409, with the current value) applies nothing; clamp takes what fits;
  i64 fields go negative; a row that does not exist answers row_absent without `create`;
- the field by name (with a layout) or by offset and type;
- requests the state machine would refuse are refused with 400 before reaching it.

Usage: adds.py <path to nerva> [--seed=N]
"""
import os, random, sys, threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from api import Cluster, plain, request  # noqa: E402

TABLE = 30
LAYOUT = {"name": "budgets", "fields": [{"name": "available", "type": "u64"},
                                         {"name": "held", "type": "u64"},
                                         {"name": "balance", "type": "i64"}]}


def commit(port, entries):
    return request(port, "POST", "/v1/commit", {"entries": entries})


def add(row, field, **options):
    entry = {"kind": "add", "table": TABLE, "id": str(row), "field": field}
    for name, value in options.items():
        entry[name] = str(value) if name in ("delta", "min", "max") else value
    return entry


def fields(port, row):
    status, body = request(port, "POST", "/v1/lookup", {"rows": [{"table": TABLE, "id": str(row)}]})
    assert status == 200, body
    return body["rows"][0].get("fields")


def reservation_race(ports, seed, threads=50, rounds=12):
    funded = 200 * threads  # Less than the threads will ask for: clamping must happen.
    status, body = commit(ports[0], [add(1, "available", delta=funded, create=True)])
    assert status == 200, body
    held_by_thread = [0] * threads
    clamped = [0]
    errors = []

    def worker(index):
        rng = random.Random(seed * 1000 + index)
        port = ports[index % 2]
        try:
            for _ in range(rounds):
                if held_by_thread[index] > 0 and rng.random() < 0.4:
                    amount = rng.randint(1, held_by_thread[index])
                    entries = [add(1, "held", delta=-amount, min=0),
                               add(1, "available", delta_from=0)]
                else:
                    amount = rng.randint(1, 300)
                    entries = [add(1, "available", delta=-amount, min=0, clamp=True),
                               add(1, "held", delta_from=0)]
                status, body = commit(port, entries)
                # Adds never conflict, and these never cross a bound.
                assert status == 200, (status, body)
                first, second = body["adds"]
                assert (first["index"], second["index"]) == (0, 1), body
                assert int(second["applied"]) == -int(first["applied"]), body
                if entries[0]["field"] == "held":
                    assert int(first["applied"]) == -amount, body
                    held_by_thread[index] -= amount
                else:
                    taken = -int(first["applied"])
                    assert 0 <= taken <= amount, body
                    # Clamped: took everything there was.
                    assert taken == amount or first["value"] == "0", body
                    clamped[0] += taken < amount
                    held_by_thread[index] += taken
        except Exception as error:  # Reported below.
            errors.append(repr(error))

    pool = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
    for thread in pool:
        thread.start()
    for thread in pool:
        thread.join()
    assert not errors, errors[:3]
    row = fields(ports[0], 1)
    held = int(row["held"])
    assert held == sum(held_by_thread), (held, sum(held_by_thread))
    assert int(row["available"]) + held == funded, (row, funded)
    assert clamped[0] > 0, "no reservation was clamped: the budget never ran out"
    return threads * rounds, clamped[0]


def check_bounds(port):
    status, body = commit(port, [add(2, "available", delta=10, create=True)])
    assert status == 200 and body["adds"] == [{"index": 0, "applied": "10", "value": "10"}], body

    # Crossing a bound: 409 with the current value, and the put before it is not applied.
    status, body = commit(port, [
        {"kind": "put", "table": TABLE, "id": "3", "value_hex": "01"},
        add(2, "available", delta=-11, min=0)])
    assert status == 409 and plain(body) == {"status": "out_of_bounds", "index": 1, "value": "10"}, body
    status, body = request(port, "POST", "/v1/lookup", {"rows": [{"table": TABLE, "id": "3"}]})
    assert body["rows"][0]["exists"] is False, body
    status, body = commit(port, [add(2, "available", delta=1, max=10)])
    assert status == 409 and body["status"] == "out_of_bounds", body

    # Clamped: takes what there is.
    status, body = commit(port, [add(2, "available", delta=-25, clamp=True)])
    assert status == 200 and body["adds"] == [{"index": 0, "applied": "-10", "value": "0"}], body

    # i64 goes negative, rendered signed; bounds are signed too.
    status, body = commit(port, [add(2, "balance", delta=-7)])
    assert status == 200 and body["adds"][0]["value"] == "-7", body
    status, body = commit(port, [add(2, "balance", delta=-5, min=-10)])
    assert status == 409 and plain(body) == {"status": "out_of_bounds", "index": 0, "value": "-7"}, body
    assert fields(port, 2) == {"available": "0", "held": "0", "balance": "-7"}, fields(port, 2)

    # Absent rows.
    status, body = commit(port, [add(4, "available", delta=1)])
    assert status == 409 and plain(body) == {"status": "row_absent", "index": 0}, body

    # By offset and type, on a table without a layout; several adds to one row.
    status, body = commit(port, [
        {"kind": "add", "table": 31, "id": "1", "offset": 72, "type": "u64", "delta": "5",
         "create": True},
        {"kind": "add", "table": 31, "id": "1", "offset": 72, "type": "u64", "delta": "6"}])
    assert status == 200 and [a["value"] for a in body["adds"]] == ["5", "11"], body
    status, body = request(port, "POST", "/v1/lookup", {"rows": [{"table": 31, "id": "1"}]})
    assert body["rows"][0]["value_hex"] == "00" * 72 + (11).to_bytes(8, "little").hex(), body


def check_refused(port):
    refused = [
        [add(2, "available", delta=1, delta_from=0)],
        [add(2, "available", delta_from=0)],
        [{"kind": "put", "table": TABLE, "id": "9", "value_hex": "00"},
         add(2, "available", delta_from=0)],
        [add(2, "available")],
        [add(2, "nothing", delta=1)],
        [add(2, "available", delta=1, min=5, max=4)],
        [add(2, "available", delta=-9223372036854775808)],
        [add(2, "available", delta=1, offset=8)],
        [{"kind": "add", "table": 31, "id": "1", "offset": 73, "type": "u64", "delta": "1"}],
        [{"kind": "add", "table": 31, "id": "1", "offset": 0, "delta": "1"}],
        [{"kind": "add", "table": 31, "id": "1", "field": "x", "delta": "1"}],
        [{"kind": "add", "table": 31, "id": "1", "offset": 0, "type": "u64", "delta": "1",
          "op_seen": "1"}],
        [{"kind": "put", "table": TABLE, "id": "2", "value_hex": "00", "delta": "1"}],
        [add(2, "available", delta=1), {"kind": "put", "table": TABLE, "id": "2",
                                         "value_hex": "00"}],
    ]
    for entries in refused:
        status, body = commit(port, entries)
        assert status == 400, (entries, status, body)
    # A field that is not 64-bit.
    status, body = request(port, "PUT", "/v1/tables/32", {"name": "small", "fields": [
        {"name": "count", "type": "u32"}]})
    assert status == 200, body
    status, body = commit(port, [{"kind": "add", "table": 32, "id": "1", "field": "count",
                                  "delta": "1", "create": True}])
    assert status == 400, body


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    cluster = Cluster(nerva)
    try:
        ports = cluster.ports
        status, body = request(ports[0], "PUT", f"/v1/tables/{TABLE}", LAYOUT)
        assert status == 200, body
        transactions, clamped = reservation_race(ports, seed)
        check_bounds(ports[0])
        check_refused(ports[1])
        print(f"adds: PASSED ({transactions} reservations and releases from 50 threads, none "
              f"retried, {clamped} clamped; seed {seed})")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
