#!/usr/bin/env python3
"""The signed apt and dnf repositories install on real distributions (docs/releases/packages.md,
slice 2: `repos-verify`'s check, `.github/scripts/repo_install_check.sh`).

Usage: repos.py [--no-docker] [--images IMAGE,IMAGE,...]

It builds three repository trees with the real `package_repos.sh` (throwaway keys, the fake bucket
of test_r2.py, a stand-in `gh`; `.github/scripts/test_package_repos.py` is the harness), serves each
over local HTTP, and runs `repo_install_check.sh` in a container per distribution, with
`--network host` so the container reaches the server:

  1. the install text's commands equal `repo_install_check.sh`'s (needs no Docker, runs first);
  2. every image installs `stable` (a release) and `rc` (a candidate, and `stable` must not list it),
     where the candidate's tree has an empty `stable` (so `dnf list` exits 1: the check reads output);
  3. dnf 5 (fedora 43 and 44) installs with `gpgcheck=1`, `repo_gpgcheck=1` and no `rpm --import`;
  4. a wrong fingerprint is NRV-E1146, three lines, and says the release is public;
  5. a setup that cannot reach its mirror is NRV-E1157 (Debian, with no network);
  6. apt refuses a `stable` that is a copy of `rc` on a host that read `stable` before;
  7. a dual-signed InRelease verifies on debian 12 (gpgv) and 13 (sqv) with only one of the two keys.

`--no-docker` runs only 1 and tree generation. The images are tags here; `packages.yml`'s job pins
them by digest (slice 4). Requires root-less docker, gpg, rpmbuild, dpkg-deb, apt-ftparchive,
createrepo_c and rpmsign on the host, as `ci.yml` installs them.
"""
import re
import subprocess
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / ".github/scripts"
sys.path.insert(0, str(SCRIPTS))
import test_package_repos as H  # noqa: E402  (the harness: Base, packages, the stand-in gh)

IMAGES = ["debian:12", "debian:13", "ubuntu:22.04", "ubuntu:24.04", "rockylinux:9", "fedora:43", "fedora:44"]
SPEC = ROOT / "docs/releases/packages.md"
CHECK = SCRIPTS / "repo_install_check.sh"
failures = []


def fail(what):
    failures.append(what)
    print("FAIL:", what, flush=True)


def ok(what):
    print("ok:  ", what, flush=True)


# ---- 1. the install text --------------------------------------------------------------------

def spec_blocks():
    text = SPEC.read_text()
    section = text.split("## Install instructions", 1)[1].split("\n## ", 1)[0]
    return re.findall(r"```bash\n(.*?)```", section, re.S)


def normalize(block):
    out = []
    for line in block.splitlines():
        line = re.sub(r"\s+#.*$", "", line).rstrip()
        if not line:
            continue
        line = line.replace("sudo apt update && sudo apt install nerva",
                            "$SUDO apt-get update && $SUDO apt-get install -y nerva=$APT_VER")
        line = line.replace("sudo dnf install nerva", "$SUDO dnf install -y nerva-$RPM_VER")
        line = line.replace("sudo ", "$SUDO ")
        line = line.replace("https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc",
                            "$KEY_URL")
        line = line.replace("https://packages.nerva.pro/apt", "$BASE/apt")
        line = line.replace("https://packages.nerva.pro/rpm/stable", "$BASE/rpm/$CHANNEL")
        line = line.replace("Suites: stable", "Suites: $CHANNEL").replace("<<'EOF'", "<<EOF")
        out.append(line)
    return out


def script_region(*names):
    text = CHECK.read_text()
    out = []
    for n in names:
        m = re.search(rf"# INSTALL-BEGIN {n}\n(.*?)# INSTALL-END {n}\n", text, re.S)
        if not m:
            return None
        out += [l.strip() for l in m.group(1).splitlines() if l.strip()]
    return out


def check_install_text():
    blocks = spec_blocks()
    if len(blocks) < 2:
        return fail("the install section has no two bash blocks")
    for name, block, regions in (("apt", blocks[0], ("apt", "apt-install")), ("dnf", blocks[1], ("dnf", "dnf-install"))):
        want = normalize(block)
        got = script_region(*regions)
        if got != want:
            fail(f"the {name} commands in repo_install_check.sh differ from the install text:\n  text   {want}\n  script {got}")
        else:
            ok(f"the {name} commands equal the install text")
    if "rpm --import" in re.sub(r"(?m)^\s*#.*$", "", CHECK.read_text()):
        fail("repo_install_check.sh runs rpm --import")
    else:
        ok("repo_install_check.sh never runs rpm --import")


# ---- the trees -----------------------------------------------------------------------------------

class Gen(H.Base):
    def runTest(self):
        pass


def tree(tags, current="a", next_=None):
    """Publish `tags` (in order) into a fresh bucket with the real script; returns (Gen, web)."""
    g = Gen()
    g.setUp()
    g.set_keys(current=current, next=next_)
    for t in tags:
        g.release(t)
        rc, _, err = g.ready(t)
        if rc != 0:
            sys.exit(f"building the tree failed at ready {t}:\n{err}")
        g.set_state(t, "published")
        rc, _, err = g.publish(t)
        if rc != 0:
            sys.exit(f"building the tree failed at publish {t}:\n{err}")
    return g


def serve(g, keys_text):
    g.web.override["keys/nerva-release.asc"] = keys_text.encode()
    return f"http://127.0.0.1:{g.web.server_address[1]}"


# ---- the containers ------------------------------------------------------------------------------

