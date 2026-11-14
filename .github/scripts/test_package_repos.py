#!/usr/bin/env python3
"""Tests for package_repos.sh (docs/releases/packages.md, slice 2; NRV-E1139 to NRV-E1156). Run from
the repository root: python3 -I .github/scripts/test_package_repos.py

They use the real gpg, gpgv, apt-ftparchive, createrepo_c, rpmbuild and rpmsign, throwaway keys, a
throwaway packaging/keys/ directory, a stand-in `gh` (a Python script that answers from files), and
r2.py against test_r2.py's fake S3 server, which also enforces the bucket locks. packages.nerva.pro is
a second local server that serves the fake bucket's objects."""
import copy
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
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


def sums_of(files):
    """The SHA256SUMS text over {name: bytes}, without SHA256SUMS itself."""
    return "".join(f"{hashlib.sha256(b).hexdigest()}  {n}\n"
                   for n, b in sorted(files.items()) if n != "SHA256SUMS").encode()


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
            f"printf '#!/bin/sh\\necho version {v}\\n# {rarch} {salt}\\n' > %{{buildroot}}/usr/bin/nerva\n"
            f"%files\n%attr(0755,root,root) /usr/bin/nerva\n")
        sh("rpmbuild", "-bb", "--target", "noarch", "--define", f"_topdir {top}", "--define",
           "debug_package %{nil}", "--define", "_build_id_links none", "--define",
           "_binary_payload w9.gzdio", str(spec))
        built = next((top / "RPMS").rglob("*.rpm"))
        name = f"nerva-{fv}-1.{rarch}.rpm"
        out[name] = built.read_bytes()
    # The other files SHA256SUMS lists (P417e): four tarballs, two .debug files, the bill of materials.
    for t in ("x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos"):
        out[f"nerva-{tag}-{t}.tar.gz"] = f"tarball {t} {salt}".encode()
    for t in ("x86_64-linux", "aarch64-linux"):
        out[f"nerva-{tag}-{t}.debug"] = f"debug {t} {salt}".encode()
    out[f"nerva-{tag}.cdx.json"] = f"{{\"salt\": \"{salt}\"}}".encode()
    out["SHA256SUMS"] = sums_of(out)
    _pkgs[(tag, salt)] = out
    return out


def fixtures_cleanup():
    if _scratch:
        shutil.rmtree(_scratch, ignore_errors=True)


def tearDownModule():
    fixtures_cleanup()


