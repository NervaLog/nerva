#!/usr/bin/env python3
"""The canvas demo under crashes (docs/DECISIONS.md N38).

Runs `demo/canvas/server.py` (three replicas, the API, two view processes, fast simulated
painters) and, for a while, crashes and restarts random processes through the demo's own
endpoints while visitors paint too. Then requires:

- every paint the server confirmed, at op N, to be on the canvas read as of op N (each
  timelapse frame is a read as of an op, so this is the timelapse being right);
- the colour counts to cover the whole canvas, and both view processes to agree at one op;
- the demo server, stopped with SIGTERM, to leave no Nerva process behind.

Usage: canvas_chaos.py <path to nerva> [--seconds=N] [--seed=N]
"""
import http.client, json, os, random, shutil, signal, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "..", "demo", "canvas", "server.py")


def call(port, method, path, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    connection.request(method, path, body=json.dumps(body) if body is not None else None)
    response = connection.getresponse()
    result = response.status, json.loads(response.read())
    connection.close()
    return result


def main():
    nerva = os.path.abspath(sys.argv[1])
    seconds = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seconds=")), 60)
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    rng = random.Random(seed)
    data_dir = tempfile.mkdtemp(prefix="nerva-canvas-chaos-")
    port = 8900 + rng.randrange(200)
    server = subprocess.Popen([sys.executable, SERVER, "--nerva", nerva, "--data", data_dir,
                               "--port", str(port), "--nerva-port", str(5000 + rng.randrange(300) * 30),
                               "--pace", "4", "--no-limits"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        line = server.stdout.readline()
        assert "canvas demo:" in line, line

        crashes, confirmed = 0, []
        processes = ["replica 0", "replica 1", "replica 2", "api", "view a", "view b"]
        deadline = time.time() + seconds
        while time.time() < deadline:
            name = rng.choice(processes)
            status, _ = call(port, "POST", "/api/crash", {"process": name})
            crashes += status == 200
            time.sleep(rng.uniform(1, 3))
            for _ in range(4):
                paint = {"x": rng.randrange(64), "y": rng.randrange(64), "color": rng.randrange(8)}
                status, body = call(port, "POST", "/api/paint", paint)
                if status == 200:
                    confirmed.append({**paint, "op": int(body["op"])})
            call(port, "POST", "/api/restart", {"process": name})
            time.sleep(rng.uniform(1, 2))

        for name in processes:
            call(port, "POST", "/api/restart", {"process": name})
        time.sleep(8)
        status, state = call(port, "GET", "/api/state")
        assert status == 200, state
        assert all(p["alive"] for p in state["cluster"]), state["cluster"]
        assert confirmed, "no paint was confirmed"

        # Every confirmed paint is on the canvas as of its op, the visitors' and the bots' alike.
        bots = [{"x": e["x"], "y": e["y"], "color": e["color"], "op": int(e["op"])}
                for e in state["events"]]
        for paint in confirmed + bots:
            status, frame = call(port, "GET", f"/api/frame?as_of={paint['op']}")
            assert status == 200, frame
            assert frame["pixels"][paint["y"] * 64 + paint["x"]] == str(paint["color"]), (
                paint, frame["op"])

        assert sum(int(g["count"]) for g in state["colors"]) == 64 * 64, state["colors"]
        a, b = state["hashes"]
        assert a and b and a["op"] == b["op"] and a["hash"] == b["hash"], state["hashes"]

        print(f"canvas demo chaos: PASSED ({seconds} s, {crashes} crashes, "
              f"{state['stats']['paints']} paints, {len(confirmed)} visitor and {len(bots)} "
              f"recent painter paints checked as of their ops, seed {seed})")
    except BaseException:
        server.send_signal(signal.SIGTERM)
        print(server.communicate(timeout=30)[0][-4000:])
        raise
    finally:
        if server.poll() is None:
            server.send_signal(signal.SIGTERM)
        server.wait(timeout=30)
        time.sleep(1)
        out = subprocess.run(["pgrep", "-f", data_dir], capture_output=True, text=True).stdout
        left = [int(pid) for pid in out.split()]
        for pid in left:
            os.kill(pid, signal.SIGKILL)
        shutil.rmtree(data_dir, ignore_errors=True)
        assert not left, f"the demo left Nerva processes behind: {left}"


if __name__ == "__main__":
    main()
