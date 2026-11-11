#!/usr/bin/env python3
"""`nerva backup` and `nerva restore` (docs/briefs/r5.md, P149, R5 slice 6).

Usage: restore.py <nerva> [<other nerva>]   (the second argument is accepted for `test:release`
and unused: a backup is restored by the release that made it)

A cluster of three replicas takes writes without stopping (seats put one after another, a view
over them and a ledger declared first). Then:
- a backup `--as-of` an earlier op, while the writer goes on: its manifest is checked against the
  file (SHA-256, size, op) and against what the cluster says as of that op (the view's hash and
  group count, the ledger's total);
- a restore drill: the backup restored into a one-replica cluster with another cluster id,
  while the first cluster keeps committing; every view hash and ledger total read from the drill
  equals the manifest's;
- the first cluster stopped and wiped, its three replicas restored from the backup under their
  own cluster id, and compared again;
- each refusal is one coded line, exit status 1, and no data file: a backup with one byte
  changed (E0804), the manifest of another backup (E0809), a manifest with one view hash changed
  (E0809), a missing manifest (E0808), a manifest that is not one (E0808, E0808 for an unknown
  version and for one past its size), and, for `backup`, an output that exists (E0004), a
  manifest that exists (E0004) and an op the cluster has not reached (E0802, nothing written).
"""
import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

# Replicas authenticate each other with a real cluster key, never the development key (P102).
os.environ["NERVA_CLUSTER_KEY"] = os.urandom(32).hex()

KEY = "restore-test-key"
SEATS = 5        # A layout, and the view over it.
ACCOUNTS = 40    # The ledger: available and held, floored at zero.
SOURCES = 41     # The ledger: balance, no floor.
SEATS_LAYOUT = {"name": "seats", "fields": [{"name": "section", "type": "u8"},
                                            {"name": "price", "type": "u64"},
                                            {"name": "sold", "type": "bool"}]}
ACCOUNTS_LAYOUT = {"name": "accounts", "fields": [{"name": "available", "type": "i64"},
                                                  {"name": "held", "type": "i64"}]}
SOURCES_LAYOUT = {"name": "sources", "fields": [{"name": "balance", "type": "i64"}]}
VIEW = {"table": SEATS, "group_by": ["section"],
        "aggregates": [{"fn": "count"}, {"fn": "sum", "field": "price"},
                       {"fn": "min", "field": "price"}, {"fn": "max", "field": "price"}]}
LEDGER = {"fields": [{"table": ACCOUNTS, "field": "available", "floor": "0"},
                     {"table": ACCOUNTS, "field": "held", "floor": "0"},
                     {"table": SOURCES, "field": "balance", "floor": None}]}
DRILL_CLUSTER = 7
MANIFEST_SIZE_MAX = 64 * 1024  # `manifest_size_max` in src/nerva/backup.zig.


def free_ports(count):
    sockets = [socket.socket() for _ in range(count)]
    for s in sockets:
        s.bind(("127.0.0.1", 0))
    ports = [s.getsockname()[1] for s in sockets]
    for s in sockets:
        s.close()
    return ports


def request(port, method, target, body=None, timeout=60):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request(method, target, body=None if body is None else json.dumps(body),
                           headers={"X-Nerva-Key": KEY})
        response = connection.getresponse()
        return response.status, json.loads(response.read() or b"null")
    finally:
        connection.close()


def ok(port, method, target, body=None):
    status, reply = request(port, method, target, body)
    assert status == 200, (method, target, body, status, reply)
    return reply


def seat(id, round):
    return {"kind": "put", "table": SEATS, "id": str(id),
            "fields": {"section": round % 5, "price": (round * 37) % 1000,
                       "sold": round % 3 != 0}}


class Writer(threading.Thread):
    """Commits one seat put after another until stopped; `ops` are the acknowledged ops."""

    def __init__(self, port):
        super().__init__(daemon=True)
        self.port = port
        self.ops = []
        self.stopping = False
        self.failure = None

    def run(self):
        try:
            round = 0
            while not self.stopping:
                try:
                    status, reply = request(self.port, "POST", "/v1/commit", {"entries": [
                        seat(round % 97, round)]})
                except (OSError, http.client.HTTPException):
                    time.sleep(0.2)
                    continue
                if status == 200:
                    self.ops.append(int(reply["op"]))
                    round += 1
                else:
                    assert status in (503, 504), (status, reply)
                    time.sleep(0.2)
                time.sleep(0.005)
        except BaseException as error:  # noqa: BLE001
            self.failure = error

    def wait_for(self, count, seconds=180):
        target = len(self.ops) + count
        deadline = time.monotonic() + seconds
        while len(self.ops) < target:
            assert self.failure is None, self.failure
            assert time.monotonic() < deadline, f"only {len(self.ops)} of {target} commits"
            time.sleep(0.05)

    def finish(self):
        self.stopping = True
        self.join(60)
        assert self.failure is None, self.failure


