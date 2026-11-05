#!/usr/bin/env python3
"""A gateway under more connections than it has slots, answering every one (R4 slice 2, #120).

Runs one replica and one gateway, a ledger of accounts funded from a source, and then, for 60
seconds (`--seconds=N`), 32 threads each moving money between an account's `available` and `held`
under a commit key of its own, while 16 connections drip a request head for 2 s of every 10 s:

- every reply is `200` committed, a `409` result, or `503` with `"applied": false` and a code
  (NRV-E0602 busy); nothing else, and never a transport error: no connection is closed without a
  status line;
- every `503` is resent under its key, after a pause, until it is `200`;
- at least one reply was `busy`;
- at the end every key answers `replayed` at the op it committed at, and the ledger's total is
  what it was: the source lost what the accounts hold, and `held` is the sum of what the
  threads were told they took.

Usage: busy.py <path to nerva> [--seconds=N]
"""
import os, random, socket, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from api import Cluster, request  # noqa: E402

ACCOUNTS, SOURCES = 40, 41
ROWS = 8
FUNDED = 1_000_000
THREADS = 32
DRIPPERS = 16


def move(table, row, field, **options):
    entry = {"kind": "add", "table": table, "id": str(row), "field": field}
    for name, value in options.items():
        entry[name] = str(value) if name in ("delta", "min", "max") else value
    return entry


def declare(port):
    for table, layout in (
            (ACCOUNTS, {"name": "accounts", "fields": [{"name": "available", "type": "i64"},
                                                        {"name": "held", "type": "i64"}]}),
            (SOURCES, {"name": "sources", "fields": [{"name": "balance", "type": "i64"}]})):
        status, body = request(port, "PUT", f"/v1/tables/{table}", layout)
        assert status == 200, body
    status, body = request(port, "PUT", "/v1/ledgers/1", {"fields": [
        {"table": SOURCES, "field": "balance", "floor": None},
        {"table": ACCOUNTS, "field": "available", "floor": "0"},
        {"table": ACCOUNTS, "field": "held", "floor": "0"}]})
    assert status == 200, body
    for row in range(ROWS):
        status, body = request(port, "POST", "/v1/commit", {"entries": [
            move(SOURCES, 1, "balance", delta=-FUNDED, pair=True, create=True),
            move(ACCOUNTS, row, "available", delta_from=0, create=True)]})
        assert status == 200, body


def totals(port):
    rows = [{"table": SOURCES, "id": "1"}] + [{"table": ACCOUNTS, "id": str(r)} for r in range(ROWS)]
    status, body = request(port, "POST", "/v1/lookup", {"rows": rows})
    assert status == 200, body
    source, *accounts = [row["fields"] for row in body["rows"]]
    return (int(source["balance"]), sum(int(a["available"]) for a in accounts),
            sum(int(a["held"]) for a in accounts))


def drip(port, stop):
    """Sixteen connections that have sent bytes and no more, for 2 s of every 10."""
    while not stop.is_set():
        held = []
        for _ in range(DRIPPERS):
            try:
                connection = socket.create_connection(("127.0.0.1", port), timeout=5)
                connection.sendall(b"GET /healthz HTTP/1.1\r\n")
                held.append(connection)
            except OSError:
                pass
        stop.wait(2)
        for connection in held:
            connection.close()
        stop.wait(8)


def main():
    nerva = sys.argv[1]
    seconds = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seconds=")), 60)
    cluster = Cluster(nerva)
    try:
        port = cluster.ports[0]
        declare(port)
        before = totals(port)
        assert before == (-FUNDED * ROWS, FUNDED * ROWS, 0), before

        stop = threading.Event()
        lock = threading.Lock()
        committed = {}   # key -> (op, amount taken)
        errors = []
        counts = {"busy": 0, "other_503": 0, "conflict": 0}

        def worker(index):
            rng = random.Random(index)
            number = 0
            try:
                while not stop.is_set():
                    number += 1
                    key = f"{index:08x}{number:024x}"
                    entries = [move(ACCOUNTS, rng.randrange(ROWS), "available",
                                    delta=-rng.randint(1, 5), pair=True, clamp=True)]
                    entries.append(move(ACCOUNTS, int(entries[0]["id"]), "held", delta_from=0))
                    while True:
                        status, body = request(port, "POST", "/v1/commit",
                                               {"key": key, "entries": entries})
                        if status == 200:
                            # A resend of a request that had committed says so, without amounts.
                            taken = None if body.get("replayed") else -int(body["adds"][0]["applied"])
                            with lock:
                                committed[key] = (body["op"], taken, entries)
                            break
                        if status == 409:
                            with lock:
                                counts["conflict"] += 1
                            break
                        assert status == 503 and body.get("applied") is False \
                            and body.get("code", "").startswith("NRV-E06"), (status, body)
                        with lock:
                            counts["busy" if body["code"] == "NRV-E0602" else "other_503"] += 1
                        time.sleep(rng.uniform(0.01, 0.05))
            except Exception as error:  # noqa: BLE001
                errors.append(repr(error))
                stop.set()

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(THREADS)]
        threads.append(threading.Thread(target=drip, args=(port, stop)))
        for thread in threads:
            thread.start()
        time.sleep(seconds)
        stop.set()
        for thread in threads:
            thread.join(timeout=120)
        assert not errors, errors[:3]
        assert counts["busy"] > 0, f"the gateway was never busy: {counts}"
        assert counts["other_503"] == 0, counts

        # Every key answers replayed with the op it committed at; the ledger is conserved.
        assert committed, "nothing committed"
        pending = sorted(committed.items())
        failures = []

        # Retried on a busy answer, as any client would: only `replayed` counts.
        def replay_retrying(share):
            for item in share:
                for _ in range(100):
                    status, body = request(port, "POST", "/v1/commit",
                                           {"key": item[0], "entries": item[1][2]})
                    if status != 503:
                        break
                    time.sleep(0.02)
                if not (status == 200 and body.get("replayed") is True and body["op"] == item[1][0]):
                    failures.append((item[0], item[1][0], status, body))
                    return

        pool = [threading.Thread(target=replay_retrying, args=(pending[i::8],)) for i in range(8)]
        for thread in pool:
            thread.start()
        for thread in pool:
            thread.join()
        assert not failures, failures[:3]
        source, available, held = totals(port)
        assert source == before[0] and source + available + held == 0, (
            before, source, available, held)
        if all(taken is not None for _, taken, _ in committed.values()):
            assert held == sum(taken for _, taken, _ in committed.values()), held
        print(f"busy: {len(committed)} transfers, {counts['busy']} busy replies, "
              f"{counts['conflict']} conflicts, held {held}")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
