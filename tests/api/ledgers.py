#!/usr/bin/env python3
"""Ledgers through `nerva api` (docs/DECISIONS.md N74).

Runs one replica and two API gateways, then:

- declares a ledger over accounts (`available` and `held`, floored at 0) and a source (no
  floor), by field name and by offset; again identically (the same op), and reads it back;
- funds an account, then races fifty threads of clamped reservations (`available` to `held`)
  through both gateways: none conflicts or fails, each reply moves one amount, and at the end
  `available + held` is exactly what was funded;
- a sum view over the accounts (no `where`, no `group_by`) answers the funded total at the last
  op, and the source's balance is its negation;
- each refusal: unpaired halves, a partner that clamps or sits outside the ledger, a partner
  stopped by its floor, puts, deletes and straddling adds of balances, a different
  declaration under the same id, a field in two ledgers, views over a conserved field in either
  order (the later one leaves no catalog document), and invalid declarations.

Usage: ledgers.py <path to nerva> [--seed=N]
"""
import os, random, sys, threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from api import Cluster, request  # noqa: E402

ACCOUNTS = 40
SOURCES = 41
GROUPED = 42
ACCOUNTS_LAYOUT = {"name": "accounts", "fields": [{"name": "available", "type": "i64"},
                                                  {"name": "held", "type": "i64"},
                                                  {"name": "note", "type": "u64"}]}
SOURCES_LAYOUT = {"name": "sources", "fields": [{"name": "balance", "type": "i64"}]}
GROUPED_LAYOUT = {"name": "grouped", "fields": [{"name": "kind", "type": "i64"},
                                                {"name": "amount", "type": "i64"}]}
LEDGER = {"fields": [
    # Out of order on purpose: the gateway sorts them.
    {"table": SOURCES, "offset": 0, "floor": None},
    {"table": ACCOUNTS, "field": "held", "floor": "0"},
    {"table": ACCOUNTS, "field": "available", "floor": "0"},
]}


def commit(port, entries):
    return request(port, "POST", "/v1/commit", {"entries": entries})


def move(table, row, field, **options):
    entry = {"kind": "add", "table": table, "id": str(row), "field": field}
    for name, value in options.items():
        entry[name] = str(value) if name in ("delta", "min", "max") else value
    return entry


def fields(port, table, row):
    status, body = request(port, "POST", "/v1/lookup", {"rows": [{"table": table, "id": str(row)}]})
    assert status == 200, body
    return body["rows"][0].get("fields")


def declare(ports):
    for port, table, layout in ((ports[0], ACCOUNTS, ACCOUNTS_LAYOUT),
                                (ports[0], SOURCES, SOURCES_LAYOUT),
                                (ports[1], GROUPED, GROUPED_LAYOUT)):
        status, body = request(port, "PUT", f"/v1/tables/{table}", layout)
        assert status == 200, body
    assert request(ports[0], "GET", "/v1/ledgers/1")[0] == 404

    status, created = request(ports[0], "PUT", "/v1/ledgers/1", LEDGER)
    assert status == 200 and created["declared"] == "created", created
    status, again = request(ports[1], "PUT", "/v1/ledgers/1", LEDGER)
    assert status == 200 and again == {**created, "declared": "exists"}, again

    status, body = request(ports[1], "GET", "/v1/ledgers/1")
    assert status == 200, body
    assert body == {"ledger": 1, "op": created["op"], "fields": [
        {"table": ACCOUNTS, "offset": 0, "field": "available", "floor": "0"},
        {"table": ACCOUNTS, "offset": 8, "field": "held", "floor": "0"},
        {"table": SOURCES, "offset": 0, "field": "balance", "floor": None},
    ]}, body


def fund(port, row, amount):
    status, body = commit(port, [move(SOURCES, 1, "balance", delta=-amount, pair=True,
                                      create=True),
                                 move(ACCOUNTS, row, "available", delta_from=0, create=True)])
    assert status == 200, body
    assert [a["applied"] for a in body["adds"]] == [str(-amount), str(amount)], body
    return int(body["op"])


