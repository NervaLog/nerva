#!/usr/bin/env python3
"""Tests for r2.py (docs/releases/packages.md, slice 1; NRV-E1143). Run from the repository root:
python3 -I .github/scripts/test_r2.py

A fake S3 server (http.server, in this file) checks every SigV4 signature, keeps objects in
memory, enforces the bucket locks and can fail on demand. SigV4 itself is checked against the
examples in AWS's documentation ("Signature Calculations for the Authorization Header")."""
import contextlib
import hashlib
import io
import os
import subprocess
import sys
import tempfile
import threading
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

    def test_put_new_other_4xx_is_e1143(self):
        wrong = dict(self.srv.env, R2_BUCKET="nope")
        self.assertEqual(self.run_r2("put-new", "a/b", self.file(b"x"), env=wrong), 1)
        self.assertIn("error[NRV-E1143]: r2 put-new a/b: HTTP 404 NoSuchBucket", self.last[1])

    def test_put_refuses_names_outside_the_replaceable_set(self):
        for key in ("apt/pool/main/n/nerva/nerva_0.7.1-1_amd64.deb",
                    "rpm/stable/packages/nerva-0.7.1-1.x86_64.rpm", "manifest/0000000002.asc",
                    "apt/dists/beta/InRelease", "apt/dists/stable/InRelease/x",
                    "rpm/stable/repodata/" + "c" * 63 + "-primary.xml.gz",
                    "rpm/stable/repodata/" + "c" * 64 + "-primary.xml",
                    "apt/dists/stable/main/binary-i386/Packages", "lock/x", ""):
            self.srv.log.clear()
            self.assertEqual(self.run_r2("put", key, self.file(b"x")), 64, key)
            self.assertEqual(self.srv.log, [], key)  # refused before any request
            self.assertIn("refused", self.last[1])

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

    def test_probe_locked_any_other_answer_is_e1143(self):
        key = "manifest/0000000001.asc"
        self.srv.faults = [403]  # not the pinned pair, and not retried
        self.srv.secret = "different"
        self.assertEqual(self.run_r2("probe-locked", key, self.file(b"x")), 1)
        self.assertIn("error[NRV-E1143]: r2 probe-locked manifest/0000000001.asc: HTTP 403",
                      self.last[1])
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
        self.assertIn("error[NRV-E1143]: r2 list p/: truncated, more than 100 pages", self.last[1])
        del self.srv.objects["p/0100"]  # exactly 100 pages is complete, not truncated
        self.assertEqual(self.run_r2("list", "p/"), 0)
        self.assertEqual(len(self.last[0].splitlines()), 100)


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
        self.assertIn("error[NRV-E1143]: r2 head k/v: HTTP 500 after 3 retries", self.last[1])
        self.assertEqual(len(self.srv.faults), 1)  # 4 attempts, no more

    def test_connection_refused_is_e1143(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.assertEqual(self.run_r2("head", "k/v"), 1)
        self.assertIn("error[NRV-E1143]: r2 head k/v: connection failed", self.last[1])

    def test_a_4xx_is_not_retried(self):
        self.srv.secret = "other"
        self.assertEqual(self.run_r2("head", "k/v"), 1)
        self.assertEqual(self.sleeps, [])
        self.assertIn("HTTP 403", self.last[1])

    def test_the_environment_is_required(self):
        env = dict(self.srv.env)
        del env["R2_SECRET_ACCESS_KEY"]
        self.assertEqual(self.run_r2("head", "k", env=env), 64)
        self.assertIn("R2_SECRET_ACCESS_KEY", self.last[1])
        self.assertEqual(self.run_r2("nosuch"), 64)
        self.assertEqual(self.run_r2("put-new", "only-a-key"), 64)

    def test_a_missing_local_file_is_e1143(self):
        self.assertEqual(self.run_r2("put-new", "k/v", "/nonexistent/file"), 1)
        self.assertIn("NRV-E1143", self.last[1])

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
        self.assertEqual(p.returncode, 64)
        self.assertEqual(p.stdout, "")


class Pins(unittest.TestCase):
    def test_the_lock_pin_and_the_bounds_are_the_documented_ones(self):
        self.assertEqual((r2.LOCK_STATUS, r2.LOCK_CODE), (409, "ObjectLockedByBucketPolicy"))
        self.assertEqual((r2.PAGES_MAX, r2.RETRIES), (100, 3))

    def test_e1143_text_is_one_line_with_operation_key_status(self):
        e = r2.fail("put-new", "a/b", "HTTP 400")
        self.assertEqual(e.text, "error[NRV-E1143]: r2 put-new a/b: HTTP 400")
        self.assertEqual(e.code, 1)


if __name__ == "__main__":
    unittest.main()
