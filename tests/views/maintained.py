#!/usr/bin/env python3
"""Views maintained by the state machine (docs/DECISIONS.md N52, N62), against `nerva view` (v0,
N35) as the oracle.

One replica, `nerva api` and one `nerva view` process. Writes 5,000 seats, more than one pulse
backfills, before declaring two views, one with count and sum, one with count, min and max, so
that they build over existing rows. Then requires:

- the view to become `ready` by itself (pulses run while the cluster is idle);
- its groups, read through `GET /v1/views/<name>/groups` in pages, to equal what `nerva view`
  answers as of the same op, before and after rounds of random writes (sells, re-prices,
  deletes, and adds to the summed price);
- the replicated hash to be the sum, modulo 2^256, of the groups' digests, recomputed here from
  the groups as served, and the group count to match;
- an add to a field the view groups or filters by to answer 409 `view_key_field`;
- a commit of thousands of writes to one group to apply (admission counts distinct groups, not
  writes), and one touching more distinct groups than an op admits (a view grouped by price) to
  answer 413 `views_too_large`, applying nothing, and to commit once split in two (#32);
- `min` and `max` to stay exact as the seats holding them are re-priced, deleted or moved;
- every op compared earlier to read the same through `?as_of=<op>` at the end, as `nerva view`
  answers as of that op; and before a view's declaration, 404;
- the whole view from `nerva api` (`GET /v1/views/<name>`, N66) to equal `nerva view`'s answer
  byte for byte, latest and as of past ops; `min_op` and `as_of` ahead of the log to answer 504;
  `/definition` and the listing; a view of more than 10,000 groups to be refused (400);
- a view named `groups` to be read (404 before it exists, not a crash: #26) and declared.

Usage: maintained.py <path to nerva> [--seed=N]
"""
import hashlib, os, random, struct, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from declared import Cluster, request  # noqa: E402

TABLE = 5
LAYOUT = {"name": "seats", "fields": [{"name": "section", "type": "u8"},
                                      {"name": "price", "type": "u64"},
                                      {"name": "sold", "type": "bool"}]}
REVENUE = {"table": TABLE, "where": [{"field": "sold", "op": "eq", "value": True}],
           "group_by": ["section"],
           "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"}]}
BY_PRICE = {"table": TABLE, "group_by": ["price"], "aggregates": [{"fn": "count"}]}
EXTREMES = {"table": TABLE, "group_by": ["section"],
            "aggregates": [{"fn": "count"}, {"fn": "min", "field": "price"},
                           {"fn": "max", "field": "price"}]}
SEATS = 5000


def seat_value(section, price, sold):
    return {"section": section, "price": str(price), "sold": sold}


def commit(api, entries):
    return request(api, "POST", "/v1/commit", {"entries": entries})


def put(seat, fields):
    return {"kind": "put", "table": TABLE, "id": str(seat), "fields": fields}


def maintained(api, name, as_of=None):
    """Every page of the view's groups, and the last page's header. Each page is read at an op
    of its own; this test is the only writer, so the view does not change between pages, which
    the hash, the same on every page, confirms."""
    groups, cursor, hashes = [], None, set()
    while True:
        target = f"/v1/views/{name}/groups?limit=7" + (f"&cursor={cursor}" if cursor else "")
        target += f"&as_of={as_of}" if as_of else ""
        status, body = request(api, "GET", target)
        assert status == 200, (status, body)
        hashes.add(body["hash"])
        groups += body["groups"]
        if not body["more"]:
            break
        cursor = body["cursor"]
    assert len(hashes) == 1 or body["state"] != "ready", hashes
    return groups, body


# Per view, the names its groups give its aggregate slots after `count` (slot 0).
SLOTS = {"revenue": ["sum_price"], "extremes": ["min_price", "max_price"]}


def view_hash(view_id, name, groups):
    """The replicated hash, from the groups as served (`views.group_digest`, N52)."""
    total = 0
    for group in groups:
        key = bytes([group["section"]]) + bytes(63)
        sums = struct.pack("<qq", 0, 0)
        for slot in SLOTS[name]:
            sums += struct.pack("<QQ", *divmod_i128(int(group[slot])))
        sums += bytes(16 * (5 - len(SLOTS[name])))
        digest = hashlib.sha256(b"nerva.view.digest.v1" + struct.pack("<Q", view_id) + key +
                                struct.pack("<Q", int(group["count"])) + sums).digest()
        total = (total + int.from_bytes(digest, "little")) % (1 << 256)
    return total.to_bytes(32, "little").hex()


