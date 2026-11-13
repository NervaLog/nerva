#!/usr/bin/env python3
"""The simulation fleet's reporter (ops/sim-fleet/README.md, P147h).

    sim_fleet.py ingest --round DIR --round-id ID --commit SHA --state FILE [--source-root DIR]
                        [--repo OWNER/NAME --token-file FILE] [--tracker N] [--dry-run]
    sim_fleet.py refuse --round-id ID --commit SHA --state FILE
    sim_fleet.py soak --commit SHA --state FILE

Reads one round that `run.sh` wrote: each worker's directory `DIR/w<N>/` holds `results`, one
line per seed run (`<target> <seed> <exit code> <seconds>`), and for each failing seed a
directory `fail-<target>-<seed>/` with `tail.log` (the last bytes of its output) and, for a VOPR
correctness failure, `errors.log` (the last `[err]` lines of a full-log replay). Targets are
`vopr-nerva`, `vopr-testing` and `fuzz:<fuzzer>`.

It counts the seeds per UTC day in the state file and, on the first round of a new day, first
posts each finished day's totals on the tracking issue. Then each distinct failure (its
fingerprint: target, exit class and normalised signature; never the seed or the commit) that no
issue carries becomes an issue labelled `sim-fleet`; one that has an issue gets a comment only
for a commit it has not been reported on, at most `COMMENTS_PER_FAILURE_PER_DAY` times a UTC day,
and at most `FAILURES_PER_DAY` distinct failures are looked at a day. A rate limit (429, or 403
with `Retry-After` or no requests left) stops every write and holds them until GitHub's wait is
over. No request follows a redirect, so the token never goes to another host. `--dry-run` asks
GitHub nothing and prints what it would file (it still counts into the state file it is given:
give it a state file of its own). `--source-root` is the checkout the binaries were built in; a
stack frame is Nerva's when its path is under its `src/`.

`soak` prints, from the state file alone, what the release gate asks of the fleet for one commit
(the candidate of the release soak, ops/sim-fleet/README.md): the hours its rounds ran, the seeds
by kind, the failing, deadline-hit and host-killed seeds, the failures its rounds hit (with their
issues) and its refused rounds. A seed counts for at most SEED_SECONDS_MAX seconds. A round's hours
are its busiest worker's seconds (the sum of the `<seconds>` column of that worker's `results`),
so they come from the rounds' own records and never from wall time. Exit 0 if the commit ran and
is clean; 1 if the state has no round of it (`0.0 h`), or any seed of it failed, ran past its
deadline or was killed by the host, or a failure fingerprint was hit, or a round of it was refused
(#370); 2 if the state file is missing or unreadable.

The round's record (P382). `ingest` counts the round, or refuses it whole (more than
ROUND_FAILURES_MAX failing seeds, a malformed `results` line: its seeds are unknown, so it counts
against its commit as `refused`), and saves that in one atomic write of the state file together
with `last_round`, the round's id (`--round-id`, which run.sh makes), before it needs the token or
GitHub. `refuse` records a round `ingest` left unrecorded as refused, and does nothing if it is
recorded. run.sh decides by that record alone, never by an exit code: after `ingest` it looks for
the id in the state file, runs `refuse` if it is not there, and stops with the round kept if it is
still not there. Both commands are idempotent for one id, so a round a stop or a crash left is
ingested again safely. Exit codes are for people: `ingest` 0 counted (or already recorded), 1
not; `refuse` 0 recorded, 1 not; argparse's own 2 for a bad command line. The state is saved
whatever GitHub answered. Standard library only.
"""

import argparse
import datetime
import hashlib
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

LABEL = "sim-fleet"
MARKER = re.compile(r"<!-- vopr-fleet fingerprint: ([0-9a-f]{32}) -->")
STATE_VERSION = 1

# Bounds. Every collection this reads or keeps has one.
RESULTS_LINES_MAX = 500_000  # Seeds per round (a 15-minute round on 64 cores at 1 s a seed: 58k).
ROUND_FAILURES_MAX = 4096  # Failing seeds read per round; past it the round is refused.
LOG_READ_BYTES_MAX = 256 * 1024  # Read of one tail.log or errors.log.
ISSUE_LOG_LINES_MAX = 60  # Lines of log in an issue body.
ISSUE_LOG_BYTES_MAX = 8 * 1024  # Bytes of log in an issue body.
SIGNATURE_FRAMES = 3  # Stack frames inside src/ that name a crash.
SIGNATURE_BYTES_MAX = 300
TITLE_BYTES_MAX = 120
SEEDS_LISTED_MAX = 20  # Other seeds of the round that failed alike, listed in a report.
FILED_MAX = 2048  # Fingerprints remembered.
DAYS_KEPT = 31
COMMITS_KEPT = 64  # Commits whose hours and seeds are remembered (the release soak); the oldest go.
FAILURES_PER_DAY = 64  # Distinct failures looked at a UTC day; the rest are only counted.
COMMENTS_PER_FAILURE_PER_DAY = 4
FIND_PAGES_MAX = 5  # Issue pages (100 each) scanned when the state file is rebuilt.
FIND_PAGE_SIZE = 100
RESPONSE_BYTES_MAX = 8 * 1024 * 1024
TOKEN_BYTES_MAX = 4096
STATE_BYTES_MAX = 4 * 1024 * 1024
HOLD_SECONDS_DEFAULT = 3600
HOLD_SECONDS_MAX = 24 * 3600
HTTP_TIMEOUT_SECONDS = 60

