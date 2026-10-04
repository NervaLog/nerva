#!/usr/bin/env python3
"""The seat demo under crashes (docs/DECISIONS.md N36).

Runs `demo/seats/server.py` (three replicas, the API, two view processes, fast simulated buyers)
and, for a while, crashes and restarts random processes through the demo's own endpoints while
visitors buy too. Then requires:

- no seat sold twice;
- every purchase the server saw confirmed to be in the seat map, to the buyer it recorded;
- the sold count to agree between the seat map and the sales view;
- both view processes to give the same hash at the same op;
- the demo server, stopped with SIGTERM, to leave no Nerva process behind.

Usage: seats_chaos.py <path to nerva> [--seconds=N] [--seed=N]
"""
import http.client, json, os, random, shutil, signal, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "..", "demo", "seats", "server.py")


def call(port, method, path, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    connection.request(method, path, body=json.dumps(body) if body is not None else None)
    response = connection.getresponse()
    result = response.status, json.loads(response.read())
    connection.close()
    return result


def nerva_processes(data_dir):
    out = subprocess.run(["pgrep", "-f", data_dir], capture_output=True, text=True).stdout
    return [int(pid) for pid in out.split()]


def main():
    nerva = os.path.abspath(sys.argv[1])
    seconds = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seconds=")), 60)
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    rng = random.Random(seed)
    data_dir = tempfile.mkdtemp(prefix="nerva-seats-chaos-")
    port = 8700 + rng.randrange(200)
    server = subprocess.Popen([sys.executable, SERVER, "--nerva", nerva, "--data", data_dir,
                               "--port", str(port), "--nerva-port", str(4000 + rng.randrange(500) * 30),
                               "--pace", "6", "--no-limits"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        line = server.stdout.readline()
        assert "seat demo:" in line, line

        crashes, bought = 0, 0
        processes = ["replica 0", "replica 1", "replica 2", "api", "view a", "view b"]
        deadline = time.time() + seconds
        while time.time() < deadline:
            name = rng.choice(processes)
            status, _ = call(port, "POST", "/api/crash", {"process": name})
            crashes += status == 200
            time.sleep(rng.uniform(1, 4))
            for _ in range(3):
                status, body = call(port, "POST", "/api/buy",
                                    {"seat": rng.choice([0, 1, 2, 10_000, 20_000 + rng.randrange(8)])})
                bought += status == 200 and body.get("outcome") == "sold"
            call(port, "POST", "/api/restart", {"process": name})
            time.sleep(rng.uniform(1, 3))

        # Let everything come back, then read the venue.
        for name in processes:
            call(port, "POST", "/api/restart", {"process": name})
        time.sleep(8)
        status, state = call(port, "GET", "/api/state")
        assert status == 200, state
        assert all(p["alive"] for p in state["cluster"]), state["cluster"]
        stats = state["stats"]
        assert stats["double_sold"] == 0, stats
        assert stats["sold"] > 0, stats

        seats = {(g["section"], g["row"], g["number"]): g for g in state["seats"]}
        sold_in_map = sum(1 for g in seats.values() if g["max_sold"] == "1")
        sold_in_view = sum(int(g["count"]) for g in state["sales"])
        assert sold_in_map == sold_in_view, (sold_in_map, sold_in_view)

        # Every sale this show that the server saw confirmed is in the map, to that buyer.
        confirmed = 0
        for event in state["events"]:
            seat = event["seat"]
            group = seats[(seat // 10_000, seat // 100 % 100, seat % 100)]
            if int(event["op"]) <= int(state["op"]):
                assert group["max_sold"] == "1" and group["max_buyer"] == str(event["buyer"]), (
                    event, group)
                confirmed += 1

        a, b = state["hashes"]
        assert a and b and a["op"] == b["op"] and a["hash"] == b["hash"], state["hashes"]

        print(f"seat demo chaos: PASSED ({seconds} s, {crashes} crashes, {stats['sold']} seats "
              f"sold this show, {stats['lost_race']} races lost, {bought} bought by visitors, "
              f"{confirmed} recent sales checked in the map, show {state['show']}, seed {seed})")
    except BaseException:
        server.send_signal(signal.SIGTERM)
        print(server.communicate(timeout=30)[0][-4000:])
        raise
    finally:
        if server.poll() is None:
            server.send_signal(signal.SIGTERM)
        server.wait(timeout=30)
        time.sleep(1)
        left = nerva_processes(data_dir)
        for pid in left:
            os.kill(pid, signal.SIGKILL)
        shutil.rmtree(data_dir, ignore_errors=True)
        assert not left, f"the demo left Nerva processes behind: {left}"


if __name__ == "__main__":
    main()
