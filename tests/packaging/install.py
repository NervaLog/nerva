#!/usr/bin/env python3
"""The Linux tarball installs (docs/briefs/v0.7.1.md, slice 4).

Usage: sudo install.py <nerva> <packaging/linux directory>

Run as root on a machine booted with systemd (CI's ubuntu-24.04 runner): it changes /usr/local/bin,
/etc/nerva, /etc/systemd/system and /var/lib/nerva, and creates the user `nerva`. It stages a
tarball's contents, then checks, against the real units:
  1. `install.sh --dry-run` changes nothing;
  2. `install.sh` installs, and a second run changes nothing; both units pass `systemd-analyze verify`;
  3. every refusal, NRV-E1101 to NRV-E1109, with its code, exit status and three-line block; a
     fixed PATH; a dry run that does not chmod; NRV-W1102 (a package's /usr/bin/nerva); a symlinked
     /var/lib/nerva left alone;
  4. the gateway nerva-api@0 started while the cluster is down fails with NRV-E0604 and is restarted,
     and serves once three replicas, formatted as `nerva` and run as nerva@0..2, are up; a commit and a
     lookup; `systemctl kill -s KILL nerva@1` is restarted and catches up (a quorum of it and
     replica 2 commits while replica 0 is stopped);
  5. a replica imported from another export than its peers exits 8 (NRV-E0711) and systemd does not
     restart it;
  5b. `--upgrade` while the units run is refused with NRV-E1118 (also with --dry-run), and with a
      systemctl that cannot list them (NRV-E1102); not with only a failed unit; with only the gateway
      running; over a package's /usr/bin/nerva;
  5c. the unit restarts exit 1 (NRestarts), and its start limit ends the loop as `failed`;
  6. `install.sh --uninstall` removes the binary, the units and the enable links of the instances
     that were enabled, and leaves /var/lib/nerva.
Not provoked: a `nerva` on a noexec mount (a script that exits 1 stands for it in NRV-E1107).
"""
import http.client
import json
import os
import platform
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time

BIN = "/usr/local/bin/nerva"
UNIT_DIR = "/etc/systemd/system"
ETC = "/etc/nerva"
DATA = "/var/lib/nerva"
UNITS = ["nerva@.service", "nerva-api@.service"]
FILES = ["install.sh", "replica.env.example", "api.env.example"] + UNITS
KEY = "packaging-test-gateway-key-0123456789"
CLUSTER_KEY = os.urandom(32).hex()
TABLE = 3
NOT_OURS = "A user, group or unit named nerva exists and is not the one Nerva's installer makes"
STATUS_ORIGIN_MISMATCH = 8


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def free_ports(count):
    sockets = [socket.socket() for _ in range(count)]
    for s in sockets:
        s.bind(("127.0.0.1", 0))
    ports = [s.getsockname()[1] for s in sockets]
    for s in sockets:
        s.close()
    return ports


def sha256(path):
    return sh(["sha256sum", path]).stdout.split()[0]


def snapshot():
    """Every path the installer owns or may touch, with what a change would alter."""
    seen = {}
    roots = [BIN] + [f"{UNIT_DIR}/{u}" for u in UNITS] + [ETC, DATA]
    for root in roots:
        for base, dirs, files in os.walk(root) if os.path.isdir(root) else [(None, [], [])]:
            for name in dirs + files:
                path = os.path.join(base, name)
                seen[path] = entry(path)
        if os.path.lexists(root):
            seen[root] = entry(root)
    seen["passwd"] = sh(["getent", "passwd", "nerva"]).stdout
    return seen


def entry(path):
    st = os.lstat(path)
    digest = sha256(path) if stat.S_ISREG(st.st_mode) and not path.startswith(DATA) else ""
    return (st.st_mode, st.st_uid, st.st_gid, st.st_mtime_ns, digest)


def installer(stage, *args, user=None, expect=0):
    command = ["sh", os.path.join(stage, "install.sh")] + list(args)
    if user:
        command = ["runuser", "-u", user, "--"] + command
    result = sh(command)
    assert result.returncode == expect, (args, result.returncode, expect, result.stdout, result.stderr)
    return result


