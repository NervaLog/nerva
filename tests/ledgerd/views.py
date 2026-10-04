#!/usr/bin/env python3
"""The ledgerd views against `ledgerd.py`'s own files (docs/DECISIONS.md N26).

Drives `ledgerd.py` and `nerva ledgerd` with the same requests (the conformance scenarios and
fuzzer), then requires:

- the `journal` view to equal the oracle's `journal.log`, line for line, byte for byte;
- the `spend` view to equal the agent spend rollup recomputed from the oracle's `ledger.txt`;
- a restarted `nerva view` (rebuilt from the feed) to give the same answers;
- `min_op` past the watermark to wait, then answer 504.

Usage: views.py <path to nerva> [--seed=N] [--steps=N]
"""
import http.client, os, sys, time
from conformance import Services, Checker, KEY, scenarios, fuzz, isolation


def view_get(port, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    connection.request("GET", path, headers={"X-Ledger-Key": KEY})
    response = connection.getresponse()
    result = (response.status, response.read().decode())
    connection.close()
    return result


def view_lines(port, ledger, view):
    status, body = view_get(port, f"/v1/views/{ledger}/{view}?min_op=latest")
    assert status == 200, (status, body)
    lines = body.split("\n")
    assert lines[0].startswith("op=") and lines[-1] == "ok=true", body
    return int(lines[0][3:]), lines[1:-1]


def journal_view(port, ledger):
    op, lines = view_lines(port, ledger, "journal")
    assert all(line.startswith("line_hex=") for line in lines), lines
    return op, [bytes.fromhex(line[len("line_hex="):]) for line in lines]


def spend_view(port, ledger):
    op, lines = view_lines(port, ledger, "spend")
    rows = []
    for line in lines:
        assert line.startswith("rollup="), line
        path_hex, depth, own, subtree, settled, denied = line[len("rollup="):].split(":")
        rows.append((bytes.fromhex(path_hex).decode(), int(depth), int(own), int(subtree),
                     int(settled), int(denied)))
    return op, rows


def agent_path(rid):
    return "/".join(segment.split(":", 1)[0] for segment in rid.split("/"))


def rollup_from_oracle(oracle_dir):
    """Botpike's agent spend rollup, recomputed independently from `ledger.txt`."""
    own, settled, denied = {}, {}, {}
    ledger = os.path.join(oracle_dir, "ledger.txt")
    for line in open(ledger, encoding="utf-8").read().splitlines():
        key, _, value = line.partition("=")
        if key.startswith("done."):
            path = agent_path(key[len("done."):])
            own[path] = own.get(path, 0) + int(value)
            settled[path] = settled.get(path, 0) + 1
        elif key.startswith("denied."):
            path = agent_path(key[len("denied."):])
            denied[path] = denied.get(path, 0) + 1
    paths = set()
    for path in set(own) | set(denied):
        parts = path.split("/")
        paths.update("/".join(parts[:i]) for i in range(1, len(parts) + 1))
    rows = []
    for path in sorted(paths, key=lambda p: p.encode()):
        subtree = sum(v for p, v in own.items() if p == path or p.startswith(path + "/"))
        rows.append((path, path.count("/"), own.get(path, 0), subtree, settled.get(path, 0),
                     denied.get(path, 0)))
    return rows


def oracle_journal(oracle_dir):
    journal = os.path.join(oracle_dir, "journal.log")
    if not os.path.exists(journal):
        return []
    data = open(journal, "rb").read()
    assert data == b"" or data.endswith(b"\n")
    return data.split(b"\n")[:-1]


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    steps = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--steps=")), 400)
    services = Services(nerva)
    try:
        def start_view():
            process = services.spawn(
                [nerva, "view", "--cluster=0", f"--addresses={services.replica_address}",
                 "--listen=127.0.0.1:0"], env={**os.environ, "LEDGER_KEY": KEY})
            return process, int(process.stdout.readline())

        view_process, view_port = start_view()
        check = Checker(services)
        scenarios(check)
        fuzz(check, seed, steps)
        isolation(services)
        oracle_dir = os.path.join(services.tmp, "oracle")

        op, journal = journal_view(view_port, 1)
        expected_journal = oracle_journal(oracle_dir)
        assert journal == expected_journal, (len(journal), len(expected_journal))
        _, spend = spend_view(view_port, 1)
        assert spend == rollup_from_oracle(oracle_dir), (spend, rollup_from_oracle(oracle_dir))
        assert journal_view(view_port, 2)[1] == [] and spend_view(view_port, 2)[1] == []

        # A restarted view rebuilds from the feed and answers the same.
        view_process.kill()
        view_process.wait()
        _, view_port = start_view()
        assert journal_view(view_port, 1)[1] == journal
        assert spend_view(view_port, 1)[1] == spend

        # A position the cluster has not reached: the view waits, then answers 504.
        started = time.monotonic()
        status, _ = view_get(view_port, f"/v1/views/1/journal?min_op={op + 10**9}")
        assert status == 504 and time.monotonic() - started >= 9, status

        print(f"ledgerd views: PASSED (journal {len(journal)} lines, spend {len(spend)} agents, "
              f"through op {op}, seed {seed})")
    finally:
        services.close()


if __name__ == "__main__":
    main()
