#!/usr/bin/env python3
"""The key-model test (docs/releases/packages.md, slice K, P376 point 1): can a certify-only
primary with signing subkeys sign the apt and dnf repositories, and can a subkey rotate, without a
single extra command on any host?

Usage: subkeys.py --host | --image IMAGE [--expiry-seconds N]

Every key here is made in this run, in a throwaway home, and thrown away with it. Nothing is read
from the environment and nothing is committed. The run:

  1. makes a certify-only RSA 4096 primary, no expiry, and signing subkeys S1 (the first CI
     subkey), S2 (its successor), S4 (revoked later) and S3 (expires seconds after it is made),
     with setup step 4A's own commands for the first two (`--host` also runs all of 4A, the
     `--passwd` and the `sec#` listing included, and prints its output). The CI signer is a home
     that holds only the subkeys, under a passphrase of its own: the primary is a stub (`sec#`);
  2. signs small repositories with it (`InRelease`, `Release.gpg`, `repomd.xml.asc`, one rpm each);
  3. serves them over local HTTP and installs from them, in `--image IMAGE` (a container with
     `--network host`, apt on Debian and Ubuntu, dnf on Rocky and Fedora) or, with `--host`, with
     the runner's own rpm 4.18 and gpgv/sqv.

The cells (printed `CELL <group>/<name> PASS|FAIL|INFO`; the run exits 1 if any FAIL is not one of FINDINGS, below):

  install     a fresh host installs from a repository signed by S1, with the key file {P, S1}
  rotation    a host that has {P, S1} meets InRelease signed by S1 and S2 (before and after it has
              the new key file), then signed by S2 alone (before: NO_PUBKEY, expected; after the
              INSTALL.md `curl` line alone: must work); on dnf `dnf upgrade nerva` across the swap
              with the key file now {P, S1, S2} and nothing else done (a cell that needs `rpm -e
              gpg-pubkey` or a second import is a FAIL: the diagnosis after it is INFO)
  expiry      an rpm signed by S3 before it expired still installs after (a FAIL means subkeys
              without expiry); apt's answer on an InRelease of an expired subkey is INFO
  revocation  a key file that carries S4's revocation: apt and dnf refuse what S4 signed
  primary     the certify-only primary cannot sign, and every signature names a subkey, never
              the primary (the P376 check of package_repos.sh reads exactly that field)

The result of a pull request's run is the decision: docs/decisions/P376*.md.
"""
import argparse
import functools
import http.server
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SECONDS_S3 = 150  # S3's life: long enough to sign with it, short enough to wait out
PRIMARY_PW = "primary-passphrase-throwaway"
CI_PW = "ci-passphrase-throwaway"
APT_IMAGES = ["debian:12", "debian:13", "ubuntu:22.04", "ubuntu:24.04"]
DNF_IMAGES = ["rockylinux:9", "fedora:43", "fedora:44"]
CELLS = []  # (name, verdict, text)


def record(name, verdict, text=""):
    assert verdict in ("PASS", "FAIL", "INFO")
    CELLS.append((name, verdict, text))
    print(f"CELL {name} {verdict} {text}".rstrip(), flush=True)


