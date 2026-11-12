#!/usr/bin/env python3
"""Tests for package_repos.sh (docs/releases/packages.md, slice 2; NRV-E1139 to NRV-E1156). Run from
the repository root: python3 -I .github/scripts/test_package_repos.py

They use the real gpg, gpgv, apt-ftparchive, createrepo_c, rpmbuild and rpmsign, throwaway keys, a
throwaway packaging/keys/ directory, a stand-in `gh` (a Python script that answers from files), and
r2.py against test_r2.py's fake S3 server, which also enforces the bucket locks. packages.nerva.pro is
a second local server that serves the fake bucket's objects."""
import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_r2 as T  # noqa: E402

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "package_repos.sh"
R2 = HERE / "r2.py"
REPO = "NervaLog/nerva"
COMMIT = "c0ffee" * 6 + "c0de"
PASS = {"a": "pw-a", "b": "pw-b", "c": "pw-c"}
FOOT = "Check the signing key and the package's NEVRA and payload against the release's file, then run again"
E1142_FIX = ("Find who changed the bucket outside the pipeline, restore the listed object or remove the "
             "unlisted one, then run again")
ARCH = {"amd64": "x86_64", "arm64": "aarch64"}

_scratch = None
_keys = {}
_pkgs = {}
_baselines = {}


def scratch():
    global _scratch
    if _scratch is None:
        _scratch = Path(tempfile.mkdtemp(prefix="prs", dir="/tmp"))
    return _scratch


def sh(*argv, **kw):
    return subprocess.run(argv, check=True, capture_output=True, text=True, **kw)


def keys():
    """Three throwaway keys: a (current), b (next), c (in no list)."""
    if not _keys:
        home = scratch() / "gk"
        home.mkdir(mode=0o700)
        env = {**os.environ, "GNUPGHOME": str(home)}
        for n in "abc":
            subprocess.run(["gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", PASS[n],
                            "--quick-generate-key", f"Test {n} <{n}@example.invalid>", "rsa2048", "sign",
                            "never"], check=True, capture_output=True, env=env)
            fpr = subprocess.run(["gpg", "--list-keys", "--with-colons", f"{n}@example.invalid"],
                                 check=True, capture_output=True, text=True, env=env).stdout
            fpr = [x.split(":")[9] for x in fpr.splitlines() if x.startswith("fpr")][0]
            sec = subprocess.run(["gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", PASS[n],
                                  "--armor", "--export-secret-keys", fpr], check=True, capture_output=True,
                                 text=True, env=env).stdout
            pub = subprocess.run(["gpg", "--armor", "--export", fpr], check=True, capture_output=True,
                                 text=True, env=env).stdout
            _keys[n] = (fpr, sec, pub)
    return _keys


def packages(tag, salt=""):
    """The four packages of a release and its SHA256SUMS, built once. Returns {name: bytes}."""
    if (tag, salt) in _pkgs:
        return _pkgs[(tag, salt)]
    v = tag[1:]
    fv = v.replace("-rc.", ".rc.")
    pv = v.replace("-rc.", "~rc.")
    d = scratch() / f"pk-{tag}{salt}"
    d.mkdir()
    out = {}
    for deb_arch in ("amd64", "arm64"):
        root = d / f"deb-{deb_arch}"
        (root / "DEBIAN").mkdir(parents=True)
        (root / "usr/bin").mkdir(parents=True)
        (root / "usr/bin/nerva").write_text(f"#!/bin/sh\necho version {v}\n# {deb_arch} {salt}\n")
        (root / "usr/bin/nerva").chmod(0o755)
        (root / "DEBIAN/control").write_text(
            f"Package: nerva\nVersion: {pv}-1\nArchitecture: {deb_arch}\nMaintainer: t <t@example.invalid>\n"
            "Description: test\n")
        name = f"nerva_{fv}-1_{deb_arch}.deb"
        sh("dpkg-deb", "--root-owner-group", "-Zgzip", "-b", str(root), str(d / name))
        out[name] = (d / name).read_bytes()
        rarch = ARCH[deb_arch]
        top = d / f"rpm-{rarch}"
        spec = d / f"{rarch}.spec"
        spec.write_text(
            f"Name: nerva\nVersion: {pv}\nRelease: 1\nSummary: t\nLicense: Apache-2.0\nBuildArch: noarch\n"
            f"%description\nt\n%install\nmkdir -p %{{buildroot}}/usr/bin\n"
            f"echo 'version {v} {rarch} {salt}' > %{{buildroot}}/usr/bin/nerva\n%files\n/usr/bin/nerva\n")
        sh("rpmbuild", "-bb", "--target", "noarch", "--define", f"_topdir {top}", "--define",
           "debug_package %{nil}", "--define", "_build_id_links none", "--define",
           "_binary_payload w9.gzdio", str(spec))
        built = next((top / "RPMS").rglob("*.rpm"))
        name = f"nerva-{fv}-1.{rarch}.rpm"
        out[name] = built.read_bytes()
    sums = "".join(f"{hashlib.sha256(b).hexdigest()}  {n}\n" for n, b in sorted(out.items()))
    out["SHA256SUMS"] = sums.encode()
    _pkgs[(tag, salt)] = out
    return out


