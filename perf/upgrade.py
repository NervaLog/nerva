#!/usr/bin/env python3
"""Measures `nerva export` and `nerva import` (docs/DECISIONS.md N80): wall time and peak memory.

Usage: upgrade.py <nerva> <bench-load> [--changes=1000000] [--batch=1024]
                  [--dir=<scratch directory>] [--development]

Starts one replica and loads at least `--changes` changes with `bench-load` (the performance
harness's load generator, N55: workload c1, blind puts of `--batch` distinct rows per request,
over `--changes` keys), then exports them, and imports the export into one data file. Each
step is timed, with the peak resident memory of its process. Prints one JSON object per step, as
`perf/nightly/run.sh` does. Every file is removed at the end: a data file of a million rows
takes about 2 GiB.
"""
import json
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

# Replicas authenticate each other with a real cluster key, never the development key (N86).
os.environ["NERVA_CLUSTER_KEY"] = os.urandom(32).hex()


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def timed(argv, log):
    """Runs `argv` to completion: (seconds, the process's peak RSS in MiB, its stderr)."""
    started = time.monotonic()
    with open(log, "w") as stderr:
        process = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=stderr)
        _, status, usage = os.wait4(process.pid, 0)
    seconds = time.monotonic() - started
    with open(log) as f:
        text = f.read()
    assert os.waitstatus_to_exitcode(status) == 0, text[-3000:]
    return seconds, usage.ru_maxrss / 1024, text


def main():
    nerva, bench_load = sys.argv[1], sys.argv[2]
    options = dict(arg[2:].split("=", 1) if "=" in arg else (arg[2:], "1")
                   for arg in sys.argv[3:])
    changes = int(options.get("changes", 1_000_000))
    batch = int(options.get("batch", 1024))
    development = ["--development"] if "development" in options else []
    tmp = tempfile.mkdtemp(prefix="nerva-upgrade-perf-", dir=options.get("dir"))
    replica = None
    try:
        data = os.path.join(tmp, "old.nerva")
        subprocess.run([nerva, "format", "--cluster=0", "--replica=0", "--replica-count=1",
                        *development, data], check=True, capture_output=True)
        address = f"127.0.0.1:{free_port()}"
        replica = subprocess.Popen([nerva, "start", f"--addresses={address}", *development, data],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)

        # bench-load runs for a time, not a count: a one-second run measures the rate, then one
        # run long enough for the rest (each run starts again from the same keys).
        def load(seconds):
            out = subprocess.run([bench_load, f"--addresses={address}", "--workload=c1",
                                  f"--batch={batch}", "--clients=4", f"--seconds={seconds}",
                                  f"--keys={changes}"], capture_output=True, text=True)
            assert out.returncode == 0, out.stderr[-2000:]
            return json.loads(out.stdout)["entries"]

        started = time.monotonic()
        loaded = load(1)
        while loaded < changes:
            loaded += load(max(1, math.ceil((changes - loaded) / loaded * 1.1)))
        load_seconds = time.monotonic() - started

        export = os.path.join(tmp, "cluster.nerva-export")
        seconds, peak, stderr = timed([nerva, "export", "--cluster=0", f"--addresses={address}",
                                       f"--output={export}"], os.path.join(tmp, "export.log"))
        replica.kill()
        replica.wait()
        replica = None
        os.remove(data)
        exported, rows = (int(n) for n in re.findall(r"(\d+) changes, (\d+) rows", stderr)[0])
        assert exported == loaded, (exported, loaded)
        print(json.dumps({"step": "export", "changes": exported, "rows": rows, "batch": batch,
                          "seconds": round(seconds, 1), "peak_rss_mib": round(peak),
                          "bytes": os.path.getsize(export), "load_seconds": round(load_seconds)}))

        imported = os.path.join(tmp, "new.nerva")
        seconds, peak, stderr = timed([nerva, "import", "--cluster=0", "--replica=0",
                                       "--replica-count=1", f"--input={export}", *development,
                                       imported], os.path.join(tmp, "import.log"))
        assert "checks passed" in stderr, stderr[-3000:]
        print(json.dumps({"step": "import", "changes": exported, "rows": rows, "batch": batch,
                          "seconds": round(seconds, 1), "peak_rss_mib": round(peak),
                          "data_file_bytes": os.path.getsize(imported)}))
    finally:
        if replica is not None:
            replica.kill()
            replica.wait()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