def reservation_race(ports, seed, threads=50, rounds=10):
    funded = 150 * threads  # Less than the threads will ask for: clamping must happen.
    fund(ports[0], 1, funded)
    taken_by_thread = [0] * threads
    clamped = [0]
    last_op = [0]
    errors = []

    def worker(index):
        rng = random.Random(seed * 1000 + index)
        port = ports[index % 2]
        try:
            for _ in range(rounds):
                amount = rng.randint(1, 300)
                status, body = commit(port, [
                    move(ACCOUNTS, 1, "available", delta=-amount, pair=True, clamp=True),
                    move(ACCOUNTS, 1, "held", delta_from=0)])
                # Pairs never conflict, and a clamped first half never crosses its floor.
                assert status == 200, (status, body)
                first, second = body["adds"]
                taken = -int(first["applied"])
                assert int(second["applied"]) == taken and 0 <= taken <= amount, body
                assert taken == amount or first["value"] == "0", body
                assert int(first["value"]) >= 0, body
                taken_by_thread[index] += taken
                clamped[0] += taken < amount
                last_op[0] = max(last_op[0], int(body["op"]))
        except Exception as error:  # noqa: BLE001
            errors.append(error)

    workers = [threading.Thread(target=worker, args=(index,)) for index in range(threads)]
    for worker_thread in workers:
        worker_thread.start()
    for worker_thread in workers:
        worker_thread.join()
    assert not errors, errors[0]
    assert clamped[0] > 0

    account = fields(ports[0], ACCOUNTS, 1)
    assert int(account["available"]) + int(account["held"]) == funded, account
    assert int(account["held"]) == sum(taken_by_thread), account
    assert int(account["available"]) == 0, account
    return funded, threads * rounds, clamped[0], last_op[0]


def check_totals(ports, funded, last_op):
    status, body = request(ports[0], "PUT", "/v1/views/ledger_totals", {
        "table": ACCOUNTS,
        "aggregates": [{"fn": "sum", "field": "available"}, {"fn": "sum", "field": "held"}]})
    assert status == 200 and body["maintained"], body
    # Ready once the rows written before the declaration are in (pulses).
    for _ in range(200):
        status, body = request(ports[1], "GET", f"/v1/views/ledger_totals?min_op={last_op}")
        if status == 200:
            break
        assert status == 503, body
    assert status == 200, body
    assert int(body["op"]) >= last_op, body
    (group,) = body["groups"]
    assert int(group["sum_available"]) + int(group["sum_held"]) == funded, body
    assert int(fields(ports[1], SOURCES, 1)["balance"]) == -funded


