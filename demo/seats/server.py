#!/usr/bin/env python3
"""The seat-booking demo (docs/DECISIONS.md N36).

Runs a three-replica Nerva cluster, declares a venue (a typed table of seats) and three views,
sells the venue to simulated buyers racing for the best seats, and serves a page where visitors
watch, buy, rewind, crash processes and declare views of their own. When a show sells out, the
next one starts.

    python3 demo/seats/server.py --nerva zig-out/bin/nerva --data /tmp/seats --port 8000

Standard library only. The API key never leaves this process; visitors reach Nerva only through
the endpoints below, which validate what they send.
"""
import argparse, json, os, random, re, secrets, signal, sys, threading, time, traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from cluster import Cluster  # noqa: E402
from nerva_http import Http, Unavailable  # noqa: E402

SEATS = 10
LAYOUT = {"name": "seats", "fields": [
    {"name": "section", "type": "u8"}, {"name": "row", "type": "u8"},
    {"name": "number", "type": "u8"}, {"name": "sold", "type": "bool"},
    {"name": "price", "type": "u64"}, {"name": "buyer", "type": "u64"}]}
SECTIONS = [("Floor", 8, 16, 250), ("Lower", 8, 16, 180), ("Upper", 8, 16, 120),
            ("Balcony", 8, 16, 80)]  # name, rows, seats per row, price
VIEWS = {
    "seat_map": {"table": SEATS, "group_by": ["section", "row", "number"],
                 "aggregates": [{"fn": "max", "field": "sold"}, {"fn": "max", "field": "buyer"}]},
    "sales_by_section": {"table": SEATS, "where": [{"field": "sold", "op": "eq", "value": True}],
                         "group_by": ["section"],
                         "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"}]},
    "remaining_by_price": {"table": SEATS,
                           "where": [{"field": "sold", "op": "eq", "value": False}],
                           "group_by": ["price"], "aggregates": [{"fn": "count"}]},
}
VISITOR = 1_000_000  # Buyer ids from here up are visitors; below are the simulated buyers.
VISITOR_VIEWS_MAX = 24
RESTART_AFTER = 20  # Seconds before a crashed process is restarted on its own.


def seat_id(section, row, number):
    return section * 10_000 + row * 100 + number


def all_seats():
    for section, (_, rows, per_row, price) in enumerate(SECTIONS):
        for row in range(rows):
            for number in range(per_row):
                yield section, row, number, price


