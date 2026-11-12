#!/usr/bin/env python3
"""Tests for r2.py (docs/releases/packages.md, slice 1; NRV-E1143). Run from the repository root:
python3 -I .github/scripts/test_r2.py

A fake S3 server (http.server, in this file) checks every SigV4 signature, keeps objects in
memory, enforces the bucket locks and can fail on demand. SigV4 itself is checked against the
examples in AWS's documentation ("Signature Calculations for the Authorization Header")."""
import contextlib
import datetime
import hashlib
import io
import os
import subprocess
import sys
import tempfile
import threading
import types
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import r2  # noqa: E402

SCRIPT = Path(r2.__file__)
AKID = "AKIAFAKEFAKEFAKE1234"
SECRET = "s3cr3t/FAKE+secret/key/never/printed0123456789"
BUCKET = "nerva-packages"
LOCKED = ("apt/pool/", "rpm/stable/packages/", "rpm/rc/packages/", "manifest/")
LOCK_BODY = ("<Error><Code>ObjectLockedByBucketPolicy</Code>"
             "<Message>locked</Message></Error>")


class Fake(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.objects = {}      # key -> (body, headers)
        self.locks = LOCKED
        self.lock_mode = "412"  # what put-new of an existing locked object answers
        self.page_size = 1000
        self.faults = []       # next requests: an int status, or "drop"
        self.log = []          # (method, key, headers)
        self.secret = SECRET
        self.mutex = threading.Lock()

    def locked(self, key):
        return any(key.startswith(p) for p in self.locks)

    @property
    def env(self):
        return {"R2_ENDPOINT": f"http://127.0.0.1:{self.server_address[1]}",
                "R2_BUCKET": BUCKET, "R2_ACCESS_KEY_ID": AKID,
                "R2_SECRET_ACCESS_KEY": SECRET}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, status, body=b"", headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)) if self.command != "HEAD" or body
                         else headers.get("Content-Length", "0") if headers else "0")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def authentic(self, body):
        h = {k.lower(): v for k, v in self.headers.items()}
        auth = h.get("authorization", "")
        try:
            signed = auth.split("SignedHeaders=")[1].split(",")[0].strip().split(";")
            given = auth.split("Signature=")[1].strip()
        except IndexError:
            return False
        u = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qsl(u.query, keep_blank_values=True)
        sig, _ = r2.sigv4(self.command, u.path, query, {n: h[n] for n in signed},
                          h["x-amz-content-sha256"], h["x-amz-date"], "auto", "s3", AKID,
                          self.server.secret)
        return (sig == given and h["x-amz-content-sha256"] == hashlib.sha256(body).hexdigest()
                and "host" in signed and "x-amz-date" in signed)

    def handle_any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        srv = self.server
        with srv.mutex:
            if srv.faults:
                f = srv.faults.pop(0)
                if f == "store_drop":  # the write lands, the answer is lost
                    u = urllib.parse.urlsplit(self.path)
                    srv.objects[urllib.parse.unquote(u.path).split("/", 2)[2]] = (
                        body, {k.lower(): v for k, v in self.headers.items()})
                    f = "drop"
                if f == "drop":
                    self.close_connection = True
                    self.connection.close()
                    return
                return self.reply(f, b"<Error><Code>InternalError</Code></Error>")
            if not self.authentic(body):
                return self.reply(403, b"<Error><Code>SignatureDoesNotMatch</Code></Error>")
            u = urllib.parse.urlsplit(self.path)
            parts = urllib.parse.unquote(u.path).split("/", 2)
            key = parts[2] if len(parts) > 2 else ""
            srv.log.append((self.command, key, {k.lower(): v for k, v in self.headers.items()}))
            if parts[1] != BUCKET:
                return self.reply(404, b"<Error><Code>NoSuchBucket</Code></Error>")
            if self.command == "GET" and not key:
                return self.do_list(u)
            if self.command in ("GET", "HEAD"):
                return self.do_read(key)
            return self.do_put(key, body)

    def do_read(self, key):
        obj = self.server.objects.get(key)
        if obj is None:
            return self.reply(404, b"<Error><Code>NoSuchKey</Code></Error>")
        body, hdrs = obj
        out = {"Content-Length": str(len(body))}
        if "x-amz-meta-sha256" in hdrs:
            out["x-amz-meta-sha256"] = hdrs["x-amz-meta-sha256"]
        return self.reply(200, body, out)

    def do_put(self, key, body):
        srv = self.server
        hdrs = {k.lower(): v for k, v in self.headers.items()}
        exists = key in srv.objects
        if exists and srv.locked(key):
            if hdrs.get("if-none-match") == "*" and srv.lock_mode == "412":
                return self.reply(412, b"<Error><Code>PreconditionFailed</Code></Error>")
            return self.reply(409, LOCK_BODY.encode())
        if exists and hdrs.get("if-none-match") == "*":
            return self.reply(412, b"<Error><Code>PreconditionFailed</Code></Error>")
        srv.objects[key] = (body, hdrs)
        return self.reply(200)

    def do_list(self, u):
        q = dict(urllib.parse.parse_qsl(u.query))
        assert q.get("list-type") == "2"
        keys = sorted(k for k in self.server.objects if k.startswith(q.get("prefix", "")))
        start = int(q["continuation-token"]) if "continuation-token" in q else 0
        page = keys[start:start + self.server.page_size]
        more = start + len(page) < len(keys)
        ns = "http://s3.amazonaws.com/doc/2006-03-01/"
        xml = f'<ListBucketResult xmlns="{ns}"><IsTruncated>{str(more).lower()}</IsTruncated>'
        for k in page:
            xml += f"<Contents><Key>{k}</Key><Size>{len(self.server.objects[k][0])}</Size></Contents>"
        if more:
            xml += f"<NextContinuationToken>{start + len(page)}</NextContinuationToken>"
        return self.reply(200, (xml + "</ListBucketResult>").encode())

    do_GET = do_HEAD = do_PUT = handle_any


