#!/usr/bin/env python3
"""Differential test: `nerva ledgerd` against `ledgerd.py` (docs/DECISIONS.md N8).

Every request goes to both services; replies must match byte for byte (status and every line,
journal lines included). Error replies match on status and the `error=` prefix (N9).

Usage: conformance.py <path to nerva> [--seed=N] [--steps=N]
"""
import http.client, os, random, shutil, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
KEY = "conformance-key"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def post(port, route, fields, key=KEY):
    body = "\n".join(f"{k}={v}" for k, v in fields)
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    headers = {"Content-Type": "text/plain"}
    if key is not None:
        headers["X-Ledger-Key"] = key
    connection.request("POST", route, body=body.encode(), headers=headers)
    response = connection.getresponse()
    result = (response.status, response.read().decode())
    connection.close()
    return result


def get(port, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    connection.request("GET", path)
    response = connection.getresponse()
    result = (response.status, response.read().decode())
    connection.close()
    return result


def normalize(reply):
    status, body = reply
    if status != 200:
        return status, "error=" if body.startswith("error=") else body
    return reply


class Services:
    def __init__(self, nerva):
        self.tmp = tempfile.mkdtemp(prefix="nerva-ledgerd-")
        self.processes = []
        data_file = os.path.join(self.tmp, "0_0.nerva")
        subprocess.run([nerva, "format", "--cluster=0", "--replica=0", "--replica-count=1",
                        "--development", data_file], check=True, capture_output=True)
        replica = self.spawn([nerva, "start", "--addresses=0", "--development", data_file])
        replica_port = int(replica.stdout.readline())
        self.replica_address = f"127.0.0.1:{replica_port}"

        def ledgerd(ledger):
            process = self.spawn([nerva, "ledgerd", "--cluster=0",
                                  f"--addresses=127.0.0.1:{replica_port}", f"--ledger={ledger}",
                                  "--listen=127.0.0.1:0"], env={**os.environ, "LEDGER_KEY": KEY})
            return int(process.stdout.readline())

        self.nerva_port = ledgerd(1)
        self.nerva_port_other = ledgerd(2)  # Another ledger on the same cluster.

        self.oracle_port = free_port()
        self.spawn([sys.executable, os.path.join(HERE, "ledgerd_reference.py")],
                   env={**os.environ, "LEDGER_DIR": os.path.join(self.tmp, "oracle"),
                        "LEDGER_KEY": KEY, "LEDGER_PORT": str(self.oracle_port)})
        self.wait_healthy(self.oracle_port)

    def spawn(self, argv, env=None, stderr=subprocess.DEVNULL):
        process = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=stderr, text=True)
        self.processes.append(process)
        return process

    def wait_healthy(self, port):
        for _ in range(100):
            try:
                if get(port, "/healthz")[0] == 200:
                    return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError(f"no service on port {port}")

    def close(self):
        for process in self.processes:
            process.kill()
            process.wait()
        shutil.rmtree(self.tmp, ignore_errors=True)


def hexed(text):
    return text.encode().hex() if isinstance(text, str) else text.hex()


class Checker:
    def __init__(self, services):
        self.services = services
        self.requests = 0

    def same(self, route, fields, key=KEY):
        expected = post(self.services.oracle_port, route, fields, key)
        actual = post(self.services.nerva_port, route, fields, key)
        self.requests += 1
        if normalize(expected) != normalize(actual):
            print(f"MISMATCH on {route} {fields}\n  ledgerd.py: {expected}\n  nerva:      {actual}")
            sys.exit(1)
        return actual