GH = """#!/usr/bin/env python3
import json, os, shutil, subprocess, sys
d = os.environ["GH_DIR"]
args = sys.argv[1:]
with open(d + "/log", "a") as f:
    f.write(" ".join(args) + "\\n")
if args[:2] == ["release", "upload"]:
    # gh release upload <tag> <file> --repo <r>: the file becomes an asset of the release, in every
    # fixture the stand-in reads.
    if "release/upload" in (open(d + "/fail").read().split() if os.path.exists(d + "/fail") else []):
        sys.stderr.write("gh: HTTP 502\\n")
        sys.exit(1)
    new = max([int(x) for x in os.listdir(d + "/assets")] + [0]) + 1
    shutil.copy(args[3], d + "/assets/" + str(new))
    for fx in os.listdir(d):
        if fx.startswith("releases.") and fx.endswith(".json"):
            rels = json.load(open(d + "/" + fx))
            for r in rels:
                if r["tag_name"] == args[2]:
                    r["assets"].append({"id": new, "name": os.path.basename(args[3])})
            json.dump(rels, open(d + "/" + fx, "w"))
    sys.exit(0)
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
             "GH_DIR": str(self.gh_dir), "GITHUB_OUTPUT": str(self.tmp / "output"),
             "PACKAGE_REPOS_SERVED_WAIT": "0:0", "REPO_SIGNING_KEY": self.k[self.secret][1],
             "REPO_SIGNING_PASSPHRASE": PASS[self.secret], "MAC_ATTEMPT": "1", "GITHUB_RUN_ATTEMPT": "1"}
        if self.next_secret:
            e["REPO_SIGNING_KEY_NEXT"] = self.k[self.next_secret][1]
            e["REPO_SIGNING_PASSPHRASE_NEXT"] = PASS[self.next_secret]
        e.update(self.s3.env)
        e.update(extra)
        return e

    def code(self):
        """The `code` output the last run wrote to $GITHUB_OUTPUT, or None."""
        f = self.tmp / "output"
        got = [l[5:] for l in f.read_text().splitlines() if l.startswith("code=")] if f.exists() else []
        self.assertLessEqual(len(got), 1)
        return got[0] if got else None

    def run_script(self, *args, **extra):
        (self.gh_dir / "count").unlink(missing_ok=True)
        (self.tmp / "output").unlink(missing_ok=True)
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


def bound_cache(self, tag):
    """The baseline bucket plus `tag` bound (ready) by an approved run, its release published."""
    self.baseline()
    key = ("bound", tag)
    self.release(tag, "draft")
    if key not in _baselines:
        rc, _, err = self.ready(tag)
        assert rc == 0, err
        _baselines[key] = copy.deepcopy(self.s3.objects)
    self.s3.objects = copy.deepcopy(_baselines[key])
    self.set_state(tag, "published")
    self.s3.log.clear()
    return tag


Base.bound = bound_cache


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
        self.assertNotEqual(self.verify(self.good("b")), 0)

    def test_a_manifest_is_signed_by_current_or_previous_and_never_by_next(self):
        self.set_keys(current="a", next="b", previous="c")
        self.assertEqual(self.verify(self.good("a")), 0)
        self.assertEqual(self.verify(self.good("c")), 0)
        self.assertNotEqual(self.verify(self.good("b")), 0, "a signature by next is refused on a manifest")

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

    def test_a_missing_tool_is_e1139(self):
        self.release("v0.7.1")
        bare = self.tmp / "nojq"
        bare.mkdir()
        for d in os.environ["PATH"].split(":"):
            for f in (os.scandir(d) if os.path.isdir(d) else ()):
                if f.name != "jq" and not (bare / f.name).exists():
                    os.symlink(f.path, bare / f.name)
        rc, _, err = self.ready("v0.7.1", PATH=f"{self.tmp}/bin:{bare}")
        self.assert_diag(rc, err, "NRV-E1139")
        self.assertIn("jq", err)

    def test_a_testing_override_on_a_runner_is_e1139(self):
        self.release("v0.7.1")
        for v in ("PACKAGE_KEYS_DIR", "R2_PY", "PACKAGE_REPOS_FREE_KIB", "PACKAGE_REPOS_SERVED_WAIT", "PACKAGE_REPOS_CLOCK",
                  "PACKAGE_REPOS_KILL_AT"):
            rc, _, err = self.ready("v0.7.1", GITHUB_ACTIONS="true", **{v: "1"})
            self.assert_diag(rc, err, "NRV-E1139")
            self.assertIn("is set on a runner", err)

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

    # ---- SHA256SUMS.asc (P417c) ---------------------------------------------------------------

    def asset_bytes(self, tag, name):
        for r in json.loads((self.gh_dir / "releases.json").read_text()):
            if r["tag_name"] == tag:
                for a in r["assets"]:
                    if a["name"] == name:
                        return (self.gh_dir / "assets" / str(a["id"])).read_bytes()
        return None

    def uploads(self):
        log = self.gh_dir / "log"
        return [l for l in log.read_text().splitlines() if l.startswith("release upload")] if log.exists() else []

    def test_ready_signs_sha256sums_and_uploads_the_signature_to_the_draft(self):
        self.release("v0.7.1")
        rc, _, err = self.ready("v0.7.1")
        self.assertEqual(rc, 0, err)
        asc = self.asset_bytes("v0.7.1", "SHA256SUMS.asc")
        self.assertIsNotNone(asc)
        self.assertTrue(asc.startswith(b"-----BEGIN PGP SIGNATURE-----"))
        self.assertEqual(len(self.uploads()), 1)
        # What a reader does: the pinned check, against the key file alone.
        (self.tmp / "s.asc").write_bytes(asc)
        (self.tmp / "s").write_bytes(self.asset_bytes("v0.7.1", "SHA256SUMS"))
        rc, _, err = self.run_script("verify-sig", "releasegpg", str(self.tmp / "s.asc"), str(self.tmp / "s"))
        self.assertEqual(rc, 0, err)
        self.assert_no_secrets(err)

    def test_a_second_ready_keeps_the_signature_and_uploads_nothing(self):
        self.release("v0.7.1")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        first = self.asset_bytes("v0.7.1", "SHA256SUMS.asc")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        self.assertEqual(len(self.uploads()), 1)
        self.assertEqual(self.asset_bytes("v0.7.1", "SHA256SUMS.asc"), first)

    def test_a_signature_of_other_sums_is_refused_and_not_replaced(self):
        self.release("v0.7.1")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        self.releases = json.loads((self.gh_dir / "releases.json").read_text())  # the stand-in added the .asc
        # the same lines in another order: every hash still matches, the signature does not
        self.sums_edit("v0.7.1", lambda ls: ls[::-1])
        rc, _, err = self.ready("v0.7.1")
        self.assert_diag(rc, err, "NRV-E1165")
        self.assertEqual(self.code(), "NRV-E1165")
        self.assertEqual(len(self.uploads()), 1)

    # ---- every file SHA256SUMS lists is hashed before it is signed (P417e) ---------------------

    def sums_edit(self, tag, fn):
        text = self.asset_bytes(tag, "SHA256SUMS").decode()
        self.replace_asset(tag, "SHA256SUMS", "".join(fn(text.splitlines(True))).encode())

    def refused_unsigned(self, what):
        rc, _, err = self.ready("v0.7.1")
        self.assert_diag(rc, err, "NRV-E1140", what)
        self.assertEqual(self.uploads(), [])
        self.assertIsNone(self.asset_bytes("v0.7.1", "SHA256SUMS.asc"))

    def test_a_zero_hash_for_a_debug_file_is_refused_and_nothing_is_signed(self):
        self.release("v0.7.1")
        self.sums_edit("v0.7.1", lambda ls: [("0" * 64 + l[64:]) if ".debug" in l else l for l in ls])
        self.refused_unsigned("no real hash")

    def test_a_wrong_hash_for_a_debug_file_is_refused_and_nothing_is_signed(self):
        self.release("v0.7.1")
        self.sums_edit("v0.7.1", lambda ls: [("1" * 64 + l[64:]) if ".debug" in l else l for l in ls])
        self.refused_unsigned("does not match SHA256SUMS")

    def test_a_missing_line_is_refused_and_nothing_is_signed(self):
        self.release("v0.7.1")
        self.sums_edit("v0.7.1", lambda ls: [l for l in ls if "aarch64-linux.debug" not in l])
        self.refused_unsigned("does not list exactly")

    def test_an_extra_line_is_refused_and_nothing_is_signed(self):
        self.release("v0.7.1")
        self.sums_edit("v0.7.1", lambda ls: ls + ["a" * 64 + "  stray-file\n"])
        self.refused_unsigned("does not list exactly")

    def test_a_line_with_extra_fields_is_refused_and_nothing_is_signed(self):
        self.release("v0.7.1")
        self.sums_edit("v0.7.1", lambda ls: [l.rstrip("\n") + " trailing-junk\n" if ".cdx.json" in l else l for l in ls])
        self.refused_unsigned("sha256sum -c would not read")

    def test_whitespace_after_the_name_is_refused_and_nothing_is_signed(self):
        for ws in ("\t", "\tjunk", " ", "\x0b", "\x0c"):
            with self.subTest(ws=ws):
                self.release("v0.7.1")
                self.sums_edit("v0.7.1", lambda ls: [l.rstrip("\n") + ws + "\n" if ".cdx.json" in l else l for l in ls])
                self.refused_unsigned("sha256sum -c would not read")

    def test_a_crlf_sha256sums_is_refused_with_a_message_naming_the_crlf(self):
        self.release("v0.7.1")
        self.sums_edit("v0.7.1", lambda ls: [l.rstrip("\n") + "\r\n" for l in ls])
        self.refused_unsigned("CRLF")

    def test_a_listed_file_missing_from_the_draft_is_refused_and_nothing_is_signed(self):
        self.release("v0.7.1", drop=("nerva-v0.7.1-x86_64-linux.debug",))
        self.refused_unsigned("has no nerva-v0.7.1-x86_64-linux.debug")

    def test_a_signature_by_a_key_that_is_not_the_pinned_one_is_refused_and_not_replaced(self):
        self.release("v0.7.1")
        sums = self.asset_bytes("v0.7.1", "SHA256SUMS")
        home = self.tmp / "other"
        home.mkdir(mode=0o700)
        env = {**os.environ, "GNUPGHOME": str(home)}
        subprocess.run(["gpg", "--batch", "--import"], input=self.k["c"][1], text=True, env=env,
                       capture_output=True, check=True)
        (self.tmp / "sums").write_bytes(sums)
        subprocess.run(["gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", PASS["c"],
                        "--digest-algo", "SHA512", "--armor", "--detach-sign", "-u", self.k["c"][0],
                        "-o", str(self.tmp / "sums.asc"), str(self.tmp / "sums")],
                       check=True, capture_output=True, env=env)
        self.release("v0.7.1", extra_assets=[("SHA256SUMS.asc", (self.tmp / "sums.asc").read_bytes())])
        rc, _, err = self.ready("v0.7.1")
        m = self.assert_diag(rc, err, "NRV-E1165", "does not verify")
        self.assertIn("delete that asset", m.group(3))
        self.assertEqual(self.uploads(), [])

    def legacy_release(self, tag):
        """The pre-P417 set: no .debug files, nine lines in SHA256SUMS."""
        debug = tuple(n for n in packages(tag) if n.endswith(".debug"))
        self.release(tag, drop=debug)
        self.sums_edit(tag, lambda ls: [l for l in ls if ".debug" not in l])

    def test_the_pre_p417_set_of_v0_7_1_is_accepted_unsigned_and_sums_verify_passes(self):
        self.legacy_release("v0.7.1")
        rc, _, err = self.ready("v0.7.1")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.uploads(), [])
        rc, _, err = self.run_script("sums-verify", "v0.7.1")
        self.assertEqual(rc, 0, err)

    def test_the_pre_p417_set_is_refused_for_a_later_version(self):
        self.legacy_release("v0.7.2")
        rc, _, err = self.ready("v0.7.2")
        self.assert_diag(rc, err, "NRV-E1140", "does not list exactly")
        self.assertEqual(self.uploads(), [])

    def test_the_pre_p417_set_is_refused_for_a_release_candidate_of_v0_7_1(self):
        for tag in ("v0.7.1-rc.9", "v0.7.0"):
            self.legacy_release(tag)
            rc, _, err = self.ready(tag)
            self.assert_diag(rc, err, "NRV-E1140", "does not list exactly")
            self.assertEqual(self.uploads(), [])

    def test_a_failed_upload_of_the_signature_is_e1155(self):
        self.release("v0.7.1")
        self.gh_fail("release/upload")
        rc, _, err = self.ready("v0.7.1")
        self.assert_diag(rc, err, "NRV-E1155")
        self.assertIn("SHA256SUMS.asc", err)

    def test_the_signing_key_not_being_the_pinned_one_signs_nothing(self):
        self.release("v0.7.1")
        rc, _, err = self.ready("v0.7.1", REPO_SIGNING_KEY=self.k["b"][1], REPO_SIGNING_PASSPHRASE=PASS["b"])
        self.assert_diag(rc, err, "NRV-E1139")
        self.assertEqual(self.uploads(), [])

    def test_sums_verify_needs_no_secret_and_passes_a_signed_release(self):
        self.release("v0.7.1")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        rc, _, err = self.run_script("sums-verify", "v0.7.1", REPO_SIGNING_KEY="", REPO_SIGNING_PASSPHRASE="")
        self.assertEqual(rc, 0, err)

    def test_sums_verify_refuses_an_unsigned_release_and_changed_sums(self):
        self.release("v0.7.1")
        rc, _, err = self.run_script("sums-verify", "v0.7.1")
        self.assert_diag(rc, err, "NRV-E1165", "has no SHA256SUMS.asc")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        self.releases = json.loads((self.gh_dir / "releases.json").read_text())
        self.replace_asset("v0.7.1", "SHA256SUMS", self.asset_bytes("v0.7.1", "SHA256SUMS") + b"x\n")
        rc, _, err = self.run_script("sums-verify", "v0.7.1")
        self.assert_diag(rc, err, "NRV-E1165", "does not verify")

    def test_a_rebind_by_a_later_attempt_when_no_object_exists(self):
        self.release("v0.7.1")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        self.release("v0.7.1", salt="2")
        rc, _, err = self.ready("v0.7.1", GITHUB_RUN_ATTEMPT="2", MAC_ATTEMPT="2")
        self.assertEqual(rc, 0, err)
        self.assertTrue(all(v[0] == "pending" for v in self.entries().values()))

    def test_a_changed_asset_is_refused_when_an_object_of_the_tag_exists_at_another_name(self):
        """The spec: the entries are replaced only when no object of the tag's old entries exists."""
        self.release("v0.7.1")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        old = packages("v0.7.1")
        rpms = [n for n in old if n.endswith(".rpm")]
        key = next(k for k in self.entries() if k.startswith("rpm/rc/") and k.endswith(rpms[0]))
        self.put_raw(key, old[rpms[0]])
        # only the debs change; the rpms are the bound ones, so the entries at their names agree
        self.release("v0.7.1", salt="2")
        new = packages("v0.7.1", "2")
        mixed = {n: (old[n] if n in rpms else new[n]) for n in new if n != "SHA256SUMS"}
        for n, b in mixed.items():
            self.replace_asset("v0.7.1", n, b)
        self.replace_asset("v0.7.1", "SHA256SUMS", sums_of(mixed))
        before = self.manifest()
        rc, _, err = self.ready("v0.7.1", GITHUB_RUN_ATTEMPT="2", MAC_ATTEMPT="2")
        self.assert_diag(rc, err, "NRV-E1141")
        self.assertEqual(self.manifest(), before)

    def test_ready_for_a_published_release_writes_nothing_not_even_a_lock_probe(self):
        self.baseline()
        self.s3.log.clear()
        rc, _, err = self.ready("v0.7.1", published=True)
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.writes(), [])

    def test_a_rebind_is_refused_when_an_object_of_the_tag_exists(self):
        self.release("v0.7.1")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        self.assertEqual(self.publish("v0.7.1", )[0], 0) if False else None
        deb = [k for k in packages("v0.7.1") if k.endswith(".deb")][0]
        self.put_raw("apt/pool/main/n/nerva/" + deb, packages("v0.7.1")[deb])
        self.release("v0.7.1", salt="2")
        rc, _, err = self.ready("v0.7.1", GITHUB_RUN_ATTEMPT="2", MAC_ATTEMPT="2")
        self.assert_diag(rc, err, "NRV-E1141")
