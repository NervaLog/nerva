#!/usr/bin/env python3
"""Records, declared indexes and views over records through `nerva api` (P123b, P123c).

Runs one replica and two API gateways, keeps a model of a table of "executions" (a record
table: 128-bit ids, 448-byte values), and requires:

- a record and a row to commit in one transaction (sent as `commit_wide`); lookups (of records
  or of rows, never both in one), stale reads (409 with the record's version), deletes,
  `/v1/history`, `/v1/row?as_of` and the merged `/v1/changes` feed (rows and records in one
  order, each change once, paged by one cursor) to answer as the model says;
- record ids to be 32 hex digits, given back as sent; adds and short ids to be refused;
- two indexes declared over existing records (one partial: `status == reserved`, by `created`;
  one by `agent`, by `created`) to build by themselves, then to answer every scan (each agent,
  ascending and descending, `min`/`max` bounds, pages of 3 that cross runs of equal `created`)
  as the model does, before and after rounds of random puts, moves out of the partial index,
  and deletes;
- a second declaration of the same index to answer `exists`, a different one under the same
  name 409 `different`, and an index over a row table or an unknown field 400;
- a view over the records (count and sum of `amount`, by `status`) to build and equal the
  model; `min` over a record table to be refused;
- indexes to be listed under `/v1/indexes`, and read one by one.

Usage: records.py <path to nerva> [--seed=N]
"""
import os, random, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from api import Cluster, request  # noqa: E402

TABLE = 0x8000_0007          # a record table (P123b)
ROWS = 41                    # a row table, beside it
LAYOUT = {"name": "executions", "fields": [
    {"name": "agent", "type": "bytes", "size": 16},
    {"name": "status", "type": "u8"},
    {"name": "created", "type": "u64"},
    {"name": "amount", "type": "u64"},
    {"name": "memo", "type": "bytes", "size": 200},
]}
RESERVED, SETTLED, RELEASED = 1, 2, 3
AGENTS = ["%032x" % (0xA6E7 << 100 | n) for n in range(5)]
REAPER = {"table": TABLE, "order": "created",
          "where": [{"field": "status", "op": "eq", "value": RESERVED}]}
