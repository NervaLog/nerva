#!/usr/bin/env python3
"""The Linux packages (docs/briefs/v0.7.1.md, slice 5): a .deb (dpkg-deb) and an .rpm (rpmbuild).

Usage: packages.py <nerva> <repository> --aarch64 <nerva-aarch64> [--version N.N.N[-suffix]]
                   [--require-version-line] [--no-containers] [--images IMAGE,...]

<nerva> is a release build for x86_64-linux and --aarch64 one for aarch64-linux (`zig build -Drelease
-Dtarget=aarch64-linux`): each package carries the binary built for its architecture, and the build
scripts read the ELF header and refuse another (NRV-E1110). <repository> is a checkout
(packaging/linux, LICENSE and NOTICE). It runs as an ordinary user with dpkg-deb, rpmbuild,
rpm2archive, tar and (for step 5) docker. Nothing is compiled.
  1. Both packages for both architectures are built twice, with a different time zone, locale,
     umask, output directory and working directory, and the bytes are equal. (The two builds share
     one filesystem and one set of tool versions, so the test does not show that archive entries
     are sorted, only that these inputs do not change the bytes.)
  2. `dpkg-deb --info`, `--contents`, `-e` and `rpm -qp` (--queryformat, --dump, --scripts) show the
     names, versions, architectures, files, modes, owners, no signature, and maintainer scripts that
     only create the user and the directories, reload systemd and disable enable links on removal
     (nothing starts, stops, enables, formats or deletes anything).
  3. The binary inside each package equals the input byte for byte; the units and examples equal
     packaging/linux's.
  4. A build given a binary for the other architecture, or a file that is not an ELF (/bin/true's
     wrong sibling, a script), is refused with NRV-E1110 and builds nothing.
  5. In ubuntu:24.04, debian:12, rockylinux:9 and fedora:latest, with the images' own settings
     (dpkg's /usr/share/doc exclusion, dnf's nodocs): install from the file, run `nerva version`,
     check the units, the examples in /usr/share/nerva, the user and the directories, install
     again, upgrade to the next patch version and downgrade (the data, the settings, the user and
     an enable link survive; nothing is stopped), remove the package (a deb also purged) and check
     /var/lib/nerva, /etc/nerva and the user remain and the enable link is gone; and a user, a group
     or a tarball install that conflicts is refused with NRV-E1105 or NRV-E1111 before anything is
     unpacked, with the exact message.
Whether fedora:latest accepts an unsigned rpm is printed as `FINDING:` and recorded in P295.
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
BIN = {"amd64": "x86", "x86_64": "x86", "arm64": "arm", "aarch64": "arm"}
IMAGES = {"ubuntu:24.04": "deb", "debian:12": "deb", "rockylinux:9": "rpm", "fedora:latest": "rpm"}
# What a maintainer script may never do: start, stop, restart, format or delete anything. Each
# script may run only the systemctl verbs listed for it.
FORBIDDEN = ["invoke-rc.d", "deb-systemd-helper", "rm -", "rmdir", "userdel", "nerva format"]
SCRIPTS = {  # file in packaging/linux: the systemctl verbs it may run
    "package-setup.sh": set(),
    "package-prerm.sh": {"disable"},
    "package-reload.sh": {"daemon-reload"},
}


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


def file_version(version):
    """A package's file name has `.` for the `~` of a prerelease's version (GitHub renames an asset
    whose name has a `~`, P311); the version inside the package keeps it."""
    return version.replace("~", ".")


def build(repo, binaries, version, out, epoch, reproducibility_probe=False):
    """Builds all four packages into `out`; returns {name: path}. `binaries` maps "x86" and "arm"."""
    env = dict(os.environ, SOURCE_DATE_EPOCH=str(epoch))
    preexec = None
    cwd = None
    if reproducibility_probe:
        env["TZ"] = "Asia/Tokyo"
        env["LC_ALL"] = "C"
        preexec = lambda: os.umask(0o077)  # noqa: E731
        cwd = tempfile.mkdtemp(prefix="nerva-cwd-")
    built = {}
    for deb, rpm in PACKAGES:
        for script, arch in (("build-deb.sh", deb), ("build-rpm.sh", rpm)):
            result = run(
                ["sh", f"{repo}/packaging/linux/{script}", binaries[BIN[arch]], arch, version, out],
                env=env, preexec_fn=preexec, cwd=cwd,
            )
            path = result.stdout.strip().split("\n")[-1]
            built[os.path.basename(path)] = path
    if cwd:
        shutil.rmtree(cwd, ignore_errors=True)
    assert sorted(built) == sorted(
        [f"nerva_{file_version(version)}-1_amd64.deb", f"nerva_{file_version(version)}-1_arm64.deb",
         f"nerva-{file_version(version)}-1.x86_64.rpm", f"nerva-{file_version(version)}-1.aarch64.rpm"]), \
        sorted(built)
    return built


def check_refusals(repo, binaries, version, tmp):
    """A binary for the other architecture, or no ELF at all, is refused with NRV-E1110."""
    script = os.path.join(tmp, "not-elf")
    with open(script, "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    cases = [
        ("build-deb.sh", "amd64", binaries["arm"], "is for aarch64, and the package is for x86_64"),
        ("build-deb.sh", "arm64", binaries["x86"], "is for x86_64, and the package is for aarch64"),
        ("build-rpm.sh", "x86_64", binaries["arm"], "is for aarch64, and the package is for x86_64"),
        ("build-rpm.sh", "aarch64", binaries["x86"], "is for x86_64, and the package is for aarch64"),
        ("build-deb.sh", "arm64", "/bin/true", "is for x86_64, and the package is for aarch64"),
        ("build-rpm.sh", "aarch64", "/bin/true", "is for x86_64, and the package is for aarch64"),
        ("build-deb.sh", "amd64", script, "is not an ELF executable, and the package is for x86_64"),
        ("build-rpm.sh", "aarch64", script, "is not an ELF executable, and the package is for aarch64"),
    ]
    for name, arch, binary, text in cases:
        out = os.path.join(tmp, "refused")
        result = run(["sh", f"{repo}/packaging/linux/{name}", binary, arch, version, out], check=False)
        assert result.returncode == 2, (name, arch, binary, result.returncode, result.stderr)
        shown = os.path.realpath(binary) if name == "build-rpm.sh" else binary  # the rpm script resolves it
        assert f"error[NRV-E1110]: {name}: {shown} {text}\n" in result.stderr, result.stderr
        assert "  cause  " in result.stderr and "  fix    " in result.stderr, result.stderr
        assert not os.path.exists(out), f"{name} {arch} built something"
    print(f"  {len(cases)} wrong-architecture builds refused with NRV-E1110")


def check_prerelease(repo, binaries, tmp, epoch):
    """release.yml packages a prerelease (0.7.1-rc.1) as 0.7.1~rc.1, which sorts before 0.7.1, in
    files named 0.7.1.rc.1; a bad suffix is refused."""
    built = build(repo, binaries, "0.7.1~rc.1", f"{tmp}/pre", epoch)
    deb = built["nerva_0.7.1.rc.1-1_amd64.deb"]
    assert run(["dpkg-deb", "-f", deb, "Version"]).stdout.strip() == "0.7.1~rc.1-1"
    assert run(["dpkg", "--compare-versions", "0.7.1~rc.1-1", "lt", "0.7.1-1"], check=False).returncode == 0
    rpm = built["nerva-0.7.1.rc.1-1.aarch64.rpm"]
    assert run(["rpm", "-qp", "--qf", "%{VERSION}-%{RELEASE}", rpm]).stdout == "0.7.1~rc.1-1"
    for name, arch in (("build-deb.sh", "amd64"), ("build-rpm.sh", "x86_64")):
        for bad in ("0.7.1~", "0.7.1~rc!1", "0.7.1-rc.1", "~rc.1"):
            result = run(["sh", f"{repo}/packaging/linux/{name}", binaries["x86"], arch, bad,
                          f"{tmp}/bad"], check=False)
            assert result.returncode == 1 and "version" in result.stderr, (name, bad, result.stderr)
            assert not os.path.exists(f"{tmp}/bad"), (name, bad)
    print("  a prerelease builds as N.N.N~suffix in files named N.N.N.suffix; a bad suffix is refused")


def check_setup_modes(repo, tmp):
    """The NRV-E1111 check of package-setup.sh runs on a first install only (#319): a copy with its
    paths moved under a scratch directory and the tools it calls stubbed, run with the arguments dpkg
    and rpm pass. Runs here, with no container."""
    root = f"{tmp}/modes"
    os.makedirs(f"{root}/bin")
    os.makedirs(f"{root}/etc/systemd/system")
    text = read(f"{repo}/packaging/linux/package-setup.sh").decode()
    for path in ("/usr/local/bin", "/etc/systemd/system"):
        text = text.replace(path, root + path)
    # A path added to the script later and not moved here would be checked on the host itself.
    assert not re.findall(r"(?<!modes)/(?:usr/local|etc/systemd)", text), "a host path is not moved"
    with open(f"{root}/setup.sh", "w") as out:
        out.write(text)
    for tool in ("getent", "useradd", "install", "id"):
        with open(f"{root}/bin/{tool}", "w") as out:
            out.write("#!/bin/sh\nexit 1\n" if tool == "getent" else "#!/bin/sh\nexit 0\n")
        os.chmod(f"{root}/bin/{tool}", 0o755)
    env = {**os.environ, "PATH": f"{root}/bin:{os.environ['PATH']}"}
    unit = f"{root}/etc/systemd/system/nerva@.service"
    open(unit, "w").close()
    for args, refused in ((["install"], True), (["install", "0.7.0-1"], True), (["1"], True), ([], True),
                          (["upgrade", "0.7.0-1"], False), (["2"], False), (["10"], False),
                          (["abort-upgrade"], False)):
        result = run(["sh", f"{root}/setup.sh", *args], check=False, env=env)
        assert (result.returncode == 1) == refused, (args, result.returncode, result.stderr)
        assert ("NRV-E1111" in result.stderr) == refused, (args, result.stderr)
    os.remove(unit)
    for args in (["install"], ["upgrade", "0.7.0-1"], ["1"], ["2"]):
        result = run(["sh", f"{root}/setup.sh", *args], check=False, env=env)
        assert result.returncode == 0, (args, result.stderr)
        assert "NRV-W1101" not in result.stderr, (args, result.stderr)
    binary = f"{root}/usr/local/bin/nerva"
    os.makedirs(os.path.dirname(binary))
    open(binary, "w").close()
    for args, first in ((["install"], True), (["upgrade", "0.7.0-1"], False), (["2"], False),
                        (["10"], False)):
        result = run(["sh", f"{root}/setup.sh", *args], check=False, env=env)
        assert result.returncode == (1 if first else 0), (args, result.returncode, result.stderr)
        assert ("NRV-W1101" in result.stderr) == (not first), (args, result.stderr)
        if not first:
            assert result.stderr.startswith("warning[NRV-W1101]: nerva package: "), result.stderr
            assert "\n  cause  " in result.stderr and "\n  fix    " in result.stderr, result.stderr
            # The fix is W1102's advice (#340): keep one install, stop the replicas, and the
            # enabled instances survive (or are enabled again).
            assert "keep one install" in result.stderr and "systemctl stop" in result.stderr, result.stderr
            assert "systemctl enable for any instance that is not enabled" in result.stderr, result.stderr
    print("  NRV-E1111 is checked on a first install (install, rpm 1); an upgrade (upgrade, rpm 2) "
          "warns NRV-W1101 about /usr/local/bin/nerva and goes on")


def check_reproducible(first, second):
    for name in first:
        a, b = sha256(first[name]), sha256(second[name])
        assert a == b, f"{name} is not reproducible: {a} != {b}"
        print(f"  {name}  {a[:16]}")


def check_deb(path, repo, binary, version, arch, epoch, tmp):
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
        "./usr/share/doc/nerva/NOTICE": "-rw-r--r--",
        "./usr/share/doc/nerva/copyright": "-rw-r--r--",
        "./usr/share/nerva/api.env.example": "-rw-r--r--",
        "./usr/share/nerva/replica.env.example": "-rw-r--r--",
    }, files
    assert all(m == "drwxr-xr-x" for n, m in entries.items() if m.startswith("d")), entries
    # Nothing is owned in /var/lib/nerva or /etc/nerva: the maintainer script makes them, and
    # removal leaves them.
    assert not any("/var/" in n or "/etc/" in n for n in entries), entries
    control = os.path.join(tmp, "control-" + arch)
    run(["dpkg-deb", "-e", path, control])
    assert sorted(os.listdir(control)) == ["control", "md5sums", "postinst", "postrm", "preinst", "prerm"], \
        os.listdir(control)
    for name, script in (("preinst", "package-setup.sh"), ("prerm", "package-prerm.sh"),
                         ("postinst", "package-reload.sh"), ("postrm", "package-reload.sh")):
        check_script(read(f"{control}/{name}").decode(), repo, script)
        assert os.stat(f"{control}/{name}").st_mode & 0o777 == 0o755
    root = os.path.join(tmp, "deb-" + arch)
    run(["dpkg-deb", "-x", path, root])
    check_payload(root, repo, binary, "copyright")
    # md5sums lists exactly the files, with their sums (dpkg --verify and debsums read it).
    sums = dict(reversed(l.split("  ", 1)) for l in read(f"{control}/md5sums").decode().strip().split("\n"))
    assert sorted(sums) == sorted(n[2:] for n in files), sorted(sums)
    for name, digest in sums.items():
        assert hashlib.md5(read(f"{root}/{name}")).hexdigest() == digest, name
    return root


def check_script(text, repo, name):
    assert text.strip() == read(f"{repo}/packaging/linux/{name}").decode().strip(), name
    code = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
    for word in FORBIDDEN:
        assert word not in code, f"{name} runs {word!r}"
    verbs = set(re.findall(r"(?<!command -v )systemctl ([a-z][a-z-]*)", code))
    assert verbs <= SCRIPTS[name], f"{name} runs systemctl {verbs - SCRIPTS[name]}"
    assert "%" not in code, f"{name} has a percent sign: the .rpm embeds it in its spec"
    if name == "package-setup.sh":
        assert "useradd" in code and "NRV-E1105" in code and "NRV-E1111" in code


def check_rpm(path, repo, binary, version, arch, epoch, tmp):
    query = run(["rpm", "-qp", "--queryformat", "%{NAME} %{VERSION} %{RELEASE} %{ARCH} %{BUILDTIME}\n", path])
    assert query.stdout.strip() == f"nerva {version} 1 {arch} {epoch}", query.stdout
    names = run(["rpm", "-qpl", path]).stdout.split()
    assert sorted(names) == sorted([
        "/usr/bin/nerva", "/usr/lib/systemd/system/nerva-api@.service",
        "/usr/lib/systemd/system/nerva@.service", "/usr/share/doc/nerva",
        "/usr/share/doc/nerva/LICENSE", "/usr/share/doc/nerva/NOTICE",
        "/usr/share/nerva", "/usr/share/nerva/api.env.example", "/usr/share/nerva/replica.env.example"]), names
    dump = run(["rpm", "-qp", "--dump", path]).stdout.strip().split("\n")
    for line in dump:
        name, _size, mtime, _digest, mode, owner, group, *_rest = line.split()
        assert (owner, group) == ("root", "root"), line
        assert int(mtime) == epoch, line
        expected = {"/usr/bin/nerva": 0o100755, "/usr/share/doc/nerva": 0o040755,
                    "/usr/share/nerva": 0o040755}.get(name, 0o100644)
        assert int(mode, 8) == expected, line
    # The examples are plain files (no doc filter drops them); the licence is flagged %license.
    docfiles = run(["rpm", "-qp", "--docfiles", path]).stdout.split()
    assert not any(n.startswith("/usr/share/nerva") for n in docfiles), docfiles
    assert run(["rpm", "-qp", "--licensefiles", path]).stdout.split() == ["/usr/share/doc/nerva/LICENSE"]
    scripts = run(["rpm", "-qp", "--scripts", path]).stdout
    parts = re.split(r"^(\w+) scriptlet[^\n]*\n", scripts, flags=re.M)
    assert parts[1::2] == ["preinstall", "preuninstall"], scripts
    check_script(parts[2], repo, "package-setup.sh")
    check_script(parts[4], repo, "package-prerm.sh")
    signatures = run(["rpm", "-qp", "--queryformat", "%{RSAHEADER:pgpsig}|%{DSAHEADER:pgpsig}|%{SIGPGP:pgpsig}", path])
    assert signatures.stdout == "(none)|(none)|(none)", signatures.stdout  # unsigned, as documented
    root = os.path.join(tmp, "rpm-" + arch)
    os.makedirs(root)
    unpack = subprocess.run(f"rpm2archive - < '{path}' | tar -xz", shell=True, cwd=root,
                            capture_output=True, text=True)
    assert unpack.returncode == 0, unpack.stderr
    check_payload(root, repo, binary, "LICENSE")


def check_payload(root, repo, binary, license_name):
    """The package's binary is the input, and its units and examples are slice 4's, byte for byte."""
    assert read(f"{root}/usr/bin/nerva") == read(binary), "the packaged nerva is not the input"
    for unit in UNITS:
        assert read(f"{root}/usr/lib/systemd/system/{unit}") == read(f"{repo}/packaging/linux/{unit}"), unit
    for doc in DOCS:
        assert read(f"{root}/usr/share/nerva/{doc}") == read(f"{repo}/packaging/linux/{doc}"), doc
    assert read(f"{root}/usr/share/doc/nerva/{license_name}") == read(f"{repo}/LICENSE")
    assert read(f"{root}/usr/share/doc/nerva/NOTICE") == read(f"{repo}/NOTICE")


# The checks a container runs after an install; @NAME@ are replaced by Python, never by sh.
CHECKS = r"""
same() {
    [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$(sha256sum "$2" | cut -d' ' -f1)" ]
}
check_installed() {
    nerva version > /tmp/version.out
    [ -s /tmp/version.out ]
    if [ "@REQUIRE@" = 1 ]; then
        [ "$(tail -n1 /tmp/version.out)" = "version @BINVERSION@" ]
    fi
    tail -n1 /tmp/version.out
    [ "$(stat -c '%a %U %G' /usr/bin/nerva)" = "755 root root" ]
    for unit in nerva@.service nerva-api@.service; do
        same /usr/lib/systemd/system/$unit /src/$unit
    done
    # The examples are where no doc filter applies (this image's own settings are in force).
    for doc in replica.env.example api.env.example; do
        same /usr/share/nerva/$doc /src/$doc
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
# The images have no systemd: a stand-in (in /usr/bin: apt runs maintainer scripts without /usr/local/bin) logs every call and does what `disable` does to a link.
stub_systemctl() {
    mkdir -p /run/systemd/system /etc/systemd/system/multi-user.target.wants
    cat > /usr/bin/systemctl << 'STUB'
#!/bin/sh
echo "$*" >> /tmp/systemctl.log
case "$1" in disable) rm -f /etc/systemd/system/*.wants/"$2" ;; esac
STUB
    chmod 755 /usr/bin/systemctl
    : > /tmp/systemctl.log
}
link=/etc/systemd/system/multi-user.target.wants/nerva@0.service
# An operator's data and settings, and an enabled replica.
make_state() {
    echo data > /var/lib/nerva/marker
    echo "NERVA_ADDRESSES=3001" > /etc/nerva/replica-0.env
    ln -s /usr/lib/systemd/system/nerva@.service $link
}
check_state() {
    [ "$(cat /var/lib/nerva/marker)" = data ]
    [ "$(cat /etc/nerva/replica-0.env)" = "NERVA_ADDRESSES=3001" ]
    [ "$(id -u nerva)" = "$uid" ]
    [ -L $link ]
    nerva version > /dev/null
    # an upgrade, a downgrade and a reinstall never stop, start or disable anything
    if grep -E '^(stop|start|restart|try-restart|disable|enable) ' /tmp/systemctl.log; then exit 1; fi
}
clear_state() {
    rm /var/lib/nerva/marker /etc/nerva/replica-0.env
}
"""

DEB_FLOW = r"""
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null
cp /dist/@PKG@ /tmp/@PKG@
cp /dist/@PKG2@ /tmp/@PKG2@
chmod 644 /tmp/@PKG@ /tmp/@PKG2@
stub_systemctl
apt-get install -y -qq --no-install-recommends /tmp/@PKG@ > /dev/null
check_installed
grep -qx daemon-reload /tmp/systemctl.log
uid=$(id -u nerva)
make_state
apt-get install -y -qq --reinstall --no-install-recommends /tmp/@PKG@ > /dev/null
check_state
echo "reinstall kept the data, the settings, the user and the enabled replica"
mkdir -p /etc/systemd/system
touch /etc/systemd/system/nerva@.service /usr/local/bin/nerva
apt-get install -y -qq --no-install-recommends /tmp/@PKG2@ > /tmp/upgrade.out 2>&1
grep -q 'warning.NRV-W1101.: nerva package: /usr/local/bin/nerva exists' /tmp/upgrade.out
[ "$(dpkg-query -W -f='${Version}' nerva)" = "@VERSION2@-1" ]
check_state
apt-get install -y -qq --allow-downgrades --no-install-recommends /tmp/@PKG@ > /dev/null
[ "$(dpkg-query -W -f='${Version}' nerva)" = "@VERSION@-1" ]
rm /etc/systemd/system/nerva@.service /usr/local/bin/nerva
check_state
echo "upgrade to @VERSION2@ and downgrade back kept the data, the settings, the user and the enabled replica"
dpkg --verify nerva
rm $link
clear_state
check_installed
make_state
dpkg -r nerva > /dev/null
check_removed
[ ! -L $link ]
grep -qx 'disable nerva@0.service' /tmp/systemctl.log
[ "$(tail -n1 /tmp/systemctl.log)" = daemon-reload ]
dpkg -P nerva > /dev/null
check_removed
[ "$(cat /etc/nerva/replica-0.env)" = "NERVA_ADDRESSES=3001" ]
echo "remove and purge left /var/lib/nerva, /etc/nerva and the user, and disabled the enabled replica"
"""

# dnf4 (Rocky 9) and dnf5 (Fedora 43 on) both take install/remove with -y; the weak dependency
# on systemd is left out so the container stays small. Whether an image
# accepts the unsigned file is recorded as a FINDING; a refusal fails the run.
RPM_FLOW = r"""
cp /dist/@PKG@ /tmp/@PKG@
cp /dist/@PKG2@ /tmp/@PKG2@
chmod 644 /tmp/@PKG@ /tmp/@PKG2@
stub_systemctl
# An unsigned local package must install with the defaults: no option turns the signature
# check off, so what users of the unsigned .rpm must do is recorded from this run.
if dnf install -y -q --setopt=install_weak_deps=False /tmp/@PKG@ > /tmp/dnf.out 2>&1; then
    echo "FINDING: @IMAGE@ ($(rpm --version)) installed the unsigned rpm with its defaults"
else
    echo "FINDING: @IMAGE@ ($(rpm --version)) refused the unsigned rpm with its defaults:"
    head -n 12 /tmp/dnf.out
    exit 1
fi
check_installed
uid=$(id -u nerva)
make_state
if rpm -U --replacepkgs /tmp/@PKG@ > /tmp/rpm.out 2>&1; then
    echo "FINDING: @IMAGE@ rpm -U installed the unsigned rpm with its defaults"
else
    echo "FINDING: @IMAGE@ rpm -U refused the unsigned rpm with its defaults: $(head -n 2 /tmp/rpm.out | tr '\n' ' ')"
    rpm -U --replacepkgs --nosignature /tmp/@PKG@
    echo "FINDING: @IMAGE@ rpm -U --nosignature installed it"
fi
check_state
echo "reinstall kept the data, the settings, the user and the enabled replica"
mkdir -p /etc/systemd/system
touch /etc/systemd/system/nerva@.service /usr/local/bin/nerva
# No -q: dnf's quiet mode hides a scriptlet's stderr, and an operator who upgrades with dnf must see
# the warning. The dnf logs are searched too, and the output is printed when the warning is missing.
if ! dnf install -y --setopt=install_weak_deps=False /tmp/@PKG2@ > /tmp/upgrade.out 2>&1; then
    cat /tmp/upgrade.out
    exit 1
fi
cat /tmp/upgrade.out /var/log/dnf*.log > /tmp/upgrade.all 2> /dev/null || true
if ! grep -q 'warning.NRV-W1101.: nerva package: /usr/local/bin/nerva exists' /tmp/upgrade.out; then
    echo "the upgrade did not show NRV-W1101; dnf printed:"
    cat /tmp/upgrade.out
    echo "the dnf logs have it: $(grep -c 'NRV-W1101' /tmp/upgrade.all)"
    exit 1
fi
[ "$(rpm -q --qf '%{VERSION}' nerva)" = "@VERSION2@" ]
check_state
rpm -U --oldpackage --nosignature /tmp/@PKG@
[ "$(rpm -q --qf '%{VERSION}' nerva)" = "@VERSION@" ]
rm /etc/systemd/system/nerva@.service /usr/local/bin/nerva
check_state
echo "upgrade to @VERSION2@ and downgrade back kept the data, the settings, the user and the enabled replica"
rpm -V nerva
rm $link
clear_state
check_installed
make_state
dnf remove -y -q nerva > /dev/null
check_removed
[ ! -L $link ]
grep -qx 'disable nerva@0.service' /tmp/systemctl.log
[ "$(cat /etc/nerva/replica-0.env)" = "NERVA_ADDRESSES=3001" ]
echo "remove left /var/lib/nerva, /etc/nerva and the user, and disabled the enabled replica"
"""

# Conflicts the package refuses before it unpacks anything: (label, setup, message, extra check).
E1105_CAUSE = "A user, group or unit named nerva exists and is not the one Nerva's installer makes"
E1111_CAUSE = ("A file that is not this package's (a tarball install, a source build or a full unit "
               "override) would shadow the package's binary or units")
E1111_FIX = ("if it is a tarball install, run install.sh --uninstall from the tarball (it keeps "
             "/var/lib/nerva, /etc/nerva and the user); otherwise move or remove the file (change a "
             "unit with a drop-in); then install the package")
FOREIGN = [
    ("a foreign user nerva", "useradd --system --home-dir /nonexistent nerva",
     "NRV-E1105", "nerva package: the user nerva exists, with home /nonexistent", E1105_CAUSE,
     "rename or remove that user, or give it the home /var/lib/nerva"),
    ("a user nerva with another primary group",
     "useradd --system --no-user-group --home-dir /var/lib/nerva --no-create-home nerva",
     "NRV-E1105", "nerva package: the user nerva exists, with primary group ", E1105_CAUSE,
     "give the user the primary group nerva (usermod -g nerva nerva), or remove the user"),
    ("a group nerva and no user", "groupadd nerva",
     "NRV-E1105", "nerva package: the group nerva exists, and the user nerva does not", E1105_CAUSE,
     "remove the group (groupdel nerva), or create the user nerva with it as primary group "
     "(useradd -g nerva ...)"),
    ("a tarball install's binary", "touch /usr/local/bin/nerva",
     "NRV-E1111", "nerva package: /usr/local/bin/nerva exists and is not this package's",
     E1111_CAUSE, E1111_FIX),
    ("a tarball install's unit", "mkdir -p /etc/systemd/system; touch /etc/systemd/system/nerva@.service",
     "NRV-E1111", "nerva package: /etc/systemd/system/nerva@.service exists and is not this package's",
     E1111_CAUSE, E1111_FIX),
]

DEB_FOREIGN = r"""
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null
cp /dist/@PKG@ /tmp/@PKG@
chmod 644 /tmp/@PKG@
@SETUP@
if apt-get install -y --no-install-recommends /tmp/@PKG@ > /tmp/out 2>&1; then
    echo "the install should have been refused"; exit 1
fi
"""

RPM_FOREIGN = r"""
cp /dist/@PKG@ /tmp/@PKG@
chmod 644 /tmp/@PKG@
@SETUP@
if dnf install -y --setopt=install_weak_deps=False /tmp/@PKG@ > /tmp/out 2>&1; then
    echo "the install should have been refused"; exit 1
fi
"""

# The message is asserted whole: the code and headline, the cause and the fix line. dnf prints a
# scriptlet's stderr in its output or its log, so both are searched.
FOREIGN_END = r"""
cat /tmp/out /var/log/dnf*.log /var/log/hawkey.log > /tmp/all 2> /dev/null || true
grep -qF "error[@CODE@]: @HEADLINE@" /tmp/all
grep -qF "  cause  @CAUSE@" /tmp/all
grep -qF "  fix    @FIX@" /tmp/all
grep -F "error[@CODE@]: @HEADLINE@" /tmp/all | head -n 1
[ ! -e /usr/bin/nerva ]
[ ! -e /usr/lib/systemd/system/nerva@.service ]
[ ! -d /var/lib/nerva ]
[ ! -d /etc/nerva ]
@AFTER@
echo "refused with @CODE@, nothing unpacked"
"""


def container(image, dist, repo, script, label):
    command = ["docker", "run", "--rm", "-v", f"{dist}:/dist:ro", "-v", f"{repo}/packaging/linux:/src:ro",
               image, "sh", "-eux", "-c", script]
    result = run(command, check=False)
    print(f"  [{image}] {label}")
    for line in result.stdout.strip().split("\n"):
        if line:
            print(f"    {line}")
    if result.returncode != 0:
        tail = "\n".join(result.stderr.strip().split("\n")[-60:])
        sys.exit(f"FAIL: {image} {label}: exit {result.returncode}\nstderr (last 60 lines):\n{tail}")


def containers(images, dist, repo, version, version2, require_line):
    for image in images:
        kind = IMAGES[image]
        name = ((lambda v: f"nerva_{file_version(v)}-1_amd64.deb") if kind == "deb"
                else (lambda v: f"nerva-{file_version(v)}-1.x86_64.rpm"))

        def fill(text, **extra):
            values = {"PKG": name(version), "PKG2": name(version2), "IMAGE": image, "VERSION": version, "BINVERSION": version.replace("~", "-"),
                      "VERSION2": version2, "REQUIRE": "1" if require_line else "0", **extra}
            for key, value in values.items():
                text = text.replace(f"@{key}@", value)
            return text

        flow = DEB_FLOW if kind == "deb" else RPM_FLOW
        container(image, dist, repo, fill(CHECKS + flow),
                  "install, reinstall, upgrade, downgrade, remove")
        for label, setup, code, headline, cause, fix in FOREIGN:
            after = "if getent passwd nerva > /dev/null; then exit 1; fi" if code == "NRV-E1111" else ""
            script = (DEB_FOREIGN if kind == "deb" else RPM_FOREIGN) + FOREIGN_END
            container(image, dist, repo,
                      fill(script, SETUP=setup, CODE=code, HEADLINE=headline, CAUSE=cause, FIX=fix, AFTER=after),
                      label)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("nerva")
    parser.add_argument("repository")
    parser.add_argument("--aarch64", required=True,
                        help="a release build for aarch64-linux (zig build -Drelease -Dtarget=aarch64-linux)")
    parser.add_argument("--version", default=None)
    parser.add_argument("--require-version-line", action="store_true",
                        help="nerva version must end in 'version N.N.N' (v0.7.1's slice 3)")
    parser.add_argument("--no-containers", action="store_true")
    parser.add_argument("--images", default=",".join(IMAGES))
    args = parser.parse_args()
    repo = os.path.realpath(args.repository)
    binaries = {"x86": os.path.realpath(args.nerva), "arm": os.path.realpath(args.aarch64)}
    release = args.version or read(f"{repo}/VERSION").decode().strip()
    # A prerelease's VERSION (0.7.1-rc.1) is the package version 0.7.1~rc.1 (#313).
    base, _, suffix = release.partition("-")
    major, minor, patch = base.split(".")
    version = base + (f"~{suffix}" if suffix else "")
    version2 = f"{major}.{minor}.{int(patch) + 1}"
    epoch = int(run(["git", "-C", repo, "log", "-1", "--format=%ct"]).stdout)
    tmp = tempfile.mkdtemp(prefix="nerva-packages-")
    try:
        print(f"rpmbuild: {run(['rpmbuild', '--version']).stdout.strip()}; "
              f"{run(['dpkg-deb', '--version']).stdout.split(chr(10))[0]}")
        print("0. the package script's first-install and upgrade modes (no build needed)")
        check_setup_modes(repo, tmp)
        print("1. built twice, the bytes equal")
        first = build(repo, binaries, version, f"{tmp}/a", epoch)
        second = build(repo, binaries, version, f"{tmp}/b", epoch, reproducibility_probe=True)
        check_reproducible(first, second)
        print("2. and 3. metadata, files, scripts, units")
        for deb, rpm in PACKAGES:
            check_deb(first[f"nerva_{file_version(version)}-1_{deb}.deb"], repo, binaries[BIN[deb]], version, deb, epoch, tmp)
            check_rpm(first[f"nerva-{file_version(version)}-1.{rpm}.rpm"], repo, binaries[BIN[rpm]], version, rpm, epoch, tmp)
        print("  ok")
        print("4. a binary for another architecture is refused")
        check_refusals(repo, binaries, version, tmp)
        check_prerelease(repo, binaries, tmp, epoch)
        if not args.no_containers:
            print("5. installed in containers")
            # The next patch version, from the same binary: what an upgrade installs over this one.
            build(repo, binaries, version2, f"{tmp}/a", epoch)
            containers(args.images.split(","), f"{tmp}/a", repo, version, version2, args.require_version_line)
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
