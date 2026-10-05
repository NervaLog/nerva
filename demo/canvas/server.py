#!/usr/bin/env python3
"""The shared canvas demo (docs/DECISIONS.md N38).

A 64 x 64 canvas everyone paints on, one pixel at a time, from an 8-colour palette. Simulated
painters keep it alive: one keeps a logo standing, others scribble over it, one draws a sunset,
one a spiral. Visitors paint, play the timelapse (the canvas view read at a series of ops),
crash processes and declare views. The canvas starts over every `--reset-minutes`.

    python3 demo/canvas/server.py --nerva zig-out/bin/nerva --data /tmp/canvas --port 8001

Moderation (to be confirmed before it is public, N38): 8 colours, 1 pixel a second per visitor,
a reset every hour, no free text except view names (lowercase letters, digits and _).
"""
import math, os, random, sys, time, zlib

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from common import Demo, Limiter, run  # noqa: E402
from nerva_http import Unavailable  # noqa: E402

PIXELS = 20
SIZE = 64
COLORS = 8  # White, black, grey, red, orange, yellow, green, blue (the page holds the values).
VISITOR = 1_000_000  # Painter ids from here up are visitors.

# "NERVA" in a 5 x 7 font, for the logo keeper.
FONT = {
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "V": ["10001", "10001", "10001", "10001", "01010", "01010", "00100"],
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
}


def logo_pixels():
    """(x, y) of the logo, centred."""
    word = "NERVA"
    width = len(word) * 6 - 1
    left, top = (SIZE - width) // 2, (SIZE - 7) // 2
    for index, letter in enumerate(word):
        for row, bits in enumerate(FONT[letter]):
            for column, bit in enumerate(bits):
                if bit == "1":
                    yield left + index * 6 + column, top + row


def pixel_id(x, y):
    return y * SIZE + x