HIDE = """import os, subprocess, sys
r = subprocess.run([sys.executable, "-I", os.environ["REAL_R2"], *sys.argv[1:]], capture_output=True, text=True)
out = r.stdout
if sys.argv[1:2] == ["list"] and sys.argv[2:3] == ["manifest/"]:
    hide = os.environ["HIDE_KEY"]
    out = "".join(l for l in out.splitlines(True) if not l.startswith(hide))
sys.stdout.write(out)
sys.stderr.write(r.stderr)
sys.exit(r.returncode)
"""


class Bucket(Base):
    def refresh_red(self, code="NRV-E1142"):
        rc, _, err = self.refresh()
        self.assert_diag(rc, err, code)
        return err

    def snapshot(self, prefix):
        return {k: v[0] for k, v in self.s3.objects.items() if k.startswith(prefix)}

    def test_a_refresh_of_a_clean_bucket_writes_a_new_generation_and_changes_no_package(self):
        self.baseline()
        before = self.keys_under("apt/pool/") + self.keys_under("rpm/stable/packages/")
        n = len(self.manifest_keys())
        rc, _, err = self.refresh()
        self.assertEqual(rc, 0, err)
        self.assertGreater(len(self.manifest_keys()), n)
        self.assertEqual(before, self.keys_under("apt/pool/") + self.keys_under("rpm/stable/packages/"))
        self.assertIn("state complete", self.manifest())
        self.assert_no_secrets(self.last.stdout, self.last.stderr)

    def tamper_and_heal(self, mutate, name):
        self.baseline()
        good = self.s3.objects[name][0] if name in self.s3.objects else None
        mutate(name)
        self.refresh_red()
        self.assertEqual(self.s3.objects[name][0] != b"", True)
        rc, _, err = self.refresh()
        self.assertEqual(rc, 0, err)
        return good

    def test_an_index_replaced_deleted_or_copied_across_channels_is_healed_then_e1142(self):
        name = "apt/dists/stable/InRelease"
        other = "apt/dists/rc/InRelease"
        for how in ("replace", "delete", "copy"):
            self.baseline()
            if how == "replace":
                self.put_raw(name, b"junk")
            elif how == "delete":
                del self.s3.objects[name]
            else:
                self.s3.objects[name] = self.s3.objects[other]
            self.refresh_red()
            self.assertNotEqual(self.s3.objects[name][0], b"junk")
            self.assertTrue(self.s3.objects[name][0].startswith(b"-----BEGIN PGP SIGNED MESSAGE"), how)
            self.assertEqual(self.refresh()[0], 0, how)

    def test_a_copied_index_of_another_channel_is_not_accepted_for_a_channel_that_read_it_before(self):
        self.baseline()
        self.s3.objects["apt/dists/stable/Release"] = self.s3.objects["apt/dists/rc/Release"]
        err = self.refresh_red()
        self.assertIn("apt/dists/stable/Release", err)

    def test_a_by_hash_or_hashed_repodata_file_with_wrong_content_is_replaced_and_noted(self):
        self.baseline()
        keys = [k for k in self.keys_under("apt/dists/stable/main/binary-amd64/by-hash/")]
        keys += [k for k in self.keys_under("rpm/stable/repodata/") if k.endswith("-primary.xml.gz")]
        self.assertGreaterEqual(len(keys), 2)
        want = {k: self.s3.objects[k][0] for k in keys}
        for k in keys:
            self.put_raw(k, b"wrong")
        rc, _, err = self.refresh()
        self.assertEqual(rc, 1, err)
        self.assertIn("::notice::noted", err)
        for k in keys:
            self.assertEqual(self.s3.objects[k][0], want[k], k)

    def test_a_lock_rule_that_is_gone_is_e1149(self):
        self.baseline()
        self.s3.locks = ()
        rc, _, err = self.refresh()
        self.assert_diag(rc, err, "NRV-E1149", fix="Add the bucket lock rule in Cloudflare, then run again")

    def test_a_lock_refusal_with_another_status_is_e1143(self):
        self.baseline()
        self.s3.faults = [403]
        rc, _, err = self.refresh()
        self.assertEqual(rc, 1, err)
        self.assertIn("NRV-E1143", err)

    def test_junk_under_each_locked_prefix_is_noted_skipped_and_the_run_ends_red(self):
        for prefix in ("apt/pool/main/n/nerva/", "rpm/stable/packages/", "rpm/rc/packages/"):
            self.baseline()
            self.put_raw(prefix + "stray.bin", b"x")
            n = len(self.manifest_keys())
            rc, _, err = self.refresh()
            self.assert_diag(rc, err, "NRV-E1142")
            self.assertIn("stray.bin", err)
            self.assertGreater(len(self.manifest_keys()), n, "the run finished: a complete manifest")
            self.assertIn("state complete", self.manifest())

    def test_junk_in_manifest_under_the_wanted_name_moves_the_run_to_the_next_name(self):
        self.baseline()
        top = int(self.manifest_keys()[-1][9:19])
        self.put_raw(f"manifest/{top + 1:010d}.asc", b"not a manifest")
        rc, _, err = self.refresh()
        self.assert_diag(rc, err, "NRV-E1142")
        self.assertIn(f"manifest/{top + 2:010d}.asc", self.manifest_keys())

    def test_a_verified_manifest_at_the_wanted_name_is_e1147_and_nothing_more_is_written(self):
        self.baseline()
        top = self.manifest_keys()[-1]
        wrapper = self.tmp / "hide_r2.py"
        wrapper.write_text(HIDE)
        before = dict(self.s3.objects)
        rc, _, err = self.refresh(R2_PY=str(wrapper), REAL_R2=str(SCRIPT.parent / "r2.py"), HIDE_KEY=top)
        self.assert_diag(rc, err, "NRV-E1147")
        self.assertEqual(before, self.s3.objects)

    def test_a_manifest_prefix_with_only_objects_that_do_not_verify_is_refused(self):
        self.put_raw("manifest/0000000001.asc", b"junk")
        self.release("v0.7.1")
        rc, _, err = self.ready("v0.7.1")
        self.assert_diag(rc, err, "NRV-E1142")
        rc, _, err = self.refresh()
        self.assert_diag(rc, err, "NRV-E1142")
        self.assertEqual(self.keys_under("apt/"), [])

    def test_a_candidate_under_stable_is_e1142(self):
        self.baseline()
        self.put_raw("rpm/stable/packages/nerva-0.7.2.rc.1-1.x86_64.rpm", b"x")
        rc, _, err = self.refresh()
        self.assert_diag(rc, err, "NRV-E1142", what="candidate")

    def test_the_two_thousand_entry_limit(self):
        ents = [("pending", sha(b"%d" % i), "1", f"apt/pool/main/n/nerva/nerva_9.9.{i}-1_amd64.deb",
                 sha(b"%d" % i), "v9.9.9", COMMIT) for i in range(2001)]
        ents.sort(key=lambda e: e[3])
        self.sign_manifest(self.mtext(1, "complete", pk=ents), "a", "manifest/0000000001.asc")
        rc, _, err = self.refresh()
        self.assert_diag(rc, err, "NRV-E1142", what="2001 entries")
        self.assertEqual(self.writes(), [])

    def test_too_little_disk_is_e1156(self):
        self.baseline()
        before = dict(self.s3.objects)
        rc, _, err = self.refresh(PACKAGE_REPOS_FREE_KIB="1")
        self.assert_diag(rc, err, "NRV-E1156")
        self.assertEqual(before, self.s3.objects)

    def test_a_refresh_with_nothing_bound(self):
        rc, _, err = self.refresh()
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.entries(), {})

    def test_a_publish_of_a_tag_nothing_bound_is_e1148(self):
        self.baseline()
        rc, _, err = self.publish("v0.9.9")
        self.assert_diag(rc, err, "NRV-E1148")

    def test_a_quiet_repository_is_e1150_after_45_days_but_the_run_still_publishes(self):
        self.baseline()
        self.commit_age(46)
        n = len(self.manifest_keys())
        rc, _, err = self.refresh()
        self.assert_diag(rc, err, "NRV-E1150")
        self.assertGreater(len(self.manifest_keys()), n)
        self.commit_age(44)
        self.assertEqual(self.refresh()[0], 0)

    def test_stable_holding_no_candidate_and_rc_holding_both(self):
        self.baseline("v0.7.1")
        self.release("v0.8.0-rc.1")
        self.assertEqual(self.ready("v0.8.0-rc.1")[0], 0)
        self.set_state("v0.8.0-rc.1", "published")
        rc, _, err = self.publish("v0.8.0-rc.1")
        self.assertEqual(rc, 0, err)
        self.assertEqual([k for k in self.keys_under("rpm/stable/packages/") if "rc." in k], [])
        self.assertTrue([k for k in self.keys_under("rpm/rc/packages/") if "0.8.0.rc.1" in k])
        stable = self.s3.objects["apt/dists/stable/main/binary-amd64/Packages"][0]
        self.assertNotIn(b"0.8.0~rc.1", stable)
        rc_ = self.s3.objects["apt/dists/rc/main/binary-amd64/Packages"][0]
        self.assertIn(b"0.8.0~rc.1", rc_)

    def sqv_accepts(self, inrelease, ring):
        """Debian 13's apt-sequoia checks the clearsigned text with sqv: split it as sqv wants it."""
        head, _, rest = inrelease.partition(b"\n\n")
        text, _, sig = rest.partition(b"\n-----BEGIN PGP SIGNATURE-----")
        lines = [(ln[2:] if ln.startswith(b"- ") else ln).rstrip(b" \t\r") for ln in text.split(b"\n")]
        (self.tmp / "text").write_bytes(b"\r\n".join(lines))
        (self.tmp / "text.sig").write_bytes(b"-----BEGIN PGP SIGNATURE-----" + sig)
        p = subprocess.run(["sqv", "--keyring", str(ring), str(self.tmp / "text.sig"), str(self.tmp / "text")],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_a_dual_signed_inrelease_verifies_with_either_key_alone(self):
        self.set_keys(current="a", next="b")
        self.release("v0.7.1")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        self.set_state("v0.7.1", "published")
        rc, _, err = self.publish("v0.7.1")
        self.assertEqual(rc, 0, err)
        data = self.s3.objects["apt/dists/stable/InRelease"][0]
        f = self.tmp / "InRelease"
        f.write_bytes(data)
        for n in "ab":
            ring = self.tmp / f"{n}.gpg"
            ring.write_bytes(subprocess.run(["gpg", "--dearmor"], input=self.k[n][2].encode(),
                                            capture_output=True, check=True).stdout)
            # as apt reads it: one VALIDSIG by a key it has, the other signature unknown to it
            p = subprocess.run(["gpgv", "--status-fd", "1", "--keyring", str(ring), str(f)],
                               capture_output=True, text=True)
            self.assertRegex(p.stdout, rf"VALIDSIG {self.k[n][0]} ")
            if shutil.which("sqv"):
                self.sqv_accepts(data, ring)
        self.assert_no_secrets(self.last.stdout, self.last.stderr)


KILL_POINTS = ("checked", "deb_put", "rpm_manifest", "rpm_put", "writing_manifest", "content_named",
               "index_put", "indexes_uploaded", "served")


class Publish(Base):
    def finish(self, tag):
        rc, _, err = self.publish(tag)
        self.assertEqual(rc, 0, err)
        e = self.entries()
        self.assertTrue(all(v[0] == "published" for v in e.values()), e)
        self.assertIn("state complete", self.manifest())
        for k in self.keys_under("apt/pool/") + self.keys_under("rpm/") :
            if k.endswith((".deb", ".rpm")):
                self.assertIn(k, [v[3] for v in e.values()], "an object no entry lists: " + k)

    def test_a_kill_after_each_step_then_a_second_run_finishes_the_job(self):
        for point in KILL_POINTS + ("deb_put:2", "rpm_put:2"):
            with self.subTest(point=point):
                self.bound("v0.7.2")
                rc, _, err = self.publish("v0.7.2", PACKAGE_REPOS_KILL_AT=point)
                self.assertEqual(rc, -9, f"{point}: {err}")
                self.assert_no_secrets(self.last.stdout, self.last.stderr)
                self.finish("v0.7.2")

    def test_a_kill_between_the_writing_manifest_and_the_upload_and_between_the_upload_and_complete(self):
        self.bound("v0.7.2")
        rc, _, err = self.publish("v0.7.2", PACKAGE_REPOS_KILL_AT="writing_manifest")
        self.assertEqual(rc, -9, err)
        self.assertIn("state writing", self.manifest())
        self.assertIn("index-was", self.manifest())
        rc, _, err = self.publish("v0.7.2", PACKAGE_REPOS_KILL_AT="served")
        self.assertEqual(rc, -9, err)
        self.assertIn("state writing", self.manifest())
        self.finish("v0.7.2")
        self.assertIn("state complete", self.manifest())

    def test_a_package_lines_only_generation_copies_state_index_and_index_was(self):
        self.bound("v0.7.2")
        before = self.manifest()
        rc, _, err = self.publish("v0.7.2", PACKAGE_REPOS_KILL_AT="rpm_manifest")
        self.assertEqual(rc, -9, err)
        after = self.manifest()
        keep = lambda t: [l for l in t.splitlines() if not l.startswith(("package ", "generation "))]
        self.assertEqual(keep(before), keep(after))
        self.assertNotEqual(before, after)
        self.finish("v0.7.2")

    def test_a_first_run_killed_before_its_first_manifest_then_a_run_from_generation_zero(self):
        self.release("v0.7.1")
        rc, _, err = self.ready("v0.7.1", PACKAGE_REPOS_KILL_AT="before_manifest")
        self.assertEqual(rc, -9, err)
        self.assertEqual(self.s3.objects, {})
        rc, _, err = self.ready("v0.7.1")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.manifest_keys(), ["manifest/0000000001.asc"])

    def test_a_ready_killed_after_its_manifest_is_finished_by_a_second_ready(self):
        self.release("v0.7.1")
        rc, _, err = self.ready("v0.7.1", PACKAGE_REPOS_KILL_AT="ready_manifest")
        self.assertEqual(rc, -9, err)
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        self.assertEqual(len(self.entries()), 6)

    def test_a_pending_entry_whose_release_is_draft_or_missing_is_skipped_with_a_notice(self):
        for how in ("draft", "404"):
            self.bound("v0.7.2")
            if how == "draft":
                self.set_state("v0.7.2", "draft")
            else:
                self.releases = [r for r in self.releases if r["tag_name"] != "v0.7.2"]
                self.write_releases()
            rc, _, err = self.publish("v0.7.2")
            self.assertIn("::notice::the release v0.7.2 reads", err, how)
            self.assertTrue(all(v[0] == "pending" for k, v in self.entries().items() if "0.7.2" in k))
            self.assertEqual(rc, 1, how)  # the tag asked for is still pending: E1148
            self.assertEqual(self.refresh()[0], 0, how)  # a scheduled refresh stays green

    def test_a_github_error_on_one_pending_entry_is_e1155_and_the_others_publish(self):
        self.baseline()
        for t in ("v0.7.2", "v0.7.3"):
            self.release(t)
            self.assertEqual(self.ready(t)[0], 0)
            self.set_state(t, "published")
        self.gh_fail("/releases#2")
        rc, _, err = self.refresh()
        self.assert_diag(rc, err, "NRV-E1155")
        e = self.entries()
        self.assertTrue(all(v[0] == "published" for k, v in e.items() if "0.7.2" in k), e)
        self.assertTrue(all(v[0] == "pending" for k, v in e.items() if "0.7.3" in k), e)
        self.gh_fail()
        self.assertEqual(self.refresh()[0], 0)
        self.assertTrue(all(v[0] == "published" for v in self.entries().values()))

    def test_junk_at_a_name_the_run_must_write_is_refused(self):
        self.bound("v0.7.2")
        deb = "apt/pool/main/n/nerva/nerva_0.7.2-1_amd64.deb"
        self.put_raw(deb, b"junk")
        rc, _, err = self.publish("v0.7.2")
        self.assert_diag(rc, err, "NRV-E1142")
        self.assertEqual(self.s3.objects[deb][0], b"junk")
        self.assertTrue(any(v[0] == "pending" and v[3] == deb for v in self.entries().values()))

    def test_lying_metadata_at_a_pending_deb_is_noted_and_the_indexes_are_still_re_signed(self):
        """An object is adopted on its bytes, not its x-amz-meta-sha256 (P368b)."""
        self.bound("v0.7.2")
        deb = "apt/pool/main/n/nerva/nerva_0.7.2-1_amd64.deb"
        sha_ = next(v[1] for v in self.entries().values() if v[3] == deb)
        self.s3.objects[deb] = (b"junk", {"x-amz-meta-sha256": sha_})
        for run in (lambda: self.publish("v0.7.2"), self.refresh):
            self.s3.log.clear()
            rc, _, err = run()
            self.assert_diag(rc, err, "NRV-E1142")
            self.assertNotIn("NRV-E1143", err)
            self.assertIn(deb, err)
            put = [k for _, k in self.writes()]
            for name in ("apt/dists/stable/InRelease", "apt/dists/rc/InRelease",
                         "rpm/stable/repodata/repomd.xml", "rpm/rc/repodata/repomd.xml"):
                self.assertIn(name, put)
            self.assertEqual(self.s3.objects[deb][0], b"junk")
            self.assertTrue(any(v[0] == "pending" and v[3] == deb for v in self.entries().values()))
            listed = self.s3.objects["apt/dists/stable/main/binary-amd64/Packages"][0].decode()
            self.assertNotIn("nerva_0.7.2-1_amd64.deb", listed)

    def test_the_release_file_names_the_repository_and_expires_after_21_days(self):
        self.bound("v0.7.2")
        self.finish("v0.7.2")
        for c, label in (("stable", "Nerva"), ("rc", "Nerva candidates")):
            text = self.s3.objects[f"apt/dists/{c}/InRelease"][0].decode()
            f = dict(l.split(": ", 1) for l in text.splitlines() if re.match(r"^[A-Za-z-]+: ", l))
            self.assertEqual((f["Origin"], f["Label"], f["Suite"], f["Codename"]),
                             ("Nerva", label, c, f"nerva-{c}"))
            fmt = "%a, %d %b %Y %H:%M:%S %z"
            date, until = (datetime.datetime.strptime(f[k], fmt) for k in ("Date", "Valid-Until"))
            self.assertEqual(until - date, datetime.timedelta(days=21))

    def test_a_package_the_release_no_longer_matches_is_e1148_and_nothing_is_published_from_it(self):
        self.bound("v0.7.2")
        name = [n for n in packages("v0.7.2") if n.endswith(".deb")][0]
        self.replace_asset("v0.7.2", name, b"swapped")
        rc, _, err = self.publish("v0.7.2")
        self.assert_diag(rc, err, "NRV-E1148")
        # the other deb matches its entry and is put (spec, "Put"); the swapped one never is
        self.assertNotIn(f"apt/pool/main/n/nerva/{name}", self.keys_under("apt/pool/"))
        self.assertTrue(all(v[0] == "pending" for k, v in self.entries().items() if k.endswith(name)))

    def test_a_signature_that_is_not_by_the_current_key_is_e1144(self):
        self.bound("v0.7.2")
        (self.tmp / "bin/rpmsign").write_text('#!/bin/sh\n[ "$1" = --version ] && echo "RPM version 4.18.2"\nexit 0\n')
        (self.tmp / "bin/rpmsign").chmod(0o755)
        rc, _, err = self.publish("v0.7.2")
        self.assert_diag(rc, err, "NRV-E1144")

    def test_a_signing_failure_is_e1144_and_carries_gpgs_last_line(self):
        self.bound("v0.7.2")
        real = shutil.which("gpg")
        (self.tmp / "bin/gpg").write_text(
            f'#!/bin/sh\ncase " $* " in *" --clearsign "*) echo "gpg: signing failed: Inappropriate ioctl for device" >&2; exit 2;; esac\nexec {real} "$@"\n')
        (self.tmp / "bin/gpg").chmod(0o755)
        rc, _, err = self.publish("v0.7.2")
        self.assert_diag(rc, err, "NRV-E1144", what="(gpg: gpg: signing failed: Inappropriate ioctl for device)")
        self.assert_no_secrets(self.last.stdout, self.last.stderr)

    def test_a_tool_of_another_version_is_e1139(self):
        self.bound("v0.7.2")
        for ver in ("RPM version 4.19.1", "RPM version 4.18.20", "RPM version 4.18.2.1"):
            (self.tmp / "bin/rpmsign").write_text(f'#!/bin/sh\n[ "$1" = --version ] && echo "{ver}"\nexit 0\n')
            (self.tmp / "bin/rpmsign").chmod(0o755)
            rc, _, err = self.publish("v0.7.2")
            self.assert_diag(rc, err, "NRV-E1139")
            self.assertIn("rpmsign", err)

    def test_lying_metadata_at_a_replaceable_index_name_is_noted_and_overwritten(self):
        """A replaceable name is overwritten, never trusted or refused (P368b)."""
        self.bound("v0.7.2")
        self.finish("v0.7.2")
        for name in ("apt/dists/stable/Release", "rpm/stable/repodata/repomd.xml"):
            self.s3.objects[name] = (b"junk", {"x-amz-meta-sha256": "0" * 64})
            self.s3.log.clear()
            rc, _, err = self.refresh()
            self.assert_diag(rc, err, "NRV-E1142")
            self.assertNotIn("NRV-E1143", err)
            self.assertIn(name, err)
            self.assertIn("apt/dists/stable/InRelease", [k for _, k in self.writes()])
            self.assertNotEqual(self.s3.objects[name][0], b"junk")

    def test_a_site_that_serves_other_bytes_is_e1145(self):
        self.bound("v0.7.2")
        self.web.override["apt/dists/stable/InRelease"] = b"not what the bucket holds"
        rc, _, err = self.publish("v0.7.2")
        self.assert_diag(rc, err, "NRV-E1145")
        rc, _, err = self.run_script("served")
        self.assert_diag(rc, err, "NRV-E1145")
        self.web.override.clear()
        self.assertEqual(self.run_script("served")[0], 0)

    def test_a_tag_that_is_not_a_version_is_e1139(self):
        rc, _, err = self.ready("main")
        self.assert_diag(rc, err, "NRV-E1139")

    def test_no_credential_reaches_a_message_or_a_command_line(self):
        self.release("v0.7.1")
        self.assertEqual(self.ready("v0.7.1")[0], 0)
        self.assert_no_secrets(self.last.stdout, self.last.stderr, (self.gh_dir / "log").read_text())
        self.set_state("v0.7.1", "published")
        rc, _, err = self.publish("v0.7.1", PACKAGE_REPOS_TRACE="1")
        self.assertEqual(rc, 0, err)
        self.assert_no_secrets(self.last.stdout, self.last.stderr, (self.gh_dir / "log").read_text())
        self.assertNotIn("+ ", err, "no set -x output")

    def test_a_complete_manifest_may_carry_index_was_lines(self):
        text = self.mtext(1, "complete", iw=[(sha(b"x"), "apt/dists/stable/InRelease")])
        data = self.sign_manifest(text)
        f = self.tmp / "v.asc"
        f.write_bytes(data)
        p = subprocess.run(["bash", str(SCRIPT), "verify-manifest", str(f), "1"], env=self.env())
        self.assertEqual(p.returncode, 0)  # a package-lines-only generation copies them (spec, "The manifest")


