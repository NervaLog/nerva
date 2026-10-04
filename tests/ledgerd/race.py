#!/usr/bin/env python3
"""Two `nerva ledgerd` gateways on one ledger, hammered concurrently (docs/DECISIONS.md N11).

`ledgerd.py` serializes with one lock in one process; Nerva serializes with optimistic
transactions across processes. After a concurrent run of reserves, settles and claims:

- money is conserved: available + held + settled - overage == everything funded;
- every claim of one agent's sequence number is claimed exactly once;
- both gateways report the same state.

Usage: race.py <path to nerva> [--threads=N] [--operations=N]
"""
import os, random, sys, threading
from conformance import Services, post, KEY  # noqa: F401  (KEY used by post's default)


def summary_numbers(port):
    status, body = post(port, "/v1/summary", [])
    assert status == 200, body
    line = body.splitlines()[0].removeprefix("summary=ledger: ")
    numbers = {}
    for part in line.split(", "):
        name, value = part.split(" ")
        numbers[name] = int(value)
    return numbers


def main():
    nerva = sys.argv[1]
    threads = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--threads=")), 8)
    operations = next((int(a.split("=")[1]) for a in sys.argv[2:]
                       if a.startswith("--operations=")), 60)
    services = Services(nerva)
    try:
        # A second gateway on the *same* ledger.
        gateway_b_log = open(os.path.join(services.tmp, "gateway_b.log"), "w")
        gateway_b = services.spawn(
            [nerva, "ledgerd", "--cluster=0",
             f"--addresses={services.replica_address}", "--ledger=1", "--listen=127.0.0.1:0"],
            env={**os.environ, "LEDGER_KEY": KEY}, stderr=gateway_b_log)
        port_b = int(gateway_b.stdout.readline())
        ports = [services.nerva_port, port_b]

        funded = 50_000
        status, body = post(ports[0], "/v1/admin/init", [("amount", str(funded))])
        assert status == 200, body

        claims = {"claimed": 0, "reentered": 0, "stale": 0}
        errors = []
        lock = threading.Lock()

        def worker(index):
            rng = random.Random(index)
            port = ports[index % 2]
            try:
                for step in range(operations):
                    rid = f"w{index}:0:{step}"
                    estimate = rng.randint(1, 2000)
                    status, body = post(port, "/v1/reserve", [
                        ("request_id", rid), ("memo_hex", b"race".hex()),
                        ("estimate", str(estimate))])
                    assert status == 200, body
                    if "granted=true" in body:
                        actual = rng.choice([estimate // 2, estimate, estimate * 3])
                        status, body = post(port, "/v1/settle", [
                            ("request_id", rid), ("actual", str(actual))])
                        assert status == 200, body
                    # Every worker races to claim the same sequence number of one agent.
                    status, body = post(port, "/v1/claim", [("agent", "shared"),
                                                            ("expected", str(step))])
                    assert status == 200, body
                    result = body.splitlines()[0].removeprefix("result=")
                    with lock:
                        claims[result] += 1
            except Exception as error:  # Reported below; a thread cannot fail the test itself.
                with lock:
                    errors.append(repr(error))

        pool = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
        for thread in pool:
            thread.start()
        for thread in pool:
            thread.join()
        assert not errors, errors

        a, b = summary_numbers(ports[0]), summary_numbers(ports[1])
        assert a == b, (a, b)
        conserved = a["available"] + a["held"] + a["settled"] - a.get("overage", 0)
        assert conserved == funded, (a, funded)
        assert a["held"] == 0, a  # Every granted reserve was settled.

        # Each sequence number 0..operations-1 was claimed exactly once, and the agent's
        # sequence ends one past the last claim.
        status, body = post(ports[1], "/v1/sequence", [("agent", "shared")])
        seq = int(body.splitlines()[0].removeprefix("seq="))
        assert claims["claimed"] == seq, (claims, seq)
        assert seq <= operations, (claims, seq)
        gateway_b_log.flush()
        conflicts = open(gateway_b_log.name).read().count("conflict, retrying")
        assert conflicts > 0, "the gateways never conflicted: the retry path was not exercised"
        print(f"ledgerd race: PASSED ({threads} threads on 2 gateways, {operations} rounds "
              f"each; {conflicts} conflicts retried by one gateway; claims {claims}; {a})")
    finally:
        services.close()


if __name__ == "__main__":
    main()