def scenarios(check):
    """The runtime's paths through the ledger, as in its README and demo."""
    memo = lambda text: ("memo_hex", hexed(text))
    check.same("/v1/admin/init", [("amount", "20000")])
    check.same("/v1/available", [])
    # Reserve, settle under, over (charged to available), and with no hold.
    check.same("/v1/reserve", [("request_id", "planner-1:0:0"), memo("llm.complete"),
                               ("estimate", "3110")])
    check.same("/v1/settle", [("request_id", "planner-1:0:0"), ("actual", "2900")])
    check.same("/v1/reserve", [("request_id", "planner-1:0:1"), memo("spend: dataset"),
                               ("estimate", "1000")])
    check.same("/v1/settle", [("request_id", "planner-1:0:1"), ("actual", "1500")])
    check.same("/v1/settle", [("request_id", "ghost:0:0"), ("actual", "40")])
    # Replay, recover, mismatch.
    check.same("/v1/reserve", [("request_id", "planner-1:0:0"), memo("llm.complete"),
                               ("estimate", "3110")])
    check.same("/v1/reserve", [("request_id", "planner-1:0:2"), memo("spend: premium filings"),
                               ("estimate", "9000")])
    check.same("/v1/reserve", [("request_id", "planner-1:0:2"), memo("spend: premium filings"),
                               ("estimate", "9000")])
    check.same("/v1/reserve", [("request_id", "planner-1:0:2"), memo("spend: basic filings"),
                               ("estimate", "3000")])
    # Denied, counted once; a retry is not recounted; refused.
    check.same("/v1/reserve", [("request_id", "planner-1:0:3"), memo("big"), ("estimate", "99999")])
    check.same("/v1/reserve", [("request_id", "planner-1:0:3"), memo("big"), ("estimate", "99999")])
    check.same("/v1/reserve", [("request_id", "planner-1:0:3"), memo("big"), ("estimate", "99999"),
                               ("retry", "1")])
    check.same("/v1/refused", [("request_id", "planner-1:0:4"), memo("spend: x"),
                               ("estimate", "500"), ("why_hex", hexed("over the amount limit"))])
    check.same("/v1/refused", [("request_id", "planner-1:0:4"), memo("spend: x"),
                               ("estimate", "500"), ("why_hex", hexed("over the amount limit"))])
    # Overage beyond what is available: the agent stops for review, also on re-run.
    check.same("/v1/reserve", [("request_id", "r:0:0"), memo("llm"), ("estimate", "100")])
    check.same("/v1/settle", [("request_id", "r:0:0"), ("actual", "50000")])
    check.same("/v1/settle", [("request_id", "r:0:0"), ("actual", "50000")])
    # Results, sequences, claims (the receipt race), blocks, notes, status.
    check.same("/v1/recall", [("request_id", "researcher-1:0:0")])
    check.same("/v1/remember", [("request_id", "researcher-1:0:0"), ("value_hex", "ab" * 2000)])
    check.same("/v1/remember", [("request_id", "researcher-1:0:0"), ("value_hex", "cd")])
    check.same("/v1/recall", [("request_id", "researcher-1:0:0")])
    check.same("/v1/remember", [("request_id", "n-1:0:0/allowance"), ("value_hex", "3330")])
    check.same("/v1/recall", [("request_id", "n-1:0:0/allowance")])
    check.same("/v1/sequence", [("agent", "a")])
    check.same("/v1/claim", [("agent", "a"), ("expected", "0")])
    check.same("/v1/claim", [("agent", "a"), ("expected", "0")])
    check.same("/v1/claim", [("agent", "a"), ("expected", "7")])
    check.same("/v1/bump", [("agent", "a")])
    check.same("/v1/block", [("key", "a"), ("why_hex", hexed("needs approval: send email"))])
    check.same("/v1/blocked", [("key", "a")])
    check.same("/v1/status", [])
    check.same("/v1/unblock", [("key", "a")])
    check.same("/v1/unblock", [("key", "a")])
    check.same("/v1/blocked", [("key", "a")])
    check.same("/v1/note", [("text_hex", hexed("a note\nwith a newline and €"))])
    check.same("/v1/note", [("text_hex", "e282ffc3")])  # Invalid UTF-8 reaches the journal.
    check.same("/v1/admin/topup", [("amount", "6000")])
    check.same("/v1/summary", [])
    check.same("/v1/status", [])
    # Errors: bad key, unknown route, missing and malformed fields, limits.
    check.same("/v1/summary", [], key="wrong")
    check.same("/v1/summary", [], key=None)
    check.same("/v1/nope", [])
    check.same("/v1/reserve", [("estimate", "1")])
    check.same("/v1/reserve", [("request_id", "q"), ("estimate", "abc")])
    check.same("/v1/reserve", [("request_id", "q"), ("estimate", "-1")])
    check.same("/v1/reserve", [("request_id", "q"), ("estimate", str(10**15 + 1))])
    check.same("/v1/reserve", [("request_id", "q"), ("memo_hex", "zz"), ("estimate", "1")])
    check.same("/v1/refused", [("request_id", "q2"), ("memo_hex", "zz"), ("estimate", "7")])
    check.same("/v1/summary", [])  # The refused above still counted its denial.
    check.same("/v1/admin/topup", [("amount", str(10**15))])
    # init forgets everything.
    check.same("/v1/admin/init", [("amount", "5")])
    check.same("/v1/status", [])
    check.same("/v1/recall", [("request_id", "researcher-1:0:0")])