class Roles(Base):
    """Which role may sign which file (docs/releases/packages.md, "The signature check"), through
    `verify-sig`: a current, b next, c previous."""

    def setUp(self):
        super().setUp()
        self.set_keys(current="a", next="b", previous="c")
        self.data = self.tmp / "data.txt"
        self.data.write_text("Date: now\n")

    def sign(self, key, detach):
        home = self.tmp / "sg"
        home.mkdir(mode=0o700, exist_ok=True)
        env = {**os.environ, "GNUPGHOME": str(home)}
        subprocess.run(["gpg", "--batch", "--import"], input=self.k[key][1], text=True, env=env,
                       capture_output=True, check=True)
        out = self.tmp / ("sig.asc" if detach else "clear.asc")
        out.unlink(missing_ok=True)
        subprocess.run(["gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", PASS[key],
                        "--digest-algo", "SHA512", "--detach-sign" if detach else "--clearsign", "--armor",
                        "-u", self.k[key][0], "-o", str(out), str(self.data)],
                       check=True, capture_output=True, env=env)
        return out

    def check(self, kind, sig, data=None):
        args = ["bash", str(SCRIPT), "verify-sig", kind, str(sig)] + ([str(data)] if data else [])
        p = subprocess.run(args, env=self.env(), capture_output=True, text=True)
        return p.returncode

    def test_inrelease_may_be_signed_by_current_or_next_and_not_previous(self):
        self.assertEqual(self.check("inrelease", self.sign("a", False)), 0)
        self.assertEqual(self.check("inrelease", self.sign("b", False)), 0)
        self.assertEqual(self.check("inrelease", self.sign("c", False)), 1, "previous may not sign InRelease")

    def test_release_gpg_may_be_signed_by_current_or_next_and_not_previous(self):
        self.assertEqual(self.check("releasegpg", self.sign("a", True), self.data), 0)
        self.assertEqual(self.check("releasegpg", self.sign("b", True), self.data), 0)
        self.assertEqual(self.check("releasegpg", self.sign("c", True), self.data), 1)

    def test_repomd_asc_is_signed_by_current_only(self):
        self.assertEqual(self.check("repomd", self.sign("a", True), self.data), 0)
        self.assertEqual(self.check("repomd", self.sign("b", True), self.data), 1, "next may not sign repomd.xml.asc")
        self.assertEqual(self.check("repomd", self.sign("c", True), self.data), 1, "previous may not either")

    def test_a_manifest_kind_refuses_next_through_the_same_door(self):
        self.assertEqual(self.check("manifest", self.sign("c", False)), 0)
        self.assertEqual(self.check("manifest", self.sign("b", False)), 1)

    def test_the_class_must_match_the_kind_of_file(self):
        self.assertEqual(self.check("releasegpg", self.sign("a", False)), 1, "a clearsigned file is not a detached signature")
        self.assertEqual(self.check("inrelease", self.sign("a", True), self.data), 1, "a detached signature is not clearsigned")

    def test_a_signer_without_a_listed_key_is_refused(self):
        self.set_keys(current="a")
        self.assertEqual(self.check("inrelease", self.sign("b", False)), 1)