assert COMMENTS_PER_FAILURE_PER_DAY > 0
assert COMMITS_KEPT > 0
assert FAILURES_PER_DAY <= FILED_MAX
assert HOLD_SECONDS_DEFAULT <= HOLD_SECONDS_MAX
assert ISSUE_LOG_BYTES_MAX <= LOG_READ_BYTES_MAX

VOPR_TARGETS = ("vopr-nerva", "vopr-testing")
KINDS = ("vopr-nerva", "vopr-testing", "fuzz")  # What a soak line counts seeds by.
TARGET = re.compile(r"^(vopr-nerva|vopr-testing|fuzz:[a-z0-9_]{1,64})$")
COMMIT = re.compile(r"[0-9a-f]{7,64}")
# A round's id, as run.sh makes it: its start time and 8 random bytes. Saved in `last_round` in
# the same write that counts or refuses the round; run.sh looks for it, quoted, in the state file.
ROUND_ID = re.compile(r"[0-9]{1,20}-[0-9a-f]{16}")
# Exit codes that are the host's, not the code's: counted, never filed. 124: past the per-seed
# deadline (`timeout`); 125, 126: `timeout` or the exec failed; 137: SIGKILL, the OOM killer.
# One seed's seconds count for at most this much: a seed's deadline (600 s VOPR, 900 s fuzz by
# default) plus its replay (1800 s), rounded up. A clock step during a seed cannot add hours.
SEED_SECONDS_MAX = 3600
HOST_CODES = {124: "timeout", 125: "host", 126: "host", 137: "host"}

PANIC = re.compile(r"(?:^|\s)panic: (.+)$")
RETURNED_ERROR = re.compile(r"^error: (\w+)\s*$")
SEGFAULT = re.compile(r"^(Segmentation fault|Illegal instruction|Bus error)\b.*$")
# `/root/nerva/src/vsr/replica.zig:1234:13: 0x10a2b3c in on_prepare (vopr)`. A frame is
# Nerva's when its path starts with `<source root>/src/` (the checkout the binary was built in,
# `--source-root`); without a root, the last `src/` of the path, unless the path is Zig's own
# library (`lib/std`, which `./zig/` keeps inside the checkout).
FRAME = re.compile(r"^(\S+?\.zig):\d+:\d+: 0x[0-9a-fA-F]+ in ([^\s(]+)")
FRAME_SRC = re.compile(r"^(?:.*/)?(src/\S+)$")
CONVERGENCE = re.compile(r"no state convergence: (.+)$")
# The full log mode's prefix is `[<level>] (<scope>): `, and the level of an error is `err`.
ERROR_LINE = re.compile(r"^\[err\] (.+)$")
# Scopes that log at `err` in runs that pass: never a failure's signature.
ERROR_NOISE = re.compile(r"^\((client)\): ")
HEX = re.compile(r"0x[0-9a-fA-F]+")
DIGITS = re.compile(r"[0-9]+")


class BadInput(Exception):
    """The round is not what run.sh writes: refused whole, no seed counted, the round counted
    against its commit as refused."""


class Environment(Exception):
    """The state file or the token."""


# ------------------------------------------------------------------------------------------------
# Fingerprints.


def normalise(text):
    """Addresses out, digits to N, spaces collapsed, bounded: what is left names the bug."""
    text = HEX.sub("ADDR", text)
    text = DIGITS.sub("N", text)
    text = " ".join(text.split())
    return text[:SIGNATURE_BYTES_MAX]


def frame_path(path, source_root):
    """`src/...` for a file of Nerva's, else None."""
    if source_root is not None:
        prefix = source_root.rstrip("/") + "/src/"
        return "src/" + path[len(prefix):] if path.startswith(prefix) else None
    if "/lib/std/" in path or path.startswith("lib/std/"):
        return None
    match = FRAME_SRC.match(path)
    return match.group(1) if match else None


def frames_of(lines, source_root=None):
    """The top frames inside `src/` of the first stack trace, as `src/path.zig:function`."""
    frames = []
    for line in lines:
        match = FRAME.match(line.strip())
        path = frame_path(match.group(1), source_root) if match else None
        if path:
            frames.append(f"{path}:{match.group(2)}")
            if len(frames) == SIGNATURE_FRAMES:
                break
    return frames


def crash_signature(lines, code, source_root=None):
    """A panic's message and its top frames; else a returned error, a fault, or the exit."""
    message = None
    for line in lines:
        stripped = line.strip()
        for pattern in (PANIC, RETURNED_ERROR, SEGFAULT):
            match = pattern.search(stripped)
            if match:
                message = match.group(1) if pattern is not SEGFAULT else match.group(0)
                break
        if message:
            break
    # The exit code itself is not normalised: it is the class of the failure, not noise.
    if message is None:
        signature = f"killed by signal {code - 128}" if code > 128 else f"exit {code}"
    else:
        signature = normalise(message)
    frames = frames_of(lines, source_root)
    if frames:
        signature += " at " + " < ".join(normalise(frame) for frame in frames)
    return signature


def classify(target, code):
    """The exit class of a failing seed. The VOPR's own codes (src/testing/cluster.zig, `Failure`)
    are 127 crash, 128 liveness and 129 correctness; a panic aborts (134) and any other signal or
    exit is a crash too. A fuzzer has only crashes."""
    assert code != 0 and code not in HOST_CODES
    if target in VOPR_TARGETS:
        if code == 128:
            return "liveness"
        if code == 129:
            return "correctness"
    return "crash"