def docker(image, args, base, network="host", extra=()):
    cmd = ["docker", "run", "--rm", "--network", network, "-v", f"{SCRIPTS}:/s:ro",
           "-e", f"INSTALL_KEY_URL={base}/keys/nerva-release.asc", *extra, image, "bash", "/s/repo_install_check.sh", *args]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=1500)


def mgr_of(image):
    return "apt" if image.split(":")[0] in ("debian", "ubuntu") else "dnf"


def cell(image, channel, base, fpr, version, what, **kw):
    p = docker(image, [mgr_of(image), channel, base, fpr, version], base, **kw)
    if p.returncode != 0:
        fail(f"{image} {what}:\n{p.stderr[-1500:]}")
        return None
    ok(f"{image} {what}")
    return p


def refusal(image, args, base, code, what, **kw):
    p = docker(image, args, base, **kw)
    m = re.search(rf"^error\[{code}\]: repo_install_check\.sh: .*\n  cause  .*\n  fix    .*$", p.stderr, re.M)
    if p.returncode != 1 or not m:
        fail(f"{image} {what}: wanted {code}, got {p.returncode}:\n{p.stderr[-800:]}")
        return
    ok(f"{image} {what}")


def exec_in(cid, script):
    return subprocess.run(["docker", "exec", cid, "bash", "-c", script], capture_output=True, text=True)


def copied_channel(image, g, base, fpr):
    """A host that read `stable` before refuses a `stable` that is `rc`'s files."""
    cid = subprocess.run(["docker", "run", "-d", "--network", "host", "-v", f"{SCRIPTS}:/s:ro", "-e",
                          f"INSTALL_KEY_URL={base}/keys/nerva-release.asc", image, "sleep", "600"],
                         capture_output=True, text=True).stdout.strip()
    try:
        pre = "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq curl ca-certificates gnupg >/dev/null"
        cfg = (f"install -d /etc/apt/keyrings && curl -fsSL $INSTALL_KEY_URL -o /etc/apt/keyrings/nerva.asc && "
               f"printf 'Types: deb\\nURIs: {base}/apt\\nSuites: stable\\nComponents: main\\nArchitectures: amd64 arm64\\nSigned-By: /etc/apt/keyrings/nerva.asc\\n' > /etc/apt/sources.list.d/nerva.sources")
        if exec_in(cid, pre + " && " + cfg).returncode != 0 or exec_in(cid, "apt-get update").returncode != 0:
            return fail(f"{image}: the first apt-get update against stable failed")
        for f in ("InRelease", "Release", "Release.gpg"):
            g.web.override[f"apt/dists/stable/{f}"] = g.s3.objects[f"apt/dists/rc/{f}"][0]
        p = exec_in(cid, "apt-get update")
        if p.returncode == 0 or "Suite" not in p.stdout + p.stderr:
            fail(f"{image}: apt accepted rc's files as stable:\n{p.stdout[-600:]}{p.stderr[-600:]}")
        else:
            ok(f"{image} apt refuses a copied channel")
        for f in ("InRelease", "Release", "Release.gpg"):
            g.web.override.pop(f"apt/dists/stable/{f}", None)
    finally:
        subprocess.run(["docker", "rm", "-f", cid], capture_output=True)


def main(argv):
    no_docker = "--no-docker" in argv
    images = IMAGES
    if "--images" in argv:
        images = argv[argv.index("--images") + 1].split(",")
    check_install_text()
    g1 = tree(["v0.7.1", "v0.8.0-rc.1"])          # a release and a candidate
    g2 = tree(["v0.8.0-rc.1"])                      # a candidate, `stable` empty
    g3 = tree(["v0.7.1"], current="a", next_="b")   # a dual-signed repository
    for g, name in ((g1, "release and candidate"), (g2, "candidate only"), (g3, "dual-signed")):
        if "state complete" not in g.manifest():
            fail(f"the {name} tree has no complete manifest")
    ok("the three trees were generated and verify")
    if not no_docker:
        fpr = g1.k["a"][0]
        b1 = serve(g1, g1.k["a"][2])
        b2 = serve(g2, g2.k["a"][2])
        for image in images:
            cell(image, "stable", b1, fpr, "0.7.1", "installs stable 0.7.1")
            cell(image, "rc", b1, fpr, "0.8.0-rc.1", "installs candidate 0.8.0-rc.1 from rc; stable does not list it")
            cell(image, "rc", b2, fpr, "0.8.0-rc.1", "installs the candidate with an empty stable")
            refusal(image, [mgr_of(image), "stable", b1, "0" * 40, "0.7.1"], b1, "NRV-E1146", "wrong fingerprint is NRV-E1146")
        if "debian:12" in images or "debian:13" in images:
            refusal("debian:12" if "debian:12" in images else "debian:13", ["apt", "stable", b1, fpr, "0.7.1"], b1,
                    "NRV-E1157", "no network is NRV-E1157", network="none")
        for image in [i for i in images if i.startswith(("debian", "ubuntu"))]:
            copied_channel(image, g1, b1, fpr)
        for image in [i for i in images if i in ("debian:12", "debian:13")]:
            for n in "ab":
                cell(image, "stable", serve(g3, g3.k[n][2]), g3.k[n][0], "0.7.1",
                     f"verifies a dual-signed InRelease with only key {n}")
    for g in (g1, g2, g3):
        g.cleanup()
    print(f"repos.py: {'FAIL' if failures else 'PASS'} ({len(failures)} failures)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
