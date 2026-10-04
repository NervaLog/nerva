#!/usr/bin/env python3
"""The ledgerd views against `ledgerd.py`'s own files (docs/DECISIONS.md N26).

Drives `ledgerd.py` and `nerva ledgerd` with the same requests (the conformance scenarios and
fuzzer), then requires:

- the `journal` view to equal the oracle's `journal.log`, line for line, byte for byte;
- the `spend` view to equal the agent spend rollup recomputed from the oracle's `ledger.txt`;
- a restarted `nerva view` (rebuilt from the feed) to give the same answers;
- every journal line to carry the op that wrote it;
- `as_of` reads to reproduce the oracle's files as they were after sampled requests: every key
  of `ledger.txt` and `results.txt` read at that request's op, and keys that did not exist yet
  read as absent (G6, docs/DECISIONS.md N28);
- `min_op` past the watermark to wait, then answer 504.

Usage: views.py <path to nerva> [--seed=N] [--steps=N]
"""
import http.client, os, random, sys, time
from conformance import Services, Checker, KEY, scenarios, fuzz, isolation

SNAPSHOT_EVERY = 7
KEYS_PER_SNAPSHOT = 40


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
    """The journal's lines, and the op that wrote each."""
    op, lines = view_lines(port, ledger, "journal")
    entries = []
    for line in lines:
        assert line.startswith("line="), line
        line_op, _, line_hex = line[len("line="):].partition(":")
        assert 0 < int(line_op) <= op, (line_op, op)
        entries.append((int(line_op), bytes.fromhex(line_hex)))
    assert [o for o, _ in entries] == sorted(o for o, _ in entries), "journal out of op order"
    return op, [line for _, line in entries]


def as_of(port, ledger, key, op):
    """`(op, value or None)`: a ledger key as it was at `op` ("latest" for now)."""
    status, body = view_get(port, f"/v1/ledgers/{ledger}/as_of?op={op}&key_hex={key.encode().hex()}")
    assert status == 200, (status, body)
    lines = body.split("\n")
    assert lines[0].startswith("op=") and lines[-1] == "ok=true", body
    if lines[1] == "found=false":
        assert len(lines) == 3, body
        return int(lines[0][3:]), None
    assert lines[1] == "found=true" and lines[2].startswith("value_hex=") and len(lines) == 4, body
    return int(lines[0][3:]), bytes.fromhex(lines[2][len("value_hex="):]).decode()


def oracle_state(oracle_dir):
    """`ledger.txt` and `results.txt` as one map of ledgerd keys (results under `result.`)."""
    state = {}
    ledger = os.path.join(oracle_dir, "ledger.txt")
    if os.path.exists(ledger):
        for line in open(ledger, encoding="utf-8").read().split("\n"):
            if line:
                key, _, value = line.partition("=")
                state[key] = value
    results = os.path.join(oracle_dir, "results.txt")
    if os.path.exists(results):
        for line in open(results, encoding="utf-8").read().split("\n"):
            if line:
                rid, _, value_hex = line.partition("=")
                state.setdefault("result." + rid, value_hex)  # `recall` finds the first.
    return state


class SnapshotChecker(Checker):
    """Records the oracle's state, and the op it corresponds to, every few requests."""

    def __init__(self, services, view_port):
        super().__init__(services)
        self.view_port = view_port
        self.oracle_dir = os.path.join(services.tmp, "oracle")
        self.snapshots = []

    def same(self, route, fields, key=KEY):
        actual = super().same(route, fields, key)
        if self.requests % SNAPSHOT_EVERY == 0:
            # Requests are sequential: the watermark after catching up is at or after this
            # request's commit, and before the next one's.
            op, available = as_of(self.view_port, 1, "available", "latest")
            state = oracle_state(self.oracle_dir)
            assert available == state.get("available"), (available, state.get("available"))
            self.snapshots.append((op, state))
        return actual


def check_snapshots(port, snapshots, seed):
    """Every snapshot, re-read as of its op: present keys equal, other keys absent."""
    rng = random.Random(seed)
    every_key = sorted(set().union(*(state.keys() for _, state in snapshots)))
    reads = 0
    for op, state in snapshots:
        keys = set(rng.sample(every_key, min(KEYS_PER_SNAPSHOT, len(every_key))))
        keys |= {"available", "held", "settled"}
        for key in sorted(keys):
            read_op, value = as_of(port, 1, key, op)
            assert read_op == op, (read_op, op)
            assert value == state.get(key), (op, key, value, state.get(key))
            reads += 1
    return reads


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
        check = SnapshotChecker(services, view_port)
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
        reads = check_snapshots(view_port, check.snapshots, seed)
        assert len(check.snapshots) > 10, len(check.snapshots)

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
              f"{reads} as-of reads over {len(check.snapshots)} snapshots, through op {op}, "
              f"seed {seed})")
    finally:
        services.close()


if __name__ == "__main__":
    main()
