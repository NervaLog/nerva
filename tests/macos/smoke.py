#!/usr/bin/env python3
"""The macOS smoke test (docs/briefs/v0.7.1.md, slice 2; #278): a release binary, run for real.

Usage: smoke.py <nerva> --arch arm64|x86_64 --expect-signature adhoc|developer-id|none|any

Runs on a Mac, on the thin binary of the runner's architecture and again on the universal one,
and holds no secret. Eight steps, one line each; the last line is `macos-smoke: PASS` or
`macos-smoke: FAIL step N: ...`.

 0  the host: `--arch` must be the machine's own architecture, not run under Rosetta, so the
    slice of a universal binary that runs is the one named
 1  `codesign -dv` is recorded and must show `--expect-signature` (`any` records only)
 2  `nerva version`
 3  format three replicas with `--development` in a temporary directory and start them
 4  `nerva api --statsd=127.0.0.1:<port>` against a UDP listener of this script
 5  `/healthz` 200; `PUT /v1/tables/1`, commit, lookup and `GET /v1/changes` each answer right
 6  a `nerva.api.requests` line arrives within 25 s
 7  SIGTERM to every process: each exits, none panicked, no process or file is left behind
"""
import http.client
import json
import os
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import traceback

KEY = "macos-smoke-key-0123456789abcdef0123456789"
REPLICAS = 3
STATSD_SECONDS = 25
step_number = 0


def say(text):
    print(f"step {step_number}: {text}", flush=True)


def free_ports(count):
    sockets = [socket.socket() for _ in range(count)]
    for s in sockets:
        s.bind(("127.0.0.1", 0))
    ports = [s.getsockname()[1] for s in sockets]
    for s in sockets:
        s.close()
    return ports


def request(port, method, target, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    try:
        connection.request(method, target, body=None if body is None else json.dumps(body),
                           headers={"X-Nerva-Key": KEY})
        response = connection.getresponse()
        return response.status, json.loads(response.read() or b"null")
    finally:
        connection.close()


def ok(port, method, target, body=None, seconds=120):
    """A request that answers 200, retried while the cluster answers 503 or 504 or is not up."""
    deadline = time.monotonic() + seconds
    while True:
        try:
            status, reply = request(port, method, target, body)
        except (OSError, http.client.HTTPException):
            status, reply = 0, None
        if status == 200:
            return reply
        assert status in (0, 503, 504) and time.monotonic() < deadline, \
            (method, target, status, reply)
        time.sleep(0.3)


def sysctl(name):
    result = subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, timeout=30)
    return result.stdout.strip() if result.returncode == 0 else ""


def step_0_host(arch):
    if sys.platform != "darwin":  # Only so that the script can be tried on a Linux build.
        say("host: skipped, not macOS")
        return
    # Not platform.machine(): a translated Python reports x86_64 on an Apple-silicon Mac.
    host = "arm64" if sysctl("hw.optional.arm64") == "1" else "x86_64"
    translated = sysctl("sysctl.proc_translated") == "1"
    assert not translated, "this script runs under Rosetta, so no x86_64 slice runs natively"
    assert host == arch, f"--arch {arch} but this Mac is {host}: the {arch} slice would not run"
    say(f"host: {host}, not translated; the {arch} slice runs natively")


def step_1_codesign(nerva, arch, expect):
    if sys.platform != "darwin":
        say("codesign: skipped, not macOS")
        return
    result = subprocess.run(["codesign", "-dv", nerva], capture_output=True, text=True)
    shown = result.stderr.strip().replace("\n", " | ")
    if "Authority=Developer ID Application" in result.stderr:
        found = "developer-id"
    elif "Signature=adhoc" in result.stderr:
        found = "adhoc"
    elif "not signed at all" in result.stderr:
        found = "none"
    else:
        found = "unrecognised"
    assert expect == "any" or found == expect, f"expected {expect}, found {found}: {shown}"
    say(f"codesign: {found}, expected {expect} ({arch})")
    print(f"  codesign -dv: {shown}", flush=True)


def step_2_version(nerva):
    result = subprocess.run([nerva, "version"], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.returncode, result.stderr)
    assert re.match(r"Nerva version \d+\.\d+\.\d+", result.stdout), result.stdout
    say(result.stdout.splitlines()[0])


