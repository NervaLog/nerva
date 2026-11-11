#!/usr/bin/env python3
"""A cluster upgraded to another release keeps its data (docs/DECISIONS.md N80, NV-2).

Usage: upgrade.py <nerva> <nerva of another release> [--records]

With `--records` (P123b, P123c), the script also writes records (128-bit ids, 448-byte values)
in the same commits as rows, and deletes some; declares an index before them and one after them
(built by pulses, before and after the import), and a view over them. Their lookups, histories,
`row?as_of`, index scans and view are recorded and compared too, and the export is format
version 2. Without it, the cluster holds no records and the export is version 1.

On `nerva` (this build) three replicas run a fixed script through `nerva api`: layouts, puts,
deletes, adds, reads, documents, a view declared before its table has rows, a ledger moved by
pairs, then a view declared over rows that already exist. The test records what a client sees:
every view (hash, groups, as of several ops), the ledger and its total, every row's history and
`row?as_of` at a spread of ops, the change feed page by page with its cursors, and documents.

`nerva export` writes the cluster's export; the old replicas stop. The other release (`0.0.200`,
which `zig build test:release` builds: the same code under another release string) runs
`nerva import` once per replica and starts three replicas from the files. Everything recorded
must read the same, the view over existing rows once the new cluster's pulses have built it; a
version read before the upgrade still commits (`op_seen`), and a feed cursor from before
continues. The new cluster then commits on, loses a replica, commits on, and takes it back.
Last, an export with one byte changed is refused, and the data file it began is removed.

Both sides here are builds of this commit. Once a published release contains `nerva export`,
this test fetches the previous release's binary, as CI fetches releases, and exports with it.
"""
import http.client
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

# Replicas authenticate each other with a real cluster key, never the development key (P102).
os.environ["NERVA_CLUSTER_KEY"] = os.urandom(32).hex()

KEY = "upgrade-test-key"
SEATS = 5        # A layout; the early view and the late view.
COUNTERS = 6     # No layout: raw values and adds.
ACCOUNTS = 40    # The ledger: available and held, floored at zero.
SOURCES = 41     # The ledger: balance, no floor.
SEATS_LAYOUT = {"name": "seats", "fields": [{"name": "section", "type": "u8"},
                                            {"name": "price", "type": "u64"},
                                            {"name": "sold", "type": "bool"}]}
ACCOUNTS_LAYOUT = {"name": "accounts", "fields": [{"name": "available", "type": "i64"},
                                                  {"name": "held", "type": "i64"}]}
SOURCES_LAYOUT = {"name": "sources", "fields": [{"name": "balance", "type": "i64"}]}
EARLY = {"table": SEATS, "group_by": ["section"],
         "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"},
                        {"fn": "min", "field": "price"}, {"fn": "max", "field": "price"}]}
LATE = {"table": SEATS, "where": [{"field": "sold", "op": "eq", "value": True}],
        "group_by": ["section"], "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"}]}
LEDGER = {"fields": [{"table": ACCOUNTS, "field": "available", "floor": "0"},
                     {"table": ACCOUNTS, "field": "held", "floor": "0"},
                     {"table": SOURCES, "field": "balance", "floor": None}]}
ROUNDS = 1100    # Past the first checkpoint (op 959): the import checkpoints more than once.
RECORDS = "--records" in sys.argv[3:]
FACTS = 0x8000_0001   # A record table (P123b).
FACTS_LAYOUT = {"name": "facts", "fields": [{"name": "agent", "type": "bytes", "size": 16},
                                            {"name": "status", "type": "u8"},
                                            {"name": "created", "type": "u64"},
                                            {"name": "amount", "type": "u64"},
                                            {"name": "memo", "type": "bytes", "size": 255}]}
# Declared before any record, and after (built by pulses on both sides of the import).
EARLY_INDEX = {"table": FACTS, "eq": ["agent"], "order": "created"}
LATE_INDEX = {"table": FACTS, "order": "created",
              "where": [{"field": "status", "op": "eq", "value": 1}]}
