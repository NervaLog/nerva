#!/usr/bin/env python3
"""Layouts kept between requests (P135): a gateway never answers for an old layout.

Runs one replica and two API gateways. Each gateway keeps the layouts it has read, and the other
extends them. For a table of rows and a table of records:

- gateway A reads a layout, gateway B appends a field, and A's next lookup, put with `fields`
  and add by field name use the new layout: no field is missing from a read, none is refused;
- a put through A under an older layout writes what the new layout would (absent fields zero),
  and a field the old layout lacks is not refused;
- a seeded random walk: either gateway extends a layout, puts or adds, or looks up; every lookup
  answers exactly the model's fields under the layout as the log holds it.

Usage: layouts.py <path to nerva> [--seed=N]
"""
import os, random, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from api import Cluster, request  # noqa: E402

ROWS = 41
RECORDS = 0x80000000 + 41
FIELDS_MAX = 8


def layout(count):
    return {"name": "kept", "fields": [{"name": f"f{i}", "type": "u64"} for i in range(count)]}


def put_layout(port, table, count):
    status, body = request(port, "PUT", f"/v1/tables/{table}", layout(count))
    assert status == 200 and body["layout"] in ("created", "extended", "unchanged"), body


def is_record(table):
    return table >= 0x80000000


def row_id(table, n):
    return "%032x" % n if is_record(table) else str(n)


def put(port, table, n, fields):
    entry = {"kind": "put", "table": table, "id": row_id(table, n),
             "fields": {k: str(v) for k, v in fields.items()}}
    return request(port, "POST", "/v1/commit", {"entries": [entry]})


def lookup(port, table, n):
    status, body = request(port, "POST", "/v1/lookup",
                           {"rows": [{"table": table, "id": row_id(table, n)}]})
    assert status == 200, body
    return body["rows"][0]


def expect(count, model):
    return {f"f{i}": str(model.get(f"f{i}", 0)) for i in range(count)}


def check_extension(a, b, table):
    put_layout(a, table, 1)
    status, body = put(a, table, 1, {"f0": 5})
    assert status == 200, body
    assert lookup(a, table, 1)["fields"] == {"f0": "5"}      # A keeps layout 1
    put_layout(b, table, 3)                                    # B appends f1, f2
    # A's lookup shows them, and the row as it was.
    assert lookup(a, table, 1)["fields"] == {"f0": "5", "f1": "0", "f2": "0"}
    put_layout(b, table, 4)
    # A has layout 3, and puts under it a field only layout 4 has.
    status, body = put(a, table, 2, {"f3": 9})
    assert status == 200, body
    assert lookup(b, table, 2)["fields"] == {"f0": "0", "f1": "0", "f2": "0", "f3": "9"}
    # A put under an older layout is the whole row: absent fields are zero, as under the new.
    put_layout(b, table, 5)
    status, body = put(a, table, 2, {"f0": 1})
    assert status == 200, body
    row = lookup(b, table, 2)
    assert row["fields"] == expect(5, {"f0": 1}), row
    if not is_record(table):
        # An add by field name, to a field A has not seen.
        put_layout(b, table, 6)
        entry = {"kind": "add", "table": table, "id": "2", "field": "f5", "delta": "7"}
        status, body = request(a, "POST", "/v1/commit", {"entries": [entry]})
        assert status == 200, body
        assert lookup(b, table, 2)["fields"]["f5"] == "7"
    # A field no layout has is refused.
    status, body = put(a, table, 3, {"nope": 1})
    assert status == 400, body


def check_walk(ports, table, rng, rounds=150):
    model = {}      # n -> {field: value}
    count = 1
    base = 100
    put_layout(ports[0], table, count)
    for _ in range(rounds):
        port = rng.choice(ports)
        action = rng.random()
        n = base + rng.randrange(4)
        if action < 0.15 and count < FIELDS_MAX:
            count += 1
            put_layout(port, table, count)
        elif action < 0.5:
            fields = {f"f{i}": rng.randrange(1000) for i in range(count) if rng.random() < 0.6}
            status, body = put(port, table, n, fields)
            assert status == 200, (status, body)
            model[n] = fields
        else:
            row = lookup(port, table, n)
            if n in model:
                assert row["exists"] and row["fields"] == expect(count, model[n]), (row, count)
            else:
                assert not row["exists"], row


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    rng = random.Random(seed)
    cluster = Cluster(nerva)
    try:
        a, b = cluster.ports
        for table in (ROWS, RECORDS):
            check_extension(a, b, table)
            check_extension(b, a, table + 1000)
            check_walk([a, b], table + 2000, rng)
        print(f"layouts: PASSED (extensions seen by the other gateway, a random walk; seed {seed})")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