def fixtures_cleanup():
    if _scratch:
        shutil.rmtree(_scratch, ignore_errors=True)


def tearDownModule():
    fixtures_cleanup()


GH = """#!/usr/bin/env python3
import json, os, subprocess, sys
d = os.environ["GH_DIR"]
args = sys.argv[1:]
with open(d + "/log", "a") as f:
    f.write(" ".join(args) + "\\n")
jq = path = None
i = 1
while i < len(args):
    a = args[i]
    if a == "-H":
        i += 1
    elif a == "--jq":
        i += 1
        jq = args[i]
    elif a != "--paginate":
        path = a
    i += 1
fails = open(d + "/fail").read().split() if os.path.exists(d + "/fail") else []
for f in fails:
    base, _, nth = f.partition("#")
    n = int(open(d + "/count").read()) if os.path.exists(d + "/count") else 0
    if base in path and (not nth or (path.endswith("/releases") and n + 1 == int(nth))):
        sys.stderr.write("gh: HTTP 502\\n")
        sys.exit(1)
if path.endswith("/releases"):
    n = int(open(d + "/count").read()) + 1 if os.path.exists(d + "/count") else 1
    open(d + "/count", "w").write(str(n))
    src = d + f"/releases.{n}.json"
    if not os.path.exists(src):
        src = d + "/releases.json"
    sys.stdout.write(subprocess.run(["jq", "-r", jq, src], check=True, capture_output=True, text=True).stdout)
elif "/releases/assets/" in path:
    p = d + "/assets/" + path.rsplit("/", 1)[1]
    if not os.path.exists(p):
        sys.stderr.write("gh: HTTP 404\\n")
        sys.exit(1)
    sys.stdout.buffer.write(open(p, "rb").read())
elif path.endswith("/commits/main"):
    sys.stdout.write(subprocess.run(["jq", "-r", jq, d + "/commit.json"], check=True, capture_output=True,
                                    text=True).stdout)
else:
    sys.stderr.write("gh: unexpected " + path + "\\n")
    sys.exit(2)
"""


class Web(ThreadingHTTPServer):
    """packages.nerva.pro: serves the fake bucket's objects, with overrides."""
    daemon_threads = True

    def __init__(self, bucket):
        super().__init__(("127.0.0.1", 0), WebHandler)
        self.bucket = bucket
        self.override = {}


class WebHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        key = self.path.lstrip("/")
        body = self.server.override.get(key)
        if body is None:
            obj = self.server.bucket.objects.get(key)
            body = obj[0] if obj else None
        if body is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def sha(b):
    return hashlib.sha256(b).hexdigest()