class Case(unittest.TestCase):
    def setUp(self):
        self.srv = Fake()
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.tmp = tempfile.TemporaryDirectory()
        self.sleeps = []
        r2._sleep = self.sleeps.append
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)

    def file(self, data, name="f"):
        p = os.path.join(self.tmp.name, name)
        Path(p).write_bytes(data)
        return p

    def run_r2(self, *argv, env=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = r2.main(list(argv), self.srv.env if env is None else env)
        self.last = (out.getvalue(), err.getvalue())
        return code

    def assert_diag(self, headline, cause=r2.E1143_CAUSE, fix=r2.E1143_FIX):
        """stderr is exactly the registered form: headline, a cause line and a fix line."""
        self.assertEqual(self.last[1], f"{headline}\n  cause  {cause}\n  fix    {fix}\n")

    def assert_clean(self, text):
        for secret in (SECRET, AKID):
            self.assertNotIn(secret, text)
        self.assertNotIn("Authorization", text)
        self.assertNotIn("Signature=", text)


class SigV4(unittest.TestCase):
    """AWS's published examples: access key AKIAIOSFODNN7EXAMPLE, 2013-05-24, us-east-1."""
    AK = "AKIAIOSFODNN7EXAMPLE"
    SK = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    D = "20130524T000000Z"
    EMPTY = hashlib.sha256(b"").hexdigest()
    HOST = "examplebucket.s3.amazonaws.com"

    def sign(self, method, path, query, headers, payload):
        return r2.sigv4(method, path, query, headers, payload, self.D, "us-east-1", "s3",
                        self.AK, self.SK)[0]

    def test_get_object(self):
        h = {"Host": self.HOST, "Range": "bytes=0-9", "x-amz-content-sha256": self.EMPTY,
             "x-amz-date": self.D}
        self.assertEqual(self.sign("GET", "/test.txt", [], h, self.EMPTY),
                         "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")

    def test_put_object(self):
        body = hashlib.sha256(b"Welcome to Amazon S3.").hexdigest()
        h = {"Date": "Fri, 24 May 2013 00:00:00 GMT", "Host": self.HOST,
             "x-amz-date": self.D, "x-amz-storage-class": "REDUCED_REDUNDANCY",
             "x-amz-content-sha256": body}
        self.assertEqual(self.sign("PUT", "/test%24file.text", [], h, body),
                         "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")

    def test_get_bucket_lifecycle(self):
        h = {"Host": self.HOST, "x-amz-date": self.D, "x-amz-content-sha256": self.EMPTY}
        self.assertEqual(self.sign("GET", "/", [("lifecycle", "")], h, self.EMPTY),
                         "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")

    def test_list_objects(self):
        h = {"Host": self.HOST, "x-amz-date": self.D, "x-amz-content-sha256": self.EMPTY}
        self.assertEqual(self.sign("GET", "/", [("max-keys", "2"), ("prefix", "J")], h,
                                   self.EMPTY),
                         "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")


class Puts(Case):
    def test_put_new_writes_and_stores_headers(self):
        data = b"deb bytes"
        key = "apt/pool/main/n/nerva/nerva_0.7.1-1_amd64.deb"
        self.assertEqual(self.run_r2("put-new", key, self.file(data)), 0)
        body, h = self.srv.objects[key]
        self.assertEqual(body, data)
        self.assertEqual(h["if-none-match"], "*")
        self.assertEqual(h["x-amz-meta-sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(h["content-type"], "application/vnd.debian.binary-package")
        self.assertEqual(h["cache-control"], "public, max-age=31536000, immutable")

    def test_content_types_and_cache_control_per_kind(self):
        sha = "a" * 64
        cases = {
            "rpm/stable/packages/nerva-0.7.1-1.x86_64.rpm":
                ("application/x-rpm", r2.IMMUTABLE),
            "manifest/0000000001.asc": ("text/plain", r2.IMMUTABLE),
            "apt/dists/stable/InRelease": ("text/plain", "no-cache"),
            "apt/dists/stable/Release.gpg": ("application/pgp-signature", "no-cache"),
            "apt/dists/rc/main/binary-arm64/Packages": ("text/plain", "no-cache"),
            "apt/dists/rc/main/binary-arm64/Packages.gz": ("application/gzip", "no-cache"),
            f"apt/dists/rc/main/binary-arm64/by-hash/SHA256/{sha}":
                ("application/octet-stream", r2.IMMUTABLE),
            "rpm/stable/repodata/repomd.xml": ("application/xml", "no-cache"),
            "rpm/stable/repodata/repomd.xml.asc": ("application/pgp-signature", "no-cache"),
            f"rpm/rc/repodata/{sha}-primary.xml.gz": ("application/gzip", r2.IMMUTABLE),
        }
        for key, (ct, cc) in cases.items():
            self.assertEqual((r2.content_type(key), r2.cache_control(key)), (ct, cc), key)
            if r2.replaceable(key):
                self.assertEqual(self.run_r2("put", key, self.file(b"x")), 0, key)
                h = self.srv.objects[key][1]
                self.assertEqual((h["content-type"], h["cache-control"]), (ct, cc))

    def test_put_new_existing_is_412_exit_3(self):
        key = "rpm/rc/repodata/" + "b" * 64 + "-other.xml.gz"  # not locked
        self.assertEqual(self.run_r2("put-new", key, self.file(b"one")), 0)
        self.assertEqual(self.run_r2("put-new", key, self.file(b"two")), 3)
        self.assertEqual(self.srv.objects[key][0], b"one")

    def test_put_new_existing_under_lock_both_answers_exit_3(self):
        key = "manifest/0000000001.asc"
        for mode in ("412", "refusal"):
            self.srv.objects.clear()
            self.srv.lock_mode = mode
            self.assertEqual(self.run_r2("put-new", key, self.file(b"one")), 0)
            self.srv.log.clear()
            self.assertEqual(self.run_r2("put-new", key, self.file(b"two")), 3, mode)
            self.assertEqual(self.srv.objects[key][0], b"one")
            self.assertEqual(self.last, ("", ""))

    def test_put_new_whose_answer_was_lost_is_done_not_exists(self):
        data = b"manifest"
        for key, mode in (("manifest/0000000002.asc", "412"), ("manifest/0000000002.asc", "409"),
                          ("apt/dists/stable/main/binary-amd64/by-hash/SHA256/" + "a" * 64, "412")):
            self.srv.objects.clear()
            self.srv.lock_mode = mode
            self.srv.faults = ["store_drop"]
            self.assertEqual(self.run_r2("put-new", key, self.file(data)), 0, (key, mode))
            self.assertEqual(self.srv.objects[key][0], data)
            self.assertEqual(self.sleeps[-1], 1)

    def test_put_new_exists_after_a_retry_with_other_bytes_is_exists(self):
        key = "manifest/0000000002.asc"
        for stored in (b"another writer", b"manifes!", b"manifest+"):
            self.srv.objects[key] = (stored, {"x-amz-meta-sha256":
                                              hashlib.sha256(stored).hexdigest()})
            self.srv.faults = ["drop"]  # a retry happens, the object is not ours
            self.assertEqual(self.run_r2("put-new", key, self.file(b"manifest")), 3, stored)
        self.srv.objects[key] = (b"manifest", {})  # right size, no recorded hash
        self.srv.faults = ["drop"]
        self.assertEqual(self.run_r2("put-new", key, self.file(b"manifest")), 3)

    def test_put_new_exists_on_the_first_attempt_is_exists_without_a_head(self):
        key = "manifest/0000000002.asc"
        self.assertEqual(self.run_r2("put-new", key, self.file(b"same")), 0)
        self.srv.log.clear()
        self.assertEqual(self.run_r2("put-new", key, self.file(b"same")), 3)
        self.assertEqual([m for m, _, _ in self.srv.log], ["PUT"])

    def test_put_new_other_4xx_is_e1143(self):
        wrong = dict(self.srv.env, R2_BUCKET="nope")
        self.assertEqual(self.run_r2("put-new", "a/b", self.file(b"x"), env=wrong), 1)
        self.assert_diag("error[NRV-E1143]: r2.py: put-new a/b: HTTP 404 NoSuchBucket")

    def test_put_refuses_names_outside_the_replaceable_set(self):
        for key in ("apt/pool/main/n/nerva/nerva_0.7.1-1_amd64.deb",
                    "rpm/stable/packages/nerva-0.7.1-1.x86_64.rpm", "manifest/0000000002.asc",
                    "apt/dists/beta/InRelease", "apt/dists/stable/InRelease/x",
                    "rpm/stable/repodata/" + "c" * 63 + "-primary.xml.gz",
                    "rpm/stable/repodata/" + "c" * 64 + "-primary.xml",
                    "apt/dists/stable/main/binary-i386/Packages", "lock/x", ""):
            self.srv.log.clear()
            self.assertEqual(self.run_r2("put", key, self.file(b"x")), 70, key)
            self.assertEqual(self.srv.log, [], key)  # refused before any request
            self.assert_diag(
                f"bug[NRV-B0005]: r2.py: put {key}: refused, not a name a run replaces",
                "the calling script asked to replace an object whose name is never replaced",
                "Report it; the script's naming of the objects it replaces is wrong")

    def test_put_replaces_a_replaceable_name(self):
        key = "apt/dists/stable/InRelease"
        self.assertEqual(self.run_r2("put", key, self.file(b"one")), 0)
        self.assertEqual(self.run_r2("put", key, self.file(b"two")), 0)
        self.assertEqual(self.srv.objects[key][0], b"two")

    def test_probe_locked_both_ways(self):
        key = "manifest/0000000001.asc"
        data = b"signed manifest"
        self.assertEqual(self.run_r2("put-new", key, self.file(data)), 0)
        self.assertEqual(self.run_r2("probe-locked", key, self.file(data)), 0)
        self.assertEqual(self.srv.objects[key][0], data)
        self.srv.locks = ()  # the lock rule is gone
        self.assertEqual(self.run_r2("probe-locked", key, self.file(data)), 4)
        self.assertIn("lock rule is missing", self.last[1])
        self.assertNotIn("error", self.last[1])  # the caller owns the code (NRV-E1149)

    def test_probe_locked_any_other_answer_is_e1143(self):
        key = "manifest/0000000001.asc"
        self.srv.faults = [403]  # not the pinned pair, and not retried
        self.srv.secret = "different"
        self.assertEqual(self.run_r2("probe-locked", key, self.file(b"x")), 1)
        self.assert_diag("error[NRV-E1143]: r2.py: probe-locked manifest/0000000001.asc: HTTP 403 InternalError")
        self.srv.secret = SECRET
        # a 409 with another code, or the pinned code with another status, is not the pin
        for status, code in ((409, "OperationAborted"), (403, r2.LOCK_CODE)):
            self.assertFalse(r2.is_lock(status, f"<Error><Code>{code}</Code></Error>".encode()))


class Reads(Case):
    def test_head_and_get(self):
        data = b"hello"
        self.assertEqual(self.run_r2("put-new", "x/y", self.file(data)), 0)
        self.assertEqual(self.run_r2("head", "x/y"), 0)
        self.assertEqual(self.last[0], f"5\t{hashlib.sha256(data).hexdigest()}\n")
        dest = os.path.join(self.tmp.name, "out")
        self.assertEqual(self.run_r2("get", "x/y", dest), 0)
        self.assertEqual(Path(dest).read_bytes(), data)

    def test_absent_is_exit_2(self):
        dest = os.path.join(self.tmp.name, "out")
        self.assertEqual(self.run_r2("head", "no/such"), 2)
        self.assertEqual(self.run_r2("get", "no/such", dest), 2)
        self.assertFalse(os.path.exists(dest))

    def test_get_checks_the_stored_hash(self):
        self.srv.objects["x/y"] = (b"bytes", {"x-amz-meta-sha256": "0" * 64})
        dest = os.path.join(self.tmp.name, "out")
        self.assertEqual(self.run_r2("get", "x/y", dest), 1)
        self.assertIn("NRV-E1143", self.last[1])
        self.assertFalse(os.path.exists(dest))
        self.srv.objects["x/z"] = (b"bytes", {})  # no hash stored: nothing to check
        self.assertEqual(self.run_r2("get", "x/z", dest), 0)

    def test_head_without_a_stored_hash_prints_dash(self):
        self.srv.objects["x/z"] = (b"bytes", {})
        self.assertEqual(self.run_r2("head", "x/z"), 0)
        self.assertEqual(self.last[0], "5\t-\n")

    def test_list_across_pages(self):
        self.srv.page_size = 3
        for i in range(8):
            self.srv.objects[f"manifest/{i:010d}.asc"] = (b"x" * i, {})
        self.srv.objects["other/z"] = (b"", {})
        self.assertEqual(self.run_r2("list", "manifest/"), 0)
        lines = self.last[0].splitlines()
        self.assertEqual(lines, [f"manifest/{i:010d}.asc\t{i}" for i in range(8)])
        self.assertEqual(len([e for e in self.srv.log if e[0] == "GET"]), 3)
        self.assertEqual(self.run_r2("list", "empty/"), 0)
        self.assertEqual(self.last[0], "")

    def test_list_stops_after_100_pages(self):
        self.srv.page_size = 1
        for i in range(101):
            self.srv.objects[f"p/{i:04d}"] = (b"", {})
        self.assertEqual(self.run_r2("list", "p/"), 5)
        self.assertEqual(len(self.last[0].splitlines()), 100)
        self.assertEqual(len(self.srv.log), 100)
        self.assert_diag("error[NRV-E1143]: r2.py: list p/: truncated, more than 100 pages of keys")
        del self.srv.objects["p/0100"]  # exactly 100 pages is complete, not truncated
        self.assertEqual(self.run_r2("list", "p/"), 0)
        self.assertEqual(len(self.last[0].splitlines()), 100)


class Listing(Case):
    """A listing the fake builds by hand: the bucket's token holder can add any key."""

    def page(self, body, truncated="false", token=""):
        ns = "http://s3.amazonaws.com/doc/2006-03-01/"
        tok = f"<NextContinuationToken>{token}</NextContinuationToken>" if token else ""
        xml = (f'<ListBucketResult xmlns="{ns}"><IsTruncated>{truncated}</IsTruncated>'
               f"{body}{tok}</ListBucketResult>").encode()
        self.srv.do_list_override = xml

    def run_list(self):
        orig = Handler.do_list
        Handler.do_list = lambda h, u: h.reply(200, self.srv.do_list_override)
        self.addCleanup(setattr, Handler, "do_list", orig)
        return self.run_r2("list", "p/")

    def test_truncated_with_no_token_is_e1143(self):
        self.page("<Contents><Key>p/a</Key><Size>1</Size></Contents>", truncated="true")
        self.assertEqual(self.run_list(), 1)
        self.assertEqual(self.last[0], "")
        self.assert_diag("error[NRV-E1143]: r2.py: list p/: the listing is truncated and "
                         "gives no continuation token")

    def test_a_key_with_a_control_character_is_refused(self):
        for bad in ("p/a&#9;1&#10;p/b", "p/a&#13;", "p/a&#127;"):
            self.page(f"<Contents><Key>{bad}</Key><Size>999</Size></Contents>")
            self.assertEqual(self.run_list(), 1, bad)
            self.assertEqual(self.last[0], "")
            self.assertIn("control character", self.last[1])

    def test_a_key_xml_cannot_carry_is_refused(self):
        self.page("<Contents><Key>p/a&#1;</Key><Size>1</Size></Contents>")
        self.assertEqual(self.run_list(), 1)
        self.assertEqual(self.last[0], "")

    def test_a_missing_or_malformed_size_is_refused(self):
        for size in ("", "<Size></Size>", "<Size>None</Size>", "<Size>-1</Size>",
                     "<Size>1.5</Size>"):
            self.page(f"<Contents><Key>p/a</Key>{size}</Contents>")
            self.assertEqual(self.run_list(), 1, size)
            self.assertEqual(self.last[0], "")
            self.assertIn("no size, or one that is not a decimal", self.last[1])

    def test_a_good_page_lists(self):
        self.page("<Contents><Key>p/a b</Key><Size>7</Size></Contents>")
        self.assertEqual(self.run_list(), 0)
        self.assertEqual(self.last[0], "p/a b\t7\n")


class Encoding(unittest.TestCase):
    """What goes on the wire for awkward keys, checked against hand-written expectations (the
    fake server verifies signatures with r2.sigv4 itself, so it cannot catch a wrong path or
    query encoding). The signatures are pinned at a fixed clock, so a change to the encoding
    shows. The review cross-checked this encoding against botocore 1.44.1's S3SigV4Auth (region
    `auto`) on requests of the same kind."""

    def test_special_key_and_token_wire_form_and_signature(self):
        seen = {}

        class Resp:
            status = 200

            def getheaders(self):
                return []

            def read(self):
                return b""

        class Conn:
            def __init__(self, host, timeout=None):
                seen["host"] = host

            def request(self, method, target, body=None, headers=None):
                seen.update(target=target, headers=dict(headers))

            def getresponse(self):
                return Resp()

            def close(self):
                pass

        class Now:
            @staticmethod
            def now(tz=None):
                return datetime.datetime(2026, 11, 12, 20, 0, 0, tzinfo=datetime.timezone.utc)

        saved = (r2.http.client.HTTPSConnection, r2.datetime)
        r2.http.client.HTTPSConnection = Conn
        r2.datetime = types.SimpleNamespace(datetime=Now, timezone=datetime.timezone)
        try:
            c = r2.Client({"R2_ENDPOINT": "https://acct.r2.cloudflarestorage.com",
                           "R2_BUCKET": "nerva-packages", "R2_ACCESS_KEY_ID": "AKID",
                           "R2_SECRET_ACCESS_KEY": "SECRET/+x"})
            c._once("GET", "we ird+key/\u00fc/a=b&c?d#e%41*(),'!:@$;", [], {}, b"")
            key_target = seen["target"]
            key_auth = seen["headers"]["authorization"]
            c._once("GET", "", [("list-type", "2"), ("prefix", "apt/pool/ x+y"),
                                ("continuation-token", "1a/b+c=d==")], {}, b"")
        finally:
            r2.http.client.HTTPSConnection, r2.datetime = saved
        self.assertEqual(
            key_target, "/nerva-packages/we%20ird%2Bkey/%C3%BC/a%3Db%26c%3Fd%23e%2541"
                        "%2A%28%29%2C%27%21%3A%40%24%3B")
        self.assertEqual(
            seen["target"], "/nerva-packages?continuation-token=1a%2Fb%2Bc%3Dd%3D%3D"
                            "&list-type=2&prefix=apt%2Fpool%2F%20x%2By")
        self.assertIn("Signature=d0bb528aacc4586aa1684d61df0759f7395c16ad6d9e9fe70ff45304c05f7aa5", key_auth)
        self.assertIn("Signature=839bda920452d4ff36026ea820c5104611580267de7049b923e16c9384d140a6", seen["headers"]["authorization"])


class Failures(Case):
    def test_retries_a_5xx_and_a_dropped_connection(self):
        self.srv.faults = [503, "drop", 500]
        self.assertEqual(self.run_r2("put-new", "k/v", self.file(b"x")), 0)
        self.assertEqual(self.sleeps, [1, 2, 4])
        self.assertEqual(self.srv.objects["k/v"][0], b"x")

    def test_gives_up_after_three_retries(self):
        self.srv.faults = [500, 500, 500, 500, 500]
        self.assertEqual(self.run_r2("head", "k/v"), 1)
        self.assertEqual(self.sleeps, [1, 2, 4])
        self.assert_diag("error[NRV-E1143]: r2.py: head k/v: HTTP 500 after 3 retries")
        self.assertEqual(len(self.srv.faults), 1)  # 4 attempts, no more

    def test_connection_refused_is_e1143(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.assertEqual(self.run_r2("head", "k/v"), 1)
        self.assertIn("error[NRV-E1143]: r2.py: head k/v: connection failed", self.last[1])

    def test_a_4xx_is_not_retried(self):
        self.srv.secret = "other"
        self.assertEqual(self.run_r2("head", "k/v"), 1)
        self.assertEqual(self.sleeps, [])
        self.assertIn("HTTP 403", self.last[1])

    def test_the_environment_is_required(self):
        env = dict(self.srv.env)
        del env["R2_SECRET_ACCESS_KEY"]
        self.assertEqual(self.run_r2("head", "k", env=env), 1)
        self.assert_diag("error[NRV-E1139]: r2.py: not set in the environment: "
                         "R2_SECRET_ACCESS_KEY", r2.E1139_CAUSE, r2.E1139_FIX)
        self.assertEqual(self.run_r2("nosuch"), 64)
        self.assertEqual(self.run_r2("put-new", "only-a-key"), 64)

    def test_a_bad_endpoint_is_e1139(self):
        for url, what in (("ftp://x", "is not an http(s) URL"),
                          ("https://acct.r2.cloudflarestorage.com/nerva-packages", "has a path"),
                          ("https://acct.r2.cloudflarestorage.com/?a=b", "has a path"),
                          ("http://acct.r2.cloudflarestorage.com", "not loopback")):
            env = dict(self.srv.env, R2_ENDPOINT=url)
            self.assertEqual(self.run_r2("head", "k", env=env), 1, url)
            self.assertIn("error[NRV-E1139]: r2.py: R2_ENDPOINT", self.last[1])
            self.assertIn(what, self.last[1])
        for url in ("https://acct.r2.cloudflarestorage.com", "https://x.example/",
                    "http://localhost:9000", "http://[::1]:9000"):
            r2.Client(dict(self.srv.env, R2_ENDPOINT=url))

    def test_a_missing_local_file_is_e1143(self):
        self.assertEqual(self.run_r2("put-new", "k/v", "/nonexistent/file"), 1)
        self.assertIn("error[NRV-E1143]: r2.py: put-new: cannot read or write a local file",
                      self.last[1])

    def test_no_credential_in_any_message(self):
        data = self.file(b"x")
        self.srv.objects["manifest/1"] = (b"x", {})
        bad = dict(self.srv.env, R2_BUCKET="nope")
        runs = [("head", "a"), ("put-new", "a", data), ("put", "bad/name", data),
                ("probe-locked", "manifest/1", data), ("list", "a/"),
                ("get", "manifest/1", data + ".out")]
        for argv in runs:
            self.run_r2(*argv, env=bad)
            self.assert_clean("".join(self.last))
        self.srv.faults = [500] * 4
        self.run_r2("head", "a")
        self.assert_clean("".join(self.last))
        self.srv.secret = "other"
        self.run_r2("head", "a")
        self.assert_clean("".join(self.last))

    def test_the_command_line_carries_no_credential(self):
        # Really run it, isolated, as the workflow does; the credentials only in the environment.
        self.srv.objects["x/y"] = (b"hi", {})
        argv = [sys.executable, "-I", str(SCRIPT), "head", "x/y"]
        env = dict(self.srv.env, PATH=os.environ.get("PATH", ""))
        p = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual((p.returncode, p.stdout), (0, "2\t-\n"))
        for a in argv:
            self.assertNotIn(SECRET, a)
            self.assertNotIn(AKID, a)
        p = subprocess.run(argv, env={"PATH": env["PATH"]}, capture_output=True, text=True,
                           timeout=30)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(p.stdout, "")
        self.assertIn("error[NRV-E1139]: r2.py: not set in the environment", p.stderr)


class Pins(unittest.TestCase):
    def test_the_lock_pin_and_the_bounds_are_the_documented_ones(self):
        self.assertEqual((r2.LOCK_STATUS, r2.LOCK_CODE), (409, "ObjectLockedByBucketPolicy"))
        self.assertEqual((r2.PAGES_MAX, r2.RETRIES), (100, 3))

    def test_e1143_is_the_registered_form(self):
        e = r2.fail("put-new", "a/b", "HTTP 400")
        self.assertEqual(e.text, "error[NRV-E1143]: r2.py: put-new a/b: HTTP 400\n"
                         f"  cause  {r2.E1143_CAUSE}\n  fix    {r2.E1143_FIX}")
        self.assertEqual(e.code, 1)


if __name__ == "__main__":
    unittest.main()
