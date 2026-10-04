#!/usr/bin/env python3
"""Declared views against a model (docs/DECISIONS.md N35).

One replica, `nerva api`, and two `nerva view` processes. Declares a seat layout and a view,
then runs random seat writes (sell, re-price, delete) through the API, recording each commit's
op and a model of the table. Halfway, declares a second view. Then requires:

- each view, latest and as of sampled ops (including ops before the second view was declared),
  to equal the model's groups;
- both view processes to give the same answer and hash, and the hash to be SHA-256 of the
  groups as served;
- a restarted view process (rebuilt from the log) to give the same answers;
- declarations to be checked: unknown fields, no layout, a different view under an existing
  name (409), the same view again ("unchanged");
- `as_of` past the cluster's op to wait, then answer 504.

Usage: declared.py <path to nerva> [--seed=N] [--steps=N]
"""
import hashlib, http.client, json, os, random, shutil, subprocess, sys, tempfile, time

KEY = "views-test-key"
TABLE = 5
LAYOUT = {"name": "seats", "fields": [{"name": "section", "type": "u8"},
                                      {"name": "price", "type": "u64"},
                                      {"name": "sold", "type": "bool"},
                                      {"name": "holder", "type": "bytes", "size": 4}]}
REVENUE = {"table": TABLE, "where": [{"field": "sold", "op": "eq", "value": True}],
           "group_by": ["section"],
           "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"},
                          {"fn": "max", "field": "price"}]}
UNSOLD = {"table": TABLE, "where": [{"field": "sold", "op": "eq", "value": False},
                                    {"field": "price", "op": "lt", "value": "900"}],
          "group_by": ["section", "holder"],
          "aggregates": [{"fn": "count"}, {"fn": "min", "field": "price"}]}


def request(port, method, target, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    data = json.dumps(body) if body is not None else None
    connection.request(method, target, body=data, headers={"X-Nerva-Key": KEY})
    response = connection.getresponse()
    status, text = response.status, response.read().decode()
    connection.close()
    return status, json.loads(text)


class Cluster:
    def __init__(self, nerva):
        self.nerva = nerva
        self.tmp = tempfile.mkdtemp(prefix="nerva-views-")
        self.processes = []
        data_file = os.path.join(self.tmp, "0_0.nerva")
        subprocess.run([nerva, "format", "--cluster=0", "--replica=0", "--replica-count=1",
                        "--development", data_file], check=True, capture_output=True)
        replica = self.spawn([nerva, "start", "--addresses=0", "--development", data_file])
        self.address = replica.stdout.readline().strip()
        self.api = self.serve("api")

    def spawn(self, argv):
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True,
                                   env={**os.environ, "NERVA_KEY": KEY})
        self.processes.append(process)
        return process

    def serve(self, command):
        process = self.spawn([self.nerva, command, "--cluster=0", f"--addresses={self.address}",
                              "--listen=127.0.0.1:0"])
        port = int(process.stdout.readline())
        return port if command == "api" else (process, port)

    def close(self):
        for process in self.processes:
            process.kill()
            process.wait()
        shutil.rmtree(self.tmp, ignore_errors=True)


def model_groups(view, rows):
    """The view over `rows` ({id: fields}), as `nerva view` renders it."""
    def value(fields, name):
        v = fields[name]
        return int(v) if isinstance(v, str) and name != "holder" else v

    def matches(fields):
        for clause in view.get("where", []):
            actual = int(value(fields, clause["field"]))
            expected = int(clause["value"])
            ok = {"eq": actual == expected, "ne": actual != expected, "lt": actual < expected,
                  "le": actual <= expected, "gt": actual > expected,
                  "ge": actual >= expected}[clause["op"]]
            if not ok:
                return False
        return True

    groups = {}
    for fields in rows.values():
        if not matches(fields):
            continue
        key = tuple(fields[name] for name in view["group_by"])
        groups.setdefault(key, []).append(fields)

    def sort_key(key):
        return tuple(bytes.fromhex(k) if name == "holder" else int(k)
                     for name, k in zip(view["group_by"], key))

    out = []
    for key in sorted(groups, key=sort_key):
        members = groups[key]
        group = dict(zip(view["group_by"], key))
        for aggregate in view["aggregates"]:
            if aggregate["fn"] == "count":
                group["count"] = str(len(members))
            else:
                numbers = [int(m[aggregate["field"]]) for m in members]
                result = {"sum": sum, "min": min, "max": max}[aggregate["fn"]](numbers)
                group[f"{aggregate['fn']}_{aggregate['field']}"] = str(result)
        out.append(group)
    return out