def refused(result, status, code, summary):
    """One coded block, as `nerva` prints: a headline, the code's summary as the cause, a fix."""
    lines = result.stderr.strip().split("\n")
    assert result.returncode == status, (result.returncode, result.stderr)
    assert len(lines) == 3, result.stderr
    assert lines[0].startswith(f"error[{code}]: install.sh: "), lines[0]
    assert lines[1] == f"  cause  {summary}", lines[1]
    assert lines[2].startswith("  fix    "), lines[2]
    assert "error." not in result.stderr and "Traceback" not in result.stderr, result.stderr


def stage_tarball(packaging, nerva, tmp, name, extra=b""):
    stage = os.path.join(tmp, name)
    os.mkdir(stage)
    os.chmod(stage, 0o755)
    for file in FILES:
        shutil.copy(os.path.join(packaging, file), stage)
    shutil.copy(nerva, os.path.join(stage, "nerva"))
    if extra:
        with open(os.path.join(stage, "nerva"), "ab") as f:
            f.write(extra)
    os.chmod(os.path.join(stage, "nerva"), 0o755)
    os.chmod(os.path.join(stage, "install.sh"), 0o755)
    return stage


def systemctl(*args):
    return sh(["systemctl"] + list(args))


def show(unit, *properties):
    out = systemctl("show", unit, "--no-pager", *[f"--property={p}" for p in properties]).stdout
    return dict(line.split("=", 1) for line in out.strip().split("\n"))


def wait(what, condition, seconds=60):
    deadline = time.monotonic() + seconds
    while True:
        value = condition()
        if value:
            return value
        assert time.monotonic() < deadline, f"timed out: {what}"
        time.sleep(0.2)


def listening(port):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=1).close()
        return True
    except OSError:
        return False


def write_env(path, text):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, 0o600)


def replica_env(index, addresses):
    write_env(f"{ETC}/replica-{index}.env",
              f"NERVA_ADDRESSES={addresses}\nNERVA_CLUSTER_KEY={CLUSTER_KEY}\n"
              f"NERVA_DATA_FILE={DATA}/{index}.nerva\nNERVA_FLAGS=\n")


def prepare_replicas(addresses, exports=None):
    """Writes the env files and creates each data file as the nerva user: formatted, or imported
    from exports[index]."""
    for index in range(3):
        replica_env(index, addresses)
        path = f"{DATA}/{index}.nerva"
        if os.path.exists(path):
            os.remove(path)
        if exports is None:
            args = ["format", "--cluster=1", f"--replica={index}", "--replica-count=3", path]
        else:
            args = ["import", "--cluster=1", f"--replica={index}", "--replica-count=3",
                    f"--input={exports[index]}", path]
        done = sh(["runuser", "-u", "nerva", "--", BIN] + args)
        assert done.returncode == 0, (args, done.stderr[-2000:])


