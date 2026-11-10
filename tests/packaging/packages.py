#!/usr/bin/env python3
"""The Linux packages (docs/briefs/v0.7.1.md, slice 5): a .deb (dpkg-deb) and an .rpm (rpmbuild).

Usage: packages.py <nerva> <repository> [--version N.N.N] [--require-version-line] [--no-containers]
                   [--images IMAGE,...]

<nerva> is a release build for x86_64-linux; <repository> is a checkout (packaging/linux, LICENSE and
NOTICE). It runs as an ordinary user with dpkg-deb, rpmbuild, rpm2archive, tar and (for step 4) docker.
Nothing is compiled: the aarch64 and arm64 packages carry the same file as a stand-in for the
aarch64 release build, since only their metadata and layout are checked on this machine.
  1. Both packages for both architectures are built twice, with a different time zone, umask and
     working directory, and the bytes are equal (reproducible).
  2. `dpkg-deb --info`, `--contents`, `-e` and `rpm -qp` (--queryformat, --dump, --scripts) show the
     names, versions, architectures, files, modes, owners, no signature, and maintainer scripts that
     only create the user and the directories (no systemctl, no removal of anything).
  3. The units and examples inside each package equal packaging/linux's, byte for byte.
  4. In ubuntu:24.04, debian:12, rockylinux:9 and fedora:latest: install from the file, run
     `nerva version`, check the units, the user and the directories, install again (nothing
     changes), remove the package (a deb also purged) and check /var/lib/nerva, /etc/nerva and the
     user remain; and a user named nerva that is not ours is refused with NRV-E1105 before
     anything is unpacked.
Whether fedora:latest accepts an unsigned rpm is printed as `FINDING:` and recorded in P-decisions.
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

PACKAGES = [("amd64", "x86_64"), ("arm64", "aarch64")]
UNITS = ["nerva@.service", "nerva-api@.service"]
DOCS = ["replica.env.example", "api.env.example"]
IMAGES = {"ubuntu:24.04": "deb", "debian:12": "deb", "rockylinux:9": "rpm", "fedora:latest": "rpm"}
# What a maintainer script may never do: start, enable, format or remove anything.
FORBIDDEN = ["systemctl", "invoke-rc.d", "deb-systemd-helper", "rm -", "rmdir", "userdel", "nerva format"]


def run(args, check=True, **kw):
    result = subprocess.run(args, capture_output=True, text=True, **kw)
    if check and result.returncode != 0:
        sys.exit(f"FAIL: {args}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def read(path):
    with open(path, "rb") as f:
        return f.read()


def build(repo, nerva, version, out, epoch, reproducibility_probe=False):
    """Builds all four packages into `out`; returns {name: path}."""
    env = dict(os.environ, SOURCE_DATE_EPOCH=str(epoch))
    preexec = None
    if reproducibility_probe:
        env["TZ"] = "Asia/Tokyo"
        env["LC_ALL"] = "C"
        preexec = lambda: os.umask(0o077)  # noqa: E731
    built = {}
    for deb, rpm in PACKAGES:
        for script, arch in (("build-deb.sh", deb), ("build-rpm.sh", rpm)):
            result = run(
                ["sh", f"{repo}/packaging/linux/{script}", nerva, arch, version, out],
                env=env, preexec_fn=preexec,
            )
            path = result.stdout.strip().split("\n")[-1]
            built[os.path.basename(path)] = path
    assert sorted(built) == sorted(
        [f"nerva_{version}-1_amd64.deb", f"nerva_{version}-1_arm64.deb",
         f"nerva-{version}-1.x86_64.rpm", f"nerva-{version}-1.aarch64.rpm"]), sorted(built)
    return built


def check_reproducible(first, second):
    for name in first:
        a, b = sha256(first[name]), sha256(second[name])
        assert a == b, f"{name} is not reproducible: {a} != {b}"
        print(f"  {name}  {a[:16]}")


def check_deb(path, repo, version, arch, epoch, tmp):
    fields = run(["dpkg-deb", "-f", path, "Package", "Version", "Architecture", "Pre-Depends"]).stdout
    assert f"Package: nerva\nVersion: {version}-1\nArchitecture: {arch}\n" in fields, fields
    listing = run(["dpkg-deb", "--contents", path]).stdout.strip().split("\n")
    entries = {}
    for line in listing:
        mode, owner, _size, _date, _time, name = line.split(None, 5)
        assert owner == "root/root", line
        entries[name] = mode
    files = {n: m for n, m in entries.items() if not m.startswith("d")}
    assert files == {
        "./usr/bin/nerva": "-rwxr-xr-x",
        "./usr/lib/systemd/system/nerva-api@.service": "-rw-r--r--",
        "./usr/lib/systemd/system/nerva@.service": "-rw-r--r--",
        "./usr/share/doc/nerva/LICENSE": "-rw-r--r--",
        "./usr/share/doc/nerva/NOTICE": "-rw-r--r--",
        "./usr/share/doc/nerva/api.env.example": "-rw-r--r--",
        "./usr/share/doc/nerva/replica.env.example": "-rw-r--r--",
    }, files
    assert all(m == "drwxr-xr-x" for n, m in entries.items() if m.startswith("d")), entries
    # Nothing is owned in /var/lib/nerva or /etc/nerva: the maintainer script makes them, and
    # removal leaves them.
    assert not any("/var/" in n or "/etc/" in n for n in entries), entries
    control = os.path.join(tmp, "control-" + arch)
    run(["dpkg-deb", "-e", path, control])
    assert sorted(os.listdir(control)) == ["control", "preinst"], os.listdir(control)
    check_script(read(f"{control}/preinst").decode(), repo)
    assert os.stat(f"{control}/preinst").st_mode & 0o777 == 0o755
    root = os.path.join(tmp, "deb-" + arch)
    run(["dpkg-deb", "-x", path, root])
    check_payload(root, repo, epoch)
    return root


def check_script(text, repo):
    assert text.strip() == read(f"{repo}/packaging/linux/package-setup.sh").decode().strip()
    code = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
    for word in FORBIDDEN:
        assert word not in code, f"a maintainer script runs {word!r}"
    assert "useradd" in code and "NRV-E1105" in code


def check_rpm(path, repo, version, arch, epoch, tmp):
    query = run(["rpm", "-qp", "--queryformat", "%{NAME} %{VERSION} %{RELEASE} %{ARCH} %{BUILDTIME}\n", path])
    assert query.stdout.strip() == f"nerva {version} 1 {arch} {epoch}", query.stdout
    names = run(["rpm", "-qpl", path]).stdout.split()
    assert sorted(names) == sorted([
        "/usr/bin/nerva", "/usr/lib/systemd/system/nerva-api@.service",
        "/usr/lib/systemd/system/nerva@.service", "/usr/share/doc/nerva",
        "/usr/share/doc/nerva/LICENSE", "/usr/share/doc/nerva/NOTICE",
        "/usr/share/doc/nerva/api.env.example", "/usr/share/doc/nerva/replica.env.example"]), names
    dump = run(["rpm", "-qp", "--dump", path]).stdout.strip().split("\n")
    for line in dump:
        name, _size, mtime, _digest, mode, owner, group, *_rest = line.split()
        assert (owner, group) == ("root", "root"), line
        assert int(mtime) == epoch, line
        expected = {"/usr/bin/nerva": 0o100755, "/usr/share/doc/nerva": 0o040755}.get(name, 0o100644)
        assert int(mode, 8) == expected, line
    scripts = run(["rpm", "-qp", "--scripts", path]).stdout
    assert re.findall(r"^(\w+) scriptlet", scripts, re.M) == ["preinstall"], scripts
    check_script(scripts.split("\n", 1)[1], repo)
    signatures = run(["rpm", "-qp", "--queryformat", "%{RSAHEADER:pgpsig}|%{DSAHEADER:pgpsig}|%{SIGPGP:pgpsig}", path])
    assert signatures.stdout == "(none)|(none)|(none)", signatures.stdout  # unsigned, as documented
    root = os.path.join(tmp, "rpm-" + arch)
    os.makedirs(root)
    unpack = subprocess.run(f"rpm2archive - < '{path}' | tar -xz", shell=True, cwd=root,
                            capture_output=True, text=True)
    assert unpack.returncode == 0, unpack.stderr
    check_payload(root, repo, epoch)


def check_payload(root, repo, epoch):
    """The package's units and examples are slice 4's files, byte for byte."""
    for unit in UNITS:
        assert read(f"{root}/usr/lib/systemd/system/{unit}") == read(f"{repo}/packaging/linux/{unit}"), unit
    for doc in DOCS:
        assert read(f"{root}/usr/share/doc/nerva/{doc}") == read(f"{repo}/packaging/linux/{doc}"), doc
    for doc in ("LICENSE", "NOTICE"):
        assert read(f"{root}/usr/share/doc/nerva/{doc}") == read(f"{repo}/{doc}"), doc


# The checks a container runs after an install; %s are replaced by Python, never by sh.
CHECKS = r"""
check_installed() {
    nerva version > /tmp/version.out
    [ -s /tmp/version.out ]
    if [ "@REQUIRE@" = 1 ]; then
        [ "$(tail -n1 /tmp/version.out)" = "version @VERSION@" ]
    fi
    tail -n1 /tmp/version.out
    [ "$(stat -c '%a %U %G' /usr/bin/nerva)" = "755 root root" ]
    for unit in nerva@.service nerva-api@.service; do
        cmp /usr/lib/systemd/system/$unit /src/$unit
    done
    for doc in replica.env.example api.env.example; do
        cmp /usr/share/doc/nerva/$doc /src/$doc
    done
    entry=$(getent passwd nerva)
    [ "$(echo "$entry" | cut -d: -f6)" = /var/lib/nerva ]
    [ "$(echo "$entry" | cut -d: -f3)" -lt 1000 ]
    [ "$(id -gn nerva)" = nerva ]
    case "$(echo "$entry" | cut -d: -f7)" in */nologin | */false) ;; *) echo "nerva has a shell"; exit 1 ;; esac
    [ "$(stat -c '%a %U %G' /var/lib/nerva)" = "750 nerva nerva" ]
    [ "$(stat -c '%a %U %G' /etc/nerva)" = "750 root nerva" ]
    # nothing is enabled, started or formatted
    [ -z "$(ls -A /var/lib/nerva | grep -v '^marker$')" ]
    [ -z "$(ls -A /etc/nerva)" ]
}
check_removed() {
    [ ! -e /usr/bin/nerva ]
    [ ! -e /usr/lib/systemd/system/nerva@.service ]
    [ ! -e /usr/lib/systemd/system/nerva-api@.service ]
    [ "$(cat /var/lib/nerva/marker)" = data ]
    [ -d /etc/nerva ]
    getent passwd nerva > /dev/null
}
"""

# Container images exclude /usr/share/doc from what dpkg and dnf unpack (ubuntu's
# dpkg.cfg.d/excludes, a nodocs transaction flag); an installed machine does not, so lift both.
DEB_FLOW = r"""
rm -f /etc/dpkg/dpkg.cfg.d/*exclude*
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null
cp /dist/@PKG@ /tmp/@PKG@
chmod 644 /tmp/@PKG@
apt-get install -y -qq --no-install-recommends /tmp/@PKG@ > /dev/null
check_installed
echo data > /var/lib/nerva/marker
uid=$(id -u nerva)
apt-get install -y -qq --reinstall --no-install-recommends /tmp/@PKG@ > /dev/null
[ "$(id -u nerva)" = "$uid" ]
[ "$(cat /var/lib/nerva/marker)" = data ]
rm /var/lib/nerva/marker
check_installed
echo data > /var/lib/nerva/marker
apt-get remove -y -qq nerva > /dev/null
check_removed
apt-get purge -y -qq nerva > /dev/null
check_removed
echo "remove and purge left /var/lib/nerva, /etc/nerva and the user"
"""

# dnf4 (Rocky 9) and dnf5 (Fedora 43 on) both take install/remove with -y; the weak dependency
# on systemd is left out so the container stays small. Fedora's rpm 6 may refuse an unsigned file:
# that is recorded as a FINDING, and the install retried without the check so the rest still runs.
RPM_FLOW = r"""
cp /dist/@PKG@ /tmp/@PKG@
chmod 644 /tmp/@PKG@
dnf_install() {
    dnf install -y -q --setopt=install_weak_deps=False --setopt=tsflags= "$@" /tmp/@PKG@ > /tmp/dnf.out 2>&1
}
if dnf_install; then
    echo "FINDING: @IMAGE@ ($(rpm --version)) installed the unsigned rpm with its defaults"
else
    echo "FINDING: @IMAGE@ ($(rpm --version)) refused the unsigned rpm with its defaults:"
    head -n 12 /tmp/dnf.out
    if [ "@IMAGE@" != fedora:latest ]; then exit 1; fi
    dnf_install --no-gpgchecks || dnf_install --nogpgcheck
    echo "FINDING: it installs with the signature check off"
fi
check_installed
echo data > /var/lib/nerva/marker
uid=$(id -u nerva)
rpm -U --replacepkgs --nosignature /tmp/@PKG@ || rpm -U --replacepkgs /tmp/@PKG@
[ "$(id -u nerva)" = "$uid" ]
[ "$(cat /var/lib/nerva/marker)" = data ]
rm /var/lib/nerva/marker
check_installed
echo data > /var/lib/nerva/marker
dnf remove -y -q nerva > /dev/null
check_removed
echo "remove left /var/lib/nerva, /etc/nerva and the user"
"""

DEB_FOREIGN = r"""
rm -f /etc/dpkg/dpkg.cfg.d/*exclude*
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null
cp /dist/@PKG@ /tmp/@PKG@
chmod 644 /tmp/@PKG@
useradd --system --home-dir /nonexistent nerva
if apt-get install -y --no-install-recommends /tmp/@PKG@ > /tmp/out 2>&1; then
    echo "the install should have been refused"; exit 1
fi
"""

RPM_FOREIGN = r"""
cp /dist/@PKG@ /tmp/@PKG@
chmod 644 /tmp/@PKG@
useradd --system --home-dir /nonexistent nerva
if dnf install -y --setopt=install_weak_deps=False --setopt=tsflags= --no-gpgchecks /tmp/@PKG@ > /tmp/out 2>&1 ||
    dnf install -y --setopt=install_weak_deps=False --setopt=tsflags= --nogpgcheck /tmp/@PKG@ > /tmp/out 2>&1; then
    echo "the install should have been refused"; exit 1
fi
"""

FOREIGN_END = r"""
cat /tmp/out /var/log/dnf*.log /var/log/hawkey.log 2> /dev/null | grep -F "error[NRV-E1105]: nerva package: the user nerva exists, with home /nonexistent" | head -n 1
cat /tmp/out /var/log/dnf*.log 2> /dev/null | grep -q "NRV-E1105"
[ ! -e /usr/bin/nerva ]
[ ! -e /usr/lib/systemd/system/nerva@.service ]
[ ! -d /var/lib/nerva ]
echo "refused with NRV-E1105, nothing unpacked"
"""


def container(image, dist, repo, script, label):
    command = ["docker", "run", "--rm", "-v", f"{dist}:/dist:ro", "-v", f"{repo}/packaging/linux:/src:ro",
               image, "sh", "-eu", "-c", script]
    result = run(command, check=False)
    print(f"  [{image}] {label}")
    for line in result.stdout.strip().split("\n"):
        if line:
            print(f"    {line}")
    if result.returncode != 0:
        tail = "\n".join(result.stderr.strip().split("\n")[-60:])
        sys.exit(f"FAIL: {image} {label}: exit {result.returncode}\nstderr (last 60 lines):\n{tail}")


def containers(images, dist, repo, version, require_line):
    for image in images:
        kind = IMAGES[image]
        pkg = f"nerva_{version}-1_amd64.deb" if kind == "deb" else f"nerva-{version}-1.x86_64.rpm"

        def fill(text):
            return (text.replace("@PKG@", pkg).replace("@IMAGE@", image).replace("@VERSION@", version)
                    .replace("@REQUIRE@", "1" if require_line else "0"))

        flow = DEB_FLOW if kind == "deb" else RPM_FLOW
        container(image, dist, repo, fill(CHECKS + flow), "install, reinstall, remove")
        foreign = DEB_FOREIGN if kind == "deb" else RPM_FOREIGN
        container(image, dist, repo, fill(foreign + FOREIGN_END), "a foreign user nerva")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("nerva")
    parser.add_argument("repository")
    parser.add_argument("--version", default=None)
    parser.add_argument("--require-version-line", action="store_true",
                        help="nerva version must end in 'version N.N.N' (v0.7.1's slice 3)")
    parser.add_argument("--no-containers", action="store_true")
    parser.add_argument("--images", default=",".join(IMAGES))
    args = parser.parse_args()
    repo = os.path.realpath(args.repository)
    nerva = os.path.realpath(args.nerva)
    version = args.version or read(f"{repo}/VERSION").decode().strip()
    epoch = int(run(["git", "-C", repo, "log", "-1", "--format=%ct"]).stdout)
    tmp = tempfile.mkdtemp(prefix="nerva-packages-")
    try:
        print(f"rpmbuild: {run(['rpmbuild', '--version']).stdout.strip()}; "
              f"{run(['dpkg-deb', '--version']).stdout.split(chr(10))[0]}")
        print("1. built twice, the bytes equal")
        first = build(repo, nerva, version, f"{tmp}/a", epoch)
        second = build(repo, nerva, version, f"{tmp}/b", epoch, reproducibility_probe=True)
        check_reproducible(first, second)
        print("2. and 3. metadata, files, scripts, units")
        for deb, rpm in PACKAGES:
            check_deb(first[f"nerva_{version}-1_{deb}.deb"], repo, version, deb, epoch, tmp)
            check_rpm(first[f"nerva-{version}-1.{rpm}.rpm"], repo, version, rpm, epoch, tmp)
        print("  ok")
        if not args.no_containers:
            print("4. installed in containers")
            containers(args.images.split(","), f"{tmp}/a", repo, version, args.require_version_line)
        out = os.environ.get("PACKAGES_OUT")
        if out:
            os.makedirs(out, exist_ok=True)
            for path in first.values():
                shutil.copy(path, out)
        print("packages: PASS")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