def check_refusals(ports):
    port = ports[1]
    fund(port, 2, 10)
    before = (fields(port, ACCOUNTS, 2), fields(port, SOURCES, 1))

    unpaired = [
        # A first half alone; a partner alone; a conserved add without `pair`.
        [move(SOURCES, 1, "balance", delta=-5, pair=True)],
        [move(ACCOUNTS, 2, "held", delta=5)],
        # A partner that clamps, or sits outside the ledger (`note`), or another add naming
        # the first half.
        [move(ACCOUNTS, 2, "available", delta=-5, pair=True),
         move(ACCOUNTS, 2, "held", delta_from=0, clamp=True)],
        [move(ACCOUNTS, 2, "available", delta=-5, pair=True),
         {"kind": "add", "table": ACCOUNTS, "id": "2", "field": "note", "delta_from": 0}],
        [move(ACCOUNTS, 2, "available", delta=-5, pair=True),
         move(ACCOUNTS, 2, "held", delta_from=0),
         move(ACCOUNTS, 3, "available", delta_from=0, create=True)],
    ]
    for entries in unpaired:
        status, body = commit(port, entries)
        assert status == 409 and body["status"] == "unpaired", (entries, status, body)
    status, body = commit(port, unpaired[2])
    assert body == {"status": "unpaired", "index": 1}, body

    # A partner stopped by its floor: the whole transaction is out_of_bounds.
    status, body = commit(port, [move(ACCOUNTS, 2, "held", delta=20, pair=True),
                                 move(ACCOUNTS, 2, "available", delta_from=0)])
    assert status == 409 and body == {"status": "out_of_bounds", "index": 1, "value": "10"}, body
    # A first half stopped by its floor, without clamp.
    status, body = commit(port, [move(ACCOUNTS, 2, "available", delta=-11, pair=True),
                                 move(ACCOUNTS, 2, "held", delta_from=0)])
    assert status == 409 and body == {"status": "out_of_bounds", "index": 0, "value": "10"}, body

    conserved_writes = [
        [{"kind": "put", "table": ACCOUNTS, "id": "2", "fields": {"available": "0", "note": "1"}}],
        [{"kind": "put", "table": ACCOUNTS, "id": "4", "fields": {"held": "3"}}],
        [{"kind": "delete", "table": ACCOUNTS, "id": "2"}],
        [{"kind": "add", "table": ACCOUNTS, "id": "2", "offset": 4, "type": "i64", "delta": "1"}],
        [{"kind": "add", "table": ACCOUNTS, "id": "2", "offset": 0, "type": "u64", "delta": "1"}],
    ]
    for entries in conserved_writes:
        status, body = commit(port, entries)
        assert status == 409 and body == {"status": "conserved_write", "index": 0}, (entries, body)
    assert (fields(port, ACCOUNTS, 2), fields(port, SOURCES, 1)) == before

    # Puts that leave balances alone, and deletes of empty accounts, commit.
    status, body = commit(port, [{"kind": "put", "table": ACCOUNTS, "id": "2",
                                  "fields": {"available": "10", "note": "7"}},
                                 {"kind": "put", "table": ACCOUNTS, "id": "5",
                                  "fields": {"note": "1"}}])
    assert status == 200, body
    status, body = commit(port, [{"kind": "delete", "table": ACCOUNTS, "id": "5"}])
    assert status == 200, body

    # Declarations.
    different = {"fields": [dict(field) for field in LEDGER["fields"]]}
    different["fields"][0]["floor"] = "0"
    status, body = request(port, "PUT", "/v1/ledgers/1", different)
    assert status == 409 and body == {"status": "ledger_immutable", "ledger": 1}, body
    status, body = request(port, "PUT", "/v1/ledgers/2", {"fields": [
        {"table": ACCOUNTS, "offset": 8}, {"table": ACCOUNTS, "offset": 24}]})
    assert status == 409 and body == {"status": "ledger_field_taken", "ledger": 2}, body
    assert request(port, "GET", "/v1/ledgers/2")[0] == 404

    # A view grouping by a field, then a ledger over it; a ledger, then a view filtering on it.
    status, body = request(port, "PUT", "/v1/views/by_kind", {
        "table": GROUPED, "group_by": ["kind"], "aggregates": [{"fn": "count"}]})
    assert status == 200 and body["maintained"], body
    status, body = request(port, "PUT", "/v1/ledgers/3", {"fields": [
        {"table": GROUPED, "field": "kind"}, {"table": GROUPED, "field": "amount"}]})
    assert status == 409 and body == {"status": "field_viewed", "ledger": 3}, body
    status, body = request(port, "PUT", "/v1/views/funded", {
        "table": ACCOUNTS, "where": [{"field": "available", "op": "gt", "value": 0}],
        "aggregates": [{"fn": "count"}]})
    assert status == 409, body
    assert request(port, "GET", "/v1/views/funded/definition")[0] == 404

    invalid = [
        ("/v1/ledgers/0", LEDGER),
        ("/v1/ledgers/x", LEDGER),
        ("/v1/ledgers/4294967296", LEDGER),
        ("/v1/ledgers/4", {"fields": [{"table": ACCOUNTS, "offset": 32}]}),
        ("/v1/ledgers/4", {"fields": [{"table": ACCOUNTS, "offset": 32},
                                      {"table": ACCOUNTS, "offset": 36}]}),
        ("/v1/ledgers/4", {"fields": [{"table": ACCOUNTS, "offset": 32},
                                      {"table": ACCOUNTS, "offset": 32}]}),
        ("/v1/ledgers/4", {"fields": [{"table": ACCOUNTS, "offset": 32},
                                      {"table": ACCOUNTS, "field": "note"}]}),
        ("/v1/ledgers/4", {"fields": [{"table": ACCOUNTS, "offset": 32},
                                      {"table": ACCOUNTS, "offset": 40, "field": "held"}]}),
        ("/v1/ledgers/4", {"fields": [{"table": ACCOUNTS, "offset": 32},
                                      {"table": 4294901761, "offset": 0}]}),
        ("/v1/ledgers/4", {"fields": [{"table": ACCOUNTS, "offset": 32, "floor": "x"},
                                      {"table": ACCOUNTS, "offset": 40}]}),
    ]
    for target, declaration in invalid:
        status, body = request(port, "PUT", target, declaration)
        assert status == 400, (target, declaration, status, body)
    assert request(port, "GET", "/v1/ledgers/1?x=1")[0] == 400
    assert request(port, "POST", "/v1/ledgers/1", LEDGER)[0] == 405


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    cluster = Cluster(nerva)
    try:
        ports = cluster.ports
        declare(ports)
        funded, reservations, clamped, last_op = reservation_race(ports, seed)
        check_totals(ports, funded, last_op)
        check_refusals(ports)
        print(f"ledgers: PASSED ({reservations} clamped reservations from 50 threads, none "
              f"retried, {clamped} clamped; available + held = {funded}; seed {seed})")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