class Cluster:
    """`count` replicas of `nerva` at `cluster`, from data files `prepare(index, path)` makes."""

    def __init__(self, tmp, name, nerva, count, cluster, prepare):
        self.tmp, self.name, self.nerva = tmp, name, nerva
        self.count, self.cluster = count, cluster
        self.ports = free_ports(count)
        self.addresses = ",".join(str(port) for port in self.ports)
        self.replicas = [None] * count
        self.gateway_process = None
        try:
            for index in range(count):
                prepare(self, index, self.data_file(index))
            for index in range(count):
                self.start(index)
            self.wait_listening()
        except BaseException:
            self.close()
            raise

    def data_file(self, index):
        return os.path.join(self.tmp, f"{self.name}_{index}.nerva")

    def log(self, index):
        path = self.data_file(index) + ".log"
        if not os.path.exists(path):
            return ""
        with open(path, errors="replace") as f:
            return f.read()

    def start(self, index):
        assert self.replicas[index] is None
        self.replicas[index] = subprocess.Popen(
            [self.nerva, "start", f"--addresses={self.addresses}", "--development",
             self.data_file(index)],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=open(self.data_file(index) + ".log", "a"))

    def wait_listening(self):
        """A replica opens its data file for a while before it accepts connections."""
        deadline = time.monotonic() + 120
        for index in range(self.count):
            while True:
                assert self.replicas[index].poll() is None, self.log(index)[-3000:]
                try:
                    socket.create_connection(("127.0.0.1", self.ports[index]), timeout=1).close()
                    break
                except OSError:
                    assert time.monotonic() < deadline, self.log(index)[-3000:]
                    time.sleep(0.1)

    def gateway(self):
        log = os.path.join(self.tmp, f"{self.name}_api.log")
        self.gateway_process = subprocess.Popen(
            [self.nerva, "api", f"--cluster={self.cluster}", f"--addresses={self.addresses}",
             "--listen=127.0.0.1:0"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=open(log, "w"), env={**os.environ, "NERVA_KEY": KEY}, text=True)
        line = self.gateway_process.stdout.readline()
        assert line, f"the gateway exited: {open(log, errors='replace').read()[-3000:]}"
        return int(line)

    def check_no_panic(self):
        for index in range(self.count):
            assert "panic" not in self.log(index), self.log(index)[-3000:]

    def stop(self):
        for process in [self.gateway_process] + self.replicas:
            if process is not None:
                process.kill()
                process.wait()
        self.gateway_process = None
        self.replicas = [None] * self.count

    def remove_files(self):
        """Data files are large: remove them once done with."""
        for index in range(self.count):
            for suffix in ("", ".log", ".importing"):
                path = self.data_file(index) + suffix
                if os.path.exists(path):
                    os.remove(path)

    def close(self):
        self.stop()
        self.remove_files()


def format_prepare(cluster, index, path):
    subprocess.run([cluster.nerva, "format", f"--cluster={cluster.cluster}", f"--replica={index}",
                    f"--replica-count={cluster.count}", "--development", path],
                   check=True, capture_output=True)


def restore_command(nerva, cluster, index, count, backup, manifest, path):
    return subprocess.run(
        [nerva, "restore", f"--cluster={cluster}", f"--replica={index}",
         f"--replica-count={count}", f"--input={backup}", f"--manifest={manifest}",
         "--development", path], capture_output=True, text=True, timeout=600)


def check_refusal(result, code, *, files=()):
    """A refusal is one coded line, its cause and its fix; exit status 1; nothing written."""
    assert result.returncode == 1, (result.returncode, result.stderr[-2000:])
    lines = result.stderr.strip().splitlines()
    # Log lines (timestamped) may come first; the diagnostic is the last three lines.
    assert all(re.match(r"\d{4}-\d\d-\d\d", line) for line in lines[:-3]), result.stderr
    lines = lines[-3:]
    assert lines[0].startswith(f"error[NRV-{code}]: "), result.stderr
    assert lines[1].startswith("  cause  ") and lines[2].startswith("  fix    "), result.stderr
    assert "error." not in "".join(lines) and "panic" not in result.stderr, result.stderr
    for path in files:
        assert not os.path.exists(path), f"{path} was written"
    return lines[0]


def view_header(port, as_of=None):
    target = "/v1/views/early/groups?limit=1" + ("" if as_of is None else f"&as_of={as_of}")
    body = ok(port, "GET", target)
    return {"state": body["state"], "view_hash": body["view_hash"],
            "groups": str(body["group_count"])}


def ledger_total(port, as_of):
    """The ledger's fields summed over its rows, as of the backup's op."""
    rows = [ok(port, "GET", f"/v1/row?table={table}&id=1&as_of={as_of}")
            for table in (ACCOUNTS, SOURCES)]
    return sum(int(v) for row in rows for v in row["fields"].values())


def wait_view_ready(port):
    deadline = time.monotonic() + 120
    while view_header(port)["state"] != "ready":
        assert time.monotonic() < deadline, "the view never became ready"
        time.sleep(0.2)


def compare_with_manifest(port, manifest, what):
    """Every view's hash and group count and every ledger's total, as the manifest says."""
    wait_view_ready(port)
    [view] = manifest["views"]
    header = view_header(port)
    assert header == {"state": view["state"], "view_hash": view["view_hash"],
                      "groups": view["groups"]}, (what, header, view)
    [ledger] = manifest["ledgers"]
    total = ledger_total(port, manifest["op"])
    assert str(total) == ledger["total"], (what, total, ledger)
    print(f"  {what}: view {view['name']} hash {view['view_hash'][:12]}…, "
          f"{view['groups']} groups, ledger {ledger['id']} total {ledger['total']} "
          "match the manifest")


def backup(nerva, cluster, addresses, output, *flags):
    return subprocess.run(
        [nerva, "backup", f"--cluster={cluster}", f"--addresses={addresses}",
         f"--output={output}", *flags], capture_output=True, text=True, timeout=300)


def main(tmp, nerva):
    os.umask(0o022)  # #302: the modes asserted below must not come from the caller's umask
    cluster = Cluster(tmp, "first", nerva, 3, 0, format_prepare)
    writer = None
    restored = None
    try:
        port = cluster.gateway()
        for table, layout in ((SEATS, SEATS_LAYOUT), (ACCOUNTS, ACCOUNTS_LAYOUT),
                              (SOURCES, SOURCES_LAYOUT)):
            ok(port, "PUT", f"/v1/tables/{table}", layout)
        assert ok(port, "PUT", "/v1/views/early", VIEW)["maintained"]
        assert ok(port, "PUT", "/v1/ledgers/1", LEDGER)["declared"] == "created"
        # A pair: the ledger moves value, its total stays zero.
        ok(port, "POST", "/v1/commit", {"entries": [
            {"kind": "add", "table": SOURCES, "id": "1", "field": "balance",
             "delta": "-100000", "pair": True, "create": True},
            {"kind": "add", "table": ACCOUNTS, "id": "1", "field": "available",
             "delta_from": 0, "create": True}]})
        wait_view_ready(port)

        writer = Writer(port)
        writer.start()
        writer.wait_for(400)
        as_of = writer.ops[200]

        # ---- backup, under writes ----
        output = os.path.join(tmp, "first.backup")
        manifest_path = output + ".manifest.json"
        before = len(writer.ops)
        result = backup(nerva, 0, cluster.addresses, output, f"--as-of={as_of}")
        assert result.returncode == 0, result.stderr[-3000:]
        assert len(writer.ops) > before, "the writer stopped while the backup ran"
        match = re.fullmatch(r"backup (\S+): op (\d+), sha256 ([0-9a-f]{64})\nmanifest (\S+)\n",
                             result.stdout)
        assert match, result.stdout
        assert match.group(1) == output and int(match.group(2)) == as_of, result.stdout
        assert match.group(4) == manifest_path, result.stdout
        # #302: the backup and its manifest are owner-only, whatever the umask (022 here).
        for path in (output, manifest_path):
            assert os.stat(path).st_mode & 0o777 == 0o600, (path, oct(os.stat(path).st_mode))
        sha256 = match.group(3)
        with open(output, "rb") as f:
            data = f.read()
        # The export's identity is its `end` record's SHA-256, before the record's CRC.
        assert data[-36:-4].hex() == sha256
        with open(manifest_path, "rb") as f:
            text = f.read()
        assert text.endswith(b"\n") and text.count(b"\n") == 1 and b" " not in text
        manifest = json.loads(text)
        assert list(manifest) == ["format", "version", "release", "cluster", "op", "export_sha256",
                                  "export_size", "export_version", "views", "ledgers"], manifest
        assert manifest["format"] == "nerva-backup" and manifest["version"] == 1
        assert re.fullmatch(r"\d+\.\d+\.\d+", manifest["release"]), manifest
        assert manifest["cluster"] == "0" and manifest["op"] == str(as_of), manifest
        assert manifest["export_sha256"] == sha256
        assert manifest["export_size"] == str(len(data)), manifest
        assert manifest["export_version"] == 1, manifest
        assert len(manifest["views"]) == 1 and len(manifest["ledgers"]) == 1, manifest
        # What the cluster itself says as of that op.
        [view] = manifest["views"]
        assert view["name"] == "early" and view["id"] == 1 and view["state"] == "ready", view
        assert view_header(port, as_of) == {"state": "ready", "view_hash": view["view_hash"],
                                            "groups": view["groups"]}, (view_header(port, as_of),
                                                                        view)
        assert manifest["ledgers"] == [{"id": 1, "total": "0"}], manifest
        print(f"backup: op {as_of}, {len(data)} bytes, sha256 {sha256[:12]}…, written under writes")

        # ---- a restore drill into another cluster, while the first one commits ----
        def restore_prepare(drill, index, path):
            drill.result = restore_command(nerva, DRILL_CLUSTER, index, 1, output, manifest_path,
                                           path)
            assert drill.result.returncode == 0, drill.result.stderr[-3000:]

        before = len(writer.ops)
        drill = Cluster(tmp, "drill", nerva, 1, DRILL_CLUSTER, restore_prepare)
        try:
            line = (f"restored replica 0 from backup {sha256} at op {as_of}: "
                    "1 view and 1 ledger match the manifest")
            assert drill.result.stdout.strip() == line, drill.result.stdout
            assert "start this replica only with every replica imported" in drill.result.stderr, \
                drill.result.stderr
            drill_port = drill.gateway()
            compare_with_manifest(drill_port, manifest, "drill (cluster 7)")
            assert view_header(drill_port, as_of)["view_hash"] == view["view_hash"]
            drill.check_no_panic()
        finally:
            drill.close()
        writer.wait_for(20)
        assert len(writer.ops) > before, "the first cluster stopped committing"
        print("restore drill: one replica of cluster 7 matches the manifest while cluster 0 "
              f"committed {len(writer.ops) - before} more ops")

        # ---- the refusals, with the cluster still running ----
        refusals(tmp, nerva, cluster, output, manifest_path, manifest, data, text)

        # ---- stop and wipe the first cluster, restore its three replicas ----
        writer.finish()
        cluster.close()
        assert not os.path.exists(cluster.data_file(0))

        def restore_all(restored_cluster, index, path):
            result = restore_command(nerva, 0, index, 3, output, manifest_path, path)
            assert result.returncode == 0, result.stderr[-3000:]
            assert result.stdout.strip() == (
                f"restored replica {index} from backup {sha256} at op {as_of}: "
                "1 view and 1 ledger match the manifest"), result.stdout

        restored = Cluster(tmp, "restored", nerva, 3, 0, restore_all)
        restored_port = restored.gateway()
        compare_with_manifest(restored_port, manifest, "restored cluster 0 (3 replicas)")
        # It takes writes again.
        ok(restored_port, "POST", "/v1/commit", {"entries": [seat(1, 1)]})
        restored.check_no_panic()
        print("restore: the three replicas of cluster 0 match the manifest and take writes")
    finally:
        if writer is not None:
            writer.stopping = True
        cluster.close()
        if restored is not None:
            restored.close()


def refusals(tmp, nerva, cluster, output, manifest_path, manifest, data, text):
    path = os.path.join(tmp, "refused.nerva")
    nothing = (path, path + ".importing")

    # A backup with one byte changed: pass 1 finds it (its CRC or its SHA-256).
    changed = os.path.join(tmp, "changed.backup")
    with open(changed, "wb") as f:
        middle = len(data) // 2
        f.write(data[:middle] + bytes([data[middle] ^ 0x01]) + data[middle + 1:])
    result = restore_command(nerva, 0, 0, 3, changed, manifest_path, path)
    line = check_refusal(result, "E0804", files=nothing)
    assert changed in line, line

    # The manifest of another backup: the cluster has gone on, so its op and size differ.
    other = os.path.join(tmp, "other.backup")
    result = backup(nerva, 0, cluster.addresses, other, "--as-of=latest")
    assert result.returncode == 0, result.stderr[-3000:]
    result = restore_command(nerva, 0, 0, 3, output, other + ".manifest.json", path)
    line = check_refusal(result, "E0809", files=nothing)
    assert "does not match" in line and other + ".manifest.json" in line, line
    result = restore_command(nerva, 0, 0, 3, other, manifest_path, path)
    line = check_refusal(result, "E0809", files=nothing)
    assert "the backup is" in line, line

    # A manifest with one view hash changed.
    [view] = manifest["views"]
    digit = view["view_hash"][0]
    wrong = ("0" if digit != "0" else "1") + view["view_hash"][1:]
    altered = os.path.join(tmp, "altered.manifest.json")
    with open(altered, "wb") as f:
        f.write(text.replace(view["view_hash"].encode(), wrong.encode(), 1))
    result = restore_command(nerva, 0, 0, 3, output, altered, path)
    line = check_refusal(result, "E0809", files=nothing)
    assert "view early's hash is" in line, line

    # The ledger's total changed.
    altered_total = os.path.join(tmp, "total.manifest.json")
    with open(altered_total, "wb") as f:
        f.write(text.replace(b'"total":"0"', b'"total":"7"', 1))
    result = restore_command(nerva, 0, 0, 3, output, altered_total, path)
    line = check_refusal(result, "E0809", files=nothing)
    assert "ledger 1's total is 0" in line, line

    # A missing manifest, and manifests that are not one.
    result = restore_command(nerva, 0, 0, 3, output, os.path.join(tmp, "missing.json"), path)
    line = check_refusal(result, "E0808", files=nothing)
    assert "does not exist" in line, line
    bad = os.path.join(tmp, "bad.manifest.json")
    cases = {
        "truncated": text[:-5],
        "not json": b"hello\n",
        "empty": b"",
        "unknown version": text.replace(b'"version":1', b'"version":2', 1),
        "a number with a leading zero": text.replace(b'"op":"', b'"op":"0', 1),
        "too large": b" " * (MANIFEST_SIZE_MAX + 1),
    }
    for what, content in cases.items():
        with open(bad, "wb") as f:
            f.write(content)
        result = restore_command(nerva, 0, 0, 3, output, bad, path)
        line = check_refusal(result, "E0808", files=nothing)
        assert bad in line, (what, line)

    # `backup` itself: neither file is overwritten, and a refusal leaves nothing.
    result = backup(nerva, 0, cluster.addresses, output)
    line = check_refusal(result, "E0004")
    assert output in line, line
    with open(output, "rb") as f:
        assert f.read() == data
    lonely = os.path.join(tmp, "lonely.backup")
    with open(lonely + ".manifest.json", "w") as f:
        f.write("keep me\n")
    result = backup(nerva, 0, cluster.addresses, lonely)
    check_refusal(result, "E0004", files=(lonely,))
    with open(lonely + ".manifest.json") as f:
        assert f.read() == "keep me\n"
    ahead = os.path.join(tmp, "ahead.backup")
    result = backup(nerva, 0, cluster.addresses, ahead, f"--as-of={1 << 40}")
    check_refusal(result, "E0802", files=(ahead, ahead + ".manifest.json"))
    print("refusals: a changed backup, another backup's manifest, a changed view hash and ledger "
          "total, a missing and six malformed manifests, and the three refusals of backup: "
          "one coded line each, nothing written")


if __name__ == "__main__":
    tmp = tempfile.mkdtemp(prefix="nerva-restore-")
    try:
        main(tmp, os.path.abspath(sys.argv[1]))
        print("restore.py: ok")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