class Canvas(Demo):
    table = PIXELS
    layout = {"name": "pixels", "fields": [
        {"name": "x", "type": "u8"}, {"name": "y", "type": "u8"},
        {"name": "color", "type": "u8"}, {"name": "paints", "type": "u32"},
        {"name": "painter", "type": "u64"}]}
    views = {
        # The canvas is itself a view, so a timelapse frame is a read of it as of an op.
        "canvas": {"table": PIXELS, "group_by": ["x", "y"],
                   "aggregates": [{"fn": "max", "field": "color"}]},
        "pixels_by_color": {"table": PIXELS, "group_by": ["color"],
                            "aggregates": [{"fn": "count"}]},
        "painted_by_visitors": {"table": PIXELS,
                                "where": [{"field": "painter", "op": "ge", "value": VISITOR}],
                                "aggregates": [{"fn": "count"}, {"fn": "max", "field": "paints"}]},
    }

    def __init__(self, cluster, args):
        super().__init__(cluster, limits=not args.no_limits)
        self.pace, self.reset_seconds = args.pace, args.reset_minutes * 60
        self.limits["paint"] = Limiter(1 if not args.no_limits else 1_000, 5)
        self.epoch = 0
        self.epoch_start_op = 0
        self.epoch_started_at = 0
        self.stats = {}
        self.events = []  # recent paints: {op, x, y, color, painter}

    def setup(self):
        super().setup()
        self.reset()

    def reset(self):
        """A blank canvas, in two transactions of half the rows each: the `canvas` view keeps a
        group per pixel, and one op takes at most 4,095 distinct groups (N52, N62). The epoch
        starts at the second op, the first at which the whole canvas is blank."""
        blank = [{"kind": "put", "table": PIXELS, "id": str(pixel_id(x, y)),
                  "fields": {"x": x, "y": y, "color": 0, "paints": 0, "painter": "0"}}
                 for y in range(SIZE) for x in range(SIZE)]
        half = len(blank) // 2
        self.commit_retrying(blank[:half])
        op = self.commit_retrying(blank[half:])
        with self.lock:
            self.epoch += 1
            self.epoch_start_op = op
            self.epoch_started_at = time.time()
            self.stats = {"paints": 0, "lost_race": 0, "by_visitors": 0, "unavailable": 0}
            self.events = []

    # ---- Painting ----

    def paint(self, x, y, color, painter):
        """Read the pixel, then write it at the version read: a pixel two painters hit at once
        is painted by one and the other retries. Returns the op, or None if it kept losing."""
        for _ in range(3):
            status, body = self.api.request("POST", "/v1/lookup",
                                            {"rows": [{"table": PIXELS, "id": str(pixel_id(x, y))}]})
            if status != 200:
                raise Unavailable(f"lookup answered {status}")
            row = body["rows"][0]
            paints = int(row["fields"]["paints"]) if row["exists"] else 0
            fields = {"x": x, "y": y, "color": color, "paints": paints + 1,
                      "painter": str(painter)}
            status, body = self.api.request("POST", "/v1/commit", {"entries": [
                {"kind": "read", "table": PIXELS, "id": str(pixel_id(x, y)),
                 "op_seen": row["op"]},
                {"kind": "put", "table": PIXELS, "id": str(pixel_id(x, y)), "fields": fields}]})
            if status == 409:
                with self.lock:
                    self.stats["lost_race"] += 1
                continue
            if status != 200:
                raise Unavailable(f"commit answered {status}")
            with self.lock:
                self.stats["paints"] += 1
                self.stats["by_visitors"] += painter >= VISITOR
                self.events.insert(0, {"op": body["op"], "x": x, "y": y, "color": color,
                                       "painter": painter})
                del self.events[40:]
            return body["op"]
        return None

    def painter_loop(self, painter, strokes):
        rng = random.Random(painter)
        for x, y, color in strokes(rng):
            time.sleep(rng.uniform(0.2, 0.8) / self.pace)
            try:
                self.paint(x % SIZE, y % SIZE, color, painter)
            except Unavailable:
                with self.lock:
                    self.stats["unavailable"] += 1
                time.sleep(1)

    # The simulated painters: endless streams of strokes.

    @staticmethod
    def logo_keeper(rng):
        logo = list(logo_pixels())
        while True:
            for x, y in rng.sample(logo, len(logo)):
                yield x, y, 1

    @staticmethod
    def graffiti(rng):
        x, y = rng.randrange(SIZE), rng.randrange(SIZE // 3, 2 * SIZE // 3)
        color = rng.randrange(2, COLORS)
        while True:
            x, y = x + rng.choice((-1, 0, 1)), y + rng.choice((-1, 0, 1))
            if rng.random() < 0.05:
                color = rng.randrange(2, COLORS)
            yield x, y, color

    @staticmethod
    def sunset(rng):
        while True:
            for y in range(SIZE - 12, SIZE):
                band = (y - (SIZE - 12)) // 4
                for x in range(SIZE):
                    yield x, y, (5, 4, 3)[band]

    @staticmethod
    def spiral(rng):
        while True:
            for step in range(2000):
                angle = step * 0.25
                radius = 2 + step * 0.01
                yield int(10 + radius * math.cos(angle)), int(10 + radius * math.sin(angle)), 7

    def epoch_loop(self):
        while True:
            time.sleep(5)
            if time.time() - self.epoch_started_at > self.reset_seconds:
                self.reset()

    def loops(self):
        painters = [(1, self.logo_keeper), (2, self.sunset), (3, self.spiral)]
        painters += [(10 + i, self.graffiti) for i in range(6)]
        return super().loops() + [self.epoch_loop] + [
            lambda p=p, s=s: self.painter_loop(p, s) for p, s in painters]

    # ---- Routes ----

    def frame(self, as_of=None):
        """The canvas as a string of SIZE * SIZE colour digits, row by row."""
        view = self.view("canvas", as_of)
        if view is None:
            return None
        pixels = ["0"] * (SIZE * SIZE)
        for group in view["groups"]:
            pixels[pixel_id(group["x"], group["y"])] = group["max_color"]
        return {"op": view["op"], "pixels": "".join(pixels)}

    def state(self, params):
        as_of = params.get("as_of")
        frame = self.frame(as_of)
        colors_a, colors_b, hashes = self.agreement("pixels_by_color", as_of)
        visitors = self.view("painted_by_visitors", as_of)
        with self.lock:
            return 200, {
                **self.common_state(),
                "size": SIZE, "epoch": self.epoch, "epoch_start_op": str(self.epoch_start_op),
                "op": frame["op"] if frame else None,
                "pixels": frame["pixels"] if frame else None,
                "colors": (colors_a or colors_b or {}).get("groups"),
                "visitors": visitors["groups"] if visitors else None,
                "hashes": hashes, "stats": dict(self.stats), "events": list(self.events),
            }

    def get_frame(self, params):
        frame = self.frame(params.get("as_of"))
        return (200, frame) if frame else (503, {"error": "views unavailable"})

    def visitor_paint(self, body, visitor):
        x, y, color = body.get("x"), body.get("y"), body.get("color")
        if not all(isinstance(v, int) for v in (x, y, color)) or \
                not (0 <= x < SIZE and 0 <= y < SIZE and 0 <= color < COLORS):
            return 400, {"error": f"x and y are 0 to {SIZE - 1}, color 0 to {COLORS - 1}"}
        if not self.limits["paint"].allow(visitor):
            return 429, {"error": "one pixel a second, please"}
        painter = VISITOR + zlib.crc32(visitor.encode()) % 1_000_000  # Stable across runs.
        op = self.paint(x, y, color, painter)
        return (200, {"op": op}) if op else (409, {"error": "that pixel is busy; try again"})

    def get_routes(self):
        return {"/api/state": self.state, "/api/frame": self.get_frame}

    def post_routes(self):
        return {"/api/paint": self.visitor_paint}


def arguments(parser):
    parser.add_argument("--pace", type=float, default=1.0, help="painter speed multiplier")
    parser.add_argument("--reset-minutes", type=float, default=60)


if __name__ == "__main__":
    run("canvas", Canvas, os.path.join(os.path.dirname(__file__), "index.html"), arguments)