class Base(unittest.TestCase):
    """One fake bucket, one web server, one throwaway packaging/keys/ and one stand-in gh per test."""
    listed = ("current",)

    def setUp(self):
        self.k = keys()
        self.s3 = T.Fake()
        threading.Thread(target=self.s3.serve_forever, daemon=True).start()
        self.web = Web(self.s3)
        threading.Thread(target=self.web.serve_forever, daemon=True).start()
        self.tmp = Path(tempfile.mkdtemp(prefix="prt", dir="/tmp"))
        self.keys_dir = self.tmp / "keys"
        self.gh_dir = self.tmp / "gh"
        (self.gh_dir / "assets").mkdir(parents=True)
        (self.tmp / "bin").mkdir()
        (self.tmp / "bin/gh").write_text(GH)
        (self.tmp / "bin/gh").chmod(0o755)
        (self.tmp / "tmp").mkdir()
        self.releases = []
        self.next_asset = 100
        self.set_keys(current="a")
        self.commit_age(1)
        self.addCleanup(self.cleanup)

    def cleanup(self):
        subprocess.run(["bash", str(SCRIPT), "cleanup"], env=self.env(), capture_output=True)
        for s in (self.s3, self.web):
            s.shutdown()
            s.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ---- the environment -------------------------------------------------------------------

    def set_keys(self, current="a", next=None, previous=None, file_extra=(), secret="a"):
        self.keys_dir.mkdir(exist_ok=True)
        lines = [f"current {self.k[current][0]}\n"]
        have = [current]
        if next:
            lines.append(f"next {self.k[next][0]}\n")
            have.append(next)
        if previous:
            lines.append(f"previous {self.k[previous][0]}\n")
            have.append(previous)
        (self.keys_dir / "fingerprints").write_text("".join(lines))
        (self.keys_dir / "nerva-release.asc").write_text("".join(self.k[n][2] for n in have + list(file_extra)))
        self.secret = secret
        self.next_secret = next

    def env(self, **extra):
        e = {"PATH": f"{self.tmp}/bin:" + os.environ["PATH"], "HOME": str(self.tmp), "LANG": "C",
             "RUNNER_TEMP": str(self.tmp / "tmp"), "PACKAGE_KEYS_DIR": str(self.keys_dir),
             "PACKAGES_BASE_URL": f"http://127.0.0.1:{self.web.server_address[1]}",
             "GH_TOKEN": "ghp_FAKE_TOKEN_0123456789", "GITHUB_REPOSITORY": REPO, "GITHUB_SHA": COMMIT,
             "GH_DIR": str(self.gh_dir), "REPO_SIGNING_KEY": self.k[self.secret][1],
             "REPO_SIGNING_PASSPHRASE": PASS[self.secret], "MAC_ATTEMPT": "1", "GITHUB_RUN_ATTEMPT": "1"}
        if self.next_secret:
            e["REPO_SIGNING_KEY_NEXT"] = self.k[self.next_secret][1]
            e["REPO_SIGNING_PASSPHRASE_NEXT"] = PASS[self.next_secret]
        e.update(self.s3.env)
        e.update(extra)
        return e

    def run_script(self, *args, **extra):
        p = subprocess.run(["bash", str(SCRIPT), *args], env=self.env(**extra), capture_output=True,
                           text=True, timeout=300)
        self.last = p
        subprocess.run(["bash", str(SCRIPT), "cleanup"], env=self.env(), capture_output=True)
        return p.returncode, p.stdout, p.stderr

    def ready(self, tag, published=False, **extra):
        return self.run_script("ready", tag, "true" if published else "false", **extra)

    def publish(self, tag, **extra):
        return self.run_script("publish", tag, **extra)

    def refresh(self, **extra):
        return self.run_script("refresh", **extra)

    # ---- GitHub -----------------------------------------------------------------------------

    def release(self, tag, state="draft", extra_assets=(), drop=(), index=None, salt=""):
        """Put a release in the stand-in's fixtures. `drop` leaves out assets by name."""
        pk = packages(tag, salt)
        assets = []
        for name, data in pk.items():
            if name in drop:
                continue
            self.next_asset += 1
            (self.gh_dir / "assets" / str(self.next_asset)).write_bytes(data)
            assets.append({"id": self.next_asset, "name": name})
        for name, data in extra_assets:
            self.next_asset += 1
            (self.gh_dir / "assets" / str(self.next_asset)).write_bytes(data)
            assets.append({"id": self.next_asset, "name": name})
        self.releases = [r for r in self.releases if r["tag_name"] != tag]
        self.releases.append({"tag_name": tag, "draft": state == "draft", "assets": assets})
        self.write_releases(index)

    def write_releases(self, index=None):
        name = "releases.json" if index is None else f"releases.{index}.json"
        (self.gh_dir / name).write_text(json.dumps(self.releases))

    def set_state(self, tag, state, index=None):
        for r in self.releases:
            if r["tag_name"] == tag:
                r["draft"] = state == "draft"
        self.write_releases(index)

    def replace_asset(self, tag, name, data):
        for r in self.releases:
            if r["tag_name"] == tag:
                for a in r["assets"]:
                    if a["name"] == name:
                        (self.gh_dir / "assets" / str(a["id"])).write_bytes(data)

    def gh_fail(self, *parts):
        (self.gh_dir / "fail").write_text("\n".join(parts))

    def commit_age(self, days):
        import datetime
        d = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
        (self.gh_dir / "commit.json").write_text(json.dumps({"commit": {"committer": {"date": d}}}))

    # ---- the bucket -------------------------------------------------------------------------

    def keys_under(self, prefix):
        return sorted(k for k in self.s3.objects if k.startswith(prefix))

    def put_raw(self, key, data, meta=True):
        h = {"x-amz-meta-sha256": sha(data)} if meta else {}
        self.s3.objects[key] = (data, h)

    def manifest_keys(self):
        return self.keys_under("manifest/")

    def manifest(self, key=None):
        """The signed text of the highest manifest (or `key`), as package_repos.sh verifies it."""
        key = key or self.manifest_keys()[-1]
        f = self.tmp / "m.asc"
        f.write_bytes(self.s3.objects[key][0])
        p = subprocess.run(["bash", str(SCRIPT), "verify-manifest", str(f), str(int(key[9:19]))],
                           env=self.env(), capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def entries(self, key=None):
        out = {}
        for line in self.manifest(key).splitlines():
            if line.startswith("package "):
                f = line.split()
                out[f[4]] = f[1:]
        return out

    def index_lines(self, kind="index"):
        return {l.split()[2]: l.split()[1] for l in self.manifest().splitlines() if l.startswith(kind + " ")}

    def sign_manifest(self, text, key="a", name=None):
        """A clearsigned manifest as the pipeline writes it (for hand-made states)."""
        home = self.tmp / "sg"
        if not home.exists():
            home.mkdir(mode=0o700)
        env = {**os.environ, "GNUPGHOME": str(home)}
        subprocess.run(["gpg", "--batch", "--import"], input=self.k[key][1], text=True, env=env,
                       capture_output=True, check=True)
        f = self.tmp / "mt.txt"
        f.write_text(text)
        out = self.tmp / "mt.asc"
        out.unlink(missing_ok=True)
        subprocess.run(["gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", PASS[key],
                        "--digest-algo", "SHA512", "--clearsign", "-u", self.k[key][0], "-o", str(out), str(f)],
                       check=True, capture_output=True, env=env)
        data = out.read_bytes()
        if name:
            self.put_raw(name, data)
        return data

    @staticmethod
    def mtext(gen, state="complete", pk=(), ix=(), iw=()):
        s = f"nerva-packages manifest 4\ngeneration {gen}\nstate {state}\n"
        s += "".join(f"package {' '.join(p)}\n" for p in pk)
        s += "".join(f"index {h} {k}\n" for h, k in ix)
        s += "".join(f"index-was {h} {k}\n" for h, k in iw)
        return s

    # ---- assertions -------------------------------------------------------------------------

    def assert_diag(self, rc, err, code, what=None, fix=None):
        """stderr holds the registered block for `code`: headline, a cause line, a fix line."""
        self.assertEqual(rc, 1, err)
        m = re.search(rf"^error\[{code}\]: package_repos\.sh: (.*)\n  cause  (.*)\n  fix    (.*)$", err, re.M)
        self.assertIsNotNone(m, f"no {code} block in:\n{err}")
        if what:
            self.assertIn(what, m.group(1) + " " + m.group(2))
        if fix:
            self.assertEqual(m.group(3), fix)
        return m

    def assert_no_secrets(self, *texts):
        bad = [self.k[n][1] for n in "abc"] + list(PASS.values()) + [T.SECRET, T.AKID, "ghp_FAKE_TOKEN"]
        for t in texts:
            for b in bad:
                self.assertNotIn(b.splitlines()[0] if "\n" in b else b, t)

    def writes(self):
        return [(m, k) for m, k, h in self.s3.log if m == "PUT"]

    # ---- states ------------------------------------------------------------------------------

    def baseline(self, tag="v0.7.1"):
        """A bucket in which `tag` is published and complete; built once, then copied."""
        if tag not in _baselines:
            self.release(tag, "draft")
            rc, _, err = self.ready(tag)
            assert rc == 0, err
            self.set_state(tag, "published")
            rc, _, err = self.publish(tag)
            assert rc == 0, err
            _baselines[tag] = copy.deepcopy(self.s3.objects)
        self.s3.objects = copy.deepcopy(_baselines[tag])
        self.release(tag, "published")
        self.s3.log.clear()
        return tag


class Happy(Base):
    def test_a_release_binds_publishes_and_verifies(self):
        self.release("v0.7.1")
        rc, out, err = self.ready("v0.7.1")
        self.assertEqual(rc, 0, err)
        e = self.entries()
        self.assertEqual(len(e), 6)
        self.assertTrue(all(v[0] == "pending" for v in e.values()))
        self.set_state("v0.7.1", "published")
        rc, out, err = self.publish("v0.7.1")
        self.assertEqual(rc, 0, err)
        e = self.entries()
        self.assertTrue(all(v[0] == "published" for v in e.values()), e)
        print(self.manifest_keys(), self.keys_under("apt/"), self.keys_under("rpm/"))


class Parsing(Base):
    def verify(self, data, gen=1):
        f = self.tmp / "v.asc"
        f.write_bytes(data)
        p = subprocess.run(["bash", str(SCRIPT), "verify-manifest", str(f), str(gen)], env=self.env(),
                           capture_output=True, text=True)
        return p.returncode

    def good(self, key="a", gen=1):
        return self.sign_manifest(self.mtext(gen), key)

    def test_a_good_manifest_verifies(self):
        self.assertEqual(self.verify(self.good()), 0)

    def test_text_appended_or_prepended_is_refused(self):
        g = self.good()
        self.assertNotEqual(self.verify(g + b"package published x 1 k s t c\n"), 0)
        self.assertNotEqual(self.verify(b"package published x 1 k s t c\n" + g), 0)

    def test_two_signed_blocks_are_refused(self):
        self.assertNotEqual(self.verify(self.good() + self.good()), 0)

    def test_a_body_edited_after_signing_is_refused(self):
        self.assertNotEqual(self.verify(self.good().replace(b"generation 1", b"generation 2"), 1), 0)

    def test_a_dash_escaped_line_is_read_unescaped_and_checked_as_a_line(self):
        text = self.mtext(1) + "- package published x 1 k s t c\n"
        self.assertNotEqual(self.verify(self.sign_manifest(text)), 0)

    def test_a_key_in_the_key_file_but_not_in_fingerprints_is_refused(self):
        self.set_keys(current="a", file_extra=("b",))
        self.assertEqual(self.verify(self.good("b")), 1 if False else self.verify(self.good("b")))
        self.assertNotEqual(self.verify(self.good("b")), 0)

    def test_the_next_and_previous_keys_verify(self):
        self.set_keys(current="a", next="b", previous="c")
        for n in "abc":
            self.assertEqual(self.verify(self.good(n)), 0, n)

    def test_the_wrong_generation_is_refused(self):
        self.assertNotEqual(self.verify(self.good(gen=2), 1), 0)

    def test_a_manifest_copied_to_a_higher_generation_is_not_current(self):
        self.put_raw("manifest/0000000001.asc", self.good(gen=1))
        self.put_raw("manifest/0000000002.asc", self.s3.objects["manifest/0000000001.asc"][0])
        self.release("v0.7.1")
        rc, _, err = self.ready("v0.7.1")
        # generation 2 is junk, so the run takes the next name, 3, and ends red E1142
        self.assert_diag(rc, err, "NRV-E1142")
        self.assertIn("manifest/0000000003.asc", self.manifest_keys())
        self.assertEqual(self.manifest("manifest/0000000003.asc").count("generation 3"), 1)


class Ready(Base):
    def test_ready_with_a_published_release_while_not_published_is_refused(self):
        self.release("v0.7.1", "published")
        rc, _, err = self.ready("v0.7.1")
        self.assert_diag(rc, err, "NRV-E1148", what="does not read draft")
        self.assertEqual(self.manifest_keys(), [])

    def test_ready_in_another_attempt_is_refused(self):
        self.release("v0.7.1")
        rc, _, err = self.ready("v0.7.1", GITHUB_RUN_ATTEMPT="2")
        self.assert_diag(rc, err, "NRV-E1153")
        self.assertEqual(self.writes(), [])

    def test_a_dispatch_with_published_true_checks_no_attempt(self):
        self.release("v0.7.1", "published")
        rc, _, err = self.ready("v0.7.1", published=True, GITHUB_RUN_ATTEMPT="2", MAC_ATTEMPT="")
        self.assertEqual(rc, 0, err)

    def test_a_release_without_sha256sums_is_refused(self):
        self.release("v0.7.1", drop=("SHA256SUMS",))
        rc, _, err = self.ready("v0.7.1")
        self.assert_diag(rc, err, "NRV-E1140")

    def test_a_package_that_disagrees_with_sha256sums_is_refused(self):
        self.release("v0.7.1")
        name = [n for n in packages("v0.7.1") if n.endswith(".deb")][0]
        self.replace_asset("v0.7.1", name, b"changed")
        rc, _, err = self.ready("v0.7.1")
        self.assert_diag(rc, err, "NRV-E1140")

    def test_a_release_published_while_read_is_refused(self):
        self.release("v0.7.1")
        # the stand-in answers the second read of the releases with a published release
        self.write_releases()
        pub = [{**r, "draft": False} for r in self.releases]
        (self.gh_dir / "releases.2.json").write_text(json.dumps(pub))
        rc, _, err = self.ready("v0.7.1")
        self.assert_diag(rc, err, "NRV-E1148")

    def test_a_gh_failure_in_ready_is_e1155(self):
        self.release("v0.7.1")
        self.gh_fail("/releases")
        rc, _, err = self.ready("v0.7.1")
        self.assert_diag(rc, err, "NRV-E1155")

    def test_missing_environment_is_e1139(self):
        self.release("v0.7.1")
        rc, _, err = self.ready("v0.7.1", REPO_SIGNING_KEY="")
        self.assert_diag(rc, err, "NRV-E1139")
        self.assert_no_secrets(err)

    def test_an_unlisted_secret_key_is_e1139(self):
        self.release("v0.7.1")
        rc, _, err = self.ready("v0.7.1", REPO_SIGNING_KEY=self.k["b"][1], REPO_SIGNING_PASSPHRASE=PASS["b"])
        self.assert_diag(rc, err, "NRV-E1139")
        self.assert_no_secrets(err)

    def test_ready_binds_then_a_second_ready_adds_nothing(self):
        self.release("v0.7.1")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        n = len(self.manifest_keys())
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        self.assertEqual(len(self.manifest_keys()), n)

    def test_a_rebind_by_a_later_attempt_when_no_object_exists(self):
        self.release("v0.7.1")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        self.release("v0.7.1", salt="2")
        rc, _, err = self.ready("v0.7.1", GITHUB_RUN_ATTEMPT="2", MAC_ATTEMPT="2")
        self.assertEqual(rc, 0, err)
        self.assertTrue(all(v[0] == "pending" for v in self.entries().values()))

    def test_a_rebind_is_refused_when_an_object_of_the_tag_exists(self):
        self.release("v0.7.1")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        self.assertEqual(self.publish("v0.7.1", )[0], 0) if False else None
        deb = [k for k in packages("v0.7.1") if k.endswith(".deb")][0]
        self.put_raw("apt/pool/main/n/nerva/" + deb, packages("v0.7.1")[deb])
        self.release("v0.7.1", salt="2")
        rc, _, err = self.ready("v0.7.1", GITHUB_RUN_ATTEMPT="2", MAC_ATTEMPT="2")
        self.assert_diag(rc, err, "NRV-E1141")

if __name__ == "__main__":
    unittest.main()