def signature_of(exit_class, code, tail_lines, error_lines, source_root=None):
    if exit_class == "liveness":
        for line in reversed(tail_lines):
            match = CONVERGENCE.search(line)
            if match:
                return normalise("no state convergence: " + match.group(1))
        return "no state convergence (no reason in the log)"
    if exit_class == "correctness":
        # The last one: `fatal` logs the checker's message just before it exits, and a passing
        # run logs `[err] (client): ... session evicted` lines too.
        for line in reversed(error_lines):
            match = ERROR_LINE.match(line.strip())
            if match and not ERROR_NOISE.match(match.group(1)):
                return normalise(match.group(1))
        return "no [err] line (the full-log replay found none)"
    return crash_signature(tail_lines, code, source_root)


def fingerprint_key(target, exit_class, signature):
    """What a fingerprint hashes: never the seed, the commit or the time."""
    return f"{target}|{exit_class}|{signature}"


def fingerprint_of(key):
    return hashlib.sha256(key.encode()).hexdigest()[:32]


def title_of(target, exit_class, signature):
    """Stable and readable: `VOPR nerva liveness: no state convergence: pending request`."""
    if target.startswith("vopr-"):
        who = "VOPR " + target[len("vopr-"):]
    else:
        who = "fuzz " + target[len("fuzz:"):]
    # A crash's title names its top frame only; the body has the three.
    title = f"{who} {exit_class}: {signature.split(' < ')[0]}"
    if len(title) > TITLE_BYTES_MAX:
        title = title[: TITLE_BYTES_MAX - 3] + "..."
    return title


def replay_of(target, seed):
    if target in VOPR_TARGETS:
        machine = target[len("vopr-"):]
        return f"./zig/zig build -Drelease vopr -Dvopr-state-machine={machine} -- {seed}"
    return f"./zig/zig build -Drelease fuzz -- {target[len('fuzz:'):]} {seed}"


# ------------------------------------------------------------------------------------------------
# The round.


def read_bounded(path):
    try:
        with open(path, "rb") as file:
            file.seek(0, os.SEEK_END)
            size = file.tell()
            file.seek(max(0, size - LOG_READ_BYTES_MAX))
            data = file.read(LOG_READ_BYTES_MAX)
    except FileNotFoundError:
        return []
    return data.decode("utf-8", "replace").splitlines()


class Counts(dict):
    """Counts per target; `busy` is each worker's seconds (the sum of its seeds' seconds)."""

    def __init__(self):
        super().__init__()
        self.busy = {}


def read_round(round_dir, source_root=None):
    """Every seed of the round: counts per target (with each worker's busy seconds), and the
    failures to report."""
    if not os.path.isdir(round_dir):
        raise BadInput(f"{round_dir} is not a directory")
    counts = Counts()
    failures = []
    lines_read = 0
    workers = sorted(name for name in os.listdir(round_dir) if re.fullmatch(r"w\d{1,4}", name))
    for worker in workers:
        results = os.path.join(round_dir, worker, "results")
        if not os.path.exists(results):
            continue
        with open(results, encoding="utf-8", errors="replace") as file:
            for line in file:
                lines_read += 1
                if lines_read > RESULTS_LINES_MAX:
                    raise BadInput(f"more than {RESULTS_LINES_MAX} seeds in one round")
                failure = read_result(round_dir, worker, line, counts, source_root)
                if failure is None:
                    continue
                if len(failures) == ROUND_FAILURES_MAX:
                    raise BadInput(f"more than {ROUND_FAILURES_MAX} failing seeds in one round")
                failures.append(failure)
    return counts, failures


def read_result(round_dir, worker, line, counts, source_root):
    fields = line.split()
    if len(fields) != 4:
        raise BadInput(f"{worker}/results: not `<target> <seed> <code> <seconds>`: {line!r}")
    target, seed, code, seconds = fields
    if not TARGET.match(target):
        raise BadInput(f"{worker}/results: unknown target {target!r}")
    if not (seed.isdigit() and code.isdigit() and seconds.isdigit()):
        raise BadInput(f"{worker}/results: seed, code and seconds must be numbers: {line!r}")
    code = int(code)
    if int(seed) >= 2**64 or code > 255:
        raise BadInput(f"{worker}/results: seed or exit code out of range: {line!r}")
    count = counts.setdefault(target, {"seeds": 0, "failed": 0, "timeouts": 0, "host": 0})
    count["seeds"] += 1
    if hasattr(counts, "busy"):
        counts.busy[worker] = counts.busy.get(worker, 0) + min(int(seconds), SEED_SECONDS_MAX)
    if code == 0:
        return None
    if code in HOST_CODES:
        count["timeouts" if HOST_CODES[code] == "timeout" else "host"] += 1
        return None
    count["failed"] += 1
    fail_dir = os.path.join(round_dir, worker, f"fail-{target.replace(':', '-')}-{seed}")
    tail = read_bounded(os.path.join(fail_dir, "tail.log"))
    errors = read_bounded(os.path.join(fail_dir, "errors.log"))
    exit_class = classify(target, code)
    signature = signature_of(exit_class, code, tail, errors, source_root)
    key = fingerprint_key(target, exit_class, signature)
    return {
        "target": target,
        "seed": seed,
        "code": code,
        "class": exit_class,
        "signature": signature,
        "key": key,
        "fingerprint": fingerprint_of(key),
        "tail": tail,
        "errors": errors,
    }


def group_failures(failures):
    """Failures by fingerprint, in the order first seen."""
    groups = {}
    for failure in failures:
        groups.setdefault(failure["fingerprint"], []).append(failure)
    return list(groups.values())


def log_excerpt(lines):
    """The last lines of a log, bounded in lines and bytes, safe inside a code fence."""
    kept = []
    size = 0
    for line in reversed(lines[-ISSUE_LOG_LINES_MAX:]):
        line = line.replace("```", "'''")
        if size + len(line) + 1 > ISSUE_LOG_BYTES_MAX:
            break
        kept.append(line)
        size += len(line) + 1
    return "\n".join(reversed(kept))


