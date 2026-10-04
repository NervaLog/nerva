#!/usr/bin/env python3
"""`/v1/store/*`, the runtime's `Store` ability served from Nerva (docs/DECISIONS.md N29).

There is no oracle for these routes, so they are checked against a model, through two gateways
on one ledger:

- random puts and gets (names from a small set, values from empty to past the 64 KiB limit) read
  back exactly what the model holds, from either gateway; oversize values are refused with 400
  and change nothing;
- `/v1/admin/init` resets the ledger but keeps agent state;
- concurrent writers on distinct names all land, and concurrent writers on one name leave one
  of the values written;
- a staged suspend, written the way the runtime writes it (`<id>.next.*`, then the sequence
  advance, then the copy), is read back whole by the other gateway.

Usage: store.py <path to nerva> [--seed=N] [--steps=N]
"""
import os, random, sys, threading
from conformance import Services, post, KEY

VALUE_SIZE_MAX = 64 * 1024


def store_get(port, name):
    status, body = post(port, "/v1/store/get", [("name_hex", name.encode().hex())])
    assert status == 200, (status, body)
    lines = body.split("\n")
    assert lines[-1] == "ok=true", body
    if lines[0] == "found=false":
        assert len(lines) == 2, body
        return None
    assert lines[0] == "found=true" and lines[1].startswith("value_hex=") and len(lines) == 3, body
    return bytes.fromhex(lines[1][len("value_hex="):])


def store_put(port, name, value):
    return post(port, "/v1/store/put", [("name_hex", name.encode().hex()),
                                        ("value_hex", value.hex())])


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    steps = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--steps=")), 300)
    rng = random.Random(seed)
    services = Services(nerva)
    try:
        gateway_b = services.spawn(
            [nerva, "ledgerd", "--cluster=0", f"--addresses={services.replica_address}",
             "--ledger=1", "--listen=127.0.0.1:0"], env={**os.environ, "LEDGER_KEY": KEY})
        ports = [services.nerva_port, int(gateway_b.stdout.readline())]

        # Random puts and gets against a model.
        model = {}
        names = [f"agent-{i}.{suffix}" for i in range(4)
                 for suffix in ("cont", "code", "receipt", "receipt.sig")]
        refused = 0
        for _ in range(steps):
            port = rng.choice(ports)
            name = rng.choice(names)
            if rng.random() < 0.5:
                size = rng.choice([0, 1, 79, 80, 200, 4557, rng.randint(0, VALUE_SIZE_MAX),
                                   VALUE_SIZE_MAX, VALUE_SIZE_MAX + 1])
                value = rng.randbytes(size)
                status, body = store_put(port, name, value)
                if size > VALUE_SIZE_MAX:
                    assert status == 400, (status, body)
                    refused += 1
                else:
                    assert (status, body) == (200, "ok=true"), (status, body)
                    model[name] = value
            else:
                assert store_get(port, name) == model.get(name), name
        assert refused > 0
        for name in names:
            for port in ports:
                assert store_get(port, name) == model.get(name), name

        # Resetting the ledger keeps agent state.
        status, body = post(ports[0], "/v1/admin/init", [("amount", "1000")])
        assert status == 200, body
        for name in model:
            assert store_get(ports[1], name) == model[name], name

        # Concurrent writers.
        errors = []

        def writer(index):
            try:
                port = ports[index % 2]
                for step in range(20):
                    value = f"{index}:{step}".encode() * 50
                    assert store_put(port, f"own-{index}", value)[0] == 200
                    assert store_put(port, "shared", value)[0] == 200
                    assert store_get(port, f"own-{index}") == value
            except Exception as error:  # Reported below.
                errors.append(repr(error))

        threads = [threading.Thread(target=writer, args=(i,)) for i in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        assert not errors, errors
        for index in range(8):
            assert store_get(ports[0], f"own-{index}") == f"{index}:19".encode() * 50
        shared = store_get(ports[1], "shared")
        assert shared in {f"{i}:{s}".encode() * 50 for i in range(8) for s in range(20)}

        # The runtime's suspend, as `daemon.suspend` writes it, read back by the other gateway.
        staged = {suffix: rng.randbytes(n) for suffix, n in
                  [("cont", 4557), ("code", 9000), ("receipt", 300), ("receipt.sig", 64)]}
        for suffix, value in staged.items():
            assert store_put(ports[0], f"planner-1.next.{suffix}", value)[0] == 200
        status, body = post(ports[0], "/v1/bump", [("agent", "planner-1")])
        assert status == 200 and body.startswith("seq=1"), body
        for suffix, value in staged.items():
            assert store_put(ports[0], f"planner-1.{suffix}", value)[0] == 200
        assert store_put(ports[0], "planner-1.next.receipt", b"")[0] == 200
        for suffix, value in staged.items():
            assert store_get(ports[1], f"planner-1.{suffix}") == value
        assert store_get(ports[1], "planner-1.next.receipt") == b""

        print(f"ledgerd store: PASSED ({steps} steps, {len(model)} names, {refused} oversize "
              f"refused, 8 concurrent writers, seed {seed})")
    finally:
        services.close()


if __name__ == "__main__":
    main()