def fuzz(check, seed, steps):
    rng = random.Random(seed)
    rids = ["a:0:0", "a:0:1", "b:0:0", "p:0:0/s:1", "n:0:0/allowance", "x"]
    agents = ["a", "b", "c"]
    keys = ["a", "b"]

    def amount():
        return rng.choice([str(rng.randint(0, 30000)), str(rng.randint(0, 10**15)), "0",
                           str(10**15 + rng.randint(1, 9)), "abc", "-3", ""])

    def text_hex():
        kind = rng.random()
        if kind < 0.6:
            return hexed(rng.choice(["llm.complete", "spend: data", "€ ünïcode", "tab\there", ""]))
        if kind < 0.9:
            return bytes(rng.randrange(256) for _ in range(rng.randint(0, 12))).hex()
        return rng.choice(["z", "abc", "0g"])  # Not hex.

    def maybe_drop(fields):
        if rng.random() < 0.05 and fields:
            del fields[rng.randrange(len(fields))]
        return fields

    for _ in range(steps):
        route = rng.choices(
            ["/v1/reserve", "/v1/settle", "/v1/refused", "/v1/available", "/v1/note",
             "/v1/recall", "/v1/remember", "/v1/block", "/v1/blocked", "/v1/unblock",
             "/v1/sequence", "/v1/claim", "/v1/bump", "/v1/summary", "/v1/status",
             "/v1/admin/init", "/v1/admin/topup"],
            weights=[20, 15, 4, 2, 2, 4, 4, 3, 3, 3, 3, 8, 3, 2, 3, 1, 3])[0]
        rid = ("request_id", rng.choice(rids))
        fields = {
            "/v1/reserve": lambda: [rid, ("memo_hex", text_hex()), ("estimate", amount())]
                                   + ([("retry", "1")] if rng.random() < 0.2 else []),
            "/v1/settle": lambda: [rid, ("actual", amount())],
            "/v1/refused": lambda: [rid, ("memo_hex", text_hex()), ("estimate", amount()),
                                    ("why_hex", text_hex())],
            "/v1/note": lambda: [("text_hex", text_hex())],
            "/v1/recall": lambda: [rid],
            "/v1/remember": lambda: [rid, ("value_hex", "ef" * rng.choice([1, 10, 500, 3000]))],
            "/v1/block": lambda: [("key", rng.choice(keys)), ("why_hex", text_hex())],
            "/v1/blocked": lambda: [("key", rng.choice(keys))],
            "/v1/unblock": lambda: [("key", rng.choice(keys))],
            "/v1/sequence": lambda: [("agent", rng.choice(agents))],
            "/v1/claim": lambda: [("agent", rng.choice(agents)),
                                  ("expected", rng.choice(["0", "1", "2", "3", "x"]))],
            "/v1/bump": lambda: [("agent", rng.choice(agents))],
            "/v1/admin/init": lambda: [("amount", amount())],
            "/v1/admin/topup": lambda: [("amount", amount())],
        }.get(route, lambda: [])()
        check.same(route, maybe_drop(fields))


def isolation(services):
    """A second ledger on the same cluster sees none of the first's state."""
    assert post(services.nerva_port_other, "/v1/summary", [])[1] == \
        "summary=ledger: available 0, held 0, settled 0, prevented 0\nok=true"
    before = post(services.nerva_port, "/v1/status", [])
    status, body = post(services.nerva_port_other, "/v1/admin/init", [("amount", "1")])
    assert status == 200, body
    assert post(services.nerva_port, "/v1/status", []) == before
    assert post(services.nerva_port_other, "/v1/available", [])[1] == "available=1\nok=true"


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    steps = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--steps=")), 400)
    services = Services(nerva)
    try:
        check = Checker(services)
        assert get(services.nerva_port, "/healthz") == get(services.oracle_port, "/healthz")
        scenarios(check)
        fuzz(check, seed, steps)
        isolation(services)
        print(f"ledgerd conformance: PASSED ({check.requests} requests, seed {seed})")
    finally:
        services.close()


if __name__ == "__main__":
    main()