def report_text(group, commit, first):
    """An issue body (`first`) or a comment: the same facts, the marker only in the body."""
    failure = group[0]
    out = []
    if first:
        out.append(f"The simulation fleet (ops/sim-fleet/README.md) found this on `main`.\n")
    else:
        out.append(f"Failed again, on commit `{commit}`.\n")
    out.append(f"- **Run:** `{failure['target']}`, {failure['class']} (exit {failure['code']})")
    out.append(f"- **Signature:** `{failure['signature']}`")
    out.append(f"- **Commit:** `{commit}`")
    out.append(f"- **Seed:** `{failure['seed']}`")
    out.append("")
    out.append("Replay exactly:")
    out.append("")
    out.append("```")
    out.append(f"git checkout {commit} && {replay_of(failure['target'], failure['seed'])}")
    out.append("```")
    if len(group) > 1:
        seeds = ", ".join(f"`{other['seed']}`" for other in group[1:SEEDS_LISTED_MAX + 1])
        more = len(group) - 1 - min(len(group) - 1, SEEDS_LISTED_MAX)
        out.append("")
        out.append(f"Other seeds of the same round that failed alike: {seeds}"
                   + (f" and {more} more" if more else "") + ".")
    if failure["class"] == "correctness" and failure["errors"]:
        out.append("")
        out.append("The last `[err]` lines of a full-log replay (`-Dvopr-log=full`):")
        out.append("")
        out.append("```")
        out.append(log_excerpt(failure["errors"]))
        out.append("```")
    out.append("")
    out.append(f"Tail of the log (at most {ISSUE_LOG_LINES_MAX} lines):")
    out.append("")
    out.append("```")
    out.append(log_excerpt(failure["tail"]) or "(no output)")
    out.append("```")
    if first:
        out.append("")
        out.append(f"<!-- vopr-fleet fingerprint: {failure['fingerprint']} -->")
        out.append(f"<!-- vopr-fleet key: {html_comment_safe(failure['key'])} -->")
    return "\n".join(out) + "\n"


def html_comment_safe(text):
    return text.replace("--", "- -")


# ------------------------------------------------------------------------------------------------
# State.


def ymd(now):
    return datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y-%m-%d")


def new_state():
    return {"version": STATE_VERSION, "filed": {}, "days": {}, "hold_until": 0, "commits": {},
            "sequence": 0}


def load_state(path):
    """None if the file is missing (rebuild it from the issues); an unreadable file is an error,
    never taken for empty."""
    try:
        with open(path, "rb") as file:
            data = file.read(STATE_BYTES_MAX + 1)
    except FileNotFoundError:
        return None
    except OSError as err:
        raise Environment(f"cannot read the state file {path}: {err}")
    if len(data) > STATE_BYTES_MAX:
        raise Environment(f"the state file {path} is larger than {STATE_BYTES_MAX} bytes")
    try:
        state = json.loads(data)
    except ValueError as err:
        raise Environment(f"the state file {path} is not JSON: {err}")
    if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
        raise Environment(f"the state file {path} is not version {STATE_VERSION}")
    for key, kind in (("filed", dict), ("days", dict), ("hold_until", int)):
        if not isinstance(state.get(key), kind):
            raise Environment(f"the state file {path} has no valid `{key}`")
    if len(state["filed"]) > FILED_MAX:
        raise Environment(f"the state file {path} remembers more than {FILED_MAX} failures")
    # Written by a fleet that did not count commits: start counting, nothing is invented.
    state.setdefault("commits", {})
    state.setdefault("sequence", 0)
    if not isinstance(state["commits"], dict) or not isinstance(state["sequence"], int):
        raise Environment(f"the state file {path} has no valid `commits`")
    if len(state["commits"]) > COMMITS_KEPT:
        raise Environment(f"the state file {path} remembers more than {COMMITS_KEPT} commits")
    return state


def save_state(path, state):
    assert len(state["filed"]) <= FILED_MAX
    assert len(state["commits"]) <= COMMITS_KEPT
    data = json.dumps(state, indent=1, sort_keys=True).encode()
    assert len(data) <= STATE_BYTES_MAX
    temporary = path + ".new"
    with open(temporary, "wb") as file:
        file.write(data)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)
    # The rename itself must outlive a power cut: it carries a round's record (`last_round`).
    folder = os.open(os.path.dirname(os.path.abspath(path)), os.O_RDONLY)
    try:
        os.fsync(folder)
    finally:
        os.close(folder)


def day_of(state, today):
    day = state["days"].get(today)
    if day is None:
        day = {"reported": False, "rounds": 0, "commit": "", "targets": {}, "seen": {},
               "overflow": 0, "commits": {}}
        state["days"][today] = day
        for old in sorted(state["days"])[:-DAYS_KEPT]:
            del state["days"][old]
    return day


def kind_of(target):
    return "fuzz" if target.startswith("fuzz:") else target


def round_seconds(counts):
    """A round's hours, as seconds: its busiest worker's. Workers run at once, so no worker's
    busy time exceeds the round's wall time, and the fleet never claims more than ran."""
    return max(getattr(counts, "busy", {}).values(), default=0)


def commit_entry(entries, commit, sequence):
    """The entry of `commit` in `entries` (the state's, or a day's), made if new; past
    COMMITS_KEPT the entry least recently counted is dropped."""
    entry = entries.get(commit)
    if entry is None:
        while len(entries) >= COMMITS_KEPT:
            oldest = min(entries, key=lambda sha: entries[sha]["last"])
            del entries[oldest]
        entry = {"last": sequence, "seconds": 0, "rounds": 0, "kinds": {}, "fingerprints": [],
                 "dropped": 0, "refused": 0}
        entries[commit] = entry
    entry["last"] = sequence
    assert len(entries) <= COMMITS_KEPT
    return entry


