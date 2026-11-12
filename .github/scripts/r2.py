#!/usr/bin/env python3
"""S3 calls to Cloudflare R2 for the package repositories (docs/releases/packages.md, "Tools on
the runner, pinned"). Python 3 standard library only; run as `python3 -I r2.py <subcommand> ...`.

Environment (never argv): R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY.

  list <prefix>           stdout: one `<key><TAB><size>` per object, every page (at most 100)
  head <key>              stdout: `<size><TAB><x-amz-meta-sha256 or ->`
  get <key> <file>        writes <file>; checks x-amz-meta-sha256 when the object has one
  put-new <key> <file>    If-None-Match: *; "exists" is a 412 or the pinned lock refusal
  put <key> <file>        only a name a run replaces, or a content-named index file
  probe-locked <key> <file>   unconditional put; R2 must answer with the pinned lock refusal

Exit: 0 done, 1 failed (NRV-E1143), 2 absent, 3 exists (put-new), 4 lock rule missing
(probe-locked: R2 accepted the put), 5 listing truncated at 100 pages, 64 usage or a name `put`
refuses. A message names the operation, the key and the HTTP status; never a header or a
credential."""
import datetime
import hashlib
import hmac
import http.client
import os
import re
import sys
import time
import urllib.parse
import xml.etree.ElementTree as ET

REGION = "auto"
SERVICE = "s3"
PAGES_MAX = 100
RETRIES = 3
BACKOFF_SECONDS = (1, 2, 4)
TIMEOUT_SECONDS = 120
# Cloudflare, "Bucket locks": a single-object request blocked by a lock "fails with HTTP 409 and
# the ObjectLockedByBucketPolicy error code". The rehearsal confirms it against real R2.
LOCK_STATUS = 409
LOCK_CODE = "ObjectLockedByBucketPolicy"
IMMUTABLE = "public, max-age=31536000, immutable"
NO_CACHE = "no-cache"

_sleep = time.sleep  # tests replace it

_CH = r"(?:stable|rc)"
_HEX = r"[0-9a-f]{64}"
REPLACEABLE = [re.compile(p + r"\Z") for p in (
    rf"apt/dists/{_CH}/(?:InRelease|Release|Release\.gpg)",
    rf"apt/dists/{_CH}/main/binary-(?:amd64|arm64)/(?:Packages|Packages\.gz)",
    rf"rpm/{_CH}/repodata/repomd\.xml(?:\.asc)?",
)]
CONTENT_NAMED = [re.compile(p + r"\Z") for p in (
    rf"apt/dists/{_CH}/main/binary-(?:amd64|arm64)/by-hash/SHA256/{_HEX}",
    rf"rpm/{_CH}/repodata/{_HEX}-(?:primary|filelists|other)\.xml\.gz",
)]


class Failure(Exception):
    """A failed operation: `code` is the exit status, `text` the one-line message."""

    def __init__(self, code, text):
        super().__init__(text)
        self.code = code
        self.text = text


def fail(op, key, what):
    return Failure(1, f"error[NRV-E1143]: r2 {op} {key}: {what}")


def replaceable(key):
    return any(p.match(key) for p in REPLACEABLE + CONTENT_NAMED)


def write_once(key):
    return not any(p.match(key) for p in REPLACEABLE)


def content_type(key):
    if "/by-hash/" in key:
        return "application/octet-stream"
    if key.startswith("manifest/"):
        return "text/plain"
    if key.endswith(".deb"):
        return "application/vnd.debian.binary-package"
    if key.endswith(".rpm"):
        return "application/x-rpm"
    if key.endswith(".gz"):
        return "application/gzip"
    if key.endswith(".xml"):
        return "application/xml"
    if key.endswith(".asc") or key.endswith(".gpg"):
        return "application/pgp-signature"
    return "text/plain"


def cache_control(key):
    return IMMUTABLE if write_once(key) else NO_CACHE