class Demo:
    def __init__(self, cluster, buyers, pace):
        self.cluster = cluster
        self.api = Http(cluster.api_port, cluster.key)
        self.views = [Http(port, cluster.key) for port in cluster.view_ports]
        self.buyers, self.pace = buyers, pace
        self.lock = threading.Lock()
        self.show = 0
        self.show_start_op = 0
        self.stats = {}
        self.winners = {}  # seat id -> buyer, for this show, from commit replies
        self.events = []   # recent purchases: {op, seat, buyer, outcome}
        self.visitor_views = []
        self.crashed_at = {}

    # ---- Setup ----

    def setup(self):
        for process in [self.api] + self.views:
            self.wait_for(process)
        status, body = self.api.request("PUT", f"/v1/tables/{SEATS}", LAYOUT)
        assert status == 200, body
        for name, spec in VIEWS.items():
            status, body = self.api.request("PUT", f"/v1/views/{name}", spec)
            assert status == 200, (name, body)
        status, body = self.views[0].request("GET", "/v1/views")
        self.visitor_views = [v for v in body.get("views", []) if v.startswith("v_")]
        self.new_show()

    @staticmethod
    def wait_for(process, timeout=120):
        """Until it answers: a view process listens once it has rebuilt from the log."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                status, _ = process.request("GET", "/healthz")
                if status == 200:
                    return
            except Unavailable:
                pass
            time.sleep(0.5)
        raise SystemExit(f"port {process.port} did not come up")

    def new_show(self):
        """Every seat unsold: one transaction, so the show starts at one op."""
        entries = [{"kind": "put", "table": SEATS, "id": str(seat_id(s, r, n)),
                    "fields": {"section": s, "row": r, "number": n, "sold": False,
                               "price": str(price), "buyer": "0"}}
                   for s, r, n, price in all_seats()]
        while True:
            try:
                status, body = self.api.request("POST", "/v1/commit", {"entries": entries})
                break
            except Unavailable:
                time.sleep(1)
        assert status == 200, body
        with self.lock:
            self.show += 1
            self.show_start_op = int(body["op"])
            self.stats = {"attempts": 0, "sold": 0, "lost_race": 0, "already_sold": 0,
                          "double_sold": 0, "unavailable": 0}
            self.winners = {}
            self.events = []

    # ---- Buying ----

    def buy(self, seat, buyer):
        """One attempt: read the seat, then claim it at the version read. Returns the outcome."""
        status, body = self.api.request("POST", "/v1/lookup",
                                        {"rows": [{"table": SEATS, "id": str(seat)}]})
        if status != 200:
            raise Unavailable(f"lookup answered {status}")  # 503 while the cluster recovers.
        row = body["rows"][0]
        if not row["exists"]:
            return "no such seat"
        if row["fields"]["sold"]:
            outcome = "already sold"
        else:
            fields = {**row["fields"], "sold": True, "buyer": str(buyer)}
            status, body = self.api.request("POST", "/v1/commit", {"entries": [
                {"kind": "read", "table": SEATS, "id": str(seat), "op_seen": row["op"]},
                {"kind": "put", "table": SEATS, "id": str(seat), "fields": fields}]})
            if status == 409:
                outcome = "lost race"
            elif status == 200:
                outcome = "sold"
            else:
                # 503: the cluster did not answer in time; the commit may still apply.
                raise Unavailable(f"commit answered {status}")
        with self.lock:
            self.stats["attempts"] += 1
            key = {"sold": "sold", "lost race": "lost_race", "already sold": "already_sold"}
            self.stats[key[outcome]] += 1
            if outcome == "sold":
                if seat in self.winners:
                    self.stats["double_sold"] += 1  # Never, if Nerva is right.
                self.winners[seat] = buyer
                self.events.insert(0, {"op": body["op"], "seat": seat, "buyer": buyer})
                del self.events[40:]
        return outcome

    def buyer_loop(self, buyer):
        rng = random.Random(buyer)
        # Buyers prefer the front: the floor is wanted most.
        weights = [8, 4, 2, 1]
        while True:
            time.sleep(rng.uniform(0.3, 1.7) / self.pace)
            section = rng.choices(range(len(SECTIONS)), weights)[0]
            _, rows, per_row, _ = SECTIONS[section]
            # Most want the first rows' middle seats: contention, on purpose.
            row = min(int(rng.expovariate(0.5)), rows - 1)
            number = max(0, min(per_row - 1, int(rng.gauss(per_row / 2, per_row / 4))))
            try:
                self.buy(seat_id(section, row, number), buyer)
            except Unavailable:
                with self.lock:
                    self.stats["unavailable"] += 1
                time.sleep(1)

    def show_loop(self):
        # Sold out by the view, not by `winners`: a commit whose reply was lost to a crash
        # still sold its seat.
        while True:
            time.sleep(1)
            remaining = self.view("remaining_by_price")
            if remaining is not None and int(remaining["op"]) >= self.show_start_op and \
                    not remaining["groups"]:
                time.sleep(12)
                self.new_show()

    def heal_loop(self):
        """Restarts crashed processes after a while, so the public demo heals itself."""
        while True:
            time.sleep(1)
            for process in self.cluster.processes():
                if process.alive():
                    self.crashed_at.pop(process.name, None)
                    continue
                crashed_at = self.crashed_at.setdefault(process.name, time.time())
                if time.time() - crashed_at > RESTART_AFTER:
                    self.cluster.restart(process.name)

    # ---- Reading ----

    def view_from(self, index, name, as_of=None):
        """A view from view process `index` only, or None if it is down."""
        query = f"as_of={as_of}" if as_of else "min_op=latest"
        try:
            status, body = self.views[index].request("GET", f"/v1/views/{name}?{query}")
        except Unavailable:
            return None
        return body if status == 200 else None

    def view(self, name, as_of=None, prefer=0):
        """A view from view process `prefer`, or the other if it is down."""
        query = f"as_of={as_of}" if as_of else "min_op=latest"
        for index in (prefer, 1 - prefer):
            try:
                status, body = self.views[index].request("GET", f"/v1/views/{name}?{query}")
                if status == 200:
                    return body
            except Unavailable:
                continue
        return None

    def state(self, as_of=None):
        seat_map = self.view("seat_map", as_of)
        # Both view processes, at exactly the same op: view b as of the op view a answered at.
        sales = [self.view_from(0, "sales_by_section", as_of)]
        sales.append(self.view_from(1, "sales_by_section", sales[0]["op"] if sales[0] else as_of))
        remaining = self.view("remaining_by_price", as_of)
        with self.lock:
            return {
                "show": self.show, "show_start_op": str(self.show_start_op),
                "op": seat_map["op"] if seat_map else None,
                "seats": seat_map["groups"] if seat_map else None,
                "sections": [{"name": n, "rows": r, "per_row": p, "price": price}
                             for n, r, p, price in SECTIONS],
                "sales": (sales[0] or sales[1] or {}).get("groups"),
                "remaining": remaining["groups"] if remaining else None,
                "hashes": [{"process": f"view {'ab'[i]}", "op": s["op"], "hash": s["hash"]}
                           if s else None for i, s in enumerate(sales)],
                "stats": dict(self.stats), "events": list(self.events),
                "cluster": self.cluster.status(),
                "visitor_views": list(self.visitor_views),
            }

    def declare(self, name, spec):
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,23}", name or ""):
            return 400, {"error": "a name is lowercase letters, digits and _ (up to 24)"}
        name = "v_" + name
        with self.lock:
            if len(self.visitor_views) >= VISITOR_VIEWS_MAX and name not in self.visitor_views:
                return 429, {"error": "enough views for now; they reset with the demo"}
        if not isinstance(spec, dict):
            return 400, {"error": "a view is a JSON object"}
        spec = {**spec, "table": SEATS}
        status, body = self.api.request("PUT", f"/v1/views/{name}", spec)
        if status == 200:
            with self.lock:
                if name not in self.visitor_views:
                    self.visitor_views.append(name)
        return status, {**body, "name": name}


def handler_for(demo, page):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body, content_type="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def body(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length > 16_384:
                raise ValueError("too large")
            return json.loads(self.rfile.read(length) or b"{}")

        def handle_one_request(self):
            # An unexpected error answers 500 and is logged, rather than dropping the connection.
            try:
                super().handle_one_request()
            except Exception:
                traceback.print_exc()
                try:
                    self.reply(500, {"error": "internal error"})
                except OSError:
                    pass

        def do_GET(self):
            path, _, query = self.path.partition("?")
            params = dict(p.partition("=")[::2] for p in query.split("&") if p)
            try:
                if path == "/":
                    return self.reply(200, page(), "text/html; charset=utf-8")
                if path == "/api/state":
                    as_of = params.get("as_of")
                    if as_of is not None and not as_of.isdigit():
                        return self.reply(400, {"error": "as_of is an op"})
                    return self.reply(200, demo.state(as_of))
                if path.startswith("/api/views/"):
                    name = path[len("/api/views/"):]
                    if not re.fullmatch(r"[a-z_][a-z0-9_]{0,31}", name):
                        return self.reply(404, {"error": "no such view"})
                    as_of = params.get("as_of")
                    if as_of is not None and not as_of.isdigit():
                        return self.reply(400, {"error": "as_of is an op"})
                    view = demo.view(name, as_of)
                    return self.reply(200 if view else 503, view or {"error": "views unavailable"})
                return self.reply(404, {"error": "not found"})
            except Unavailable:
                return self.reply(503, {"error": "nerva unavailable"})

        def do_POST(self):
            try:
                body = self.body()
                if self.path == "/api/buy":
                    seat = body.get("seat")
                    if not isinstance(seat, int) or seat < 0:
                        return self.reply(400, {"error": "seat is a seat id"})
                    visitor = VISITOR + secrets.randbelow(1_000_000)
                    return self.reply(200, {"outcome": demo.buy(seat, visitor), "buyer": visitor})
                if self.path == "/api/crash":
                    why = demo.cluster.crash(str(body.get("process")))
                    return self.reply(409 if why else 200, {"error": why} if why else {"ok": True})
                if self.path == "/api/restart":
                    why = demo.cluster.restart(str(body.get("process")))
                    return self.reply(409 if why else 200, {"error": why} if why else {"ok": True})
                if self.path == "/api/views":
                    status, reply = demo.declare(body.get("name"), body.get("spec"))
                    return self.reply(status, reply)
                return self.reply(404, {"error": "not found"})
            except (ValueError, AttributeError):
                return self.reply(400, {"error": "malformed request"})
            except Unavailable:
                return self.reply(503, {"error": "nerva unavailable"})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--nerva", required=True)
    parser.add_argument("--data", required=True, help="directory for data files and logs")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--nerva-port", type=int, default=3100, help="base port for the cluster")
    parser.add_argument("--buyers", type=int, default=24)
    parser.add_argument("--pace", type=float, default=1.0, help="buyer speed multiplier")
    args = parser.parse_args()

    # A stop (SIGTERM, as from Docker or Fly) must take the cluster down with it.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    cluster = Cluster(args.nerva, args.data, args.nerva_port, key=secrets.token_hex(16))
    cluster.start()
    demo = Demo(cluster, args.buyers, args.pace)
    try:
        demo.setup()
        for buyer in range(1, args.buyers + 1):
            threading.Thread(target=demo.buyer_loop, args=(buyer,), daemon=True).start()
        threading.Thread(target=demo.show_loop, daemon=True).start()
        threading.Thread(target=demo.heal_loop, daemon=True).start()

        page_path = os.path.join(os.path.dirname(__file__), "index.html")
        server = ThreadingHTTPServer((args.host, args.port),
                                     handler_for(demo, lambda: open(page_path, "rb").read()))
        print(f"seat demo: http://{args.host}:{args.port}", flush=True)
        server.serve_forever()
    finally:
        cluster.stop()


if __name__ == "__main__":
    main()