def add_round(entry, counts):
    entry["rounds"] += 1
    entry["seconds"] += round_seconds(counts)
    for target, count in counts.items():
        kind = entry["kinds"].setdefault(kind_of(target), {"seeds": 0, "failed": 0,
                                                           "timeouts": 0, "host": 0})
        for key in ("seeds", "failed", "timeouts", "host"):
            kind[key] = kind.get(key, 0) + count[key]
    assert len(entry["kinds"]) <= len(KINDS)


def refuse_round(state, commit):
    """Counts a round the reporter could not read against `commit`: its seeds are unknown, so it
    makes the commit not clean for `soak` instead of vanishing (#370). A counter, so it is
    bounded by the rounds the fleet runs."""
    state["sequence"] += 1
    entry = commit_entry(state["commits"], commit, state["sequence"])
    entry["refused"] = entry.get("refused", 0) + 1
    assert entry["refused"] > 0


def count_round(day, counts, commit, state=None):
    day["rounds"] += 1
    day["commit"] = commit
    for target, count in counts.items():
        total = day["targets"].setdefault(target, {"seeds": 0, "failed": 0, "timeouts": 0,
                                                   "host": 0})
        for key in total:
            total[key] += count[key]
    if state is not None:
        state["sequence"] += 1
        add_round(commit_entry(day.setdefault("commits", {}), commit, state["sequence"]), counts)
        add_round(commit_entry(state["commits"], commit, state["sequence"]), counts)


def record_fingerprints(state, commit, groups):
    """The failures a commit's rounds hit, whether or not a report was posted (a hold, a rate
    limit or a day's cap stop reports, not this). Bounded by FAILURES_PER_DAY; the rest are
    only counted."""
    entry = state["commits"][commit]
    for group in groups:
        fingerprint = group[0]["fingerprint"]
        if fingerprint in entry["fingerprints"]:
            continue
        if len(entry["fingerprints"]) >= FAILURES_PER_DAY:
            entry["dropped"] += 1
            continue
        entry["fingerprints"].append(fingerprint)
    assert len(entry["fingerprints"]) <= FAILURES_PER_DAY


def see(day, fingerprint, seeds):
    """Today's entry for a failure, or None past the day's cap on distinct failures."""
    seen = day["seen"].get(fingerprint)
    if seen is None:
        if len(day["seen"]) >= FAILURES_PER_DAY:
            day["overflow"] += seeds
            return None
        seen = {"comments": 0, "seeds": 0}
        day["seen"][fingerprint] = seen
    seen["seeds"] += seeds
    return seen


def remember(state, fingerprint, number, first_commit, last_commit):
    if fingerprint not in state["filed"] and len(state["filed"]) >= FILED_MAX:
        # The oldest-filed go first: they are found again by their marker if they recur.
        oldest = min(state["filed"], key=lambda fp: state["filed"][fp]["issue"])
        del state["filed"][oldest]
    state["filed"][fingerprint] = {"issue": number, "first_commit": first_commit,
                                   "last_commit": last_commit}
    assert len(state["filed"]) <= FILED_MAX


def hours_text(seconds):
    return f"{seconds // 360 / 10:.1f}"  # Floor to a tenth: never more hours than ran.


def seeds_of(entry):
    return sum(kind["seeds"] for kind in entry["kinds"].values())


def soak_line(state, commit):
    """The line the release PR quotes, whether the commit ran at all, and whether it is clean
    (no failing, hung or killed seed, no failure fingerprint). `commit` is a full SHA or a prefix
    of at least 7 hex digits; one that names two commits is not a commit."""
    matches = [sha for sha in state["commits"] if sha.startswith(commit)]
    entry = state["commits"][matches[0]] if len(matches) == 1 else \
        {"seconds": 0, "kinds": {}, "fingerprints": [], "dropped": 0}
    kinds = [f"{kind} {entry['kinds'].get(kind, {}).get('seeds', 0):,}" +
             (" seeds" if index == 0 else "") for index, kind in enumerate(KINDS)]
    sums = {key: sum(kind.get(key, 0) for kind in entry["kinds"].values())
            for key in ("failed", "timeouts", "host")}
    refused = entry.get("refused", 0)
    hit = []
    for fingerprint in entry.get("fingerprints", []):
        filed = state["filed"].get(fingerprint)
        hit.append(f"#{filed['issue']}" if filed else f"not filed ({fingerprint[:12]})")
    if entry.get("dropped"):
        hit.append(f"{entry['dropped']} more not listed")
    line = (f"soak {commit[:7]}: {hours_text(entry['seconds'])} h, {', '.join(kinds)}; "
            f"{sums['failed']} failures, {sums['timeouts']} past the deadline, "
            f"{sums['host']} killed by the host; sim-fleet issues its rounds hit: "
            f"{', '.join(hit) or 'none'}")
    if refused:
        line += f"; {refused} rounds refused or lost by the reporter, their seeds unknown"
    ran = len(matches) == 1 and (entry["seconds"] > 0 or refused > 0)
    return line, ran, not (any(sums.values()) or hit or refused)