def divmod_i128(value):
    """An i128 as its two little-endian u64 halves (low, high)."""
    value %= 1 << 128
    return value & ((1 << 64) - 1), value >> 64


def check_against_oracle(api, view_port, name="revenue", as_of=None):
    """The view's groups (latest, or as of an op) as `nerva view` answers them at the same op;
    returns the op compared at and the number of groups."""
    groups, header = maintained(api, name, as_of)
    assert header["state"] == "ready", header
    op = as_of or header["op"]
    # The oracle as of the same op (it may still be catching up: wait for it).
    status, body = request(view_port, "GET", f"/v1/views/{name}?as_of={op}&min_op={op}")
    if status == 400:  # `as_of` and `min_op` together are refused: catch up, then ask.
        request(view_port, "GET", f"/v1/views/{name}?min_op={op}")
        status, body = request(view_port, "GET", f"/v1/views/{name}?as_of={op}")
    assert status == 200, (status, body)
    ordered = sorted(groups, key=lambda group: group["section"])
    assert ordered == body["groups"], (op, ordered[:3], body["groups"][:3])
    assert header["hash"] == view_hash(header["id"], name, groups), header
    assert int(header["group_count"]) == len(groups), header
    # The whole view from `nerva api` (N66): `nerva view`'s answer, byte for byte, so its hash.
    query = f"as_of={as_of}" if as_of else f"min_op={op}"
    status, whole = request(api, "GET", f"/v1/views/{name}?{query}")
    assert status == 200, (status, whole)
    assert whole["groups"] == body["groups"] and whole["hash"] == body["hash"], (whole, body)
    assert whole["view_hash"] == header["hash"], (whole, header)
    return op, len(groups)


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    rng = random.Random(seed)
    cluster = Cluster(nerva)
    try:
        api = cluster.api
        _, view_port = cluster.serve("view")
        assert request(api, "PUT", f"/v1/tables/{TABLE}", LAYOUT)[0] == 200

        # Seats before the view, in commits of 500.
        seats = {}
        for start in range(0, SEATS, 500):
            entries = []
            for seat in range(start, start + 500):
                seats[seat] = (rng.randrange(8), rng.randrange(1, 1000), rng.random() < 0.6)
                entries.append(put(seat, seat_value(*seats[seat])))
            status, body = commit(api, entries)
            assert status == 200, body

        status, body = request(api, "PUT", "/v1/views/revenue", REVENUE)
        assert status == 200 and body["maintained"] is True, body
        status, body = request(api, "PUT", "/v1/views/extremes", EXTREMES)
        assert status == 200 and body["maintained"] is True, body
        declared_op = int(maintained(api, "extremes")[1]["declared_op"])
        deadline = time.time() + 60
        for name in ("revenue", "extremes"):
            while True:
                groups, header = maintained(api, name)
                if header["state"] == "ready":
                    break
                assert header["state"] == "building", header
                assert time.time() < deadline, "the view did not finish building"
                time.sleep(0.2)
        checks = []

        def check_both():
            for name in ("revenue", "extremes"):
                checks.append((name,) + check_against_oracle(api, view_port, name))

        check_both()

        # Rounds of random writes, each followed by a comparison.
        for _ in range(6):
            for _ in range(40):
                seat = rng.randrange(SEATS + 200)
                choice = rng.random()
                if choice < 0.5:
                    seats[seat] = (rng.randrange(8), rng.randrange(1, 1000), rng.random() < 0.6)
                    status, body = commit(api, [put(seat, seat_value(*seats[seat]))])
                elif choice < 0.7 and seat in seats:
                    status, body = commit(api, [{"kind": "delete", "table": TABLE, "id": str(seat)}])
                    del seats[seat]
                elif seat in seats:
                    delta = rng.randrange(-5, 50)
                    status, body = commit(api, [{"kind": "add", "table": TABLE, "id": str(seat),
                                                 "field": "price", "delta": str(delta),
                                                 "min": "0", "clamp": True}])
                else:
                    continue
                assert status == 200, body
            check_both()

        # Refusals: an add to a grouped field.
        # `section` is a u8 at offset 0: a u64 add there overlaps it.
        status, body = commit(api, [{"kind": "add", "table": TABLE, "id": "0",
                                     "offset": 0, "type": "u64", "delta": "1"}])
        assert status == 409 and body["status"] == "view_key_field", (status, body)
        # Many writes to one group fit in an op: the revenue view gains one group's worth.
        status, body = commit(api, [put(SEATS + 1000 + i, seat_value(1, 1, True))
                                    for i in range(3000)])
        assert status == 200, (status, body)
        check_both()

        # More distinct groups than an op admits (4,095 in this configuration): refused whole,
        # as too large for any op (413), not as busy (#32). Split in two, it commits.
        status, body = request(api, "PUT", "/v1/views/by_price", BY_PRICE)
        assert status == 200 and body["maintained"] is True, body
        while maintained(api, "by_price")[1]["state"] != "ready":
            time.sleep(0.2)
        before = maintained(api, "revenue")[1]["hash"]
        large = [put(SEATS + 10_000 + i, seat_value(2, 10_000 + i, True)) for i in range(4200)]
        status, body = commit(api, large)
        assert status == 413 and body["status"] == "views_too_large", (status, body)
        assert maintained(api, "revenue")[1]["hash"] == before  # Nothing applied.
        for half in (large[:2100], large[2100:]):
            status, body = commit(api, half)
            assert status == 200, (status, body)
        check_both()

        # As of every op compared above: the same groups, read now (N62).
        for name, op, _ in list(checks):
            checks.append((name,) + check_against_oracle(api, view_port, name, as_of=op))
        status, body = request(api, "GET", f"/v1/views/extremes/groups?as_of={declared_op - 1}")
        assert status == 404, (status, body)
        status, body = request(api, "GET", "/v1/views/extremes/groups?as_of=999999999")
        assert status == 400, (status, body)

        # The whole view's routes (N66): an op not yet committed waits for nobody (504), as in
        # `nerva view`; the declaration is at `/definition`; `GET /v1/views` lists the views.
        status, body = request(api, "GET", "/v1/views/revenue?min_op=999999999")
        assert status == 504, (status, body)
        status, body = request(api, "GET", "/v1/views/revenue?as_of=999999999")
        assert status == 504, (status, body)
        status, body = request(api, "GET", f"/v1/views/extremes?as_of={declared_op - 1}")
        assert status == 404, (status, body)
        status, body = request(api, "GET", "/v1/views/revenue?as_of=5&min_op=5")
        assert status == 400, (status, body)
        status, body = request(api, "GET", "/v1/views/extremes/definition")
        assert status == 200 and body["aggregates"][1]["fn"] == "min", (status, body)
        status, body = request(api, "GET", "/v1/views")
        assert status == 200, (status, body)
        assert [v["name"] for v in body["views"]] == ["revenue", "extremes", "by_price"], body
        assert body["views"][1]["declared_op"] == str(declared_op), body

        # A view with more groups than one answer holds (10,000): 400, read it from `/groups`.
        for start in (20_000, 24_000, 28_000):
            status, body = commit(api, [put(SEATS + start + i, seat_value(3, start + i, True))
                                        for i in range(4000)])
            assert status == 200, (status, body)
        status, body = request(api, "GET", "/v1/views/by_price")
        assert status == 400 and "/groups" in body["error"], (status, body)

        # A view named `groups` (#26): reading it before it exists answers 404 (it crashed the
        # gateway), then it can be declared and its groups read at `/v1/views/groups/groups`.
        assert request(api, "GET", "/v1/views/groups")[0] == 404
        status, body = request(api, "PUT", "/v1/views/groups", REVENUE)
        assert status == 200, (status, body)
        while (status := request(api, "GET", "/v1/views/groups")[0]) == 503:  # Building.
            time.sleep(0.2)
        assert status == 200, status
        status, body = request(api, "GET", "/v1/views/groups/groups")
        assert status == 200 and "groups" in body, (status, body)

        print(f"maintained views: PASSED ({SEATS} seats backfilled; {len(checks)} comparisons "
              f"with nerva view, half as of past ops, up to {max(c[2] for c in checks)} groups "
              f"each; seed {seed})")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
