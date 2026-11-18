#!/usr/bin/env python3
"""Every coded failure a `nerva` command can report, from the real binary (R5, P147c).

Usage: commands.py <nerva> [<nerva built with -Dtest-commit-keys=off>]

For each code a command emits (docs/ERRORS.md, 00xx, 06xx, 08xx, 09xx), triggers it and checks
the first line (`error[NRV-…]: …`), the `cause` and `fix` lines, the exit status, and that no
stack trace and no raw Zig error name (`error.Name`) is printed. NRV-E0701 and E0718 are here for the keys-off build's file and, for two real releases, in
`tests/release/mixed.py` (it needs a binary of another release), NRV-E0609 for the keys-off
build's clients against a release cluster (E0610 has a unit test only: no build here runs below
`release_client_min`), NRV-E0704 and E0705 need a file system without direct IO and a kernel older than 5.11, so only unit tests of
`src/nerva/preflight.zig` cover their parts. Codes that need a failing disk
or an export whose checks fail (NRV-E0706, E0708, E0803, E0807) are covered by unit tests of
`src/nerva/diagnostic.zig` only.
"""
import fcntl
import hashlib
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "api"))
from api import Cluster  # noqa: E402

KEY = "errors-test-key-0123456789abcdef0123456789"
# `start --statsd=<unsendable>` (#198, P427): the NRV-W0733 line lands about 20 s after open (two
# 10 s emits), so wait up to this long for it, then stay up this long (two more emits) to count.
STATSD_WARN_DEADLINE_S = 90
STATSD_QUIET_S = 25
# The format digest of a `nerva` build (R6, P259b): what `nerva version` prints. It moves with any
# change to a wire or storage layout (the state machine's, the message headers', the superblock's),
# a tree id, the cluster config, the superblock version, the outputs of the pure key and id
# derivations or `format_epoch` (src/nerva/format_digest.zig), and only then. Update it with the decision that
# says what changed (docs/decisions/), beside `format_test.zig`'s snapshot.
FORMAT_DIGEST = "a2d6e50b122836b2b596f8548a391e77c3b2beead93ee5e30939479601259362"
# The last line of `version` names the release, read from `VERSION` at build time (v0.7.1, P284).
# The format digest does not include it: two builds of one commit under different `VERSION`s are
# one protocol.
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "VERSION")) as f:
    RELEASE_VERSION = f.read().strip()
VERSION_FIRST = re.compile(r"Nerva version (\d+\.\d+\.\d+)(\+[0-9a-f]{7})?(\+keys-off)?")
RAW_NAME = re.compile(r"\berror\.[A-Z][A-Za-z0-9]+")
LOG_LINE = re.compile(r"\d{4}-\d\d-\d\d ")
TRACE = re.compile(r"panic|Stack trace|thread \d+|\.zig:\d+")


def run(nerva, argv, env=None, timeout=120):
    environment = {k: v for k, v in os.environ.items() if not k.startswith("NERVA_")}
    environment.update(env or {})
    return subprocess.run([nerva] + argv, capture_output=True, text=True, timeout=timeout,
                          env=environment)


def diagnostic_lines(result):
    return [line for line in result.stderr.splitlines()
            if re.match(r"(error|bug)\[NRV-", line)]


