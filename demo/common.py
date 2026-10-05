"""What the demos share (docs/DECISIONS.md N36, N38): a cluster, its views, crash and restart,
visitor-declared views, rate limits, and a request handler that never drops a connection.

A demo subclasses `Demo`: it names its table, layout and views, adds its own routes and
background loops, and calls `run`.
"""
import argparse, json, os, re, secrets, signal, sys, threading, time, traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cluster import Cluster
from nerva_http import Http, Unavailable

VISITOR_VIEWS_MAX = 24
RESTART_AFTER = 20  # Seconds before a crashed process is restarted on its own.


class Limiter:
    """A token bucket per visitor: `rate` actions a second, bursts of `burst`."""

    def __init__(self, rate, burst):
        self.rate, self.burst = rate, burst
        self.buckets = {}
        self.lock = threading.Lock()

    def allow(self, visitor):
        now = time.monotonic()
        with self.lock:
            if len(self.buckets) > 100_000:
                self.buckets.clear()  # Bounded: forget everyone rather than grow.
            tokens, then = self.buckets.get(visitor, (self.burst, now))
            tokens = min(self.burst, tokens + (now - then) * self.rate)
            if tokens < 1:
                self.buckets[visitor] = (tokens, now)
                return False
            self.buckets[visitor] = (tokens - 1, now)
            return True


class Demo:
    """A demo's Nerva side. Subclasses set `table`, `layout` and `views`."""

    table = None
    layout = None
    views = {}

    def __init__(self, cluster, limits=True):
        self.cluster = cluster
        self.api = Http(cluster.api_port, cluster.key)
        self.view_clients = [Http(port, cluster.key) for port in cluster.view_ports]
        self.lock = threading.Lock()
        self.visitor_views = []
        self.crashed_at = {}
        scale = 1 if limits else 1_000
        self.limits = {"crash": Limiter(0.2 * scale, 2), "declare": Limiter(0.1 * scale, 3)}

    # ---- Setup ----

    def setup(self):
        for process in [self.api] + self.view_clients:
            self.wait_for(process)
        status, body = self.api.request("PUT", f"/v1/tables/{self.table}", self.layout)
        assert status == 200, body
        for name, spec in self.views.items():
            status, body = self.api.request("PUT", f"/v1/views/{name}", spec)
            assert status == 200, (name, body)
        status, body = self.api.request("GET", "/v1/views")
        self.visitor_views = [v["name"] for v in body.get("views", [])
                              if v["name"].startswith("v_")]

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

    def commit_retrying(self, entries):
        """A commit that must happen (setup, a reset): retried until the cluster answers.
        Only for writes that are safe to apply twice."""
        while True:
            try:
                status, body = self.api.request("POST", "/v1/commit", {"entries": entries})
                if status == 200:
                    return int(body["op"])
            except Unavailable:
                pass
            time.sleep(1)

    def loops(self):
        """Background loops to run, as callables."""
        return [self.heal_loop]

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

    @staticmethod
    def view_at(process, name, as_of=None):
        """A view from one process (`nerva api` or a `nerva view`), or None if it cannot answer:
        down, or (`nerva api`) the view is still building."""
        query = f"as_of={as_of}" if as_of else "min_op=latest"
        try:
            status, body = process.request("GET", f"/v1/views/{name}?{query}")
        except Unavailable:
            return None
        return body if status == 200 else None

    def view(self, name, as_of=None):
        """A view as the cluster maintains it, from `nerva api` (N66); from a `nerva view`
        process if the gateway cannot answer."""
        for process in [self.api] + self.view_clients:
            answer = self.view_at(process, name, as_of)
            if answer:
                return answer
        return None

    def agreement(self, name, as_of=None):
        """The view as the cluster maintains it (`nerva api`), and as a `nerva view` process
        recomputes it from the log at exactly the same op: their hashes must match (N66)."""
        a = self.view_at(self.api, name, as_of)
        b, label = None, "view a"
        for index, process in enumerate(self.view_clients):
            b, label = self.view_at(process, name, a["op"] if a else as_of), f"view {'ab'[index]}"
            if b:
                break
        labels = ("maintained", f"recomputed ({label})")
        return a, b, [{"process": labels[i], "op": v["op"], "hash": v["hash"]} if v else None
                      for i, v in enumerate((a, b))]

    def common_state(self):
        return {"cluster": self.cluster.status(), "visitor_views": list(self.visitor_views)}

    # ---- Visitors ----

    def declare(self, name, spec):
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,23}", name or ""):
            return 400, {"error": "a name is lowercase letters, digits and _ (up to 24)"}
        name = "v_" + name
        with self.lock:
            if len(self.visitor_views) >= VISITOR_VIEWS_MAX and name not in self.visitor_views:
                return 429, {"error": "enough views for now; they reset with the demo"}
        if not isinstance(spec, dict):
            return 400, {"error": "a view is a JSON object"}
        status, body = self.api.request("PUT", f"/v1/views/{name}", {**spec, "table": self.table})
        if status == 200:
            with self.lock:
                if name not in self.visitor_views:
                    self.visitor_views.append(name)
        return status, {**body, "name": name}

    def get_routes(self):
        """Path -> function(params) -> (status, body). Subclasses add theirs."""
        return {}

    def post_routes(self):
        """Path -> function(body, visitor) -> (status, body). Subclasses add theirs."""
        return {}