def totals_text(state, ymd_day, day):
    targets = day["targets"]
    seeds = sum(t["seeds"] for t in targets.values())
    failed = sum(t["failed"] for t in targets.values())
    out = [f"{ymd_day} (UTC): {seeds} seeds run, {failed} failed, in {day['rounds']} rounds; the "
           f"last ran at commit `{day['commit']}`. A day with no comment here means the fleet "
           f"did not run.", "", "Seeds by run:"]
    for target in sorted(targets):
        total = targets[target]
        out.append(f"- {target}: {total['seeds']} seeds, {total['failed']} failed, "
                   f"{total['timeouts']} past the per-seed deadline, {total['host']} killed "
                   f"by the host")
    if day.get("commits"):
        out.append("")
        out.append("Commits that ran:")
        for sha in sorted(day["commits"], key=lambda sha: day["commits"][sha]["last"]):
            out.append(f"- `{sha[:7]}`: {hours_text(day['commits'][sha]['seconds'])} h that day, "
                       f"{hours_text(state['commits'].get(sha, day['commits'][sha])['seconds'])}"
                       f" h in all, {seeds_of(day['commits'][sha])} seeds that day")
    if day["seen"]:
        out.append("")
        out.append("Failures by issue:")
        for fingerprint in sorted(day["seen"]):
            filed = state["filed"].get(fingerprint)
            number = f"#{filed['issue']}" if filed else f"not filed yet ({fingerprint[:12]})"
            out.append(f"- {number}: {day['seen'][fingerprint]['seeds']} seeds")
    if day.get("overflow"):
        out.append(f"- past the cap of {FAILURES_PER_DAY} distinct failures a day: "
                   f"{day['overflow']} seeds, not looked at")
    return "\n".join(out) + "\n"


# ------------------------------------------------------------------------------------------------
# GitHub.


class GitHubError(Exception):
    """`kind`: gone (404, 410, a redirect), forbidden (403, locked), limited (rate limit),
    refused (anything else), unreachable (no answer)."""

    def __init__(self, kind, message, wait=0):
        super().__init__(message)
        self.kind = kind
        self.wait = wait


def classify_status(status, headers, now):
    """None for success, else (kind, wait seconds)."""
    if status in (200, 201):
        return None
    lower = {key.lower(): value for key, value in headers.items()}
    limited = "retry-after" in lower or lower.get("x-ratelimit-remaining") == "0"
    wait = 0
    if "retry-after" in lower and lower["retry-after"].strip().isdigit():
        wait = int(lower["retry-after"].strip())
    elif limited and lower.get("x-ratelimit-reset", "").strip().isdigit():
        wait = max(0, int(lower["x-ratelimit-reset"].strip()) - now)
    wait = min(wait, HOLD_SECONDS_MAX)
    if status == 429 or (status == 403 and limited):
        return ("limited", wait)
    if status == 403:
        return ("forbidden", 0)
    if status in (404, 410) or 300 <= status < 400:
        return ("gone", 0)
    return ("refused", 0)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect is never followed: the token must not go to another host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self, repo, token, log):
        assert re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo)
        self.repo = repo
        self.token = token
        self.log = log
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, method, path, payload=None):
        assert path.startswith("/")
        url = f"https://api.github.com/repos/{self.repo}{path}"
        data = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "nerva-sim-fleet",
            **({"Content-Type": "application/json"} if data is not None else {}),
        })
        try:
            with self.opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
                status, headers = response.status, dict(response.headers)
                body = response.read(RESPONSE_BYTES_MAX + 1)
        except urllib.error.HTTPError as err:
            status, headers, body = err.code, dict(err.headers or {}), b""
        except (urllib.error.URLError, OSError, http.client.HTTPException) as err:
            # Never the request's headers: only the method, the path and why.
            self.log(f"{method} {path}: no answer from GitHub ({type(err).__name__})")
            raise GitHubError("unreachable", "no answer")
        if len(body) > RESPONSE_BYTES_MAX:
            raise GitHubError("refused", "response too large")
        outcome = classify_status(status, headers, int(time.time()))
        if outcome is None:
            try:
                return json.loads(body) if body else None
            except ValueError:
                raise GitHubError("refused", "not JSON")
        kind, wait = outcome
        meaning = {"gone": "the issue was deleted or moved; it is filed again",
                   "forbidden": "forbidden; the issue may be locked; skipped",
                   "limited": "rate limited; GitHub writes wait"}.get(
                       kind, "the token is wrong or expired" if status == 401 else "refused")
        self.log(f"{method} {path}: HTTP {status}: {meaning}")
        raise GitHubError(kind, f"HTTP {status}", wait)

    def markers(self):
        """Fingerprint -> issue number, from the issues labelled `sim-fleet` (the latest
        FIND_PAGES_MAX * FIND_PAGE_SIZE)."""
        found = {}
        for page in range(1, FIND_PAGES_MAX + 1):
            rows = self.request("GET", f"/issues?labels={LABEL}&state=all&per_page="
                                       f"{FIND_PAGE_SIZE}&page={page}")
            if not isinstance(rows, list):
                raise GitHubError("refused", "not a list of issues")
            for row in rows:
                match = MARKER.search(row.get("body") or "")
                if match and match.group(1) not in found:
                    found[match.group(1)] = int(row["number"])
            if len(rows) < FIND_PAGE_SIZE:
                break
        return found

    def open(self, title, body):
        reply = self.request("POST", "/issues", {"title": title, "body": body,
                                                 "labels": [LABEL]})
        number = int((reply or {}).get("number", 0))
        if number <= 0:
            raise GitHubError("refused", "no issue number")
        return number

    def comment(self, number, body):
        assert number > 0
        self.request("POST", f"/issues/{number}/comments", {"body": body})


