#!/usr/bin/env python3
"""Every coded failure a `nerva` command can report, from the real binary (R5, P147c).

Usage: commands.py <nerva>

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

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "api"))
from api import Cluster  # noqa: E402

KEY = "errors-test-key"
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
    nerva = os.path.abspath(sys.argv[1])
    tmp = tempfile.mkdtemp(prefix="nerva-errors-")
    seen = []

    def check(label, argv, code, status, text, env=None, timeout=120):
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
            check(f"{command} key", [command, "--cluster=0", "--addresses=127.0.0.1:1",
                                     "--listen=127.0.0.1:0"], "NRV-E0008", 1, "NERVA_KEY")
        check("as-of", ["export", "--cluster=0", "--addresses=127.0.0.1:1", "--as-of=0",
                        "--output=" + os.path.join(tmp, "x")], "NRV-E0001", 1, "--as-of")
        check("addresses", ["start", "--addresses=127.0.0.1:1,127.0.0.1:2", "--development",
                            data], "NRV-E0710", 1, "--addresses")
        check("cluster key", ["start", "--addresses=10.0.0.1:1,10.0.0.2:2,10.0.0.3:3", data],
              "NRV-E0901", 1, "NERVA_CLUSTER_KEY")
        trace = os.path.join(tmp, "trace")
        open(trace, "w").close()
        check("trace exists", ["start", "--addresses=127.0.0.1:1,127.0.0.1:2,127.0.0.1:3",
                               "--development", "--trace=" + trace, data],
              "NRV-E0004", 1, "--trace")


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
