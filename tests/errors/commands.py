#!/usr/bin/env python3
"""Every coded failure a `nerva` command can report, from the real binary (R5, P147c).

Usage: commands.py <nerva> [<nerva built with -Dtest-commit-keys=off>]

For each code a command emits (docs/ERRORS.md, 00xx, 06xx, 08xx, 09xx), triggers it and checks
the first line (`error[NRV-…]: …`), the `cause` and `fix` lines, the exit status, and that no
stack trace and no raw Zig error name (`error.Name`) is printed. NRV-E0701 is in `tests/release/mixed.py` (it needs a binary of another release), NRV-E0704
and E0705 need a file system without direct IO and a kernel older than 5.11, so only unit tests of
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

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "api"))
from api import Cluster  # noqa: E402

KEY = "errors-test-key-0123456789abcdef0123456789"
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
        # A --statsd address this host cannot send to is the operator's: E0010 naming the flag,
        # never B0004 (a broadcast address) or E0007 "cannot listen" (no IPv6) (#181, #184).
        statsd_bad = ["255.255.255.255:8125"]
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
        # A start that failed must not leave its --trace file behind: the operator fixes the flag
        # and starts again with the same path, which must not be refused as E0004 (#197).
        trace_again = os.path.join(tmp, "trace-again")
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
            check("start locked file", start + [data], "NRV-E0703", 1, "another process holds")
        assert sha(data) == before

        # The test build with commit-key deduplication off (R1): E0717 without --development,
        # W0701 before the data file is opened with it, `+keys-off` in `version`; a release
        # build has none of the three.
        version = run(nerva, ["version"])
        assert version.returncode == 0 and "keys-off" not in version.stdout, version.stdout
        version_off = run(nerva_off, ["version"])
        assert version_off.returncode == 0 and \
            version_off.stdout.splitlines()[0].endswith("+keys-off"), version_off.stdout
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