BY_AGENT = {"table": TABLE, "eq": ["agent"], "order": "created"}
SPEND = {"table": TABLE, "group_by": ["status"],
         "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "amount"}]}


def commit(port, entries):
    return request(port, "POST", "/v1/commit", {"entries": entries})


class Model:
    def __init__(self, rng):
        self.rng = rng
        self.records = {}   # id -> (op, fields)

    def fields(self):
        return {"agent": self.rng.choice(AGENTS),
                "status": self.rng.choice([RESERVED, RESERVED, SETTLED, RELEASED]),
                # Few distinct values, so that scans page across ties.
                "created": str(self.rng.randrange(1, 40)),
                "amount": str(self.rng.randrange(1, 10_000)),
                "memo": self.rng.randbytes(self.rng.randrange(1, 200)).hex()}

    def new_id(self):
        return "%032x" % self.rng.getrandbits(128)

    def apply(self, port, writes):
        """Commits puts (id, fields) and deletes (id, None) in one transaction."""
        entries = [{"kind": "put", "table": TABLE, "id": id_, "fields": fields} if fields
                   else {"kind": "delete", "table": TABLE, "id": id_} for id_, fields in writes]
        status, body = commit(port, entries)
        assert status == 200, (status, body)
        op = int(body["op"])
        for id_, fields in writes:
            if fields:
                self.records[id_] = (op, fields)
            else:
                self.records.pop(id_, None)
        return op

    def round(self, port, count):
        writes, touched = [], set()
        for _ in range(count):
            choice = self.rng.random()
            existing = [i for i in self.records if i not in touched]
            if choice < 0.5 or not existing:
                id_ = self.new_id()
                writes.append((id_, self.fields()))
            elif choice < 0.85:
                id_ = self.rng.choice(existing)
                fields = dict(self.records[id_][1])
                fields["status"] = self.rng.choice([RESERVED, SETTLED, RELEASED])
                fields["created"] = str(self.rng.randrange(1, 40))
                writes.append((id_, fields))
            else:
                id_ = self.rng.choice(existing)
                writes.append((id_, None))
            touched.add(id_)
        return self.apply(port, writes)

    def scan(self, where=None, agent=None, low=0, high=2**64 - 1, descending=False):
        """The ids an index scan answers, in its order: (created, then first written)."""
        matched = [(int(f["created"]), id_) for id_, (_, f) in self.records.items()
                   if (where is None or f["status"] == where)
                   and (agent is None or f["agent"] == agent)
                   and low <= int(f["created"]) <= high]
        return matched, descending


def memo_padded(memo):
    return memo.ljust(400, "0")


def same_fields(served, written):
    return (served["agent"] == written["agent"] and served["status"] == written["status"]
            and served["created"] == written["created"]
            and served["amount"] == written["amount"]
            and served["memo"] == memo_padded(written["memo"]))


def scan_all(port, name, eq=None, low=None, high=None, descending=False, limit=3):
    records, after, pages = [], None, 0
    while True:
        body = {"limit": limit, "descending": descending}
        if eq is not None:
            body["eq"] = eq
        if low is not None:
            body["min"] = str(low)
        if high is not None:
            body["max"] = str(high)
        if after is not None:
            body["after"] = after
        status, page = request(port, "POST", f"/v1/indexes/{name}/scan", body)
        assert status == 200, (status, page)
        assert len(page["records"]) <= limit, page
        records += page["records"]
        pages += 1
        after = page["next"]
        if after is None:
            return records, pages


def check_scan(port, model, name, where=None, agent=None, low=None, high=None, descending=False):
    expected, _ = model.scan(where, agent, low or 0, high if high is not None else 2**64 - 1)
    records, _ = scan_all(port, name, {"agent": agent} if agent else None, low, high, descending)
    served = [(int(r["order"]), r["id"]) for r in records]
    orders = [order for order, _ in served]
    assert orders == sorted(orders, reverse=descending), (name, orders)
    # Within a run of equal `created`, the order is the index's (first written); compare sets.
    assert sorted(served) == sorted(expected), (name, agent, sorted(served)[:5], sorted(expected)[:5])
    for record in records:
        op, fields = model.records[record["id"]]
        assert int(record["op"]) == op, (record, op)
        assert same_fields(record["fields"], fields), (record["fields"], fields)
    return len(records)


def check_all_scans(port, model, rng):
    count = check_scan(port, model, "reaper", where=RESERVED)
    check_scan(port, model, "reaper", where=RESERVED, descending=True)
    low = rng.randrange(1, 40)
    check_scan(port, model, "reaper", where=RESERVED, low=low, high=low + rng.randrange(0, 10))
    for agent in AGENTS:
        check_scan(port, model, "by_agent", agent=agent)
        check_scan(port, model, "by_agent", agent=agent, descending=True, low=5, high=30)
    return count


def wait_ready(port, name, deadline=60):
    end = time.time() + deadline
    while True:
        status, body = request(port, "POST", f"/v1/indexes/{name}/scan",
                               {"eq": {"agent": AGENTS[0]}} if name == "by_agent" else {})
        if status == 200:
            return
        assert status == 503, (status, body)
        assert time.time() < end, f"index {name} did not finish building"
        time.sleep(0.2)


def check_records_beside_rows(port, model):
    assert request(port, "PUT", f"/v1/tables/{ROWS}", {"name": "budgets", "fields": [
        {"name": "available", "type": "u64"}]})[0] == 200
    id_ = model.new_id()
    fields = model.fields()
    status, body = commit(port, [
        {"kind": "put", "table": ROWS, "id": "1", "fields": {"available": "100"}},
        {"kind": "put", "table": TABLE, "id": id_, "fields": fields}])
    assert status == 200, body
    op = int(body["op"])
    model.records[id_] = (op, fields)

    status, body = request(port, "POST", "/v1/lookup", {"rows": [
        {"table": TABLE, "id": id_}, {"table": TABLE, "id": model.new_id()}]})
    assert status == 200, body
    record, absent = body["rows"]
    status, body = request(port, "POST", "/v1/lookup", {"rows": [{"table": ROWS, "id": "1"}]})
    assert status == 200, body
    row = body["rows"][0]
    # One lookup is one operation: rows and records are read by two.
    status, body = request(port, "POST", "/v1/lookup", {"rows": [
        {"table": TABLE, "id": id_}, {"table": ROWS, "id": "1"}]})
    assert status == 400, body
    assert record["id"] == id_ and record["exists"] and int(record["op"]) == op, record
    assert len(record["value_hex"]) == 896 and same_fields(record["fields"], fields), record
    assert row["fields"] == {"available": "100"} and len(row["value_hex"]) == 160, row
    assert not absent["exists"] and absent["op"] == "0", absent

    # A stale read of a record: 409 with its version; nothing applies.
    status, body = commit(port, [
        {"kind": "read", "table": TABLE, "id": id_, "op_seen": str(op - 1)},
        {"kind": "put", "table": ROWS, "id": "1", "fields": {"available": "1"}}])
    assert status == 409 and body["status"] == "conflict" and body["index"] == 0, body
    assert body["op"] == str(op), body
    # A current read commits, and the record's delete with it.
    status, body = commit(port, [
        {"kind": "read", "table": TABLE, "id": id_, "op_seen": str(op)},
        {"kind": "delete", "table": TABLE, "id": id_}])
    assert status == 200, body
    deleted = int(body["op"])
    del model.records[id_]

    # History, newest first; the record as of each op.
    status, body = request(port, "GET", f"/v1/history?table={TABLE}&id={id_}&limit=10")
    assert status == 200, body
    assert [(c["kind"], c["op"]) for c in body["changes"]] == \
        [("delete", str(deleted)), ("put", str(op))], body
    status, body = request(port, "GET", f"/v1/row?table={TABLE}&id={id_}&as_of={op}")
    assert status == 200 and body["exists"] and same_fields(body["fields"], fields), body
    status, body = request(port, "GET", f"/v1/row?table={TABLE}&id={id_}&as_of={deleted}")
    assert status == 200 and not body["exists"], body
    status, body = request(port, "GET", f"/v1/row?table={TABLE}&id={id_}&as_of={op - 1}")
    assert status == 200 and not body["exists"] and body["op"] == "0", body

    # Refused: adds to a record, a short or non-hex record id, a record id on a row table.
    status, body = commit(port, [{"kind": "add", "table": TABLE, "id": id_, "field": "amount",
                                  "delta": "1", "create": True}])
    assert status in (400, 409), (status, body)
    for table, bad_id in [(TABLE, "5"), (TABLE, "g" * 32), (TABLE, "0" * 34), (ROWS, id_)]:
        status, body = request(port, "POST", "/v1/lookup",
                               {"rows": [{"table": table, "id": bad_id}]})
        assert status == 400, (table, bad_id, body)
    # A bytes field may be up to 255 bytes in a record, and the layout fits 448.
    status, body = request(port, "PUT", f"/v1/tables/{TABLE + 1}", {"name": "too_wide", "fields": [
        {"name": "a", "type": "bytes", "size": 255}, {"name": "b", "type": "bytes", "size": 255}]})
    assert status == 400, body


def check_feed(port, model):
    """The merged feed: every change once, in op order, across rows and records."""
    seen, cursor, last = [], "0", 0
    while True:
        status, body = request(port, "GET", f"/v1/changes?cursor={cursor}&limit=7")
        assert status == 200, body
        for change in body["changes"]:
            op = int(change["op"])
            assert op >= last, (op, last)
            last = op
            seen.append((change["table"], change["id"], change["kind"], change["op"]))
        cursor = body["cursor"]
        if not body["more"]:
            break
    assert len(set(seen)) == len(seen), "a change appeared twice"
    tables = {table for table, _, _, _ in seen}
    assert TABLE in tables and ROWS in tables, tables
    latest = {}
    for table, id_, kind, op in seen:
        if table == TABLE:
            latest[id_] = (kind, int(op))
    live = {id_: op for id_, (kind, op) in latest.items() if kind == "put"}
    assert live == {id_: op for id_, (op, _) in model.records.items()}, "feed and model differ"
    return len(seen)


def check_declarations(port):
    status, body = request(port, "PUT", "/v1/indexes/reaper", REAPER)
    assert status == 200 and body["declared"] == "exists", body
    status, body = request(port, "PUT", "/v1/indexes/reaper", BY_AGENT)
    assert status == 409 and body["status"] == "different", body
    status, body = request(port, "PUT", "/v1/indexes/rows", {"table": ROWS, "order": "available"})
    assert status == 400, body
    status, body = request(port, "PUT", "/v1/indexes/nope", {"table": TABLE, "eq": ["missing"]})
    assert status == 400, body
    status, body = request(port, "GET", "/v1/indexes/reaper")
    assert status == 200 and body["name"] == "reaper", body
    status, body = request(port, "GET", "/v1/indexes")
    assert status == 200 and [i["name"] for i in body["indexes"]] == ["reaper", "by_agent"], body
    assert request(port, "GET", "/v1/indexes/absent")[0] == 404
    assert request(port, "POST", "/v1/indexes/absent/scan", {})[0] == 404
    # by_agent needs its eq key; reaper has none.
    assert request(port, "POST", "/v1/indexes/by_agent/scan", {})[0] == 400
    assert request(port, "POST", "/v1/indexes/reaper/scan", {"eq": {"agent": AGENTS[0]}})[0] == 400


def check_view(port, model, deadline=60):
    end = time.time() + deadline
    while True:
        status, body = request(port, "GET", "/v1/views/spend/groups?limit=100")
        assert status == 200, (status, body)
        if body["state"] == "ready":
            break
        assert time.time() < end, "the view over records did not finish building"
        time.sleep(0.2)
    expected = {}
    for _, fields in model.records.values():
        count, total = expected.get(fields["status"], (0, 0))
        expected[fields["status"]] = (count + 1, total + int(fields["amount"]))
    served = {g["status"]: (int(g["count"]), int(g["sum_amount"])) for g in body["groups"]}
    assert served == expected, (served, expected)


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    rng = random.Random(seed)
    model = Model(rng)
    cluster = Cluster(nerva)
    try:
        ports = cluster.ports
        status, body = request(ports[0], "PUT", f"/v1/tables/{TABLE}", LAYOUT)
        assert status == 200, body
        check_records_beside_rows(ports[0], model)
        # Records before any index, so that both indexes build over them.
        for _ in range(12):
            model.round(ports[0], 40)
        for name, definition in (("reaper", REAPER), ("by_agent", BY_AGENT)):
            status, body = request(ports[1], "PUT", f"/v1/indexes/{name}", definition)
            assert status == 200 and body["declared"] == "created", body
        status, body = request(ports[1], "PUT", "/v1/views/spend", SPEND)
        assert status == 200 and body["maintained"] is True, body
        bad_view = {"table": TABLE, "aggregates": [{"fn": "count"}, {"fn": "min", "field": "amount"}]}
        status, body = request(ports[1], "PUT", "/v1/views/spend_min", bad_view)
        assert status in (400, 409), (status, body)
        wait_ready(ports[0], "reaper")
        wait_ready(ports[0], "by_agent")
        check_declarations(ports[0])
        check_all_scans(ports[0], model, rng)
        check_view(ports[0], model)
        reserved = 0
        for round_ in range(20):
            model.round(ports[round_ % 2], rng.randrange(1, 30))
            reserved = check_all_scans(ports[(round_ + 1) % 2], model, rng)
        check_view(ports[0], model)
        changes = check_feed(ports[1], model)
        print(f"records: PASSED ({len(model.records)} records, {reserved} reserved, "
              f"{changes} changes; seed {seed})")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