def kid(fpr):
    return fpr[-16:].lower()


class Slice2b(Base):
    """Slice 2b: the pinned rpm and index checks, excluding the rpms of one key, `fresh`, the `code`
    output and the served fetch-back (docs/releases/packages.md, steps 4, 5 and 5b)."""

    OWNER = {"PACKAGE_REPOS_OWNER": "topwombat", "TRIGGERING_ACTOR": "topwombat"}

    def shim(self, name, body):
        (self.tmp / "bin" / name).write_text("#!/bin/sh\n" + body)
        (self.tmp / "bin" / name).chmod(0o755)

    def real(self, tool):
        return shutil.which(tool, path=os.environ["PATH"])

    def new_puts(self, before):
        """Keys put by the last run that the bucket did not hold before. (Every run re-puts the current
        manifest and one listed object per prefix over themselves: the lock probe.)"""
        return sorted({k for m, k in self.writes() if k not in before})

    def rotate_away(self):
        """A published by key a; then b current with a previous (a refresh signs under b); then `previous`
        is dropped, so a's rpms no longer verify."""
        self.baseline()
        self.set_keys(current="b", previous="a", secret="b")
        rc, _, err = self.refresh()
        self.assertEqual(rc, 0, err)
        self.set_keys(current="b", secret="b")

    # ---- step 4 and 5b: rpm and index checks --------------------------------------------------

    def test_a_badly_signed_rpm_is_never_recorded_or_put(self):
        self.bound("v0.7.2")
        before = copy.deepcopy(self.s3.objects)
        real = self.real("rpmkeys")
        self.shim("rpmkeys", f'case "$*" in *-K*nerva-0.7.2*) echo "$3: digests SIGNATURES NOT OK"; exit 1;; esac\nexec {real} "$@"\n')
        rc, _, err = self.publish("v0.7.2")
        self.assert_diag(rc, err, "NRV-E1161")
        self.assertEqual(self.code(), "NRV-E1161")
        self.assertFalse([k for k in self.s3.objects if k not in before and k.startswith("rpm/")])
        self.assertEqual({k: v for k, v in self.s3.objects.items() if k.startswith("manifest/")},
                         {k: v for k, v in before.items() if k.startswith("manifest/")})

    def test_an_rpm_of_an_unlisted_key_stops_a_refresh_with_nothing_written(self):
        self.rotate_away()
        self.s3.log.clear()
        before = set(self.s3.objects)
        rc, _, err = self.refresh()
        m = self.assert_diag(rc, err, "NRV-E1161")
        self.assertIn(kid(self.k["a"][0]), m.group(1) + m.group(2))
        self.assertEqual(self.new_puts(before), [])
        self.assertEqual(self.code(), "NRV-E1161")

    def test_a_changed_rpmkeys_output_stops_the_run(self):
        self.baseline()
        real = self.real("rpmkeys")
        self.shim("rpmkeys", f'case "$*" in *-K*) echo "$3: something else entirely"; exit 0;; esac\nexec {real} "$@"\n')
        before = set(self.s3.objects)
        rc, _, err = self.refresh()
        self.assert_diag(rc, err, "NRV-E1161")
        self.assertEqual(self.new_puts(before), [])

    def test_an_index_signed_by_a_key_the_pin_does_not_list_uploads_nothing(self):
        self.baseline()
        self.set_keys(current="a", secret="b")  # the secret is b's; the pinned file lists a
        self.s3.log.clear()
        rc, _, err = self.refresh()
        self.assertEqual(rc, 1, err)
        self.assertRegex(err, r"error\[NRV-E11(61|39|44)\]")
        self.assertEqual([k for m, k in self.writes() if k.startswith(("apt/", "rpm/"))], [])

    # ---- exclude and restore -----------------------------------------------------------------

    def test_exclude_indexes_without_the_rpms_of_that_key_and_the_next_run_keeps_them_out(self):
        self.rotate_away()
        ka = kid(self.k["a"][0])
        rc, _, err = self.refresh(RPM_KEY=f"exclude {ka}", **self.OWNER)
        self.assertEqual(rc, 0, err)
        e = self.entries()
        self.assertTrue(all(v[0] == "excluded" for k, v in e.items() if k.startswith("rpm/")), e)
        self.assertTrue(all(v[0] == "published" for k, v in e.items() if k.startswith("apt/")), e)
        for ch in ("stable", "rc"):
            for k in self.keys_under(f"rpm/{ch}/"):
                self.assertNotIn(".rpm", k.split("repodata")[0][len(f"rpm/{ch}/"):] if "repodata" in k else "")
        rc, _, err = self.refresh()
        self.assertEqual(rc, 0, err)
        self.assertTrue(all(v[0] == "excluded" for k, v in self.entries().items() if k.startswith("rpm/")))

    def test_restore_undoes_a_mistaken_exclusion(self):
        self.rotate_away()
        ka = kid(self.k["a"][0])
        self.assertEqual(self.refresh(RPM_KEY=f"exclude {ka}", **self.OWNER)[0], 0)
        self.set_keys(current="b", previous="a", secret="b")
        rc, _, err = self.refresh(RPM_KEY=f"restore {ka.upper()}", **self.OWNER)
        self.assertEqual(rc, 0, err)
        self.assertTrue(all(v[0] == "published" for v in self.entries().values()))

    def test_rpm_key_refusals_are_e1139_and_write_nothing(self):
        self.rotate_away()
        ka, kb = kid(self.k["a"][0]), kid(self.k["b"][0])
        cases = [
            (f"exclude {ka}", {"TRIGGERING_ACTOR": "someone", "PACKAGE_REPOS_OWNER": "topwombat"}),
            (f"exclude {ka}", {"TRIGGERING_ACTOR": "someone"}),
            (f"exclude {kb}", self.OWNER),
            ("exclude 0123456789abcdef", self.OWNER),
            (f"restore {ka}", self.OWNER),
            (f"restore {kb}", self.OWNER),
            (f"drop {ka}", self.OWNER),
            ("exclude abc", self.OWNER),
        ]
        for rpm_key, who in cases:
            self.s3.log.clear()
            before = set(self.s3.objects)
            rc, _, err = self.refresh(RPM_KEY=rpm_key, **who)
            self.assert_diag(rc, err, "NRV-E1139")
            self.assertEqual(self.new_puts(before), [], rpm_key)
            self.assertEqual(self.code(), "NRV-E1139")

    def test_restoring_a_revoked_key_is_refused(self):
        self.rotate_away()
        ka = kid(self.k["a"][0])
        self.assertEqual(self.refresh(RPM_KEY=f"exclude {ka}", **self.OWNER)[0], 0)
        env = {**os.environ, "GNUPGHOME": str(self.tmp / "rv")}
        (self.tmp / "rv").mkdir(mode=0o700)
        rev = (scratch() / "gk/openpgp-revocs.d" / (self.k["a"][0] + ".rev")).read_text().replace(
            ":-----BEGIN", "-----BEGIN")
        subprocess.run(["gpg", "--batch", "--import"], input=self.k["a"][2] + rev, text=True, env=env,
                       capture_output=True)
        pub = subprocess.run(["gpg", "--armor", "--export", self.k["a"][0]], env=env, capture_output=True,
                             text=True).stdout
        self.assertIn("BEGIN PGP PUBLIC KEY BLOCK", pub)
        self.set_keys(current="b", previous="a", secret="b")
        (self.keys_dir / "nerva-release.asc").write_text(self.k["b"][2] + pub)
        rc, _, err = self.refresh(RPM_KEY=f"restore {ka}", **self.OWNER)
        self.assert_diag(rc, err, "NRV-E1139")

    def test_restoring_a_key_that_is_neither_current_nor_previous_is_refused_before_any_write(self):
        self.rotate_away()
        ka = kid(self.k["a"][0])
        self.assertEqual(self.refresh(RPM_KEY=f"exclude {ka}", **self.OWNER)[0], 0)
        # a is in no role now (rotate_away dropped previous): a restore could never be published
        self.s3.log.clear()
        before = set(self.s3.objects)
        gens = self.manifest_keys()
        rc, _, err = self.refresh(RPM_KEY=f"restore {ka}", **self.OWNER)
        self.assert_diag(rc, err, "NRV-E1139")
        self.assertIn("neither current's nor previous's", err)
        self.assertEqual(self.new_puts(before), [])
        self.assertEqual(self.manifest_keys(), gens)
        self.assertTrue(all(v[0] == "excluded" for k, v in self.entries().items() if k.startswith("rpm/")))

    def test_a_secret_that_is_not_the_pinned_current_key_is_refused(self):
        self.baseline()
        self.set_keys(current="a", secret="c")
        self.s3.log.clear()
        before = set(self.s3.objects)
        rc, _, err = self.refresh()
        self.assertEqual(rc, 1, err)
        self.assertRegex(err, r"error\[NRV-E11\d\d\]")
        self.assertEqual(self.new_puts(before), [])

    # ---- served fetch-back, fresh, outputs ---------------------------------------------------

    def test_a_served_object_that_differs_is_e1145_and_the_retry_can_succeed(self):
        self.bound("v0.7.2")
        self.web.override["apt/dists/stable/InRelease"] = b"stale"
        rc, _, err = self.publish("v0.7.2")
        self.assert_diag(rc, err, "NRV-E1145")
        self.assertEqual(self.code(), "NRV-E1145")
        self.web.override.clear()
        rc, _, err = self.run_script("served")
        self.assertEqual(rc, 0, err)
        # a difference that heals inside the wait is accepted
        threading.Timer(1.5, self.web.override.clear).start()
        self.web.override["apt/dists/stable/InRelease"] = b"stale"
        rc, _, err = self.run_script("served", PACKAGE_REPOS_SERVED_WAIT="1:20")
        self.assertEqual(rc, 0, err)

    def test_a_stalled_edge_ends_in_e1145_inside_the_deadline_not_in_a_timeout(self):
        self.baseline()
        log = self.tmp / "curl.log"
        clock = self.tmp / "clock"
        clock.write_text("1000")
        self.shim("clock", f'n=$(cat {clock}); echo $((n + 40)) >{clock}; echo $n\n')
        # a curl that stalls to its --max-time: it records the cap and takes that long on the fake clock
        self.shim("curl", f'while [ $# -gt 0 ]; do [ "$1" = --max-time ] && m=$2; shift; done\n'
                          f'echo $m >>{log}; n=$(cat {clock}); echo $((n + m)) >{clock}; exit 28\n')
        t0 = time.time()
        rc, _, err = self.run_script("served", PACKAGE_REPOS_SERVED_WAIT="1:120",
                                     PACKAGE_REPOS_CLOCK=str(self.tmp / "bin/clock"))
        self.assert_diag(rc, err, "NRV-E1145")
        self.assertEqual(self.code(), "NRV-E1145")
        self.assertLess(time.time() - t0, 60, "the bound is the clock, not the attempts")
        caps = [int(x) for x in log.read_text().split()]
        self.assertTrue(caps and all(1 <= c <= 60 for c in caps), caps)
        self.assertLessEqual(len(caps), 4, caps)  # 120 s of fake clock at 40+ s a call

    def test_fresh_refuses_an_index_without_valid_until(self):
        self.baseline()
        old = self.s3.objects["apt/dists/stable/InRelease"][0].decode()
        body = old.split("-----BEGIN PGP SIGNATURE-----")[0].split("\n\n", 1)[1].rstrip("\n").replace("\n- ", "\n")
        body = "".join(l + "\n" for l in body.splitlines() if not l.startswith("Valid-Until:"))
        self.web.override["apt/dists/stable/InRelease"] = self.sign_manifest(body, "a")
        rc, _, err = self.run_script("fresh")
        self.assert_diag(rc, err, "NRV-E1150")
        self.assertIn("no readable Valid-Until", err)

    def test_fresh_refuses_an_index_signed_only_by_previous(self):
        self.baseline()
        self.set_keys(current="a", previous="c")
        old = self.s3.objects["apt/dists/stable/InRelease"][0].decode()
        body = old.split("-----BEGIN PGP SIGNATURE-----")[0].split("\n\n", 1)[1].rstrip("\n").replace("\n- ", "\n") + "\n"
        self.web.override["apt/dists/stable/InRelease"] = self.sign_manifest(body, "c")
        rc, _, err = self.run_script("fresh")
        self.assert_diag(rc, err, "NRV-E1150")
        self.web.override["apt/dists/stable/InRelease"] = self.sign_manifest(body, "a")
        self.assertEqual(self.run_script("fresh")[0], 0)

    def test_a_release_without_a_date_is_refused_not_read_as_midnight(self):
        self.bound("v0.7.2")
        real = self.real("apt-ftparchive")
        self.shim("apt-ftparchive", f'{real} "$@" | case " $* " in *" release "*) grep -v "^Date:";; *) cat;; esac\n')
        rc, _, err = self.publish("v0.7.2")
        self.assert_diag(rc, err, "NRV-E1156")
        self.assertIn("dated ''", err)

    def test_a_refusal_inside_step_5b_leaves_no_verify_home_behind(self):
        self.bound("v0.7.2")
        real = self.real("gpgv")
        self.shim("gpgv", f'case "$GNUPGHOME" in *verify) exit 1;; esac\nexec {real} "$@"\n')
        (self.tmp / "tmp").mkdir(exist_ok=True)
        p = subprocess.run(["bash", str(SCRIPT), "publish", "v0.7.2"], env=self.env(), capture_output=True, text=True)
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertRegex(p.stderr, r"error\[NRV-E1161\]")
        subprocess.run(["bash", str(SCRIPT), "cleanup"], env=self.env(), capture_output=True)
        self.assertEqual(sorted(x.name for x in (self.tmp / "tmp").iterdir()), [])

    def test_the_owner_gate_reads_the_runners_triggering_actor_first(self):
        self.rotate_away()
        ka = kid(self.k["a"][0])
        before = set(self.s3.objects)
        # the workflow's variable says owner, the runner's own says someone else: refused
        rc, _, err = self.refresh(RPM_KEY=f"exclude {ka}", PACKAGE_REPOS_OWNER="topwombat",
                                  TRIGGERING_ACTOR="topwombat", GITHUB_TRIGGERING_ACTOR="someone")
        self.assert_diag(rc, err, "NRV-E1139")
        self.assertEqual(self.new_puts(before), [])
        # logins are case-insensitive
        rc, _, err = self.refresh(RPM_KEY=f"exclude {ka}", PACKAGE_REPOS_OWNER="TopWombat",
                                  GITHUB_TRIGGERING_ACTOR="topwombat")
        self.assertEqual(rc, 0, err)

    def test_fresh_passes_on_a_fresh_stable_and_writes_nothing(self):
        self.baseline()
        self.s3.log.clear()
        rc, _, err = self.run_script("fresh")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.writes(), [])
        self.assertIsNone(self.code())

    def test_fresh_refuses_an_index_with_less_than_ten_days_left(self):
        self.baseline()
        real = self.real("apt-ftparchive")
        # re-sign a Release that is valid for 5 more days, as the old one is
        exp = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=5)).strftime(
            "%a, %d %b %Y %H:%M:%S UTC")
        old = self.s3.objects["apt/dists/stable/InRelease"][0].decode()
        body = re.sub(r"Valid-Until: .*", "Valid-Until: " + exp, old.split("-----BEGIN PGP SIGNATURE-----")[0]
                      .split("\n\n", 1)[1].rstrip("\n").replace("\n- ", "\n")) + "\n"
        self.web.override["apt/dists/stable/InRelease"] = self.sign_manifest(body, "a").replace(b"", b"")
        rc, _, err = self.run_script("fresh")
        self.assertEqual(rc, 1, err)
        self.assertRegex(err, r"error\[NRV-E1150\]")
        self.assertEqual(self.code(), "NRV-E1150")
        self.assertIsNotNone(real)

    def test_fresh_refuses_an_unserved_stable(self):
        self.baseline()
        self.web.override["apt/dists/stable/InRelease"] = b"garbage"
        rc, _, err = self.run_script("fresh")
        self.assert_diag(rc, err, "NRV-E1150")

    def test_a_deferred_run_writes_its_code_output(self):
        self.baseline()
        self.commit_age(50)
        rc, _, err = self.refresh()
        self.assertEqual(rc, 1, err)
        self.assertEqual(self.code(), "NRV-E1150")

    def test_r2_bucket_empty_is_e1139(self):
        self.baseline()
        rc, _, err = self.refresh(R2_BUCKET="")
        self.assert_diag(rc, err, "NRV-E1139")
        self.assertEqual(self.code(), "NRV-E1139")

    def test_source_date_epoch_is_refused(self):
        self.baseline()
        rc, _, err = self.refresh(SOURCE_DATE_EPOCH="1700000000")
        self.assert_diag(rc, err, "NRV-E1139")

    def test_a_clock_of_apt_ftparchives_own_is_e1156(self):
        self.baseline()
        real = self.real("apt-ftparchive")
        self.shim("apt-ftparchive", f'{real} "$@" | sed "s/^Date: .*/Date: Mon, 01 Jan 2001 00:00:00 UTC/"\n')
        rc, _, err = self.refresh()
        self.assert_diag(rc, err, "NRV-E1156")
        self.assertEqual(self.code(), "NRV-E1156")


if __name__ == "__main__":
    unittest.main()
