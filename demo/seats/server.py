#!/usr/bin/env python3
"""The seat-booking demo (docs/DECISIONS.md N36).

Runs a three-replica Nerva cluster, declares a venue (a typed table of seats) and three views,
sells the venue to simulated buyers racing for the best seats, and serves a page where visitors
watch, buy, rewind, crash processes and declare views of their own. When a show sells out, the
next one starts.

    python3 demo/seats/server.py --nerva zig-out/bin/nerva --data /tmp/seats --port 8000

Standard library only. The API key never leaves this process; visitors reach Nerva only through
the endpoints in `common.py` and below, which validate what they send.
"""
import os, random, secrets, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common import Demo, Limiter, run  # noqa: E402
from nerva_http import Unavailable  # noqa: E402

SEATS = 10
SECTIONS = [("Floor", 8, 16, 250), ("Lower", 8, 16, 180), ("Upper", 8, 16, 120),
            ("Balcony", 8, 16, 80)]  # name, rows, seats per row, price
VISITOR = 1_000_000  # Buyer ids from here up are visitors; below are the simulated buyers.


def seat_id(section, row, number):
    return section * 10_000 + row * 100 + number


def all_seats():
    for section, (_, rows, per_row, price) in enumerate(SECTIONS):
        for row in range(rows):
            for number in range(per_row):
                yield section, row, number, price


class Seats(Demo):
    table = SEATS
    layout = {"name": "seats", "fields": [
        {"name": "section", "type": "u8"}, {"name": "row", "type": "u8"},
        {"name": "number", "type": "u8"}, {"name": "sold", "type": "bool"},
        {"name": "price", "type": "u64"}, {"name": "buyer", "type": "u64"}]}
    views = {
        # The seat map is itself a view, so rewinding is a read of it as of an op.
        "seat_map": {"table": SEATS, "group_by": ["section", "row", "number"],
                     "aggregates": [{"fn": "max", "field": "sold"},
                                    {"fn": "max", "field": "buyer"}]},
        "sales_by_section": {"table": SEATS,
                             "where": [{"field": "sold", "op": "eq", "value": True}],
                             "group_by": ["section"],
                             "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"}]},
        "remaining_by_price": {"table": SEATS,
                               "where": [{"field": "sold", "op": "eq", "value": False}],
                               "group_by": ["price"], "aggregates": [{"fn": "count"}]},
    }

    def __init__(self, cluster, args):
        super().__init__(cluster, limits=not args.no_limits)
        self.buyers, self.pace = args.buyers, args.pace
        self.limits["buy"] = Limiter(2 if not args.no_limits else 1_000, 4)
        self.show = 0
        self.show_start_op = 0
        self.stats = {}
        self.winners = {}  # seat id -> buyer, for this show, from commit replies
        self.events = []   # recent purchases: {op, seat, buyer}

    def setup(self):
        super().setup()
        self.new_show()

    def new_show(self):
        """Every seat unsold: one transaction, so the show starts at one op."""
        op = self.commit_retrying([
            {"kind": "put", "table": SEATS, "id": str(seat_id(s, r, n)),
             "fields": {"section": s, "row": r, "number": n, "sold": False,
                        "price": str(price), "buyer": "0"}}
            for s, r, n, price in all_seats()])
        with self.lock:
            self.show += 1
            self.show_start_op = op
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
        weights = [8, 4, 2, 1]  # The floor is wanted most.
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

    def loops(self):
        buyers = [lambda b=b: self.buyer_loop(b) for b in range(1, self.buyers + 1)]
        return super().loops() + [self.show_loop] + buyers

    # ---- Routes ----

    def state(self, params):
        as_of = params.get("as_of")
        seat_map = self.view("seat_map", as_of)
        sales_a, sales_b, hashes = self.agreement("sales_by_section", as_of)
        remaining = self.view("remaining_by_price", as_of)
        with self.lock:
            return 200, {
                **self.common_state(),
                "show": self.show, "show_start_op": str(self.show_start_op),
                "op": seat_map["op"] if seat_map else None,
                "seats": seat_map["groups"] if seat_map else None,
                "sections": [{"name": n, "rows": r, "per_row": p, "price": price}
                             for n, r, p, price in SECTIONS],
                "sales": (sales_a or sales_b or {}).get("groups"),
                "remaining": remaining["groups"] if remaining else None,
                "hashes": hashes,
                "stats": dict(self.stats), "events": list(self.events),
            }

    def visitor_buy(self, body, visitor):
        seat = body.get("seat")
        if not isinstance(seat, int) or seat < 0:
            return 400, {"error": "seat is a seat id"}
        if not self.limits["buy"].allow(visitor):
            return 429, {"error": "a couple of seats a second, please"}
        buyer = VISITOR + secrets.randbelow(1_000_000)
        return 200, {"outcome": self.buy(seat, buyer), "buyer": buyer}

    def get_routes(self):
        return {"/api/state": self.state}

    def post_routes(self):
        return {"/api/buy": self.visitor_buy}


def arguments(parser):
    parser.add_argument("--buyers", type=int, default=24)
    parser.add_argument("--pace", type=float, default=1.0, help="buyer speed multiplier")


if __name__ == "__main__":
    run("seat", Seats, os.path.join(os.path.dirname(__file__), "index.html"), arguments)