class DryRun:
    """Asks GitHub nothing; prints what it would do. Issue numbers it makes up are negative."""

    def __init__(self, out):
        self.out = out
        self.next = -1

    def markers(self):
        return {}

    def open(self, title, body):
        number = self.next
        self.next -= 1
        self.out(f"--- would open issue [{LABEL}] {title!r}\n{body}")
        return number

    def comment(self, number, body):
        self.out(f"--- would comment on #{number}\n{body}")


# ------------------------------------------------------------------------------------------------
# Ingest.


def new_summary():
    return {"filed": 0, "commented": 0, "throttled": 0, "dropped": 0, "forbidden": 0,
            "reports": 0, "held": False, "stopped": None}


def count(state, counts, failures, commit, now):
    """Counts the round into the state; needs neither the token nor GitHub. Returns the failure
    groups and each one's entry for today (None past the day's cap)."""
    day = day_of(state, ymd(now))
    count_round(day, counts, commit, state)
    groups = group_failures(failures)
    record_fingerprints(state, commit, groups)
    seen = {group[0]["fingerprint"]: see(day, group[0]["fingerprint"], len(group))
            for group in groups}
    return groups, seen


def report(github, state, groups, seen, commit, tracker, now, summary):
    """Posts finished days, files or comments. Stops the writes at the first rate limit or
    unreachable GitHub."""
    if state["hold_until"] > now:
        summary["held"] = True
        return
    try:
        post_totals(github, state, ymd(now), tracker, summary)
        for group in groups:
            report_group(github, state, group, seen[group[0]["fingerprint"]], commit, summary)
    except GitHubError as err:
        summary["stopped"] = err.kind
        if err.kind == "limited":
            state["hold_until"] = now + (min(err.wait, HOLD_SECONDS_MAX) or HOLD_SECONDS_DEFAULT)
            assert state["hold_until"] > now


def ingest(github, state, counts, failures, commit, tracker, now, log):
    """Counts the round and reports it. Returns a summary dict."""
    summary = new_summary()
    groups, seen = count(state, counts, failures, commit, now)
    report(github, state, groups, seen, commit, tracker, now, summary)
    return summary


def post_totals(github, state, today, tracker, summary):
    if tracker is None:
        return
    for ymd_day in sorted(state["days"]):
        day = state["days"][ymd_day]
        if ymd_day >= today or day["reported"]:
            continue
        try:
            github.comment(tracker, totals_text(state, ymd_day, day))
        except GitHubError as err:
            if err.kind in ("gone", "forbidden"):
                return  # The days wait for a later round.
            raise
        day["reported"] = True
        summary["reports"] += 1


def report_group(github, state, group, seen, commit, summary):
    fingerprint = group[0]["fingerprint"]
    filed = state["filed"].get(fingerprint)
    if filed is None:
        if seen is None:
            summary["throttled"] += 1
            return
        open_group(github, state, group, seen, commit, summary)
        return
    if seen is None or filed["last_commit"] == commit or \
            seen["comments"] >= COMMENTS_PER_FAILURE_PER_DAY:
        summary["throttled"] += 1
        return
    try:
        github.comment(filed["issue"], report_text(group, commit, first=False))
    except GitHubError as err:
        if err.kind == "gone":
            del state["filed"][fingerprint]
            summary["dropped"] += 1
            open_group(github, state, group, seen, commit, summary)
            return
        if err.kind == "forbidden":
            filed["last_commit"] = commit
            summary["forbidden"] += 1
            return
        raise
    filed["last_commit"] = commit
    seen["comments"] += 1
    summary["commented"] += 1


def open_group(github, state, group, seen, commit, summary):
    failure = group[0]
    assert failure["fingerprint"] not in state["filed"]
    number = github.open(title_of(failure["target"], failure["class"], failure["signature"]),
                         report_text(group, commit, first=True))
    remember(state, failure["fingerprint"], number, commit, commit)
    summary["filed"] += 1


def summary_line(counts, failures, summary):
    seeds = sum(c["seeds"] for c in counts.values())
    by_target = ", ".join(f"{t} {c['seeds']}/{c['failed']}" for t, c in sorted(counts.items()))
    held = " (GitHub writes held)" if summary["held"] else ""
    stopped = f" (writes stopped: {summary['stopped']})" if summary["stopped"] else ""
    return (f"sim-fleet: {seeds} seeds, {len(failures)} failed (seeds/failed: {by_target}); "
            f"filed {summary['filed']}, commented {summary['commented']}, throttled "
            f"{summary['throttled']}, totals posted {summary['reports']}{held}{stopped}")


def read_token(path):
    try:
        with open(path, "rb") as file:
            token = file.read(TOKEN_BYTES_MAX + 1)
    except OSError as err:
        raise Environment(f"cannot read the token file: {type(err).__name__}")
    token = token.decode("ascii", "replace").strip()
    if not token or len(token) > TOKEN_BYTES_MAX or any(c.isspace() for c in token):
        raise Environment("the token file is empty or not one token")
    return token


def soak_main(args, log):
    if not COMMIT.fullmatch(args.commit):
        log("--commit must be a hex commit of at least 7 digits")
        return 1
    try:
        state = load_state(args.state)
    except Environment as err:
        log(str(err))
        return 2
    if state is None:
        log(f"no state file at {args.state}")
        return 2
    line, ran, clean = soak_line(state, args.commit)
    print(line, flush=True)
    if not ran:
        log(f"no rounds of {args.commit[:7]} in the state (or its prefix names two commits)")
    elif not clean:
        log(f"{args.commit[:7]} is not clean: a seed failed, hung or was killed, a failure "
            f"was hit, or a round was refused")
    return 0 if ran and clean else 1