def _hmac(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def _quote(s):
    return urllib.parse.quote(s, safe="-_.~")


def sigv4(method, path, query, headers, payload_sha256, amzdate, region, service, akid, secret):
    """Returns (signature, signed_headers) for the request. `headers` holds every header to
    sign, `host` and `x-amz-date` included (names any case, values stripped). `path` is the
    already-encoded URI path; `query` is a list of (name, value) pairs."""
    canon_headers = {k.lower(): " ".join(v.split()) for k, v in headers.items()}
    names = sorted(canon_headers)
    signed = ";".join(names)
    cq = "&".join(f"{_quote(k)}={_quote(v)}" for k, v in sorted(query))
    canonical = "\n".join([
        method, path, cq,
        "".join(f"{n}:{canon_headers[n]}\n" for n in names),
        signed, payload_sha256,
    ])
    day = amzdate[:8]
    scope = f"{day}/{region}/{service}/aws4_request"
    to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amzdate, scope,
        hashlib.sha256(canonical.encode()).hexdigest(),
    ])
    k = _hmac(("AWS4" + secret).encode(), day)
    for part in (region, service, "aws4_request"):
        k = _hmac(k, part)
    return hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest(), signed


class Client:
    def __init__(self, env):
        names = ("R2_ENDPOINT", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY")
        missing = [n for n in names if not env.get(n)]
        if missing:
            raise Failure(64, "error[NRV-E1143]: r2: not set in the environment: "
                          + ", ".join(missing))
        u = urllib.parse.urlsplit(env["R2_ENDPOINT"])
        if u.scheme not in ("http", "https") or not u.netloc:
            raise Failure(64, "error[NRV-E1143]: r2: R2_ENDPOINT is not an http(s) URL")
        self.scheme, self.host = u.scheme, u.netloc
        self.bucket = env["R2_BUCKET"]
        self.akid = env["R2_ACCESS_KEY_ID"]
        self.secret = env["R2_SECRET_ACCESS_KEY"]

    def _once(self, method, key, query, extra, body):
        path = "/" + _quote(self.bucket) + ("/" + urllib.parse.quote(key, safe="/-_.~")
                                            if key else "")
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        payload = hashlib.sha256(body).hexdigest()
        headers = {"host": self.host, "x-amz-date": now, "x-amz-content-sha256": payload}
        headers.update(extra)
        sig, signed = sigv4(method, path, query, headers, payload, now, REGION, SERVICE,
                            self.akid, self.secret)
        headers["authorization"] = (
            f"AWS4-HMAC-SHA256 Credential={self.akid}/{now[:8]}/{REGION}/{SERVICE}/aws4_request,"
            f" SignedHeaders={signed}, Signature={sig}")
        target = path + ("?" + "&".join(f"{_quote(k)}={_quote(v)}" for k, v in sorted(query))
                         if query else "")
        cls = http.client.HTTPSConnection if self.scheme == "https" else http.client.HTTPConnection
        conn = cls(self.host, timeout=TIMEOUT_SECONDS)
        try:
            conn.request(method, target, body=body if method == "PUT" else None,
                         headers=headers)
            r = conn.getresponse()
            return r.status, {k.lower(): v for k, v in r.getheaders()}, r.read()
        finally:
            conn.close()

    def call(self, op, key, method, query=(), extra=None, body=b"", label=None):
        """One request with retries; returns (status, headers, body). Raises on a 5xx or a
        broken connection that outlasts the retries."""
        last = "no answer"
        for attempt in range(RETRIES + 1):
            if attempt:
                _sleep(BACKOFF_SECONDS[attempt - 1])
            try:
                status, hdrs, data = self._once(method, key, list(query), extra or {}, body)
            except (OSError, http.client.HTTPException) as e:
                last = f"connection failed ({type(e).__name__})"
                continue
            if status >= 500:
                last = f"HTTP {status}"
                continue
            return status, hdrs, data
        raise fail(op, label or key, f"{last} after {RETRIES} retries")


def s3_code(data):
    try:
        el = ET.fromstring(data).find("Code")
        return el.text if el is not None else ""
    except ET.ParseError:
        return ""


def is_lock(status, data):
    return status == LOCK_STATUS and s3_code(data) == LOCK_CODE


def refuse(op, key, status, data):
    code = s3_code(data)
    return fail(op, key, f"HTTP {status}" + (f" {code}" if re.fullmatch(r"\w{1,64}", code) else ""))


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def put_headers(key, body):
    return {"content-type": content_type(key), "cache-control": cache_control(key),
            "x-amz-meta-sha256": hashlib.sha256(body).hexdigest()}


def cmd_list(c, prefix):
    out, token, pages = [], None, 0
    truncated = False
    while True:
        pages += 1
        q = [("list-type", "2"), ("prefix", prefix)]
        if token:
            q.append(("continuation-token", token))
        status, _, data = c.call("list", "", "GET", q, label=prefix)
        if status != 200:
            raise refuse("list", prefix, status, data)
        try:
            root = ET.fromstring(data)
        except ET.ParseError:
            raise fail("list", prefix, "the answer is not XML")
        ns = root.tag[:root.tag.index("}") + 1] if root.tag.startswith("{") else ""
        for item in root.findall(f"{ns}Contents"):
            out.append(f"{item.findtext(f'{ns}Key')}\t{item.findtext(f'{ns}Size')}")
        token = root.findtext(f"{ns}NextContinuationToken")
        if root.findtext(f"{ns}IsTruncated") != "true" or not token:
            break
        if pages >= PAGES_MAX:
            truncated = True
            break
    for line in out:
        print(line)
    if truncated:
        sys.stderr.write(f"error[NRV-E1143]: r2 list {prefix}: truncated, more than "
                         f"{PAGES_MAX} pages of keys\n")
        return 5
    return 0


def cmd_head(c, key):
    status, h, data = c.call("head", key, "HEAD")
    if status == 404:
        return 2
    if status != 200:
        raise fail("head", key, f"HTTP {status}")
    print(f"{h.get('content-length', '0')}\t{h.get('x-amz-meta-sha256', '-')}")
    return 0


def cmd_get(c, key, path):
    status, h, data = c.call("get", key, "GET")
    if status == 404:
        return 2
    if status != 200:
        raise refuse("get", key, status, data)
    want = h.get("x-amz-meta-sha256")
    if want and want != hashlib.sha256(data).hexdigest():
        raise fail("get", key, "the bytes do not match the object's x-amz-meta-sha256")
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return 0


def cmd_put_new(c, key, path):
    body = read_file(path)
    h = put_headers(key, body)
    h["if-none-match"] = "*"
    status, _, data = c.call("put-new", key, "PUT", extra=h, body=body)
    if 200 <= status < 300:
        return 0
    if status == 412 or is_lock(status, data):
        return 3
    raise refuse("put-new", key, status, data)


def cmd_put(c, key, path):
    if not replaceable(key):
        raise Failure(64, f"r2 put {key}: refused, not a name a run replaces")
    body = read_file(path)
    status, _, data = c.call("put", key, "PUT", extra=put_headers(key, body), body=body)
    if 200 <= status < 300:
        return 0
    raise refuse("put", key, status, data)


def cmd_probe_locked(c, key, path):
    body = read_file(path)
    status, _, data = c.call("probe-locked", key, "PUT", extra=put_headers(key, body), body=body)
    if is_lock(status, data):
        return 0
    if 200 <= status < 300:
        sys.stderr.write(f"error: r2 probe-locked {key}: R2 accepted an overwrite under a locked "
                         "prefix; the bucket lock rule is missing (the caller reports NRV-E1149)\n")
        return 4
    raise refuse("probe-locked", key, status, data)


COMMANDS = {"list": (cmd_list, 1), "head": (cmd_head, 1), "get": (cmd_get, 2),
            "put-new": (cmd_put_new, 2), "put": (cmd_put, 2),
            "probe-locked": (cmd_probe_locked, 2)}


def main(argv, env=None):
    env = os.environ if env is None else env
    if not argv or argv[0] not in COMMANDS or len(argv) != COMMANDS[argv[0]][1] + 1:
        sys.stderr.write("usage: r2.py list <prefix> | head <key> | get <key> <file> | "
                         "put-new <key> <file> | put <key> <file> | probe-locked <key> <file>\n")
        return 64
    try:
        return COMMANDS[argv[0]][0](Client(env), *argv[1:])
    except Failure as f:
        sys.stderr.write(f.text + "\n")
        return f.code
    except OSError as e:
        sys.stderr.write(f"error[NRV-E1143]: r2 {argv[0]}: cannot read or write a local file "
                         f"({type(e).__name__})\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