def request(port, method, target, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    try:
        connection.request(method, target, body=None if body is None else json.dumps(body),
                           headers={"X-Nerva-Key": KEY})
        response = connection.getresponse()
        return response.status, json.loads(response.read() or b"null")
    finally:
        connection.close()


def put(port, id, seconds=120):
    body = {"entries": [{"kind": "put", "table": TABLE, "id": str(id), "value_hex": f"{id:016x}"}]}
    deadline = time.monotonic() + seconds
    while True:
        try:
            status, reply = request(port, "POST", "/v1/commit", body)
            if status == 200:
                return int(reply["op"])
            assert status == 503, (status, reply)
        except (TimeoutError, ConnectionError, http.client.HTTPException):
            pass
        assert time.monotonic() < deadline, f"put {id} never committed"
        time.sleep(0.2)


def lookup(port, id):
    status, reply = request(port, "POST", "/v1/lookup", {"rows": [{"table": TABLE, "id": str(id)}]})
    assert status == 200 and reply["rows"][0]["exists"], (status, reply)


def stop_all():
    systemctl("stop", "nerva-api@*", "nerva@*")
    systemctl("reset-failed")


def test_early_refusals(stage):
    """Refusals that need no installed state: usage, and a group nerva without the user."""
    usage = "install.sh was given a flag or a combination of flags it does not take"
    refused(installer(stage, "--no-such-flag", expect=1), 1, "NRV-E1106", usage)
    refused(installer(stage, "--upgrade", "--uninstall", expect=1), 1, "NRV-E1106", usage)
    assert sh(["groupadd", "nerva"]).returncode == 0
    try:
        for args in ([], ["--dry-run"]):
            refused(installer(stage, *args, expect=1), 1, "NRV-E1105", NOT_OURS)
    finally:
        assert sh(["groupdel", "nerva"]).returncode == 0
    assert sh(["getent", "passwd", "nerva"]).returncode != 0


def test_dry_run_and_install(stage):
    before = snapshot()
    result = installer(stage, "--dry-run")
    assert "would" in result.stdout and "nothing was changed" in result.stdout, result.stdout
    assert snapshot() == before, "--dry-run changed something"
    assert sh(["getent", "passwd", "nerva"]).returncode != 0

    result = installer(stage)
    assert "installed: Nerva version" in result.stdout, result.stdout
    assert "systemctl enable --now nerva@0" in result.stdout, result.stdout
    assert f"runuser -u nerva -- {BIN} format" in result.stdout, result.stdout
    assert sha256(BIN) == sha256(f"{stage}/nerva")
    for unit in UNITS:
        assert sha256(f"{UNIT_DIR}/{unit}") == sha256(f"{stage}/{unit}"), unit
    for example in ["replica.env.example", "api.env.example"]:
        assert os.path.exists(f"{ETC}/{example}"), example
    assert stat.S_IMODE(os.stat(DATA).st_mode) == 0o750 and stat.S_IMODE(os.stat(ETC).st_mode) == 0o750
    passwd = sh(["getent", "passwd", "nerva"]).stdout.split(":")
    assert passwd[5] == DATA and passwd[6].strip().endswith("nologin"), passwd
    assert systemctl("is-enabled", "nerva@0").stdout.strip() != "enabled"
    assert systemctl("is-active", "nerva@0").stdout.strip() == "inactive"
    assert os.listdir(DATA) == [], "install.sh formatted or created something in the data directory"

    after = snapshot()
    again = installer(stage)
    assert snapshot() == after, "a second install.sh changed something"
    assert "installed:" in again.stdout and "install /" not in again.stdout, again.stdout


def test_refusals(packaging, nerva, tmp, stage):
    refused(installer(stage, user="nobody", expect=1), 1, "NRV-E1101",
            "The installer was not run as root")
    refused(installer(stage, "--dry-run", user="nobody", expect=1), 1, "NRV-E1101",
            "The installer was not run as root")

    # No systemd: an Ubuntu container, which has none, runs the same script.
    pulled = sh(["docker", "pull", "--quiet", "ubuntu:24.04"])
    assert pulled.returncode == 0, pulled.stderr
    container = sh(["docker", "run", "--rm", "-v", f"{stage}:/stage:ro", "ubuntu:24.04",
                    "sh", "/stage/install.sh"])
    refused(container, 2, "NRV-E1102", "The installer found no running systemd")
    # The other half: a `systemctl` on the path, and no /run/systemd/system.
    stub = sh(["docker", "run", "--rm", "-v", f"{stage}:/stage:ro", "ubuntu:24.04", "sh", "-c",
               "printf '#!/bin/sh\\nexit 0\\n' > /usr/bin/systemctl && chmod 755 /usr/bin/systemctl"
               " && test ! -d /run/systemd/system && sh /stage/install.sh"])
    refused(stub, 2, "NRV-E1102", "The installer found no running systemd")

    # A nerva that does not run on this machine: not an ELF, so no architecture to blame.
    broken = stage_tarball(packaging, nerva, tmp, "broken")
    with open(f"{broken}/nerva", "w") as f:
        f.write("#!/bin/sh\nexit 1\n")
    refused(installer(broken, expect=2), 2, "NRV-E1107",
            "This machine cannot run the tarball's nerva, though it is for this architecture")
    # The other architecture's ELF header, which no host runs (or an emulator would).
    foreign = stage_tarball(packaging, nerva, tmp, "foreign")
    with open(f"{foreign}/nerva", "r+b") as f:
        f.seek(18)
        f.write(b"\xb7\x00" if platform.machine() == "x86_64" else b"\x3e\x00")
    refused(installer(foreign, expect=2), 2, "NRV-E1104",
            "The tarball's nerva is for another architecture than this machine's")
    incomplete = "The tarball is incomplete, or install.sh was run outside the unpacked tarball"
    missing = stage_tarball(packaging, nerva, tmp, "missing")
    os.remove(f"{missing}/nerva-api@.service")
    refused(installer(missing, expect=1), 1, "NRV-E1108", incomplete)
    os.remove(f"{missing}/nerva")
    refused(installer(missing, "--dry-run", expect=1), 1, "NRV-E1108", incomplete)
    # No sha256sum: the script fixes its PATH, so the program itself is hidden, in a mount
    # namespace of its own (a file with no execute bit is not found by `command -v`).
    program = os.path.realpath(shutil.which("sha256sum"))
    hidden = sh(["unshare", "-m", "sh", "-c", f"mount --bind /dev/null {program} && exec sh {stage}/install.sh"])
    refused(hidden, 2, "NRV-E1109",
            "The installer needs sha256sum, and this machine has none on its PATH")
    assert os.access(program, os.X_OK), "the hidden sha256sum leaked out of its mount namespace"
    # The caller's PATH is not trusted: an `id` that says "not root" first on it changes nothing.
    fake = os.path.join(tmp, "evil-path")
    os.mkdir(fake)
    with open(f"{fake}/id", "w") as f:
        f.write("#!/bin/sh\necho 1000\n")
    os.chmod(f"{fake}/id", 0o755)
    trusted = sh(["sh", f"{stage}/install.sh", "--dry-run"], env={"PATH": fake + ":/usr/bin:/bin"})
    assert trusted.returncode == 0 and "nothing was changed" in trusted.stdout, (trusted.stdout, trusted.stderr)
    # Nor is CDPATH: run by a relative path, `cd stage` would search it first (and print where it
    # went), and find the empty directory of that name there.
    decoy = os.path.join(tmp, "cdpath")
    os.makedirs(os.path.join(decoy, os.path.basename(stage)))
    relative = sh(["sh", f"{os.path.basename(stage)}/install.sh", "--dry-run"], cwd=tmp,
                  env={"PATH": "/usr/bin:/bin", "CDPATH": decoy})
    assert relative.returncode == 0 and "nothing was changed" in relative.stdout, (relative.stdout, relative.stderr)
    # A dry run does not chmod the tarball's nerva (and says it cannot run it).
    plain = stage_tarball(packaging, nerva, tmp, "plain")
    os.chmod(f"{plain}/nerva", 0o644)
    done = installer(plain, "--dry-run")
    assert "would make" in done.stdout and "executable" in done.stdout, done.stdout
    assert stat.S_IMODE(os.stat(f"{plain}/nerva").st_mode) == 0o644, "--dry-run changed the mode"
    # A package's /usr/bin/nerva: warned about, on a real run and a dry run, and the install goes on.
    assert not os.path.exists("/usr/bin/nerva"), "a package's nerva is installed here"
    shutil.copy(nerva, "/usr/bin/nerva")
    try:
        for args in (["--dry-run"], []):
            done = installer(stage, *args)
            lines = done.stderr.strip().split("\n")
            assert len(lines) == 3 and lines[0].startswith(
                "warning[NRV-W1102]: install.sh: /usr/bin/nerva exists and /usr/local/bin/nerva shadows it"), done.stderr
            assert lines[1].startswith("  cause  ") and lines[2].startswith("  fix    "), done.stderr
    finally:
        os.remove("/usr/bin/nerva")
    assert installer(stage).stderr == "", "a warning without a /usr/bin/nerva"
    # A /var/lib/nerva that is a symlink to a directory the installer would make is left alone.
    real = f"{DATA}.real"
    os.rename(DATA, real)
    os.symlink(real, DATA)
    try:
        done = installer(stage)
        assert f"make {DATA}" not in done.stdout and os.path.islink(DATA), done.stdout
    finally:
        os.remove(DATA)
        os.rename(real, DATA)

    # A different nerva is installed: refused, unchanged, then replaced by --upgrade.
    other = stage_tarball(packaging, nerva, tmp, "other", extra=b"\0")
    before = snapshot()
    refused(installer(other, expect=1), 1, "NRV-E1103", "A different nerva is already installed")
    refused(installer(other, "--dry-run", expect=1), 1, "NRV-E1103",
            "A different nerva is already installed")
    assert snapshot() == before, "a refused install changed something"
    installer(other, "--upgrade")
    assert sha256(BIN) == sha256(f"{other}/nerva")
    installer(stage, "--upgrade")
    assert sha256(BIN) == sha256(f"{stage}/nerva")

    # A user or a unit that is not ours.
    assert sh(["usermod", "--home", "/home/nerva-other", "nerva"]).returncode == 0
    refused(installer(stage, expect=1), 1, "NRV-E1105", NOT_OURS)
    assert sh(["usermod", "--home", DATA, "nerva"]).returncode == 0
    # A primary group that is not nerva's own.
    assert sh(["groupadd", "nerva-other"]).returncode == 0
    assert sh(["usermod", "--gid", "nerva-other", "nerva"]).returncode == 0
    refused(installer(stage, expect=1), 1, "NRV-E1105", NOT_OURS)
    refused(installer(stage, "--dry-run", expect=1), 1, "NRV-E1105", NOT_OURS)
    assert sh(["usermod", "--gid", "nerva", "nerva"]).returncode == 0
    assert sh(["groupdel", "nerva-other"]).returncode == 0
    path = f"{UNIT_DIR}/nerva-api@.service"
    shutil.copy(path, f"{tmp}/api-unit.saved")
    with open(path, "w") as f:
        f.write("[Service]\nExecStart=/bin/true\n")
    refused(installer(stage, expect=1), 1, "NRV-E1105", NOT_OURS)
    shutil.copy(f"{tmp}/api-unit.saved", path)
    installer(stage)


def test_upgrade_while_running(packaging, nerva, tmp, stage):
    """Replicas and the gateway are running: --upgrade of another nerva is refused, and changes nothing."""
    other = stage_tarball(packaging, nerva, tmp, "other-running", extra=b"\0")
    before = snapshot()
    for args in ([ "--upgrade"], ["--upgrade", "--dry-run"]):
        result = installer(other, *args, expect=1)
        refused(result, 1, "NRV-E1118", "install.sh found a replica or gateway unit running, "
                "and would replace the nerva it executes")
        assert "nerva@0.service" in result.stderr and "nerva-api@0.service" in result.stderr, result.stderr
    assert snapshot() == before and sha256(BIN) == sha256(f"{stage}/nerva")
    # The same nerva is no replacement: nothing to refuse.
    assert "installed:" in installer(stage, "--upgrade").stdout
    # A systemctl that cannot list the units: the check cannot tell, so it refuses (exit 2).
    program = os.path.realpath(shutil.which("systemctl"))
    stub = os.path.join(tmp, "systemctl-stub")
    with open(stub, "w") as f:
        f.write("#!/bin/sh\necho 'Failed to connect to bus' >&2\nexit 1\n")
    os.chmod(stub, 0o755)
    broken = sh(["unshare", "-m", "sh", "-c",
                 f"mount --bind {stub} {program} && exec sh {other}/install.sh --upgrade --dry-run"])
    refused(broken, 2, "NRV-E1102", "The installer found no running systemd")
    assert "could not list the nerva units" in broken.stderr, broken.stderr
    assert os.access(program, os.X_OK) and sh([program, "--version"]).returncode == 0, "the stub leaked"


def test_upgrade_quiet_and_gateway(packaging, nerva, tmp, stage):
    """E1118 is quiet on a failed unit, refuses with only the gateway running, and covers a package's
    /usr/bin/nerva. Everything is --dry-run: no state changes."""
    other = stage_tarball(packaging, nerva, tmp, "other-quiet", extra=b"\0")
    assert show("nerva@9", "ActiveState")["ActiveState"] == "failed", "test_restart_policy leaves nerva@9 failed"
    assert "nothing was changed" in installer(other, "--upgrade", "--dry-run").stdout
    assert systemctl("start", "nerva-api@0").returncode == 0
    try:
        wait("the gateway is activating or active",
             lambda: show("nerva-api@0", "ActiveState")["ActiveState"] in ("active", "activating"))
        result = installer(other, "--upgrade", "--dry-run", expect=1)
        refused(result, 1, "NRV-E1118", "install.sh found a replica or gateway unit running, "
                "and would replace the nerva it executes")
        assert result.stderr.split("\n")[0].endswith("units are running: nerva-api@0.service"), result.stderr
        # No tarball install, a package's /usr/bin/nerva that differs: the units would run the
        # tarball's nerva from /usr/local/bin first, so a running unit refuses without --upgrade.
        assert not os.path.exists("/usr/bin/nerva")
        os.rename(BIN, f"{tmp}/nerva.saved")
        shutil.copy(f"{tmp}/nerva.saved", "/usr/bin/nerva")
        with open("/usr/bin/nerva", "ab") as f:
            f.write(b"\0")
        try:
            result = installer(stage, "--dry-run", expect=1)
            refused(result, 1, "NRV-E1118", "install.sh found a replica or gateway unit running, "
                    "and would replace the nerva it executes")
            assert "over /usr/bin/nerva" in result.stderr, result.stderr
        finally:
            os.remove("/usr/bin/nerva")
            os.rename(f"{tmp}/nerva.saved", BIN)
    finally:
        assert systemctl("stop", "nerva-api@0").returncode == 0


def test_restart_policy(tmp):
    """The unit's restart policy under systemd: exit 1 restarts, and a start limit ends it."""
    unit = "nerva@9"
    shipped = show(unit, "StartLimitBurst", "StartLimitIntervalUSec", "RestartUSec", "Restart")
    assert shipped == {"StartLimitBurst": "20", "StartLimitIntervalUSec": "5min", "RestartUSec": "5s",
                       "Restart": "on-failure"}, shipped
    # A data file that does not exist is exit 1 (NRV-E0006). Only the delay is shortened here.
    dropin = f"{UNIT_DIR}/{unit}.service.d"
    os.makedirs(dropin)
    write_env(f"{dropin}/fast.conf", "[Service]\nRestartSec=100ms\n")
    os.chmod(f"{dropin}/fast.conf", 0o644)
    write_env(f"{ETC}/replica-9.env",
              f"NERVA_ADDRESSES=127.0.0.1:1\nNERVA_CLUSTER_KEY={CLUSTER_KEY}\n"
              f"NERVA_DATA_FILE={DATA}/missing-9.nerva\nNERVA_FLAGS=\n")
    assert systemctl("daemon-reload").returncode == 0
    try:
        assert systemctl("start", unit).returncode == 0
        wait("the start limit stops the unit", lambda: show(unit, "ActiveState")["ActiveState"] == "failed")
        state = show(unit, "Result", "ExecMainStatus", "NRestarts")
        assert state["Result"] == "start-limit-hit", state
        assert state["ExecMainStatus"] == "1" and int(state["NRestarts"]) >= 10, state
    finally:
        shutil.rmtree(dropin)
        os.remove(f"{ETC}/replica-9.env")
        assert systemctl("daemon-reload").returncode == 0


def test_cluster(tmp):
    ports = free_ports(4)
    addresses = ",".join(f"127.0.0.1:{p}" for p in ports[:3])
    prepare_replicas(addresses)
    write_env(f"{ETC}/api-0.env",
              f"NERVA_CLUSTER=1\nNERVA_ADDRESSES={addresses}\nNERVA_KEY={KEY}\n"
              f"NERVA_LISTEN=127.0.0.1:{ports[3]}\nNERVA_FLAGS=\n")
    for unit in ["nerva@0.service", "nerva-api@0.service"]:
        verified = sh(["systemd-analyze", "verify", unit])
        assert verified.returncode == 0 and not verified.stderr.strip(), (unit, verified.stderr)

    # The gateway starts while the cluster is down. After its 30 s registration timeout it exits 1
    # with NRV-E0604, and the unit must restart it (a restart is what cures it).
    assert systemctl("start", "nerva-api@0").returncode == 0
    wait("the gateway gives up on the cluster and is restarted",
         lambda: int(show("nerva-api@0", "NRestarts")["NRestarts"]) >= 1, seconds=120)
    log = sh(["journalctl", "-u", "nerva-api@0", "--no-pager"]).stdout
    assert "NRV-E0604" in log, log[-2000:]
    assert show("nerva-api@0", "ActiveState")["ActiveState"] != "failed"
    for index in range(3):
        assert systemctl("start", f"nerva@{index}").returncode == 0
    for index in range(3):
        wait(f"replica {index} listens", lambda i=index: listening(ports[i]))
    api = ports[3]
    wait("the gateway comes up once the cluster does", lambda: listening(api), seconds=120)
    for unit in ["nerva@0", "nerva@1", "nerva@2", "nerva-api@0"]:
        assert systemctl("is-active", unit).stdout.strip() == "active", unit
    assert "User=nerva" in systemctl("cat", "nerva@0").stdout

    put(api, 1)
    lookup(api, 1)

    # SIGKILL of replica 1: systemd restarts it, and it rejoins and catches up. Replica 0 stops
    # afterwards, so replica 1 must be in the quorum that commits the next ops.
    old_pid = show("nerva@1", "MainPID")["MainPID"]
    assert systemctl("kill", "-s", "KILL", "nerva@1").returncode == 0
    for id in range(2, 8):
        put(api, id)
    wait("systemd restarts replica 1",
         lambda: show("nerva@1", "ActiveState", "MainPID")["ActiveState"] == "active"
         and show("nerva@1", "MainPID")["MainPID"] not in ("0", old_pid))
    assert int(show("nerva@1", "NRestarts")["NRestarts"]) >= 1
    wait("replica 1 listens again", lambda: listening(ports[1]))
    time.sleep(3)
    assert systemctl("stop", "nerva@0").returncode == 0
    for id in range(8, 14):
        put(api, id)
    for id in (1, 7, 13):
        lookup(api, id)
    assert systemctl("start", "nerva@0").returncode == 0
    return addresses, api


def test_origin_mismatch(tmp, addresses, api):
    """Replica 0 imported from export B, replicas 1 and 2 from export A: exit 8, no restart."""
    exports = []
    for name in "ab":
        path = f"{tmp}/{name}.nerva-export"
        done = sh([BIN, "export", "--cluster=1", f"--addresses={addresses}", f"--output={path}"],
                  env={**os.environ, "NERVA_CLUSTER_KEY": CLUSTER_KEY})
        assert done.returncode == 0, done.stderr[-2000:]
        os.chmod(path, 0o644)
        exports.append(path)
        for id in range(100, 110) if name == "a" else []:
            put(api, id)
    stop_all()
    ports = free_ports(3)
    addresses = ",".join(f"127.0.0.1:{p}" for p in ports)
    prepare_replicas(addresses, exports=[exports[1], exports[0], exports[0]])
    for index in range(3):
        assert systemctl("start", f"nerva@{index}").returncode == 0
    wait("replica 0 stops", lambda: show("nerva@0", "ActiveState")["ActiveState"] == "failed")
    time.sleep(8)  # Longer than RestartSec (5 s): a restart would show by now.
    state = show("nerva@0", "ActiveState", "Result", "ExecMainStatus", "NRestarts")
    assert state["ActiveState"] == "failed" and state["Result"] == "exit-code", state
    assert int(state["ExecMainStatus"]) == STATUS_ORIGIN_MISMATCH, state
    assert int(state["NRestarts"]) == 0, state
    log = sh(["journalctl", "-u", "nerva@0", "--no-pager"]).stdout
    assert "NRV-E0711" in log, log[-2000:]
    for index in (1, 2):
        assert systemctl("is-active", f"nerva@{index}").stdout.strip() == "active", index
    stop_all()


def test_uninstall(stage):
    for instance in ("nerva@0", "nerva@1", "nerva-api@0"):
        assert systemctl("enable", instance).returncode == 0
    links = [f"{UNIT_DIR}/multi-user.target.wants/{i}.service" for i in ("nerva@0", "nerva@1", "nerva-api@0")]
    assert all(os.path.islink(link) for link in links), links
    before = {p: v for p, v in snapshot().items() if p.startswith(DATA) or p.startswith(ETC)}
    assert os.listdir(DATA), "the data directory should hold the data files by now"
    result = installer(stage, "--uninstall", "--dry-run")
    assert "would remove" in result.stdout and "would disable nerva@0.service" in result.stdout
    assert os.path.exists(BIN) and all(os.path.islink(link) for link in links)
    result = installer(stage, "--uninstall")
    assert "disable nerva-api@0.service" in result.stdout, result.stdout
    assert not any(os.path.lexists(link) for link in links), "--uninstall left an enable link"
    assert not os.path.exists(BIN)
    assert not any(os.path.exists(f"{UNIT_DIR}/{u}") for u in UNITS)
    after = {p: v for p, v in snapshot().items() if p.startswith(DATA) or p.startswith(ETC)}
    assert after == before, "--uninstall touched the data or the settings"
    assert sh(["getent", "passwd", "nerva"]).returncode == 0
    assert "nothing to remove" in installer(stage, "--uninstall").stdout


def main():
    nerva, packaging = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    assert os.geteuid() == 0, "run as root"
    assert os.path.isdir("/run/systemd/system"), "run on a machine booted with systemd"
    assert not os.path.exists(BIN) and not os.path.exists(f"{UNIT_DIR}/nerva@.service"), \
        "a nerva is already installed here: run on a clean machine"
    tmp = tempfile.mkdtemp(prefix="nerva-packaging-")
    os.chmod(tmp, 0o755)
    started = time.monotonic()
    try:
        stage = stage_tarball(packaging, nerva, tmp, "stage")
        test_early_refusals(stage)
        test_dry_run_and_install(stage)
        print("ok: --dry-run changes nothing; install; a second install changes nothing")
        test_refusals(packaging, nerva, tmp, stage)
        print("ok: NRV-E1101 to NRV-E1109, and --upgrade")
        addresses, api = test_cluster(tmp)
        print("ok: a gateway outlives a down cluster; three replicas under systemd; a commit; SIGKILL restarts")
        test_upgrade_while_running(packaging, nerva, tmp, stage)
        print("ok: --upgrade while the units run is refused with NRV-E1118")
        test_origin_mismatch(tmp, addresses, api)
        print("ok: a wrong-origin replica exits 8 and is not restarted")
        test_restart_policy(tmp)
        print("ok: exit 1 restarts, and 20 starts in 300 s end as failed")
        test_upgrade_quiet_and_gateway(packaging, nerva, tmp, stage)
        print("ok: NRV-E1118 is quiet on a failed unit, and refuses for a gateway or a package's nerva")
        test_uninstall(stage)
        print("ok: --uninstall removes the enable links and leaves /var/lib/nerva")
        print(f"packaging: PASS in {time.monotonic() - started:.0f} s")
    except BaseException:
        stop_all()
        print(sh(["journalctl", "-u", "nerva@*", "-u", "nerva-api@*", "--no-pager", "-n", "80"]).stdout,
              file=sys.stderr)
        raise
    finally:
        stop_all()
        shutil.rmtree(tmp, ignore_errors=True)
        for index in range(3):
            for path in (f"{DATA}/{index}.nerva",):
                if os.path.exists(path):
                    os.remove(path)


if __name__ == "__main__":
    main()