def load_or_start(path, log):
    """The state, or a new one if the file is missing (with `rebuild`: the issue markers are read
    before anything is filed); None if it cannot be read (it is never taken for empty)."""
    try:
        state = load_state(path)
    except Environment as err:
        log(f"{err}; nothing is recorded")
        return None
    if state is None:
        state = new_state()
        state["rebuild"] = True
    return state


def recorded(state, round_id):
    """Whether the round is already counted or refused. run.sh settles each round before it
    starts the next, so the last round recorded is the only one to look at."""
    return state.get("last_round", {}).get("id") == round_id


def save_record(path, state, round_id, commit, outcome, log):
    """Saves the state with the round's record, in the one atomic write that also holds the
    round's count or refusal: the fact run.sh looks for. False if it could not be saved."""
    assert outcome in ("counted", "refused")
    state["last_round"] = {"id": round_id, "commit": commit, "outcome": outcome}
    try:
        save_state(path, state)
    except OSError as err:
        log(f"cannot save the state file: {err}; round {round_id} is not recorded")
        return False
    return True


def rebuild(github, state, log, dry_run):
    """Fills `filed` from the issue markers of a state that was missing. Raises GitHubError, and
    `rebuild` then stays set: nothing is filed until it is done, so nothing is filed twice."""
    assert not state["filed"]
    for fingerprint, number in github.markers().items():
        if len(state["filed"]) < FILED_MAX:
            remember(state, fingerprint, number, "", "")
    del state["rebuild"]
    source = "a dry run reads no issues" if dry_run else "issue markers"
    log(f"the state file was missing: rebuilt from {len(state['filed'])} ({source})")


def ingest_main(args, now, log):
    """Counts the round, or refuses it, and saves that with the round's record before it needs
    the token or GitHub, which can then stop only the reports. Exit 0 if this run counted the
    round, else 1; run.sh reads the record, never the exit code."""
    if not ROUND_ID.fullmatch(args.round_id):
        log("--round-id must be <seconds>-<16 hex digits>")
        return 1
    if args.tracker is not None and args.tracker <= 0:
        log("--tracker must be an issue number")
        return 1
    if not args.dry_run and not (args.repo and args.token_file):
        log("--repo and --token-file are required unless --dry-run")
        return 1
    state = load_or_start(args.state, log)
    if state is None:
        return 1
    if recorded(state, args.round_id):
        log(f"round {args.round_id} is already recorded")
        return 0
    try:
        counts, failures = read_round(args.round, args.source_root)
    except BadInput as err:
        log(f"round refused, counted against {args.commit[:7]} as refused: {err}")
        refuse_round(state, args.commit)
        save_record(args.state, state, args.round_id, args.commit, "refused", log)
        return 1
    groups, seen = count(state, counts, failures, args.commit, now)
    if not save_record(args.state, state, args.round_id, args.commit, "counted", log):
        return 1
    summary = new_summary()
    try:
        github = DryRun(print) if args.dry_run else \
            GitHub(args.repo, read_token(args.token_file), log)
        if state.get("rebuild"):
            rebuild(github, state, log, args.dry_run)
        report(github, state, groups, seen, args.commit, args.tracker, now, summary)
    except Environment as err:
        log(f"{err}; the round is counted, nothing is filed")
        summary["stopped"] = "token"
    except GitHubError as err:
        log(f"the state file was missing and the issues could not be read ({err}); the round "
            f"is counted, nothing is filed until they are")
        summary["stopped"] = err.kind
    try:
        save_state(args.state, state)
    except OSError as err:
        log(f"cannot save what was filed: {err}; the round itself is counted")
    print(summary_line(counts, failures, summary), flush=True)
    return 0


def refuse_main(args, log):
    """Records the round as refused unless it is already recorded: run.sh's fallback when
    `ingest` left no record. Exit 0 if the round is recorded, now or before; else 1."""
    if not ROUND_ID.fullmatch(args.round_id):
        log("--round-id must be <seconds>-<16 hex digits>")
        return 1
    state = load_or_start(args.state, log)
    if state is None:
        return 1
    if recorded(state, args.round_id):
        log(f"round {args.round_id} is already recorded")
        return 0
    refuse_round(state, args.commit)
    return 0 if save_record(args.state, state, args.round_id, args.commit, "refused", log) else 1


def main(argv, now=None):
    parser = argparse.ArgumentParser(prog="sim_fleet.py")
    sub = parser.add_subparsers(dest="command", required=True)
    soak = sub.add_parser("soak")
    soak.add_argument("--commit", required=True)
    soak.add_argument("--state", required=True)
    refuse = sub.add_parser("refuse")
    refuse.add_argument("--round-id", required=True)
    refuse.add_argument("--commit", required=True, type=commit_argument)
    refuse.add_argument("--state", required=True)
    cmd = sub.add_parser("ingest")
    cmd.add_argument("--round", required=True)
    cmd.add_argument("--round-id", required=True)
    cmd.add_argument("--commit", required=True, type=commit_argument)
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--repo")
    cmd.add_argument("--token-file")
    cmd.add_argument("--tracker", type=int)
    cmd.add_argument("--dry-run", action="store_true")
    cmd.add_argument("--source-root", help="the checkout the binaries were built in")
    args = parser.parse_args(argv)
    now = int(time.time()) if now is None else now

    def log(message):
        print(f"sim-fleet: {message}", file=sys.stderr, flush=True)

    if args.command == "soak":
        return soak_main(args, log)
    if args.command == "refuse":
        return refuse_main(args, log)
    return ingest_main(args, now, log)


def commit_argument(text):
    if not COMMIT.fullmatch(text):
        raise argparse.ArgumentTypeError("must be a hex commit of at least 7 digits")
    return text


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