def handler_for(demo, page, behind_proxy):
    get_routes, post_routes = demo.get_routes(), demo.post_routes()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def visitor(self):
            # Behind a proxy (Fly, nginx), the visitor is the first forwarded address.
            if behind_proxy:
                forwarded = self.headers.get("Fly-Client-IP") or \
                    (self.headers.get("X-Forwarded-For") or "").split(",")[0].strip()
                if forwarded:
                    return forwarded
            return self.client_address[0]

        def reply(self, status, body, content_type="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(data)

        def body(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length > 16_384:
                raise ValueError("too large")
            body = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(body, dict):
                raise ValueError("not an object")
            return body

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
            as_of = params.get("as_of")
            if as_of is not None and not as_of.isdigit():
                return self.reply(400, {"error": "as_of is an op"})
            try:
                if path == "/":
                    return self.reply(200, page(), "text/html; charset=utf-8")
                if path in get_routes:
                    return self.reply(*get_routes[path](params))
                if path.startswith("/api/views/"):
                    name = path[len("/api/views/"):]
                    if not re.fullmatch(r"[a-z_][a-z0-9_]{0,31}", name):
                        return self.reply(404, {"error": "no such view"})
                    view = demo.view(name, as_of)
                    return self.reply(200 if view else 503, view or {"error": "views unavailable"})
                return self.reply(404, {"error": "not found"})
            except Unavailable:
                return self.reply(503, {"error": "nerva unavailable"})

        def do_POST(self):
            try:
                body, visitor = self.body(), self.visitor()
                if self.path in ("/api/crash", "/api/restart"):
                    if not demo.limits["crash"].allow(visitor):
                        return self.reply(429, {"error": "one crash every few seconds, please"})
                    act = demo.cluster.crash if self.path == "/api/crash" else demo.cluster.restart
                    why = act(str(body.get("process")))
                    return self.reply(409 if why else 200, {"error": why} if why else {"ok": True})
                if self.path == "/api/views":
                    if not demo.limits["declare"].allow(visitor):
                        return self.reply(429, {"error": "one view every few seconds, please"})
                    return self.reply(*demo.declare(body.get("name"), body.get("spec")))
                if self.path in post_routes:
                    return self.reply(*post_routes[self.path](body, visitor))
                return self.reply(404, {"error": "not found"})
            except (ValueError, AttributeError, TypeError):
                return self.reply(400, {"error": "malformed request"})
            except Unavailable:
                return self.reply(503, {"error": "nerva unavailable"})

    return Handler


def run(name, make_demo, page_path, add_arguments=lambda parser: None):
    """Parses the common options, runs the cluster and the demo, and serves the page."""
    parser = argparse.ArgumentParser(description=f"The {name} demo.")
    parser.add_argument("--nerva", required=True)
    parser.add_argument("--data", required=True, help="directory for data files and logs")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--nerva-port", type=int, default=3100, help="base port for the cluster")
    parser.add_argument("--behind-proxy", action="store_true",
                        help="identify visitors by Fly-Client-IP or X-Forwarded-For")
    parser.add_argument("--no-limits", action="store_true", help="no rate limits (tests)")
    add_arguments(parser)
    args = parser.parse_args()

    # A stop (SIGTERM, as from Docker or Fly) must take the cluster down with it.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    cluster = Cluster(args.nerva, args.data, args.nerva_port, key=secrets.token_hex(16))
    cluster.start()
    try:
        demo = make_demo(cluster, args)
        demo.setup()
        for loop in demo.loops():
            threading.Thread(target=loop, daemon=True).start()
        server = ThreadingHTTPServer((args.host, args.port),
                                     handler_for(demo, lambda: open(page_path, "rb").read(),
                                                 args.behind_proxy))
        print(f"{name} demo: http://{args.host}:{args.port}", flush=True)
        server.serve_forever()
    finally:
        cluster.stop()