def expect(result, code, status, text, label):
    assert result.returncode == status, (label, result.returncode, result.stderr[-2000:])
    lines = diagnostic_lines(result)
    assert len(lines) == 1, (label, result.stderr[-2000:])
    assert lines[0].startswith(f"error[{code}]: ") or lines[0].startswith(f"bug[{code}]: "), \
        (label, lines[0])
    assert text in lines[0], (label, lines[0])
    assert "  cause  " in result.stderr and "  fix    " in result.stderr, (label, result.stderr)
    # What the command itself printed: not the vendored message bus's timestamped log lines,
    # which say `error.ConnectionRefused` while it retries.
    printed = "\n".join(line for line in result.stderr.splitlines()
                        if not LOG_LINE.match(line))
    assert not RAW_NAME.search(printed), (label, printed[-2000:])
    assert not TRACE.search(printed), (label, printed[-2000:])
    return code


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: commands.py <nerva> <nerva-keys-off> "
                 "(the second is the -Dtest-commit-keys=off build, for NRV-E0717 and NRV-W0701)")
    nerva = os.path.abspath(sys.argv[1])
    nerva_off = os.path.abspath(sys.argv[2])
    tmp = tempfile.mkdtemp(prefix="nerva-errors-")
    seen = []

    def check(label, argv, code, status, text, env=None, timeout=120, nerva=nerva):
        seen.append(expect(run(nerva, argv, env, timeout), code, status, text, label))

    try:
        data = os.path.join(tmp, "a.nerva")
        fmt = ["format", "--cluster=0", "--replica=0", "--replica-count=3", "--development"]
        assert run(nerva, fmt + [data]).returncode == 0
        check("format twice", fmt + [data], "NRV-E0005", 1, "exists")
        check("replica out of range",
              ["format", "--cluster=0", "--replica=3", "--replica-count=3", "--development",
               os.path.join(tmp, "b.nerva")], "NRV-E0002", 1, "--replica must be less")
        check("replica count zero",
              ["format", "--cluster=0", "--replica=0", "--replica-count=0", "--development",
               os.path.join(tmp, "b.nerva")], "NRV-E0002", 1, "greater than zero")
        for command in ("api", "view"):
            check(f"{command} listen", [command, "--cluster=0", "--addresses=127.0.0.1:1",
                                        "--listen=bogus"], "NRV-E0003", 1, "--listen must be",
                  env={"NERVA_KEY": KEY})
            for listen in ("0.0.0.0:0", "[::]:0", "10.0.0.1:0", "[::ffff:127.0.0.1]:0"):
                check(f"{command} listen {listen}", [command, "--cluster=0",
                                                     "--addresses=127.0.0.1:1",
                                                     f"--listen={listen}"], "NRV-E0009", 1,
                      "is not loopback", env={"NERVA_KEY": KEY})
            for milliseconds in ("999", "60001"):
                check(f"{command} request timeout {milliseconds}",
                      [command, "--cluster=0", "--addresses=127.0.0.1:1", "--listen=127.0.0.1:0",
                       f"--request-timeout={milliseconds}"], "NRV-E0002", 1,
                      "--request-timeout must be 1000 to 60000", env={"NERVA_KEY": KEY})
            if command == "api":
                check("api statsd", [command, "--cluster=0", "--addresses=127.0.0.1:1",
                                     "--listen=127.0.0.1:0", "--statsd=127.0.0.1:0"], "NRV-E0002", 1,
                      "--statsd must be", env={"NERVA_KEY": KEY})
            # E0009 is decided before the key is read (P183b): no NERVA_KEY, still E0009.
            check(f"{command} listen without key", [command, "--cluster=0",
                                                    "--addresses=127.0.0.1:1",
                                                    "--listen=0.0.0.0:0"], "NRV-E0009", 1,
                  "is not loopback")
            # And before anything is bound: a held port is E0009, not E0007.
            with socket.socket() as held:
                held.bind(("0.0.0.0", 0))
                held.listen()
                check(f"{command} listen held", [command, "--cluster=0",
                                                 "--addresses=127.0.0.1:1",
                                                 f"--listen=0.0.0.0:{held.getsockname()[1]}"],
                      "NRV-E0009", 1, "is not loopback", env={"NERVA_KEY": KEY})
            check(f"{command} key", [command, "--cluster=0", "--addresses=127.0.0.1:1",
                                     "--listen=127.0.0.1:0"], "NRV-E0008", 1, "NERVA_KEY")
            # #335: a gateway key shorter than 32 bytes is refused.
            check(f"{command} short key", [command, "--cluster=0", "--addresses=127.0.0.1:1",
                                           "--listen=127.0.0.1:0"], "NRV-E0008", 1,
                  "shorter than 32 bytes", env={"NERVA_KEY": "short"})
        # The vendored flag parser's own failures (stdx/flags.zig `fatal`, through the hook).
        check("unknown subcommand", ["frobnicate"], "NRV-E0001", 1, "unknown subcommand")
        check("no subcommand", [], "NRV-E0001", 1, "subcommand required")
        check("unknown flag", ["format", "--bogus=1"], "NRV-E0001", 1, "--bogus")
        check("missing value", ["format", "--cluster"], "NRV-E0001", 1, "--cluster")
        check("bad integer", ["format", "--cluster=x", "--replica=0", "--replica-count=3",
                              data + ".z"], "NRV-E0001", 1, "--cluster")
        check("duplicate flag", ["format", "--cluster=0", "--cluster=1", "--replica=0",
                                 "--replica-count=3", data + ".z"], "NRV-E0001", 1, "duplicate")
        check("missing required flag", ["format", "--replica=0", "--replica-count=3",
                                        data + ".z"], "NRV-E0001", 1, "--cluster")
        check("unexpected positional", ["version", "extra"], "NRV-E0001", 1, "extra")
        check("unknown version flag", ["version", "--bogus"], "NRV-E0001", 1, "--bogus")
        # #300: the fix line of a flag refusal names a command that works. `nerva --help` is the
        # only help there is; `nerva <command> --help` is refused, so no hint may name it.
        hint = "run nerva --help, which lists every command and the flags it takes"
        for label, argv, fix_line in (
                ("E0001", ["format", "--bogus=1"], "  fix    " + hint),
                ("E0002", ["api", "--cluster=0", "--addresses=127.0.0.1:1",
                           "--listen=127.0.0.1:0", "--request-timeout=1"],
                 "  fix    the message names the bound; " + hint)):
            refused = run(nerva, argv, {"NERVA_KEY": KEY})
            fix = [line for line in refused.stderr.splitlines() if line.startswith("  fix    ")]
            assert fix == [fix_line], (label, refused.stderr)
        # The premise (P338): per-command help does not exist. The day it does, this fails and
        # points at the hint.
        check("command help refused", ["start", "--help"], "NRV-E0001", 1, "--help")
        helped = run(nerva, ["--help"])
        assert helped.returncode == 0, helped.stderr
        for command in ("format", "start", "view", "api", "export", "import", "backup",
                        "restore", "recover", "version"):
            assert f"nerva {command} " in helped.stdout, command
        check("as-of", ["export", "--cluster=0", "--addresses=127.0.0.1:1", "--as-of=0",
                        "--output=" + os.path.join(tmp, "x")], "NRV-E0001", 1, "--as-of")
        check("addresses", ["start", "--addresses=127.0.0.1:1,127.0.0.1:2", "--development",
                            data], "NRV-E0710", 1, "--addresses")
        check("cluster key", ["start", "--addresses=10.0.0.1:1,10.0.0.2:2,10.0.0.3:3", data],
              "NRV-E0901", 1, "NERVA_CLUSTER_KEY")
        # #336: the published development key, set explicitly, is refused off loopback.
        check("development key off loopback",
              ["start", "--addresses=10.0.0.1:1,10.0.0.2:2,10.0.0.3:3", data],
              "NRV-E0901", 1, "is the public development key",
              env={"NERVA_CLUSTER_KEY": "nerva-development-cluster-key-public-do-not-use"})
        trace = os.path.join(tmp, "trace")
        open(trace, "w").close()
        check("trace exists", ["start", "--addresses=127.0.0.1:1,127.0.0.1:2,127.0.0.1:3",
                               "--development", "--trace=" + trace, data],
              "NRV-E0004", 1, "--trace")
        # A --statsd address this host has no socket for is the operator's: E0010 naming the flag,
        # never E0007 "cannot listen" (no IPv6) (#181, #184). One it cannot send to (a broadcast
        # address; no route, on other hosts) no longer stops `start`: NRV-W0733, once (#198, P427).
        statsd_bad = []
        try:
            socket.socket(socket.AF_INET6, socket.SOCK_DGRAM).close()
        except OSError:
            statsd_bad.append("[2001:db8::1]:8125")  # a host without IPv6 has no such socket
        for statsd in statsd_bad:
            result = run(nerva, ["start", "--addresses=127.0.0.1:1,127.0.0.1:2,127.0.0.1:3",
                                 "--development", f"--statsd={statsd}", data], {})
            expect(result, "NRV-E0010", 1, "start: cannot send statsd to", f"start statsd {statsd}")
            assert "cannot listen" not in result.stderr and "NRV-B0004" not in result.stderr
            seen.append("NRV-E0010")
        # An unroutable address: the replica keeps running and warns once per failing stretch, and
        # never exits E0010. The metrics emit is a 10 s timer (replica ticks) that does not depend
        # on commits; the first emit's failure is reported at the second, about 20 s after the
        # superblock opens (24.5 s after launch, measured). Poll for the line against a generous
        # deadline, then live through two more emits: a warning on every failing emit would show.
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            free_statsd_port = probe.getsockname()[1]
        stderr_path = os.path.join(tmp, "statsd-stderr")
        with open(stderr_path, "w") as stderr_file:
            process = subprocess.Popen(
                [nerva, "start", f"--addresses=127.0.0.1:{free_statsd_port},127.0.0.1:1,127.0.0.1:2",
                 "--development", "--statsd=255.255.255.255:8125", data],
                stdout=subprocess.DEVNULL, stderr=stderr_file, text=True)
            try:
                def read_stderr():
                    with open(stderr_path) as f:
                        return f.read()
                deadline = time.monotonic() + STATSD_WARN_DEADLINE_S
                while "NRV-W0733" not in read_stderr():
                    assert process.poll() is None, "start exited on an unsendable --statsd: " \
                        + read_stderr()[-1000:]
                    assert time.monotonic() < deadline, "no NRV-W0733 in time: " \
                        + read_stderr()[-1000:]
                    time.sleep(0.5)
                time.sleep(STATSD_QUIET_S)
                assert process.poll() is None, "start did not run on with an unsendable --statsd"
            finally:
                process.kill()
                process.wait()
        stderr = read_stderr()
        assert "NRV-E0010" not in stderr, stderr[-1000:]
        assert stderr.count("NRV-W0733") == 1, stderr[-1000:]
        seen.append("NRV-W0733")
        # A start that failed must not leave its --trace file behind: the operator fixes the flag
        # and starts again with the same path, which must not be refused as E0004 (#197).
        trace_again = os.path.join(tmp, "trace-again")
        # Only a host without IPv6 sockets can fail `start` on --statsd now (P427): no address is
        # unroutable on both families, since an unroutable one only warns. On a host with IPv6
        # (GitHub's runners) this E0010 and #197 case is skipped, not covered; the `api` check
        # below still registers NRV-E0010.
        if statsd_bad:
            result = run(nerva, ["start", "--addresses=127.0.0.1:1,127.0.0.1:2,127.0.0.1:3",
                                 "--development", "--trace=" + trace_again,
                                 f"--statsd={statsd_bad[0]}", data], {})
            expect(result, "NRV-E0010", 1, "start: cannot send statsd to", "trace with bad statsd")
            assert not os.path.exists(trace_again), "the failed start left its trace file"
        # Every other startup failure removes it too: a held port (NRV-E0007), a missing cluster
        # key (NRV-E0901) and a missing address (NRV-E0710).
        with socket.socket() as held:
            held.bind(("127.0.0.1", 0))
            held.listen()
            port = held.getsockname()[1]
            for label, argv, env, code, text in (
                ("port held", [f"--addresses=127.0.0.1:{port},127.0.0.1:1,127.0.0.1:2",
                               "--development"], {}, "NRV-E0007", "cannot listen"),
                ("no cluster key", ["--addresses=10.0.0.1:1,10.0.0.2:2,10.0.0.3:3"], {},
                 "NRV-E0901", "NERVA_CLUSTER_KEY"),
                ("missing address", [f"--addresses=127.0.0.1:{port}", "--development"], {},
                 "NRV-E0710", "--addresses"),
            ):
                path = os.path.join(tmp, "trace-" + label.replace(" ", "-"))
                result = run(nerva, ["start"] + argv + ["--trace=" + path, data], env)
                expect(result, code, 1, text, "trace with " + label)
                assert not os.path.exists(path), f"{label}: the failed start left its trace file"
                seen.append(code)
        # A start that gets past replica.open is not refused with E0004 (#197) and its trace file
        # exists. This does not test the clear itself (the file would exist without it): only the
        # unit test does.
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            free = [probe.getsockname()[1]]
        process = subprocess.Popen(
            [nerva, "start", f"--addresses=127.0.0.1:{free[0]},127.0.0.1:1,127.0.0.1:2",
             "--development", "--trace=" + trace_again, data],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            time.sleep(3)  # long enough for a replica that can start to be listening
            assert process.poll() is None, "the replica did not stay running"
            assert os.path.exists(trace_again), "the running replica has no trace file"
        finally:
            process.kill()
            stderr = process.communicate()[1]
        assert "NRV-E0004" not in stderr, stderr[-1000:]

        # Pre-flight before the vendored open (R5, P149): nothing here may panic or write.
        start = ["start", "--addresses=127.0.0.1:1,127.0.0.1:2,127.0.0.1:3", "--development"]

        def sha(path):
            with open(path, "rb") as f:
                return hashlib.sha256(f.read()).hexdigest()

        check("start missing file", start + [os.path.join(tmp, "nope.nerva")], "NRV-E0006", 1,
              "does not exist")
        assert not os.path.exists(os.path.join(tmp, "nope.nerva"))
        with open(data, "rb") as f:
            good = f.read()
        for label, content in (("truncated", good[:1000]), ("empty", b""),
                               ("zeros", bytes(len(good))), ("text", b"not a data file" * 100)):
            damaged = os.path.join(tmp, f"{label}.nerva")
            with open(damaged, "wb") as f:
                f.write(content)
            before = sha(damaged)
            check(f"start {label} file", start + [damaged], "NRV-E0702", 1, "no usable superblock")
            assert sha(damaged) == before and os.path.getsize(damaged) == len(content), label
        check("start a directory", start + [tmp], "NRV-E0810", 1, "directory")
        before = sha(data)
        with open(data, "rb") as holder:
            fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # The pid is named where /proc/locks names this file as os.stat does; on a file
            # system that differs (btrfs subvolumes, overlayfs) it is not, and the refusal is
            # the same without it.
            info = os.fstat(holder.fileno())
            key = f"{os.major(info.st_dev):02x}:{os.minor(info.st_dev):02x}:{info.st_ino} "
            try:
                with open("/proc/locks") as table:
                    named = any(key in line for line in table)
            except OSError:
                named = False
            check("start locked file", start + [data], "NRV-E0703", 1,
                  f"another process holds {data}" + (f" (pid {os.getpid()})" if named else ""))
        assert sha(data) == before

        # A binary with multiversion sections that hold no bundle: NRV-E0719, not a replica
        # that runs as one release (P415). Needs objcopy; E0726 and the size bound are
        # unit-tested on `bundle_present` (src/nerva_main.zig), which a test as root can reach.
        # Only the two cases that run the release build need vm.memfd_noexec to be 0 (the
        # kernel check, NRV-E0720, comes first); the E0720 cases name their own sysctl file.
        objcopy = shutil.which("objcopy")
        try:
            with open("/proc/sys/vm/memfd_noexec") as f:
                memfd_noexec = f.read().strip()
        except OSError:
            memfd_noexec = "0"  # No such sysctl (kernel before 6.3): nothing refuses.
        if not objcopy:
            print("SKIP damaged-bundle cases (NRV-E0719, NRV-E0720): objcopy is not installed")
        else:
            junk = os.path.join(tmp, "junk-section")
            with open(junk, "wb") as f:
                f.write(b"not a bundle" * 100)
            damaged_bundle = os.path.join(tmp, "nerva-damaged-bundle")
            subprocess.run([objcopy, "--add-section", f".tb_mvb={junk}",
                            "--add-section", f".tb_mvh={junk}", nerva, damaged_bundle],
                           check=True)
            os.chmod(damaged_bundle, 0o755)
            # One section of the two only: `parse_elf` finds no bundle, but the names are still
            # there. `version` calls that damaged, and `start` must too, never run it as one
            # release (P417). Built from a stripped copy: objcopy writes `.symtab`, `.strtab`
            # and `.shstrtab` after an added section, and on the unstripped binary `parse_elf`
            # fails on that layout before it looks for the bundle, so the check would pass
            # without `damaged_when_unbundled`.
            stripped = os.path.join(tmp, "nerva-stripped")
            subprocess.run([objcopy, "--strip-all", nerva, stripped], check=True)
            half_bundle = os.path.join(tmp, "nerva-half-bundle")
            subprocess.run([objcopy, "--add-section", f".tb_mvb={junk}", stripped, half_bundle],
                           check=True)
            os.chmod(half_bundle, 0o755)
            check("version with half a bundle", ["version"], "NRV-E0719", 1,
                  "bundled release is damaged", nerva=half_bundle)
            # `start` reads the bundle before the kernel check, so half a bundle is NRV-E0719
            # whatever the sysctl says.
            check("start with half a bundle", start + [data], "NRV-E0719", 1,
                  "bundle of releases cannot be read", nerva=half_bundle)
            assert sha(data) == before
            if memfd_noexec == "0":
                check("start with a damaged bundle", start + [data], "NRV-E0719", 1,
                      "bundle of releases cannot be read", nerva=damaged_bundle)
                assert sha(data) == before
            else:
                print(f"SKIP damaged bundle (NRV-E0719): vm.memfd_noexec is {memfd_noexec}, "
                      f"and the host's kernel check (NRV-E0720) comes first")
            # NRV-E0720 before the bundle is opened, in the test build only, where the sysctl
            # path can be named; a release build ignores the variable.
            refused = os.path.join(tmp, "memfd_noexec")
            with open(refused, "w") as f:
                f.write("2\n")
            damaged_off = os.path.join(tmp, "nerva-damaged-bundle-off")
            subprocess.run([objcopy, "--add-section", f".tb_mvb={junk}",
                            "--add-section", f".tb_mvh={junk}", nerva_off, damaged_off],
                           check=True)
            os.chmod(damaged_off, 0o755)
            env_noexec = {"NERVA_MEMFD_NOEXEC_PATH": refused}
            check("start with memfd_noexec 2", start + [data], "NRV-E0720", 1,
                  "vm.memfd_noexec is not 0", env=env_noexec, nerva=damaged_off)
            with open(refused, "w") as f:
                f.write("1\n")
            check("start with memfd_noexec 1", start + [data], "NRV-E0720", 1,
                  "vm.memfd_noexec is not 0", env=env_noexec, nerva=damaged_off)
            # These two do not depend on the host: the sysctl path is the test's own file.
            if memfd_noexec == "0":
                check("release build ignores the sysctl override", start + [data], "NRV-E0719",
                      1, "bundle of releases cannot be read", env=env_noexec,
                      nerva=damaged_bundle)
            assert sha(data) == before

        # The test build with commit-key deduplication off (R1): E0717 without --development,
        # W0701 before the data file is opened with it, `+keys-off` in `version`; a release
        # build has none of the three.
        version = run(nerva, ["version"])
        assert version.returncode == 0 and "keys-off" not in version.stdout, version.stdout
        version_off = run(nerva_off, ["version"])
        assert version_off.returncode == 0 and \
            version_off.stdout.splitlines()[0].endswith("+keys-off"), version_off.stdout
        # It runs another release than a release build (#222), so a release build refuses its
        # data file (NRV-E0718: the file's release is above its own), and the other way round
        # (NRV-E0701: below), with the releases named. That replicas of two
        # releases ignore each other (N61) is `tests/release/mixed.py`'s and
        # `src/nerva/release_peers.zig`'s: no run here has a keys-off and a release replica
        # in one cluster.
        release_line = [l for l in version.stdout.splitlines() if l.startswith("release ")][0]
        release_line_off = [l for l in version_off.stdout.splitlines()
                            if l.startswith("release ")][0]
        assert release_line != release_line_off, (release_line, release_line_off)
        release_text, release_text_off = release_line[8:], release_line_off[8:]
        data_off = os.path.join(tmp, "keys-off.nerva")
        assert run(nerva_off, fmt + [data_off]).returncode == 0
        digest_off = sha(data_off)
        digest = sha(data)
        check("start a keys-off file with a release build", start + [data_off],
              "NRV-E0718", 1, f"belongs to a cluster that runs release {release_text_off}, and this "
              f"binary runs {release_text} and bundles none")
        check("start a release file with a keys-off build", start + [data], "NRV-E0701",
              1, f"was written by release {release_text}, and this binary runs "
              f"{release_text_off} and bundles none", nerva=nerva_off)
        assert sha(data_off) == digest_off
        assert sha(data) == digest
        os.remove(data_off)
        verbose_off = run(nerva_off, ["version", "--verbose"])
        assert verbose_off.stdout.splitlines()[-1] == "commit_keys off", verbose_off.stdout
        # `version`'s text (R6): the first line is the one the release workflow reads; then what
        # an upgrade compares. No binary bundles a past release yet (slice 3).
        for binary_run in (version, version_off):
            lines = binary_run.stdout.splitlines()
            first = VERSION_FIRST.fullmatch(lines[0])
            assert first, binary_run.stdout
            assert lines[1:] == [
                "release " + first[1],
                "release_client_min 0.0.4",
                "format " + FORMAT_DIGEST,
                "bundles none",
                "version " + RELEASE_VERSION,
            ], binary_run.stdout
        verbose = run(nerva, ["version", "--verbose"])
        assert verbose.returncode == 0, verbose.stderr
        lines = verbose.stdout.splitlines()
        assert lines[:6] == version.stdout.splitlines(), verbose.stdout
        assert lines[6:8] == ["format_epoch 1", "superblock_version 2"], verbose.stdout
        assert re.fullmatch(r"commit ([0-9a-f]{40}|none)", lines[8]) and len(lines) == 10, \
            verbose.stdout
        assert lines[9] == "commit_keys deduplicate", verbose.stdout
        before = sha(data)
        check("start keys off without development",
              ["start", "--addresses=127.0.0.1:1,127.0.0.1:2,127.0.0.1:3", data],
              "NRV-E0717", 1, "commit-key deduplication off", nerva=nerva_off)
        assert sha(data) == before
        assert "-Dtest-commit-keys=off" in run(
            nerva_off, ["start", "--addresses=127.0.0.1:1,127.0.0.1:2,127.0.0.1:3", data]
        ).stderr
        for binary, warnings in ((nerva_off, 1), (nerva, 0)):
            one = os.path.join(tmp, f"one-{warnings}.nerva")
            assert run(binary, ["format", "--cluster=0", "--replica=0", "--replica-count=1",
                                "--development", one]).returncode == 0
            process = subprocess.Popen(
                [binary, "start", "--addresses=0", "--development", one],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True)
            try:
                assert int(process.stdout.readline()) > 0, warnings
            finally:
                process.kill()
                stderr = process.communicate()[1]
            assert stderr.count("NRV-W0701") == warnings, (warnings, stderr)
            assert stderr.count("a resent key commits again") == warnings, stderr
            assert not diagnostic_lines(subprocess.CompletedProcess([], 0, "", stderr)), \
                stderr
        seen.append("NRV-W0701")

        # import
        junk = os.path.join(tmp, "junk")
        with open(junk, "w") as f:
            f.write("not an export")
        imp = ["import", "--cluster=0", "--replica=0", "--replica-count=3", "--development"]
        check("import target exists", imp + ["--input=" + junk, data], "NRV-E0004", 1, "exists")
        check("import missing input", imp + ["--input=" + os.path.join(tmp, "none"),
                                             os.path.join(tmp, "d.nerva")],
              "NRV-E0810", 1, "no such file")
        check("import junk", imp + ["--input=" + junk, os.path.join(tmp, "d.nerva")],
              "NRV-E0804", 1, "junk")
        assert not os.path.exists(os.path.join(tmp, "d.nerva"))
        left = os.path.join(tmp, "e.nerva")
        open(left + ".importing", "w").close()
        check("import left", imp + ["--input=" + junk, left], "NRV-E0806", 1, ".importing")

        # export and gateways against a live cluster
        cluster = Cluster(nerva)
        try:
            out = os.path.join(tmp, "out.export")
            export = ["export", "--cluster=0", f"--addresses={cluster.address}"]
            first = run(nerva, export + ["--output=" + out])
            assert first.returncode == 0, first.stderr[-2000:]
            check("export exists", export + ["--output=" + out], "NRV-E0004", 1, "exists")
            # The keys-off build's own clients run its release, above this cluster's: the
            # replica evicts them (`client_release_too_high`), a refusal with its own code (#356, #222).
            too_new = f"the cluster runs release {release_text}; this client, release " \
                f"{release_text_off}, is newer, so it was evicted"
            check("export from a newer release", export + ["--output=" + os.path.join(tmp, "n")],
                  "NRV-E0609", 1, too_new, nerva=nerva_off)
            assert not os.path.exists(os.path.join(tmp, "n"))
            for command in ("api", "view"):
                check(f"{command} from a newer release",
                      [command, "--cluster=0", f"--addresses={cluster.address}",
                       "--listen=127.0.0.1:0"], "NRV-E0609", 1, too_new,
                      env={"NERVA_KEY": KEY}, nerva=nerva_off)
            seen.append("NRV-E0609")
            check("export as-of ahead", export + ["--as-of=99999999",
                                                  "--output=" + os.path.join(tmp, "f")],
                  "NRV-E0802", 1, "--as-of")
            assert not os.path.exists(os.path.join(tmp, "f"))
            check("export unwritable", export + ["--output=" + os.path.join(tmp, "no", "x")],
                  "NRV-E0810", 1, "no such file")
            # A version this release does not read: the header's version is at byte 8.
            future = os.path.join(tmp, "future.export")
            with open(out, "rb") as f:
                data_bytes = bytearray(f.read())
            data_bytes[8:12] = (99).to_bytes(4, "little")
            with open(future, "wb") as f:
                f.write(data_bytes)
            check("import future version",
                  imp + ["--input=" + future, os.path.join(tmp, "g.nerva")],
                  "NRV-E0805", 1, "version")
            # Two imports of one path at once (P489): exactly one succeeds, and the other is
            # refused cleanly (E0806 or E0814 when it met the winner's `.importing`, E0004 or
            # E0814 when the winner had finished) without removing the winner's file. The window
            # is narrow, so a few rounds; the unit test in `nerva_main.zig` forces it.
            environment = {k: v for k, v in os.environ.items() if not k.startswith("NERVA_")}
            for round_number in range(4):
                target = os.path.join(tmp, f"race{round_number}.nerva")
                racers = [subprocess.Popen([nerva] + imp + ["--input=" + out, target],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True, env=environment) for _ in range(2)]
                errors = [racer.communicate(timeout=120)[1] for racer in racers]
                codes = [racer.returncode for racer in racers]
                assert sorted(codes) == [0, 1], (codes, errors)
                refusal = errors[codes.index(1)]
                assert re.search(r"error\[NRV-E(0806|0814|0004)\]", refusal), refusal
                assert os.path.getsize(target) > 0
                assert not os.path.exists(target + ".importing"), "a staging file was left"
                check("import concurrent: the winner's file is whole",
                      imp + ["--input=" + out, target], "NRV-E0004", 1, "exists")
            # A keys-off export (P426): flag bit 0 at byte 12. The end record (the last 44 bytes:
            # size, kind, the SHA-256 of every byte before it, the CRC-32 of those) is rebuilt, so
            # only the flag is refused. A release build names it (E0812); an unknown bit is corrupt.
            with open(out, "rb") as f:
                real = f.read()

            def with_flags(flags):
                body = bytearray(real[:-44])
                body[12:16] = flags.to_bytes(4, "little")
                end = real[-44:-36] + hashlib.sha256(body).digest()
                return bytes(body) + end + zlib.crc32(end).to_bytes(4, "little")
            assert with_flags(0) == real, "the end record is not rebuilt as assumed"
            for name, flags, code, text in (("keys off", 1, "NRV-E0812", "deduplication off"),
                                            ("unknown flag", 2, "NRV-E0804", "flag")):
                flagged = os.path.join(tmp, f"{flags}.export")
                with open(flagged, "wb") as f:
                    f.write(with_flags(flags))
                target = os.path.join(tmp, f"{flags}.nerva")
                check("import " + name, imp + ["--input=" + flagged, target], code, 1, text)
                assert not os.path.exists(target)
            # The write path, from real exports (P426): a release `export` writes flags 0, a
            # keys-off `export` writes bit 0; a release import refuses the latter from the real
            # file, leaving nothing behind, and a keys-off import accepts it. The bit marks the
            # exporting build, not the cluster, so a release export of a keys-off cluster is 0.
            # The keys-off export is of a keys-off cluster: a keys-off client does not reach a
            # release cluster once its release is refused (#354), so this holds with and without it.
            assert real[12:16] == bytes(4), real[12:16]
            off_out = os.path.join(tmp, "off.export")
            cluster_off = Cluster(nerva_off)
            try:
                export_off = ["export", "--cluster=0", f"--addresses={cluster_off.address}"]
                made = run(nerva_off, export_off + ["--output=" + off_out])
            finally:
                cluster_off.close()
            assert made.returncode == 0, made.stderr[-2000:]
            with open(off_out, "rb") as f:
                off_bytes = f.read()
            assert off_bytes[12:16] == b"\x01\x00\x00\x00", off_bytes[12:16]
            off_target = os.path.join(tmp, "off.nerva")
            check("import real keys-off export", imp + ["--input=" + off_out, off_target],
                  "NRV-E0812", 1, "deduplication off")
            assert not os.path.exists(off_target)
            assert not os.path.exists(off_target + ".importing")
            accepted = run(nerva_off, imp + ["--input=" + off_out, off_target])
            assert accepted.returncode == 0, accepted.stderr[-2000:]
            assert os.path.exists(off_target)
            # A port that is taken.
            with socket.socket() as taken:
                taken.bind(("127.0.0.1", 0))
                taken.listen()
                check("listen taken", ["api", "--cluster=0", f"--addresses={cluster.address}",
                                       f"--listen=127.0.0.1:{taken.getsockname()[1]}"],
                      "NRV-E0007", 1, "cannot listen", env={"NERVA_KEY": KEY})
            # A statsd address this host cannot send to: the gateway refuses to start, before it
            # says it listens or prints its port (P176b).
            api = ["api", "--cluster=0", f"--addresses={cluster.address}", "--listen=127.0.0.1:0"]
            statsd_bad = ["255.255.255.255:8125"]
            try:
                socket.socket(socket.AF_INET6, socket.SOCK_DGRAM).close()
            except OSError:
                statsd_bad.append("[2001:db8::1]:8125")  # a host without IPv6 has no such socket
            for statsd in statsd_bad:
                result = run(nerva, api + [f"--statsd={statsd}"], {"NERVA_KEY": KEY})
                expect(result, "NRV-E0010", 1, "cannot send statsd to", f"statsd {statsd}")
                seen.append("NRV-E0010")
                assert result.stdout == "", (statsd, result.stdout)
                assert "listening on" not in result.stderr, (statsd, result.stderr[-1000:])
            # The check comes before the client registers: with the cluster unreachable a bad
            # `--statsd` still exits at once with E0010, not after a 30 s registration (P176d).
            started = time.monotonic()
            result = run(nerva, ["api", "--cluster=0", "--addresses=127.0.0.1:1",
                                 "--listen=127.0.0.1:0", "--statsd=255.255.255.255:8125"],
                         {"NERVA_KEY": KEY}, timeout=20)
            expect(result, "NRV-E0010", 1, "cannot send statsd to", "statsd bad, cluster down")
            seen.append("NRV-E0010")
            assert time.monotonic() - started < 10, "E0010 waited for the cluster"
            # `--listen-remote` accepts 0.0.0.0 and says so once (NRV-W0010); on loopback, never.
            for command in ("api", "view"):
                for listen, warnings in (("0.0.0.0:0", 1), ("127.0.0.1:0", 0)):
                    process = subprocess.Popen(
                        [nerva, command, "--cluster=0", f"--addresses={cluster.address}",
                         f"--listen={listen}", "--listen-remote"], stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True,
                        env={**os.environ, "NERVA_KEY": KEY})
                    try:
                        assert int(process.stdout.readline()) > 0, command
                    finally:
                        process.kill()
                        stderr = process.communicate()[1]
                    assert stderr.count("NRV-W0010") == warnings, (command, listen, stderr)
                    assert stderr.count("--listen-remote serves plain HTTP") == warnings, stderr
                    assert not diagnostic_lines(subprocess.CompletedProcess([], 0, "", stderr)), \
                        stderr
        finally:
            cluster.close()

        # No cluster at that address: each waits out the client's 30 s registration.
        dead = f"--addresses=127.0.0.1:{free_port()}"
        check("export no reply", ["export", "--cluster=0", dead,
                                  "--output=" + os.path.join(tmp, "h")], "NRV-E0801", 1,
              "no reply")
        check("api no reply", ["api", "--cluster=0", dead, "--listen=127.0.0.1:0"],
              "NRV-E0604", 1, "no reply", env={"NERVA_KEY": KEY})

        print("codes checked:", " ".join(sorted(set(seen))))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


if __name__ == "__main__":
    main()