FACTS_VIEW = {"table": FACTS, "group_by": ["status"],
              "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "amount"}]}
AGENTS = ["%032x" % (0xA6E7 << 100 | n) for n in range(3)]


def free_ports(count):
    sockets = [socket.socket() for _ in range(count)]
    for s in sockets:
        s.bind(("127.0.0.1", 0))
    ports = [s.getsockname()[1] for s in sockets]
    for s in sockets:
        s.close()
    return ports


def request(port, method, target, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    try:
        connection.request(method, target, body=None if body is None else json.dumps(body),
                           headers={"X-Nerva-Key": KEY})
        response = connection.getresponse()
        return response.status, json.loads(response.read() or b"null")
    finally:
        connection.close()


def ok(port, method, target, body=None):
    status, reply = request(port, method, target, body)
    assert status == 200, (method, target, body, status, reply)
    return reply


class Cluster:
    """Three replicas of `nerva`, from data files that `prepare(index, path)` creates."""

    def __init__(self, tmp, name, nerva, prepare):
        self.tmp, self.name, self.nerva = tmp, name, nerva
        self.addresses = ",".join(str(port) for port in free_ports(3))
        self.replicas = [None] * 3
        self.gateways = []
        for index in range(3):
            prepare(index, self.data_file(index))
        for index in range(3):
            self.start(index)

    def data_file(self, index):
        return os.path.join(self.tmp, f"{self.name}_{index}.nerva")

    def log(self, index):
        with open(self.data_file(index) + ".log", errors="replace") as f:
            return f.read()

    def start(self, index):
        assert self.replicas[index] is None
        self.replicas[index] = subprocess.Popen(
            [self.nerva, "start", f"--addresses={self.addresses}", "--development",
             self.data_file(index)],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=open(self.data_file(index) + ".log", "a"))

    def stop(self, index):
        self.replicas[index].kill()
        self.replicas[index].wait()
        self.replicas[index] = None

    def wait_listening(self):
        """Waits until each running replica accepts connections on its port. A replica takes a
        while to open its data file before it listens, and a gateway gives up on a port that is
        not open yet (#155)."""
        deadline = time.monotonic() + 120
        ports = [int(port) for port in self.addresses.split(",")]
        for index, replica in enumerate(self.replicas):
            if replica is None:
                continue
            while True:
                assert replica.poll() is None, self.log(index)[-3000:]
                try:
                    socket.create_connection(("127.0.0.1", ports[index]), timeout=1).close()
                    break
                except OSError:
                    assert time.monotonic() < deadline, self.log(index)[-3000:]
                    time.sleep(0.1)

    def gateway(self):
        self.wait_listening()
        process = subprocess.Popen(
            [self.nerva, "api", "--cluster=0", f"--addresses={self.addresses}",
             "--listen=127.0.0.1:0"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, env={**os.environ, "NERVA_KEY": KEY}, text=True)
        self.gateways.append(process)
        return int(process.stdout.readline())

    def check_running(self):
        for index, replica in enumerate(self.replicas):
            if replica is None:
                continue
            assert replica.poll() is None, f"replica {index} exited: {self.log(index)[-3000:]}"
            assert "panic" not in self.log(index), self.log(index)[-3000:]

    def close(self, remove=True):
        for process in self.gateways + [r for r in self.replicas if r is not None]:
            process.kill()
            process.wait()
        self.gateways = []
        self.replicas = [None] * 3
        if remove:  # Data files are large: remove them as soon as they are done with.
            for index in range(3):
                for path in (self.data_file(index), self.data_file(index) + ".log"):
                    if os.path.exists(path):
                        os.remove(path)


def seat(id, section, price, sold):
    return {"kind": "put", "table": SEATS, "id": str(id),
            "fields": {"section": section, "price": price, "sold": sold}}


def move(table, row, field, **options):
    entry = {"kind": "add", "table": table, "id": str(row), "field": field}
    for name, value in options.items():
        entry[name] = str(value) if name in ("delta", "min", "max") else value
    return entry


def commit(port, entries):
    return int(ok(port, "POST", "/v1/commit", {"entries": entries})["op"])


def fact_id(n):
    return "%032x" % (0xFAC7 << 112 | n * 0x9E3779B97F4A7C15)


def fact(round):
    return {"kind": "put", "table": FACTS, "id": fact_id(round % 61), "fields": {
        "agent": AGENTS[round % 3], "status": round % 3 + 1, "created": str(round % 23),
        "amount": str(round * 7), "memo": f"{round:08x}" * (round % 32 + 1)}}


def index_ready(port, name, body):
    status, reply = request(port, "POST", f"/v1/indexes/{name}/scan", body)
    assert status in (200, 503), (status, reply)
    return status == 200


def script(port):
    """The fixed script; returns the ops of interest."""
    for table, layout in ((SEATS, SEATS_LAYOUT), (ACCOUNTS, ACCOUNTS_LAYOUT),
                          (SOURCES, SOURCES_LAYOUT)):
        ok(port, "PUT", f"/v1/tables/{table}", layout)
    early = ok(port, "PUT", "/v1/views/early", EARLY)
    assert early["maintained"], early
    if RECORDS:
        ok(port, "PUT", f"/v1/tables/{FACTS}", FACTS_LAYOUT)
        assert ok(port, "PUT", "/v1/indexes/by_agent", EARLY_INDEX)["declared"] == "created"
    ledger = ok(port, "PUT", "/v1/ledgers/1", LEDGER)
    assert ledger["declared"] == "created", ledger
    commit(port, [move(SOURCES, 1, "balance", delta=-100000, pair=True, create=True),
                  move(ACCOUNTS, 1, "available", delta_from=0, create=True)])
    ops = []
    for round in range(ROUNDS):
        id = round % 97
        entries = [seat(id, round % 5, (round * 37) % 1000, round % 3 != 0)]
        if round % 7 == 0:
            entries.append({"kind": "put", "table": COUNTERS, "id": str(round % 11),
                            "value_hex": f"{round:016x}"})
        if round % 5 == 0:
            entries.append({"kind": "add", "table": COUNTERS, "id": "1000", "offset": 8,
                            "type": "u64", "delta": "3", "create": True})
        if round % 13 == 0:
            entries = [{"kind": "delete", "table": SEATS, "id": str((round + 50) % 97)}]
        if round % 17 == 0:
            entries = [move(ACCOUNTS, 1, "available", delta=-(round % 40 + 1), pair=True,
                            clamp=True),
                       move(ACCOUNTS, 1, "held", delta_from=0)]
        if RECORDS and round % 3 == 0:
            entries.append(fact(round))
        if RECORDS and round % 19 == 0:
            entries.append({"kind": "delete", "table": FACTS, "id": fact_id((round + 30) % 61)})
        ops.append(commit(port, entries))
        if round % 50 == 0:
            ok(port, "POST", "/v1/lookup", {"rows": [{"table": SEATS, "id": str(id)}]})
        if round % 100 == 0:
            ok(port, "POST", "/v1/documents/commit", {"namespace": "7", "writes": [
                {"key": f"doc/{round}", "value_hex": f"{round:08x}" * 64}]})
    # A view over rows that already exist: built by pulses, here and again after the import.
    late = ok(port, "PUT", "/v1/views/late", LATE)
    assert late["maintained"], late
    deadline = time.monotonic() + 60
    while ok(port, "GET", "/v1/views/late/groups?limit=1")["state"] != "ready":
        assert time.monotonic() < deadline, "the late view never became ready"
        time.sleep(0.1)
    if RECORDS:
        assert ok(port, "PUT", "/v1/indexes/reserved", LATE_INDEX)["declared"] == "created"
        assert ok(port, "PUT", "/v1/views/facts", FACTS_VIEW)["maintained"]
        wait_records_ready(port)
    ops.append(commit(port, [seat(1, 2, 1, True), {"kind": "delete", "table": SEATS, "id": "2"}]))
    return ops


def wait_records_ready(port):
    deadline = time.monotonic() + 120
    while not (index_ready(port, "reserved", {}) and
               index_ready(port, "by_agent", {"eq": {"agent": AGENTS[0]}}) and
               ok(port, "GET", "/v1/views/facts/groups?limit=1")["state"] == "ready"):
        assert time.monotonic() < deadline, "the records' indexes and view never became ready"
        time.sleep(0.1)


def keys():
    return ([(SEATS, id) for id in range(97)] + [(COUNTERS, id) for id in range(11)] +
            [(COUNTERS, 1000), (ACCOUNTS, 1), (SOURCES, 1)])


def fact_keys():
    return [(FACTS, fact_id(n)) for n in range(61)] if RECORDS else []


def scan(port, name, body):
    """Every record of an index scan, page by page."""
    records, after = [], None
    while True:
        page = dict(body, limit=7, **({"after": after} if after else {}))
        reply = ok(port, "POST", f"/v1/indexes/{name}/scan", page)
        records += reply["records"]
        after = reply["next"]
        if after is None:
            return records


def view_groups(port, name, as_of=None):
    """The view's header and every group, from the replicated groups."""
    groups, cursor, header = [], None, None
    while True:
        target = f"/v1/views/{name}/groups?limit=1000"
        if cursor is not None:
            target += f"&cursor={cursor}"
        if as_of is not None:
            target += f"&as_of={as_of}"
        body = ok(port, "GET", target)
        # Indexed, not `get`: a key renamed away must fail here, not compare None with None.
        header = {k: body[k] for k in ("state", "view_hash", "group_count")}
        groups += body["groups"]
        if not body["more"]:
            return header, groups
        cursor = body["cursor"]


def history(port, table, id):
    changes, cursor = [], None
    while True:
        target = f"/v1/history?table={table}&id={id}&op_max=latest&limit=64"
        if cursor is not None:
            target += f"&cursor={cursor}"
        body = ok(port, "GET", target)
        changes += body["changes"]
        if not body["more"]:
            return changes
        cursor = body["cursor"]


def feed(port):
    """Every change, and the cursor after each page of 100."""
    changes, cursors, cursor = [], [], "0"
    while True:
        body = ok(port, "GET", f"/v1/changes?cursor={cursor}&limit=100")
        changes += body["changes"]
        cursor = body["cursor"]
        cursors.append(cursor)
        if not body["more"]:
            return changes, cursors


def record(port, ops):
    """What a client sees, for comparison across the upgrade."""
    as_of_ops = ops[::37] + [ops[-1]]
    seen = {
        "early": view_groups(port, "early"),
        "late": view_groups(port, "late"),
        # As of past ops, the view declared before rows reads the same after the upgrade.
        "early_as_of": [view_groups(port, "early", op) for op in ops[5::150]],
        "ledger": ok(port, "GET", "/v1/ledgers/1"),
        "rows": ok(port, "POST", "/v1/lookup",
                   {"rows": [{"table": t, "id": str(i)} for t, i in keys()]})["rows"],
        "history": {f"{t}/{i}": history(port, t, i) for t, i in keys()},
        "as_of": {f"{t}/{i}/{op}": ok(port, "GET", f"/v1/row?table={t}&id={i}&as_of={op}")
                  for t, i in keys()[::3] for op in as_of_ops},
        "feed": feed(port),
        "documents": ok(port, "POST", "/v1/documents/get", {
            "namespace": "7", "keys": [f"doc/{r}" for r in range(0, ROUNDS, 100)]})["documents"],
    }
    if RECORDS:
        seen["records"] = ok(port, "POST", "/v1/lookup",
                             {"rows": [{"table": t, "id": i} for t, i in fact_keys()]})["rows"]
        for row in seen["records"]:
            row.pop("op_read", None)
        assert sum(r["exists"] for r in seen["records"]) > 30, seen["records"]
        seen["record_history"] = {i: history(port, t, i) for t, i in fact_keys()}
        seen["record_as_of"] = {
            f"{i}/{op}": ok(port, "GET", f"/v1/row?table={t}&id={i}&as_of={op}")
            for t, i in fact_keys()[::5] for op in as_of_ops}
        seen["indexes"] = ok(port, "GET", "/v1/indexes")
        seen["scans"] = {
            "reserved": scan(port, "reserved", {}),
            "reserved_down": scan(port, "reserved", {"descending": True, "min": "3", "max": "17"}),
            **{agent: scan(port, "by_agent", {"eq": {"agent": agent}}) for agent in AGENTS}}
        assert seen["scans"]["reserved"], seen["scans"]
        seen["facts"] = view_groups(port, "facts")
        assert seen["facts"][0]["state"] == "ready", seen["facts"][0]
        assert any(c["table"] == FACTS for c in seen["feed"][0]), "no record in the feed"
    for row in seen["rows"]:
        row.pop("op_read", None)
    account = next(r for r in seen["rows"] if r["table"] == ACCOUNTS)
    source = next(r for r in seen["rows"] if r["table"] == SOURCES)
    seen["ledger_total"] = (int(account["fields"]["available"]) + int(account["fields"]["held"]) +
                            int(source["fields"]["balance"]))
    assert seen["ledger_total"] == 0, seen["ledger_total"]
    assert seen["early"][0]["state"] == "ready" and seen["late"][0]["state"] == "ready"
    return seen


def compare(before, after):
    for name in before:
        if before[name] != after[name]:
            if isinstance(before[name], dict):
                for key in before[name]:
                    assert before[name][key] == after[name].get(key), (name, key,
                                                                         before[name][key],
                                                                         after[name].get(key))
            raise AssertionError(f"{name} differs:\n{str(before[name])[:2000]}\n"
                                 f"{str(after[name])[:2000]}")


def run(nerva, args, **options):
    return subprocess.run([nerva] + args, capture_output=True, text=True, **options)


def main():
    nerva, nerva_other = sys.argv[1], sys.argv[2]
    tmp = tempfile.mkdtemp(prefix="nerva-upgrade-")
    old = new = None
    try:
        def format_old(index, path):
            subprocess.run([nerva, "format", "--cluster=0", f"--replica={index}",
                            "--replica-count=3", "--development", path], check=True,
                           capture_output=True)

        started = time.monotonic()
        old = Cluster(tmp, "old", nerva, format_old)
        port = old.gateway()
        ops = script(port)
        before = record(port, ops)
        version_seen = next(r for r in before["rows"] if r["id"] == "3" and r["table"] == SEATS)
        old.check_running()

        export = os.path.join(tmp, "cluster.nerva-export")
        exported = run(nerva, ["export", "--cluster=0", f"--addresses={old.addresses}",
                               f"--output={export}"])
        assert exported.returncode == 0, exported.stderr[-3000:]
        assert "exported to" in exported.stderr, exported.stderr[-3000:]
        # #302: owner-only, whatever the umask.
        assert os.stat(export).st_mode & 0o777 == 0o600, oct(os.stat(export).st_mode)
        refused = run(nerva, ["export", "--cluster=0", f"--addresses={old.addresses}",
                              f"--output={export}"])
        assert refused.returncode != 0 and "exists" in refused.stderr, refused.stderr[-2000:]
        old.close()
        print(f"old cluster: {len(ops)} commits, export of {os.path.getsize(export)} bytes "
              f"({time.monotonic() - started:.0f} s)")

        def import_new(index, path):
            imported = run(nerva_other, ["import", "--cluster=0", f"--replica={index}",
                                         "--replica-count=3", f"--input={export}",
                                         "--development", path])
            assert imported.returncode == 0, imported.stderr[-3000:]
            assert "checks passed" in imported.stderr, imported.stderr[-3000:]

        new = Cluster(tmp, "new", nerva_other, import_new)
        port = new.gateway()
        deadline = time.monotonic() + 120
        while ok(port, "GET", "/v1/views/late/groups?limit=1")["state"] != "ready":
            assert time.monotonic() < deadline, "the late view never became ready after import"
            time.sleep(0.1)
        if RECORDS:
            wait_records_ready(port)
        after = record(port, ops)
        compare(before, after)
        new.check_running()

        # A version read before the upgrade still commits; a stale one conflicts.
        read = {"kind": "read", "table": SEATS, "id": "3", "op_seen": version_seen["op"]}
        commit(port, [read, seat(3, 1, 1, True)])
        status, body = request(port, "POST", "/v1/commit", {"entries": [read]})
        assert status == 409 and body["status"] == "conflict", (status, body)
        # A feed cursor from before the upgrade continues with the new changes.
        cursor = before["feed"][1][-1]
        body = ok(port, "GET", f"/v1/changes?cursor={cursor}&limit=100")
        assert [c["id"] for c in body["changes"]] == ["3"], body

        # The new cluster commits on, without a replica, and takes it back.
        for i in range(200):
            commit(port, [seat(200 + i, i % 5, i, True)])
        new.stop(2)
        for i in range(200):
            commit(port, [seat(400 + i, i % 5, i, True)])
        new.start(2)
        for i in range(400):
            commit(port, [seat(600 + i, i % 5, i, False)])
        time.sleep(2)
        new.check_running()
        new.close()

        # One byte changed: the import fails, and leaves no data file.
        with open(export, "r+b") as f:
            f.seek(os.path.getsize(export) // 2)
            byte = f.read(1)
            f.seek(-1, os.SEEK_CUR)
            f.write(bytes([byte[0] ^ 0x01]))
        target = os.path.join(tmp, "corrupt.nerva")
        failed = run(nerva_other, ["import", "--cluster=0", "--replica=0", "--replica-count=3",
                                   f"--input={export}", "--development", target])
        assert failed.returncode != 0, failed.stderr[-2000:]
        assert "does not match" in failed.stderr, failed.stderr[-2000:]
        assert not os.path.exists(target)

        records = (f"{len(before['record_history'])} records' histories, index scans, a view "
                   f"over records, export version 2; " if RECORDS else "")
        print(f"upgrade: PASSED ({records}{len(before['history'])} rows' histories, "
              f"{len(before['as_of'])} rows as of past ops, {len(before['feed'][0])} changes in "
              f"{len(before['feed'][1])} feed pages, views, the ledger and documents read the same "
              f"after export and import into release 0.0.200; a damaged export refused; "
              f"{time.monotonic() - started:.0f} s)")
    finally:
        for cluster in (old, new):
            if cluster is not None:
                cluster.close()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.default_int_handler)
    main()