def check_answer(ports, name, op, expected):
    """Both view processes answer `expected` as of `op` (None: latest), with one hash."""
    hashes = set()
    for port in ports:
        target = f"/v1/views/{name}" + (f"?as_of={op}" if op is not None else "?min_op=latest")
        status, body = request(port, "GET", target)
        assert status == 200, (status, body)
        assert body["groups"] == expected, (name, op, body["groups"], expected)
        served = json.dumps(body["groups"], separators=(",", ":"))
        assert body["hash"] == hashlib.sha256(served.encode()).hexdigest(), body
        if op is not None:
            assert body["op"] == str(op), body
        hashes.add(body["hash"])
    assert len(hashes) == 1, hashes
    return hashes.pop()


def main():
    nerva = sys.argv[1]
    seed = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--seed=")), 1)
    steps = next((int(a.split("=")[1]) for a in sys.argv[2:] if a.startswith("--steps=")), 300)
    rng = random.Random(seed)
    cluster = Cluster(nerva)
    try:
        api = cluster.api
        views = [cluster.serve("view"), cluster.serve("view")]
        ports = [port for _, port in views]

        # Declarations are checked.
        assert request(api, "PUT", "/v1/views/revenue", REVENUE)[0] == 400  # No layout yet.
        assert request(api, "PUT", f"/v1/tables/{TABLE}", LAYOUT)[0] == 200
        status, body = request(api, "PUT", "/v1/views/revenue", REVENUE)
        assert (status, body["declared"]) == (200, "created"), body
        assert request(api, "PUT", "/v1/views/revenue", REVENUE)[1]["declared"] == "unchanged"
        assert request(api, "PUT", "/v1/views/revenue", UNSOLD)[0] == 409
        bad = {**REVENUE, "group_by": ["nope"]}
        assert request(api, "PUT", "/v1/views/bad", bad)[0] == 400
        assert request(api, "PUT", "/v1/views/Bad", REVENUE)[0] == 400
        assert request(api, "GET", "/v1/views/revenue")[1]["table"] == TABLE

        rows, history = {}, []   # history: (op, snapshot of rows)
        declared_unsold_at = None
        for step in range(steps):
            if step == steps // 2:
                status, body = request(api, "PUT", "/v1/views/unsold", UNSOLD)
                assert status == 200, body
                declared_unsold_at = history[-1][0] if history else None
            seat = str(rng.randrange(40))
            if seat in rows and rng.random() < 0.15:
                entry = {"kind": "delete", "table": TABLE, "id": seat}
                after = {k: v for k, v in rows.items() if k != seat}
            else:
                fields = {"section": rng.randrange(4), "price": str(rng.choice([100, 250, 500, 1000])),
                          "sold": rng.random() < 0.5, "holder": rng.choice(["00000000", "0000beef", "c0ffee00"])}
                entry = {"kind": "put", "table": TABLE, "id": seat, "fields": fields}
                after = {**rows, seat: fields}
            status, body = request(api, "POST", "/v1/commit", {"entries": [entry]})
            assert status == 200, body
            rows = after
            history.append((int(body["op"]), dict(rows)))

        assert sorted(request(ports[0], "GET", "/v1/views")[1]["views"]) == ["revenue", "unsold"]
        latest = {name: check_answer(ports, name, None, model_groups(spec, rows))
                  for name, spec in (("revenue", REVENUE), ("unsold", UNSOLD))}

        samples = rng.sample(history, min(25, len(history)))
        # Always include an op before the second view was declared.
        samples.append(next(h for h in history if h[0] <= declared_unsold_at))
        for op, snapshot in samples:
            for name, spec in (("revenue", REVENUE), ("unsold", UNSOLD)):
                check_answer(ports, name, op, model_groups(spec, snapshot))
        # Before any seat: no groups.
        check_answer(ports, "revenue", history[0][0] - 1, [])

        # A restarted view process rebuilds from the log and agrees.
        views[0][0].kill()
        views[0][0].wait()
        _, port = cluster.serve("view")
        for name in latest:
            assert check_answer([port, ports[1]], name, None,
                                model_groups(REVENUE if name == "revenue" else UNSOLD, rows)) == latest[name]

        assert request(ports[1], "GET", "/v1/views/nope")[0] == 404
        assert request(ports[1], "GET", "/v1/views/revenue?as_of=0")[0] == 400
        assert request(ports[1], "GET", "/v1/views/revenue?as_of=1&min_op=1")[0] == 400
        started = time.monotonic()
        status, _ = request(ports[1], "GET", f"/v1/views/revenue?as_of={history[-1][0] + 10**9}")
        assert status == 504 and time.monotonic() - started >= 9, status

        print(f"declared views: PASSED ({steps} writes; {len(samples)} ops checked as of, for 2 "
              f"views on 2 processes, plus a restart; seed {seed})")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
