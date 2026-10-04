# Oracle copy of Botpike/runtime ledger/ledgerd.py at commit 23010baf962ae4ac69bdd8a709ed47784fc3c529 (docs/DECISIONS.md N8).
# Do not edit: update by copying the file again and recording the new commit.
#!/usr/bin/env python3
"""Reference ledger service for the Botpike Runtime.

Implements the runtime's budget and registry protocol over HTTP, so the daemon
holds no balances and no sequence numbers of its own. It is a stand-in for
Botpike: the same protocol, served from Botpike's ledger, replaces it.

Wire format: POST, key=value lines in both directions, authenticated by the
X-Ledger-Key header. Free text travels hex-encoded in fields ending `_hex`.
Journal lines the service wrote come back as `line_hex=` so the caller can
show them.

State lives in LEDGER_DIR, in the same files the daemon's built-in ledger uses:
ledger.txt, journal.log, results.txt.
"""
import os, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DIR = Path(os.environ.get("LEDGER_DIR", "state"))
KEY = os.environ.get("LEDGER_KEY", "")
PORT = int(os.environ.get("LEDGER_PORT", "8090"))
LOCK = threading.Lock()
BALANCES = ("available", "held", "settled", "prevented")


def read_ledger():
    f = DIR / "ledger.txt"
    out = {}
    if f.exists():
        for line in f.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k] = v
    return out


def write_ledger(l):
    DIR.mkdir(exist_ok=True)
    (DIR / "ledger.txt").write_text("\n".join(f"{k}={v}" for k, v in sorted(l.items())))


# The same limits as amount.max and amount.totalMax in runtime.u: one amount at
# most 10^15, a running total at most 2^62. Past either the request is refused
# (400) before anything is written, as the daemon's ledger fails instead of
# wrapping.
AMOUNT_MAX = 10**15
TOTAL_MAX = 2**62


def amount(f, key):
    n = int(f[key])
    if n < 0 or n > AMOUNT_MAX:
        raise ValueError(f"{key} {n} is outside 0..{AMOUNT_MAX}")
    return n


def total(n):
    if n > TOTAL_MAX:
        raise ValueError(f"a ledger total would pass {TOTAL_MAX}")
    return str(n)


def nat(l, k):
    try:
        return int(l.get(k, "0"))
    except ValueError:
        return 0


def summary(l):
    over = nat(l, "overage")
    return (f"ledger: available {nat(l,'available')}, held {nat(l,'held')}, "
            f"settled {nat(l,'settled')}, prevented {nat(l,'prevented')}"
            + (f", overage {over}" if over else ""))


def journal(lines, text):
    text = text.replace("\n", " ").replace("\r", " ")
    with open(DIR / "journal.log", "a") as f:
        f.write(text + "\n")
    lines.append(text)


def unhex(fields, name):
    return bytes.fromhex(fields.get(name, "")).decode("utf-8", "replace")


def req_value(memo, est):
    return f"{est}:{memo.encode().hex()}"


def mismatch(l, rid, memo, est):
    """What a known request id was reserved for, if this reserve asks for
    something else; None if the id is new or the reserve is a true re-run."""
    was = l.get(f"req.{rid}")
    if was is None or was == req_value(memo, est):
        return None
    west, _, whex = was.partition(":")
    try:
        wmemo = bytes.fromhex(whex).decode("utf-8", "replace")
    except ValueError:
        wmemo = "?"
    return f"{west} {wmemo}"


def reuse_line(rid):
    if rid.endswith("/allowance"):
        return f"REUSE    journalled allowance answer  [{rid}]"
    return f"REUSE    journalled result, provider not called again  [{rid}]"
def count_denial(l, rid, est):
    """Add a refused request to prevented once; False if it was already counted."""
    if f"denied.{rid}" in l:
        return False
    l["prevented"] = total(nat(l, "prevented") + est)
    l[f"denied.{rid}"] = str(est)
    write_ledger(l)
    return True