def sh(cmd, env=None, input=None, cwd=None, check=True):
    r = subprocess.run(cmd, env=env, input=input, cwd=cwd, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    if check and r.returncode != 0:
        sys.exit(f"error: {' '.join(map(str, cmd[:4]))} ... exited {r.returncode}\n{r.stdout[-2000:]}")
    return r


def tail(text, n=12):
    return "\n".join("  | " + line for line in text.strip().splitlines()[-n:])


# A pinentry for tests: it answers each GETPIN with the next line of $PINENTRY_QUEUE, then with the
# line of $PINENTRY_QUEUE.default (a file, because gpg-agent keeps the environment it started in). The ceremony's commands then run exactly as the owner types them, and the
# passphrase change of `--passwd` (old, then new) really happens, which loopback cannot do.
PINENTRY = r"""#!/bin/bash
q=${PINENTRY_QUEUE:-/dev/null}
echo "OK Pleased to meet you"
while IFS= read -r line; do
  case $line in
    GETPIN)
      pass=$(head -n1 "$q" 2>/dev/null || true)
      if [ -n "$pass" ]; then sed -i 1d "$q"; else pass=$(head -n1 "$q.default"); fi
      printf 'D %s\nOK\n' "$pass" ;;
    GETINFO\ pid*) echo "D $$"; echo OK ;;
    BYE*) echo "OK closing connection"; exit 0 ;;
    *) echo OK ;;
  esac
done
"""


class Keys:
    """A throwaway keyring of the primary (offline in real life) and the CI signer's home."""

    def __init__(self, w):
        self.w = w
        self.pin = w / "pinentry.sh"
        self.pin.write_text(PINENTRY)
        self.pin.chmod(0o755)
        self.queue = w / "pin-queue"
        self.queue.write_text("")
        self.homes = []

    def home(self):
        h = Path(tempfile.mkdtemp(prefix="k", dir="/tmp"))
        h.chmod(0o700)
        (h / "gpg-agent.conf").write_text(
            f"pinentry-program {self.pin}\ndefault-cache-ttl 0\nmax-cache-ttl 0\n")
        self.homes.append(h)
        return h

    def env(self, home):
        e = dict(os.environ)
        e.update(GNUPGHOME=str(home), PINENTRY_QUEUE=str(self.queue), GPG_TTY="/dev/null")
        return e

    def gpg(self, home, *args, default=PRIMARY_PW, queue=None, input=None, check=True):
        self.queue.write_text("".join(f"{x}\n" for x in (queue or [])))
        Path(f"{self.queue}.default").write_text(default + "\n")
        return sh(["gpg", "--batch", "--yes", *args], env=self.env(home), input=input,
                  check=check)

    def subkeys(self, home, fpr, secret=False):
        """[(fingerprint, expiry epoch or 0)] of the subkeys, oldest first."""
        out = self.gpg(home, "--with-colons", "--list-secret-keys" if secret else "--list-keys",
                       fpr).stdout
        subs, pending = [], None
        for line in out.splitlines():
            f = line.split(":")
            if f[0] in ("sub", "ssb"):
                pending = int(f[6] or 0)
            elif f[0] == "fpr" and pending is not None:
                subs.append((f[9], pending))
                pending = None
        return subs

    def close(self):
        for h in self.homes:
            subprocess.run(["gpgconf", "--homedir", str(h), "--kill", "all"], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(h, ignore_errors=True)


def make_keys(k, www, seconds_s3):
    """The primary, S1, S2, S4, S3; the CI home; the key files (public) the hosts fetch."""
    keys = www / "keys"
    keys.mkdir(parents=True)
    ph = k.home()
    k.gpg(ph, "--cert-digest-algo", "SHA512", "--quick-generate-key",
          "Nerva release signing key (test) <nerva-test@example.invalid>", "rsa4096", "cert", "never")
    fpr = k.gpg(ph, "--with-colons", "--list-secret-keys").stdout
    fpr = next(ln.split(":")[9] for ln in fpr.splitlines() if ln.startswith("fpr"))

    def add(expire):
        k.gpg(ph, "--cert-digest-algo", "SHA512", "--quick-add-key", fpr, "rsa4096", "sign", expire)
        return k.subkeys(ph, fpr)[-1][0]

    def export(name, home=ph):
        (keys / name).write_text(k.gpg(home, "--armor", "--export", fpr).stdout)

    s1 = add("1y")
    export("keyA.asc")  # {P, S1}: what a host installed first
    s2 = add("1y")
    export("keyAB.asc")  # {P, S1, S2}: the key file after a rotation's step 2
    s3 = add(f"seconds={seconds_s3}")
    expires = k.subkeys(ph, fpr)[-1][1]
    # keyExp is {P, S1, S2, S3} once S3 has expired, and has no revoked subkey: it is exported from a
    # copy made before S4 exists. keyRev is the key file after S4's revocation.
    ph2 = k.home()
    shutil.rmtree(ph2)
    shutil.copytree(ph, ph2, symlinks=True, ignore=shutil.ignore_patterns("S.*", "*.lock"))
    ph2.chmod(0o700)
    s4 = add("1y")
    # The CI signer: a copy under its own passphrase, then only the subkeys with a stub primary
    # (setup step 4A, exactly).
    ch0 = k.home()
    shutil.rmtree(ch0)
    shutil.copytree(ph, ch0, symlinks=True, ignore=shutil.ignore_patterns("S.*", "*.lock"))
    ch0.chmod(0o700)
    k.gpg(ch0, "--passwd", fpr, queue=[PRIMARY_PW, CI_PW, CI_PW])
    exp = k.gpg(ch0, "--armor", "--export-secret-subkeys", *[s + "!" for s in (s1, s2, s4, s3)],
                default=CI_PW).stdout
    ci = k.home()
    k.gpg(ci, "--import", input=exp, default=CI_PW)
    listing = k.gpg(ci, "--list-secret-keys", fpr).stdout
    assert re.search(r"^sec#", listing, re.M), "the CI home holds the primary's secret part"
    # Revoke S4 (the primary is needed: it signs the revocation), then wait S3 out.
    k.gpg(ph, "--command-fd", "0", "--edit-key", fpr, input="key 4\nrevkey\ny\n0\n\ny\nsave\n")
    return dict(fpr=fpr, s1=s1, s2=s2, s3=s3, s4=s4, ph=ph, ph2=ph2, ci=ci, expires=expires,
                export=export)


def sign_args(subs):
    a = []
    for s in subs:
        a += ["-u", s + "!"]
    return a


class Signer:
    def __init__(self, k, ci, www):
        self.k, self.ci, self.www = k, ci, www
        (ci / "passphrase").write_text(CI_PW + "\n")

    def gpg(self, subs, *args):
        self.k.gpg(self.ci, "--pinentry-mode", "loopback", "--passphrase-file",
                   str(self.ci / "passphrase"), "--digest-algo", "SHA512", *sign_args(subs), *args,
                   default=CI_PW)

    def rpm(self, subs, path):
        assert len(subs) == 1
        ex = f"--pinentry-mode loopback --passphrase-file {self.ci}/passphrase"
        sh(["rpmsign", "--addsign", "--define", f"_gpg_name {subs[0]}!", "--define",
            f"_gpg_path {self.ci}", "--define", f"_gpg_sign_cmd_extra_args {ex}", "--define",
            "_gpg_digest_algo sha512", str(path)], env=self.k.env(self.ci))


def build_deb(w, version):
    out = w / f"nervak_{version}-1_all.deb"
    if out.exists():
        return out
    d = w / f"deb-{version}"
    (d / "DEBIAN").mkdir(parents=True)
    (d / "usr/share/nervak").mkdir(parents=True)
    (d / "usr/share/nervak/version").write_text(version + "\n")
    (d / "DEBIAN/control").write_text(
        f"Package: nervak\nVersion: {version}-1\nArchitecture: all\nMaintainer: Test <t@example.invalid>\n"
        "Section: utils\nPriority: optional\nDescription: key-model test package\n")
    sh(["dpkg-deb", "--build", "--root-owner-group", str(d), str(out)])
    return out


def build_rpm(w, version):
    top = w / f"rpm-{version}"
    if top.exists():
        return next((top / "RPMS").rglob("*.rpm"))
    (top / "SPECS").mkdir(parents=True)
    (top / "SPECS/nervak.spec").write_text(
        f"Name: nervak\nVersion: {version}\nRelease: 1\nSummary: key-model test package\n"
        "License: Apache-2.0\nBuildArch: noarch\n%description\nkey-model test package\n"
        f"%install\nmkdir -p %{{buildroot}}/usr/share/nervak\necho {version} > %{{buildroot}}/usr/share/nervak/version\n"
        "%files\n/usr/share/nervak/version\n")
    sh(["rpmbuild", "-bb", "--define", f"_topdir {top}", str(top / "SPECS/nervak.spec")])
    return next((top / "RPMS").rglob("*.rpm"))


def make_apt(w, www, signer, name, version, subs):
    root = www / "apt" / name
    pool = root / "pool/main/n/nervak"
    pool.mkdir(parents=True)
    shutil.copy(build_deb(w, version), pool)
    for arch in ("amd64", "arm64"):
        d = root / f"dists/stable/main/binary-{arch}"
        d.mkdir(parents=True)
        (d / "Packages").write_text(sh(["apt-ftparchive", "packages", "pool"], cwd=root).stdout)
    opts = [f"-oAPT::FTPArchive::Release::{k}={v}" for k, v in
            dict(Origin="NervaKeyTest", Suite="stable", Codename="stable", Architectures="amd64 arm64",
                 Components="main").items()]
    rel = sh(["apt-ftparchive", *opts, "release", "dists/stable"], cwd=root).stdout
    (root / "dists/stable/Release").write_text(rel)
    rd = root / "dists/stable"
    signer.gpg(subs, "--clearsign", "-o", str(rd / "InRelease"), str(rd / "Release"))
    signer.gpg(subs, "--detach-sign", "--armor", "-o", str(rd / "Release.gpg"), str(rd / "Release"))
    twin = www / "apt" / f"{name}-gpg"  # the same tree without InRelease: apt reads Release.gpg
    shutil.copytree(root, twin)
    (twin / "dists/stable/InRelease").unlink()


def make_rpm_repo(w, www, signer, name, version, rpm_subs, repomd_subs):
    root = www / "rpm" / name
    root.mkdir(parents=True)
    f = root / f"nervak-{version}-1.noarch.rpm"
    shutil.copy(build_rpm(w, version), f)
    signer.rpm(rpm_subs, f)
    sh(["createrepo_c", "--no-database", "--quiet", str(root)])
    md = root / "repodata/repomd.xml"
    signer.gpg(repomd_subs, "--detach-sign", "--armor", "-o", str(root / "repodata/repomd.xml.asc"), str(md))
    return f


def build_all(w, www, keys, signer):
    s1, s2, s3, s4 = (keys[x] for x in ("s1", "s2", "s3", "s4"))
    for name, version, subs in [("s1", "1.0", [s1]), ("dual", "2.0", [s1, s2]), ("s2", "2.0", [s2]),
                                ("s3", "3.0", [s3]), ("s4", "4.0", [s4])]:
        make_apt(w, www, signer, name, version, subs)
    make_rpm_repo(w, www, signer, "s1", "1.0", [s1], [s1])
    make_rpm_repo(w, www, signer, "s2", "2.0", [s2], [s2])
    make_rpm_repo(w, www, signer, "s3", "3.0", [s3], [s1])  # the rpm signed by S3, expired later
    make_rpm_repo(w, www, signer, "s4", "4.0", [s4], [s1])  # the rpm signed by S4, revoked later
    make_rpm_repo(w, www, signer, "s4m", "5.0", [s1], [s4])  # the repomd signed by S4


def serve(www):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(www))
    handler.log_message = lambda *a, **kw: None
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def wait_for(ts, what):
    left = ts - time.time() + 3
    if left > 0:
        print(f"waiting {int(left)} s for {what}", flush=True)
        time.sleep(left)


# ---- the host cells: rpm 4.18 and gpgv/sqv on the runner ------------------------------------------

def rpmkeys(db, *args):
    return sh(["rpmkeys", "--dbpath", str(db), *args], check=False)


def host_cells(w, www, keys):
    kd = www / "keys"
    rp = lambda n: next((www / "rpm" / n).glob("*.rpm"))
    ver = sh(["rpm", "--version"]).stdout.strip()
    print(ver, flush=True)

    def verdict(r):
        return r.returncode == 0 and "OK" in r.stdout and "NOT OK" not in r.stdout

    def db():
        d = Path(tempfile.mkdtemp(prefix="rpmdb", dir=w))
        return d

    d = db()
    r = rpmkeys(d, "--import", str(kd / "keyA.asc"))
    record("install/rpm4.18-import-keyA", "PASS" if r.returncode == 0 else "FAIL", r.stdout.strip()[-200:])
    r = rpmkeys(d, "-K", str(rp("s1")))
    record("install/rpm4.18-verify-S1", "PASS" if verdict(r) else "FAIL", r.stdout.strip())
    r = rpmkeys(d, "-K", str(rp("s2")))
    record("rotation/rpm4.18-S2-before-keyAB", "PASS" if not verdict(r) else "FAIL",
           "refused, as expected: " + r.stdout.strip() if not verdict(r) else "accepted S2 without its key")
    r = rpmkeys(d, "--import", str(kd / "keyAB.asc"))
    imp = r.returncode
    r = rpmkeys(d, "-K", str(rp("s2")))
    n = sh(["rpm", "--dbpath", str(d), "-qa", "gpg-pubkey*"], check=False).stdout.split()
    record("rotation/rpm4.18-S2-after-keyAB-import", "PASS" if imp == 0 and verdict(r) else "FAIL",
           f"import rc={imp}; {r.stdout.strip()}; gpg-pubkey entries: {len(n)}")
    if not (imp == 0 and verdict(r)):
        # diagnosis only: the extra command the spec's criterion forbids
        for key in sh(["rpm", "--dbpath", str(d), "-qa", "gpg-pubkey*"], check=False).stdout.split():
            sh(["rpm", "--dbpath", str(d), "-e", key], check=False)
        rpmkeys(d, "--import", str(kd / "keyAB.asc"))
        r = rpmkeys(d, "-K", str(rp("s2")))
        record("rotation/rpm4.18-diagnosis-after-rpm-e-and-import", "INFO",
               ("works after `rpm -e gpg-pubkey-<id>` and a second import" if verdict(r) else
                "does not work even after `rpm -e` and a second import"))
    d = db()
    rpmkeys(d, "--import", str(kd / "keyExp.asc"))
    r = rpmkeys(d, "-K", str(rp("s3")))
    record("expiry/rpm4.18-S3-expired-after-signing", "PASS" if verdict(r) else "FAIL", r.stdout.strip())
    d = db()
    imp = rpmkeys(d, "--import", str(kd / "keyRev.asc"))
    r = rpmkeys(d, "-K", str(rp("s1")))
    record("revocation/rpm4.18-key-file-with-a-revocation-still-verifies-S1",
           "PASS" if imp.returncode == 0 and verdict(r) else "FAIL",
           f"import rc={imp.returncode} {imp.stdout.strip()[-100:]}; {r.stdout.strip()}")
    r = rpmkeys(d, "-K", str(rp("s4")))
    record("revocation/rpm4.18-S4-revoked", "PASS" if not verdict(r) else "FAIL",
           ("refused: " if not verdict(r) else "ACCEPTED a revoked subkey: ") + r.stdout.strip())

    gpgv_cells(w, www, keys)


def gpgv_cells(w, www, keys):
    """What the apt verifiers do with a dual-signed Release: gpgv (Debian 12, Ubuntu) and sqv."""
    kd = www / "keys"

    def ring(name):
        out = w / f"{name}.gpg"
        sh(["gpg", "--batch", "--yes", "--dearmor", "-o", str(out), str(kd / f"{name}.asc")],
           env=dict(os.environ, GNUPGHOME=str(Path(tempfile.mkdtemp(dir=w)))))
        return out

    ringA, ringAB = ring("keyA"), ring("keyAB")
    rel = lambda t: (www / "apt" / t / "dists/stable")
    for tool in ("gpgv", "sqv"):
        if not shutil.which(tool):
            record(f"rotation/{tool}-dual-S1-only", "INFO", f"{tool} is not installed here")
            continue

        def check(tree, rg, expect_ok):
            r = rel(tree)
            # apt reads gpgv's status lines (one VALIDSIG is enough, a signature whose key it lacks is
            # ignored), not its exit status, which is 2 when any signature could not be checked.
            cmd = [tool, "--keyring", str(rg), str(r / "Release.gpg"), str(r / "Release")]
            if tool == "gpgv":
                cmd.insert(1, "--status-fd=1")
            out = sh(cmd, env=dict(os.environ, GNUPGHOME=str(Path(tempfile.mkdtemp(dir=w)))), check=False)
            good = ("VALIDSIG" in out.stdout) if tool == "gpgv" else out.returncode == 0
            return good, " ".join(ln for ln in out.stdout.splitlines() if "SIG" in ln or "key" in ln)[-160:]

        ok, txt = check("dual", ringA, True)
        record(f"rotation/{tool}-dual-with-only-S1-key", "PASS" if ok else "FAIL", txt)
        ok, txt = check("dual", ringAB, True)
        record(f"rotation/{tool}-dual-with-both-keys", "PASS" if ok else "FAIL", txt)
        ok, txt = check("s2", ringA, False)
        record(f"rotation/{tool}-S2-alone-with-old-key-file", "PASS" if not ok else "FAIL",
               "refused, as expected" if not ok else "accepted")
        ok, txt = check("s2", ringAB, True)
        record(f"rotation/{tool}-S2-alone-with-new-key-file", "PASS" if ok else "FAIL", txt)


def primary_cells(k, keys, signer, www):
    """P376: the primary signs nothing, and a signature names a subkey (VALIDSIG field 3 differs
    from field 12, the primary's fingerprint, which the pinned check reads)."""
    fpr = keys["fpr"]
    r = k.gpg(keys["ph"], "--clearsign", "-u", fpr + "!", "-o", "/dev/null", str(www / "keys/keyA.asc"),
              check=False)
    record("primary/certify-only-primary-cannot-sign", "PASS" if r.returncode != 0 else "FAIL",
           r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "")
    ring = k.home()
    k.gpg(ring, "--import", str(www / "keys/keyA.asc"))
    rel = www / "apt/s1/dists/stable"
    r = sh(["gpg", "--batch", "--status-fd", "1", "--verify", str(rel / "Release.gpg"), str(rel / "Release")],
           env=k.env(ring), check=False)
    v = next((ln.split() for ln in r.stdout.splitlines() if "VALIDSIG" in ln), [])
    good = len(v) > 11 and v[2] == keys["s1"] and v[11] == fpr and v[2] != v[11]
    record("primary/signature-names-the-subkey-not-the-primary", "PASS" if good else "FAIL",
           f"signer {v[2] if len(v) > 2 else '?'} primary {v[11] if len(v) > 11 else '?'}")


# ---- setup step 4A, as the owner runs it ----------------------------------------------------------

CEREMONY = r'''
set -eu
# test: the drives are directories, HOME is a scratch home, and there is no tty
export HOME="$W/home"; mkdir -p "$HOME" "$W/NERVA-KEY-1" "$W/NERVA-KEY-2"
export GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
export GPG_TTY="$(tty || true)"
# test: gpg-agent asks this program (it types the passphrases a person would)
printf 'pinentry-program %s\ndefault-cache-ttl 0\nmax-cache-ttl 0\n' "$PIN" > "$GNUPGHOME/gpg-agent.conf"
export PINENTRY_QUEUE="$W/q"; : > "$PINENTRY_QUEUE"; echo PRIMARY > "$PINENTRY_QUEUE.default"
gpg --batch --cert-digest-algo SHA512 --quick-generate-key 'Nerva release signing key <nerva@nerva.pro>' rsa4096 cert never
fpr="$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
gpg --batch --cert-digest-algo SHA512 --quick-add-key "$fpr" rsa4096 sign 1y
sub="$(gpg --with-colons --list-secret-keys "$fpr" | awk -F: '$1 == "ssb" { s = 1 } s && $1 == "fpr" { print $10; exit }')"
echo "$fpr" && echo "$sub"
gpg --armor --export "$fpr" > "$HOME/nerva-release.asc"
gpg --armor --export-secret-keys "$fpr" > "$W/NERVA-KEY-1/nerva-release-primary.asc"
cp "$GNUPGHOME/openpgp-revocs.d/$fpr.rev" "$W/NERVA-KEY-1/nerva-release.rev"
export CIHOME="$(mktemp -d)"
chmod 700 "$CIHOME"
cp -R "$GNUPGHOME"/. "$CIHOME"/
# test: the two passphrases the person types at --passwd (the old one, then the CI one twice)
printf 'PRIMARY\nCIPASS\nCIPASS\n' > "$PINENTRY_QUEUE"
gpg --homedir "$CIHOME" --passwd "$fpr"
echo CIPASS > "$PINENTRY_QUEUE.default"
gpg --homedir "$CIHOME" --armor --export-secret-subkeys "$sub$(printf '\041')" > "$HOME/nerva-ci-subkey.asc"
export CICHECK="$(mktemp -d)"
chmod 700 "$CICHECK"
printf 'pinentry-program %s\ndefault-cache-ttl 0\nmax-cache-ttl 0\n' "$PIN" > "$CICHECK/gpg-agent.conf"
gpg --homedir "$CICHECK" --import "$HOME/nerva-ci-subkey.asc"
gpg --homedir "$CICHECK" --list-secret-keys
# test: what the text says must hold: it unlocks with the CI passphrase, and not with the primary's
echo probe > "$W/probe"
gpg --homedir "$CICHECK" --clearsign -u "$sub$(printf '\041')" -o "$W/probe.ok" "$W/probe"
echo PRIMARY > "$PINENTRY_QUEUE.default"
if gpg --homedir "$CICHECK" --clearsign -u "$sub$(printf '\041')" -o "$W/probe.bad" "$W/probe" 2>/dev/null; then echo "FAIL: the primary's passphrase unlocks the CI export"; exit 3; fi
gpg --show-keys "$W/NERVA-KEY-1/nerva-release-primary.asc" | sed -n 1,3p
gpgconf --kill all && gpgconf --homedir "$CIHOME" --kill all && gpgconf --homedir "$CICHECK" --kill all && rm -rf "$GNUPGHOME" "$CIHOME" "$CICHECK" && unset GNUPGHOME CIHOME CICHECK
test ! -e "$W/probe.bad"
echo "CEREMONY-OK"
'''


def ceremony(w):
    pin = w / "ceremony-pinentry.sh"
    pin.write_text(PINENTRY)
    pin.chmod(0o755)
    cw = Path(tempfile.mkdtemp(prefix="cer", dir="/tmp"))
    r = sh(["bash", "-c", CEREMONY], env=dict(os.environ, W=str(cw), PIN=str(pin)), check=False)
    shutil.rmtree(cw, ignore_errors=True)
    out = r.stdout
    print("---- setup step 4A, run in a throwaway ----", flush=True)
    print("\n".join(ln for ln in out.splitlines() if "revocation certificate" not in ln), flush=True)
    print("---- end of step 4A ----", flush=True)
    ok = (r.returncode == 0 and "CEREMONY-OK" in out and len(re.findall(r"^ssb", out, re.M)) == 1
          and re.search(r"^sec#", out, re.M))
    record("ceremony/step-4A-exact-commands", "PASS" if ok else "FAIL",
           "passwd changed the passphrase; CICHECK lists sec# and one ssb; the export unlocks with the "
           "CI passphrase only" if ok else f"exit {r.returncode}")


# ---- the cells in a container ---------------------------------------------------------------------

CELL_SH = r'''#!/bin/bash
# cell.sh <apt|dnf> <group> <base-url>: one container, as root. Prints CELL lines; `-- ` lines are logs.
mgr=$1 group=$2 base=${3%/}
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
log=/tmp/cell.log
say() { printf 'CELL %s %s %s\n' "$1" "$2" "$3"; }
# cell NAME ok|refuse|info CMD...: ok must succeed, refuse must fail, info reports either
cell() {
  local name=$1 want=$2; shift 2
  if "$@" > "$log" 2>&1; then got=ok; else got=fail; fi
  case $want:$got in
    ok:ok) say "$name" PASS "" ;;
    refuse:fail) say "$name" PASS "refused, as expected: $(tail -n 2 "$log" | tr '\n' ' ' | cut -c1-200)" ;;
    info:*) say "$name" INFO "$got: $(tail -n 3 "$log" | tr '\n' ' ' | cut -c1-240)" ;;
    *) say "$name" FAIL "wanted $want, got $got"; sed 's/^/-- /' "$log" | tail -n 25 ;;
  esac
}
setup_failed() { say "$group/setup" FAIL "$1"; sed 's/^/-- /' "$log" | tail -n 15; exit 0; }

# ---- apt --------------------------------------------------------------------------------------
apt_n() { apt-get -o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts=/etc/apt/nerva.d "$@"; }
apt_keyfile() { curl -fsS "$base/keys/$1" | tee /etc/apt/keyrings/nerva.asc > /dev/null; }   # INSTALL.md's curl line
apt_tree() {
  cat > /etc/apt/nerva.d/nerva.sources <<EOF
Types: deb
URIs: $base/apt/$1
Suites: stable
Components: main
Architectures: amd64 arm64
Signed-By: /etc/apt/keyrings/nerva.asc
EOF
}
# apt update must say nothing about Nerva's index but a hit or a get
apt_update_clean() {
  apt_n update > "$log.u" 2>&1; local rc=$?; cat "$log.u"
  [ $rc -eq 0 ] || return 1
  ! grep -Eq '^(W|E|Err):|NO_PUBKEY|not signed|BADSIG|EXPKEYSIG|REVKEYSIG|is not valid|invalid' "$log.u"
}
apt_has() { apt-cache -o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts=/etc/apt/nerva.d policy nervak | grep -q "Candidate: $1"; }
apt_group() {
  apt-get update > "$log" 2>&1 || setup_failed "apt-get update"
  apt-get install -y curl ca-certificates gnupg > "$log" 2>&1 || setup_failed "installing curl, ca-certificates and gnupg"
  install -d -m 0755 /etc/apt/keyrings /etc/apt/nerva.d
  apt-get --version | head -n1
  if command -v sqv >/dev/null; then echo "verifier: sqv $(sqv --version | head -n1)"; else echo "verifier: gpgv $(gpgv --version | head -n1)"; fi
  # rotation
  apt_keyfile keyA.asc; apt_tree s1
  cell rotation/apt-install-from-S1 ok bash -c 'apt_update_clean && apt_n install -y nervak=1.0-1 && dpkg -s nervak | grep -q "Version: 1.0-1"'
  apt_tree s1-gpg
  cell rotation/apt-Release.gpg-S1 ok apt_update_clean
  apt_tree dual
  cell rotation/apt-dual-signed-with-the-old-key-file ok bash -c 'apt_update_clean && apt_has 2.0-1'
  apt_tree dual-gpg
  cell rotation/apt-dual-signed-Release.gpg-with-the-old-key-file ok apt_update_clean
  apt_keyfile keyAB.asc; apt_tree dual
  cell rotation/apt-dual-signed-with-the-new-key-file ok apt_update_clean
  apt_keyfile keyA.asc; apt_tree s2
  cell rotation/apt-S2-alone-with-the-old-key-file refuse apt_update_clean
  apt_keyfile keyAB.asc
  cell rotation/apt-S2-alone-after-the-curl-line-alone ok bash -c 'apt_update_clean && apt_n install -y --only-upgrade nervak && dpkg -s nervak | grep -q "Version: 2.0-1"'
  apt_tree s2-gpg
  cell rotation/apt-S2-alone-Release.gpg-after-the-curl-line ok apt_update_clean
  # expiry and revocation: the final key file, with S3 expired and S4's revocation
  apt_keyfile keyExp.asc; apt_tree s1
  cell expiry/apt-S1-with-an-expired-subkey-in-the-key-file ok apt_update_clean
  apt_tree s3
  cell expiry/apt-InRelease-of-an-expired-subkey info apt_update_clean
  apt_keyfile keyRev.asc; apt_tree s1
  cell revocation/apt-S1-with-a-revoked-subkey-in-the-key-file ok apt_update_clean
  apt_tree s4
  cell revocation/apt-InRelease-of-a-revoked-subkey refuse apt_update_clean
}

# ---- dnf --------------------------------------------------------------------------------------
dnf_keyfile() { curl -fsS "$base/keys/$1" -o /k/key.asc; }
dnf_repo() {
  cat > /etc/yum.repos.d/nerva.repo <<EOF
[nerva]
name=Nerva (key-model test)
baseurl=$base/rpm/$1
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///k/key.asc
EOF
  dnf clean all > /dev/null 2>&1
}
installed() { [ "$(rpm -q --qf '%{VERSION}' nervak)" = "$1" ]; }
dnf_prepare() {
  mkdir -p /k
  command -v curl > /dev/null || dnf install -y curl > "$log" 2>&1 || setup_failed "installing curl"
  echo "dnf: $(rpm -q dnf5 2>/dev/null || rpm -q dnf) with $(rpm --version)"
  # dnf5 before 5.2.18.0-4 hangs on importing a repository key (RHBZ 2458182)
  if rpm -q dnf5 > /dev/null 2>&1; then dnf upgrade -y dnf5 'libdnf5*' > "$log" 2>&1 || true; fi
}
dnf_keys() { rpm -qa 'gpg-pubkey*' --qf '%{NAME}-%{VERSION}-%{RELEASE}  %{SUMMARY}\n'; }
dnf_group() {
  dnf_prepare
  case $group in
  rotation)
    dnf_keyfile keyA.asc; dnf_repo s1
    cell rotation/dnf-install-from-S1 ok bash -c 'dnf install -y nervak-1.0-1 && installed 1.0'
    say rotation/dnf-keys-after-install INFO "$(dnf_keys | tr '\n' ';')"
    dnf_repo s2
    cell rotation/dnf-upgrade-with-the-new-key-file ok bash -c 'dnf upgrade -y nervak && installed 2.0'
    say rotation/dnf-keys-after-upgrade INFO "$(dnf_keys | tr '\n' ';')"
    if ! installed 2.0; then
      # diagnosis only: what would it take?
      rpm --import /k/key.asc > "$log" 2>&1; say rotation/diagnosis-rpm-import INFO "rc=$? $(tail -n 2 "$log" | tr '\n' ' ')"
      cell rotation/diagnosis-upgrade-after-rpm-import info bash -c 'dnf clean all; dnf upgrade -y nervak && installed 2.0'
      for id in $(rpm -qa 'gpg-pubkey*'); do rpm -e "$id" > /dev/null 2>&1; done
      dnf_keyfile keyAB.asc
      cell rotation/diagnosis-upgrade-after-rpm-e-and-import info bash -c 'dnf clean all; dnf upgrade -y nervak && installed 2.0'
    fi ;;
  stale)
    dnf_keyfile keyA.asc; dnf_repo s1
    cell rotation/dnf-install-from-S1 ok bash -c 'dnf install -y nervak-1.0-1 && installed 1.0'
    dnf_repo s2
    cell rotation/dnf-S2-with-the-old-key-file refuse bash -c 'dnf upgrade -y nervak'
    ;;
  expiry)
    dnf_keyfile keyExp.asc; dnf_repo s3
    cell expiry/dnf-install-rpm-signed-by-an-expired-subkey ok bash -c 'dnf install -y nervak-3.0-1 && installed 3.0'
    ;;
  revocation)
    dnf_keyfile keyRev.asc; dnf_repo s1
    cell revocation/dnf-key-file-with-a-revocation-still-installs-S1 ok bash -c 'dnf install -y nervak-1.0-1 && installed 1.0'
    dnf_repo s4
    cell revocation/dnf-rpm-signed-by-a-revoked-subkey refuse dnf install -y nervak-4.0-1
    dnf_repo s4m
    cell revocation/dnf-repomd-signed-by-a-revoked-subkey refuse dnf install -y nervak-5.0-1
    ;;
  esac
}
export -f apt_n apt_update_clean apt_has dnf_keys installed
export base log

case $mgr in
  apt) apt_group ;;
  dnf) dnf_group ;;
esac
'''


def container_cells(image, w, www, port):
    mgr = "apt" if image in APT_IMAGES else "dnf"
    script = w / "cell.sh"
    # refuse: the revocation cells (a refusal is the pass, and a success is a FAIL, not INFO)
    script.write_text(CELL_SH)
    groups = ["apt"] if mgr == "apt" else ["rotation", "stale", "expiry", "revocation"]
    for g in groups:
        print(f"== {image} {g}", flush=True)
        r = subprocess.run(["docker", "run", "--rm", "--network", "host", "-v", f"{script}:/cell.sh:ro",
                            image, "bash", "/cell.sh", mgr, g, f"http://127.0.0.1:{port}"],
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for line in r.stdout.splitlines():
            m = re.match(r"CELL (\S+) (PASS|FAIL|INFO) ?(.*)", line)
            if m:
                name, v, text = m.groups()
                record(f"{g}:{name}", v, text)
            else:
                print(line, flush=True)
        if r.returncode != 0:
            record(f"{g}:container", "FAIL", f"docker run exited {r.returncode}")


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--host", action="store_true")
    g.add_argument("--image")
    ap.add_argument("--keep", action="store_true", help="keep the scratch directory (debugging)")
    ap.add_argument("--expiry-seconds", type=int, default=SECONDS_S3)
    a = ap.parse_args()
    w = Path(tempfile.mkdtemp(prefix="subkeys", dir="/tmp"))
    www = w / "www"
    k = Keys(w)
    try:
        t0 = time.time()
        if a.host:
            ceremony(w)
        keys = make_keys(k, www, a.expiry_seconds)
        signer = Signer(k, keys["ci"], www)
        build_all(w, www, keys, signer)
        print(f"keys and repositories made in {int(time.time() - t0)} s", flush=True)
        if time.time() > keys["expires"]:
            sys.exit("error: S3 expired before it signed; raise --expiry-seconds")
        wait_for(keys["expires"], "S3 to expire")
        keys["export"]("keyExp.asc", keys["ph2"])  # S3 expired; S1 and S2 as before; no S4
        keys["export"]("keyRev.asc")  # the same, and S4 revoked
        for name, tag in (("keyExp", "e"), ("keyRev", "r")):
            out = sh(["gpg", "--show-keys", "--with-colons", str(www / f"keys/{name}.asc")]).stdout
            assert re.search(rf"^sub:{tag}:", out, re.M), f"{name}.asc carries no {tag} subkey"
        if a.host:
            primary_cells(k, keys, signer, www)
            host_cells(w, www, keys)
        else:
            httpd = serve(www)
            container_cells(a.image, w, www, httpd.server_address[1])
            httpd.shutdown()
    finally:
        k.close()
        if a.keep:
            print("kept:", w)
        else:
            shutil.rmtree(w, ignore_errors=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(f"### {a.image or 'host'} ({os.uname().machine})\n\n| cell | result | |\n|---|---|---|\n")
            for n, v, t in CELLS:
                f.write(f"| {n} | {v} | {t.replace('|', '/')[:160]} |\n")
    bad = [n for n, v, _ in CELLS if v == "FAIL"]
    print(f"\nkey-model: {sum(v == 'PASS' for _, v, _ in CELLS)} PASS, {len(bad)} FAIL, "
          f"{sum(v == 'INFO' for _, v, _ in CELLS)} INFO")
    for n in bad:
        print("FAIL:", n)
    surprise = [n for n in bad if not any(k in n for k in FINDINGS)]
    if bad and not surprise:
        print("every FAIL is a finding of the key-model decision (P392): the rpm side does not "
              "follow a subkey rotation; the run is not red for it")
    return 1 if surprise else 0


# The cells whose FAIL is the answer to the question (docs/decisions/P392*): rpm and dnf do not
# merge a new subkey into a key they already hold, and dnf5 does not enforce what dnf4 does. They
# stay FAIL in the table; they do not turn the run red. Any other FAIL does.
FINDINGS = (
    "rotation/rpm4.18-S2-after-keyAB-import",
    "rotation/dnf-upgrade-with-the-new-key-file",
    "rotation/dnf-S2-with-the-old-key-file",
    "revocation/rpm4.18-key-file-with-a-revocation-still-verifies-S1",
    "revocation/dnf-key-file-with-a-revocation-still-installs-S1",
    "revocation/dnf-repomd-signed-by-a-revoked-subkey",
)


if __name__ == "__main__":
    sys.exit(main())