class Smoke:
    def __init__(self, nerva, tmp):
        self.nerva, self.tmp = nerva, tmp
        self.processes = []  # (name, Popen)
        self.ports = free_ports(REPLICAS)
        self.addresses = ",".join(str(port) for port in self.ports)

    def path(self, index):
        return os.path.join(self.tmp, f"0_{index}.nerva")

    def log(self, index):
        try:
            with open(self.path(index) + ".log", errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    def start_replicas(self):
        for index in range(REPLICAS):
            subprocess.run([self.nerva, "format", "--cluster=0", f"--replica={index}",
                            f"--replica-count={REPLICAS}", "--development", self.path(index)],
                           check=True, capture_output=True, timeout=300)
        for index in range(REPLICAS):
            process = subprocess.Popen(
                [self.nerva, "start", f"--addresses={self.addresses}", "--development",
                 self.path(index)],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                stderr=open(self.path(index) + ".log", "a"))
            self.processes.append((f"replica {index}", process))
        deadline = time.monotonic() + 180
        for index, port in enumerate(self.ports):
            while True:
                assert self.processes[index][1].poll() is None, \
                    f"replica {index} exited: {self.log(index)[-2000:]}"
                try:
                    socket.create_connection(("127.0.0.1", port), timeout=1).close()
                    break
                except OSError:
                    assert time.monotonic() < deadline, self.log(index)[-2000:]
                    time.sleep(0.1)

    def start_api(self, statsd_port):
        log = os.path.join(self.tmp, "0_api.log")
        process = subprocess.Popen(
            [self.nerva, "api", "--cluster=0", f"--addresses={self.addresses}",
             "--listen=127.0.0.1:0", f"--statsd=127.0.0.1:{statsd_port}"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(log, "w"),
            env={**os.environ, "NERVA_KEY": KEY}, text=True)
        self.processes.append(("api", process))
        ready, _, _ = select.select([process.stdout], [], [], 60)
        line = process.stdout.readline() if ready else ""
        assert line, f"nerva api printed no port in 60 s: {open(log, errors='replace').read()[-2000:]}"
        return int(line)

    def stop_all(self):
        """SIGTERM each process; each must be gone within 30 s, dead of the signal or exit 0."""
        for _, process in self.processes:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
        for name, process in self.processes:
            try:
                code = process.wait(30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise AssertionError(f"{name} ignored SIGTERM for 30 s")
            assert code in (0, -signal.SIGTERM), f"{name} exited with {code}"

    def kill_all(self):
        for _, process in self.processes:
            if process.poll() is None:
                process.kill()
                process.wait()


def run(nerva, arch, expect_signature):
    global step_number
    nerva = os.path.abspath(nerva)
    statsd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    statsd.bind(("127.0.0.1", 0))
    tmp = tempfile.mkdtemp(prefix="nerva-macos-smoke-")
    smoke = Smoke(nerva, tmp)
    try:
        step_number = 0
        step_0_host(arch)
        step_number = 1
        step_1_codesign(nerva, arch, expect_signature)
        step_number = 2
        step_2_version(nerva)

        step_number = 3
        smoke.start_replicas()
        say(f"{REPLICAS} replicas formatted with --development and listening on loopback")

        step_number = 4
        port = smoke.start_api(statsd.getsockname()[1])
        say(f"nerva api listening on {port}, --statsd to 127.0.0.1:{statsd.getsockname()[1]}")

        step_number = 5
        health = ok(port, "GET", "/healthz")
        say(f"/healthz: {json.dumps(health)}")
        ok(port, "PUT", "/v1/tables/1",
           {"name": "smoke", "fields": [{"name": "n", "type": "u64"}]})
        committed = ok(port, "POST", "/v1/commit", {"entries": [
            {"kind": "put", "table": 1, "id": "5", "fields": {"n": 7}}]})
        assert committed["status"] == "committed" and int(committed["op"]) > 0, committed
        looked = ok(port, "POST", "/v1/lookup", {"rows": [{"table": 1, "id": "5"}]})
        row = looked["rows"][0]
        assert row["exists"] is True and str(row["fields"]["n"]) == "7", looked
        changes = ok(port, "GET", "/v1/changes?cursor=0&limit=100")
        assert '"op":"%s"' % committed["op"] in json.dumps(changes, separators=(",", ":")), changes
        say(f"table declared, commit at op {committed['op']}, lookup and change feed agree")

        step_number = 6
        statsd.settimeout(1)
        deadline = time.monotonic() + STATSD_SECONDS
        seen = None
        while seen is None and time.monotonic() < deadline:
            try:
                for line in statsd.recv(65536).decode(errors="replace").splitlines():
                    if "nerva.api.requests" in line:
                        seen = line
                        break
            except socket.timeout:
                pass
        assert seen, f"no nerva.api.requests line within {STATSD_SECONDS} s"
        say(f"statsd: {seen}")

        step_number = 7
        smoke.stop_all()
        for index in range(REPLICAS):
            assert "panic" not in smoke.log(index), smoke.log(index)[-2000:]
        api_log = open(os.path.join(tmp, "0_api.log"), errors="replace").read()
        assert "panic" not in api_log, api_log[-2000:]
        expected = {f"0_{i}.nerva{suffix}" for i in range(REPLICAS) for suffix in ("", ".log")}
        expected.add("0_api.log")
        found = set(os.listdir(tmp))
        assert found == expected, f"files left behind: {sorted(found - expected)}, " \
            f"missing: {sorted(expected - found)}"
        say("every process stopped on SIGTERM, none panicked, only the expected files")
    finally:
        smoke.kill_all()
        statsd.close()
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    args = sys.argv[1:]
    options = {}
    for name in ("--arch", "--expect-signature"):
        if name in args:
            index = args.index(name)
            options[name] = args[index + 1]
            del args[index:index + 2]
    arch = options.get("--arch", "")
    expect = options.get("--expect-signature", "")
    assert len(args) == 1 and arch in ("arm64", "x86_64") \
        and expect in ("adhoc", "developer-id", "none", "any"), __doc__
    try:
        run(args[0], arch, expect)
    except BaseException as error:  # noqa: BLE001
        if not isinstance(error, AssertionError):
            traceback.print_exc()
        print(f"macos-smoke: FAIL step {step_number}: {error}", flush=True)
        sys.exit(1)
    print("macos-smoke: PASS", flush=True)


if __name__ == "__main__":
    main()