def state_lines(l):
    return [f"{k}={v}" for k, v in sorted(l.items()) if k.startswith(("seq.", "hold.", "resuming.", "blocked."))]


def handle(route, f):
    """Returns (reply fields as list of 'k=v', journal lines written)."""
    out, said = [], []
    l = read_ledger()

    if route == "/v1/available":
        out.append(f"available={nat(l,'available')}")

    elif route == "/v1/summary":
        out.append("summary=" + summary(l))

    elif route == "/v1/status":
        out.append("summary=" + summary(l))
        out += state_lines(l)

    elif route == "/v1/note":
        journal(said, unhex(f, "text_hex"))

    elif route == "/v1/refused":
        est, rid = amount(f, "estimate"), f["request_id"]
        why = unhex(f, "why_hex") + ("" if count_denial(l, rid, est) else "; already counted")
        journal(said, f"DENIED   {est}  {unhex(f,'memo_hex')}  ({why})  [{rid}]")

    elif route == "/v1/reserve":
        rid, memo, est = f["request_id"], unhex(f, "memo_hex"), amount(f, "estimate")
        avail = nat(l, "available")
        was = mismatch(l, rid, memo, est)
        if was is not None:
            journal(said, f"REFUSED  {est}  {memo}  (request id already used for {was})  [{rid}]")
            out += ["granted=false", "state=mismatch"]
        elif f"done.{rid}" in l:
            journal(said, f"REPLAY   already settled, not charged again  {memo}  [{rid}]")
            out += ["granted=true", "state=already_settled"]
        elif f"hold.{rid}" in l:
            journal(said, f"RECOVER  reservation already held  {memo}  [{rid}]")
            out += ["granted=true", "state=already_reserved"]
        elif est > avail:
            if f.get("retry") == "1":
                journal(said, f"DENIED   {est}  {memo}  (retry, not recounted; available {avail})  [{rid}]")
            elif count_denial(l, rid, est):
                journal(said, f"DENIED   {est}  {memo}  (available {avail})  [{rid}]")
            else:
                journal(said, f"DENIED   {est}  {memo}  (already counted; available {avail})  [{rid}]")
            out += ["granted=false", "state=denied"]
        else:
            l["available"] = str(avail - est)
            l["held"] = total(nat(l, "held") + est)
            l[f"hold.{rid}"] = str(est)
            l[f"req.{rid}"] = req_value(memo, est)
            write_ledger(l)
            journal(said, f"RESERVE  {est}  {memo}  [{rid}]")
            out += ["granted=true", "state=reserved"]

    elif route == "/v1/settle":
        # The same rules as ledger.settle in runtime.u; `within=false` tells
        # the daemon the agent overspent and must stop for review.
        rid, actual = f["request_id"], amount(f, "actual")
        held = l.get(f"hold.{rid}")
        within = True
        if held is None:
            # A re-run's settle: if the first stopped the agent for review, so
            # does this one, or a crash before the review receipt was written
            # would let the agent carry on unreviewed.
            if f"review.{rid}" in l:
                within = False
            if f"done.{rid}" not in l:
                l["settled"] = total(nat(l, "settled") + actual)
                l["overage"] = total(nat(l, "overage") + actual)
                l[f"done.{rid}"] = str(actual)
                write_ledger(l)
                journal(said, f"OVERAGE  {actual}  settled with no hold, booked to overage  [{rid}]")
        else:
            est, avail = int(held), nat(l, "available")
            l["held"] = str(max(0, nat(l, "held") - est))
            l["settled"] = total(nat(l, "settled") + actual)
            del l[f"hold.{rid}"]
            l[f"done.{rid}"] = str(actual)
            excess = actual - est
            if excess <= 0:
                l["available"] = total(avail - excess)
                journal(said, f"SETTLE   {actual}  released {-excess}  [{rid}]")
            elif excess <= avail:
                l["available"] = str(avail - excess)
                journal(said, f"SETTLE   {actual}  {excess} above its hold, charged to available  [{rid}]")
            else:
                l["overage"] = total(nat(l, "overage") + excess)
                l[f"review.{rid}"] = str(excess)
                within = False
                journal(said, f"OVERAGE  {actual}  {excess} above its hold with {avail} available, "
                              f"booked to overage; agent stops for review  [{rid}]")
            write_ledger(l)
        out.append(f"within={'true' if within else 'false'}")

    elif route == "/v1/block":
        key, why = f["key"], unhex(f, "why_hex")
        l[f"blocked.{key}"] = why.encode().hex()
        write_ledger(l)
        journal(said, f"BLOCK    {key} until a person reviews: {why}")

    elif route == "/v1/blocked":
        if f"blocked.{f['key']}" in l:
            out += ["held=true", "why_hex=" + l[f"blocked.{f['key']}"]]
        else:
            out.append("held=false")

    elif route == "/v1/unblock":
        if l.pop(f"blocked.{f['key']}", None) is not None:
            write_ledger(l)
            journal(said, f"UNBLOCK  {f['key']}")

    elif route == "/v1/recall":
        rid = f["request_id"]
        r = DIR / "results.txt"
        if r.exists():
            for line in r.read_text().splitlines():
                if line.startswith(rid + "="):
                    out += ["found=true", "value_hex=" + line[len(rid) + 1:]]
                    journal(said, reuse_line(rid))
                    break
        if not out:
            out.append("found=false")

    elif route == "/v1/remember":
        with open(DIR / "results.txt", "a") as r:
            r.write(f"{f['request_id']}={f['value_hex']}\n")

    elif route == "/v1/sequence":
        out.append(f"seq={nat(l, 'seq.' + f['agent'])}")

    elif route == "/v1/bump":
        agent = f["agent"]
        seq = nat(l, "seq." + agent) + 1
        l["seq." + agent] = str(seq)
        l.pop("resuming." + agent, None)
        write_ledger(l)
        out.append(f"seq={seq}")

    elif route == "/v1/claim":
        agent, expected = f["agent"], int(f["expected"])
        seq = nat(l, "seq." + agent)
        if expected == seq:
            l["seq." + agent] = str(seq + 1)
            l["resuming." + agent] = str(expected)
            write_ledger(l)
            out += ["result=claimed", f"seq={seq + 1}"]
        elif l.get("resuming." + agent) == str(expected):
            out += ["result=reentered", f"seq={seq}"]
        else:
            out += ["result=stale", f"seq={seq}"]

    elif route == "/v1/admin/init":
        l = {"available": str(amount(f, "amount")), "held": "0", "settled": "0", "prevented": "0"}
        for name in ("journal.log", "results.txt"):
            (DIR / name).unlink(missing_ok=True)
        write_ledger(l)
        out.append("summary=" + summary(l))

    elif route == "/v1/admin/topup":
        added = amount(f, "amount")
        l["available"] = total(nat(l, "available") + added)
        write_ledger(l)
        journal(said, f"TOPUP    {added}")
        out.append("summary=" + summary(l))

    else:
        return None, None
    return out, said


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply(self, status, lines):
        data = "\n".join(lines).encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200 if self.path == "/healthz" else 404, ["ok=true" if self.path == "/healthz" else "error=not found"])

    def do_POST(self):
        if not KEY or self.headers.get("X-Ledger-Key") != KEY:
            return self.reply(401, ["error=invalid ledger key"])
        body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        fields = dict(line.split("=", 1) for line in body.splitlines() if "=" in line)
        with LOCK:
            try:
                out, said = handle(self.path, fields)
            except (KeyError, ValueError) as e:
                return self.reply(400, [f"error=bad request: {e}"])
        if out is None:
            return self.reply(404, ["error=unknown route"])
        # `ok=true` closes every complete reply, so a cut-off body can be told
        # from a short one (D39); the client does not require it yet.
        self.reply(200, out + ["line_hex=" + s.encode().hex() for s in said] + ["ok=true"])


if __name__ == "__main__":
    DIR.mkdir(exist_ok=True)
    print(f"ledger service on 127.0.0.1:{PORT}, state in {DIR}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
