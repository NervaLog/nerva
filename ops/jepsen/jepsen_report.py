#!/usr/bin/env python3
"""The Jepsen nightly's reporter (ops/jepsen/README.md, R1 slice 6, P215, P215c).

    jepsen_report.py ingest --commit SHA --store DIR --state FILE [--archive PATH]
                            [--runs FILE] [--expect-invalid] [--no-status]
                            [--repo OWNER/NAME --token-file FILE] [--tracker N] [--dry-run]

Reads one night that `nightly.sh` wrote under DIR: `runs` (one line per Jepsen run:
`<n> <exit code> <seconds> <lein arguments...>`), `host-failure` (one line, when the night never
got to run), and for each run `<n>/store/<test>/<time>/` as Jepsen writes it (`results.edn`,
`history.edn`, `jepsen.log`). Any other tree of Jepsen `store/` directories works too (no `runs`
file: every test found is a run of unknown exit code).

Each run is valid, invalid, unknown, or the host's:

- valid: counted; the night's commit status `jepsen/nightly` is `success` if every run is;
- invalid or unknown: one issue labelled `jepsen` per fingerprint (workload, the failing checker's
  key, its anomaly class; never the seed or the commit); a known fingerprint gets a comment only
  for a commit it has not been reported on, at most COMMENTS_PER_FAILURE_PER_DAY a UTC day; at
  most FAILURES_PER_DAY distinct failures are looked at a day. The status is `failure`;
- the host's (exit 124 past the night's deadline, 125, 126, 137 the OOM killer, 143 an
  interrupted night, unless a verdict was written: an invalid or unknown one outranks the exit code; a run with no `jepsen.log` at
  all; a night that did not start; graphs that did not draw): counted, status `error`, never an
  issue;
- crashed: Jepsen started (a `jepsen.log`) and wrote no `results.edn`, and the host did not kill
  it, and its last 16 KiB shows no host failure (ssh refused, out of heap, disk full, Docker):
  Nerva's. One issue per workload (`<workload>|run|crashed`), with the log's end (P235b).

A commit's status only moves up (error, success, failure; P235b), judged against GitHub's own
status for it, read first; unreadable, nothing is posted. `--no-status` posts none.

Then one comment a day on the tracker issue: what ran, on which commit, the verdict.

`--expect-invalid` is the canary (a build with commit-key deduplication off): an invalid verdict
with a `duplicate` is what it expects. The issue it files says so and the status is
`jepsen/canary` = `success`; a verdict without the duplicate means Jepsen cannot see a duplicate
any more: status `failure` and an issue "canary is blind". `--dry-run` asks GitHub nothing and
prints what it would do (it still writes the state file it is given: give it a state of its own).

Exit codes: 0 done, 1 usage or bad input, 2 environment (state file, token, GitHub). Standard
library only. The tooling's own messages are not NRV codes (P215c).
"""

import argparse
import contextlib
import datetime
import hashlib
import json
import os
import re
import shlex
import sys
import time
import urllib.error
import urllib.request

LABEL = "jepsen"
CONTEXT_NIGHTLY = "jepsen/nightly"
CONTEXT_CANARY = "jepsen/canary"
MARKER = re.compile(r"<!-- jepsen fingerprint: ([0-9a-f]{32}) -->")
STATE_VERSION = 1

# Bounds. Every collection this reads or keeps has one.
RUNS_MAX = 64  # Lines of `runs`.
TESTS_MAX = 256  # Test directories read.
FINDINGS_MAX = 64  # (checker, class) pairs of one run.
FINDINGS_DEPTH_MAX = 4  # Composed checkers walked into.
EDN_BYTES_MAX = 4 * 1024 * 1024  # results.edn.
EDN_DEPTH_MAX = 64
LOG_TAIL_BYTES = 4 * 1024  # jepsen.log's end, for a run that died.
LOG_HEAD_BYTES = 64 * 1024  # jepsen.log: only its first lines (the command line) are read.
HISTORY_BYTES_MAX = 2 * 1024 * 1024 * 1024
HISTORY_LINES_MAX = 20_000_000
HISTORY_CONTEXT = 50  # Operations of context on each side of an anomalous one (P215c).
HISTORY_BYTES_ISSUE = 48 * 1024  # The excerpt in an issue (P215c).
HISTORY_FIT_TRIES = 8  # Times an excerpt is re-rendered smaller to fit.
HISTORY_LINE_BYTES = 1500  # A history line is cut here in an excerpt.
ANOMALIES_MAX = 4096
VERDICT_BYTES = 6 * 1024  # results.edn in an issue.
BODY_BYTES_MAX = 60_000  # GitHub's limit is 65,536 characters.
TITLE_BYTES_MAX = 120
FILED_MAX = 2048
VERDICTS_MAX = 256  # Commits whose status is remembered.
STATUS_RANK = {"error": 0, "success": 1, "failure": 2}
DAYS_KEPT = 31
FAILURES_PER_DAY = 16  # Distinct failures looked at a UTC day.
COMMENTS_PER_FAILURE_PER_DAY = 4
FIND_PAGES_MAX = 5
FIND_PAGE_SIZE = 100
RESPONSE_BYTES_MAX = 8 * 1024 * 1024
TOKEN_BYTES_MAX = 4096
STATE_BYTES_MAX = 4 * 1024 * 1024
STATUS_DESCRIPTION_MAX = 140  # GitHub's limit.
HTTP_TIMEOUT_SECONDS = 60

assert COMMENTS_PER_FAILURE_PER_DAY > 0
assert FAILURES_PER_DAY <= FILED_MAX
assert HISTORY_BYTES_ISSUE + VERDICT_BYTES + 4096 <= BODY_BYTES_MAX

# Exit codes that are the host's, not the code's: counted, never filed. 124: past the night's
# deadline (`timeout`); 125, 126: `timeout` or the exec failed; 137: SIGKILL, the OOM killer;
# 143: the night was interrupted (a systemd stop or timeout; nightly.sh's trap, P240).
HOST_CODES = {124: "past the night's deadline", 125: "the run could not start",
              126: "the run could not start", 137: "killed by the host (out of memory?)",
              143: "interrupted (the unit was stopped or timed out)"}
# What a jepsen.log's end shows when the host failed under a test that had started (ssh to a
# node refused, the JVM out of heap, the disk full, Docker): the host's, never filed (P235c).
# A bare "Connection refused" is not one: Jepsen's clients log it to gateways and replicas while
# the nemeses run, so only ssh and control-plane lines count (P235d).
HOST_LOG_SIGNATURES = re.compile(
    r"JSchException|Auth fail|session is down|"
    r"ssh: connect to host [^\n]*(?:Connection refused|Connection timed out|No route to host)|"
    r"jepsen\.control[^\n]*(?:Connection refused|Connection timed out|No route to host)|"
    r"OutOfMemoryError|No space left on device|Cannot connect to the Docker daemon|"
    r"docker: Error|Error response from daemon", re.IGNORECASE)
LOG_SIGNATURE_BYTES = 16 * 1024  # jepsen.log's end read to look for them.
# Checkers whose failure is the host's (gnuplot missing, #106), not Nerva's.
HOST_CHECKERS = ("perf", "timeline")
# Checker keys that name their anomaly class themselves (bank's checkers, and the records').
CHECKER_CLASS = {"bank": "conservation", "source": "conservation", "view": "conservation",
                 "refusals": "refusal", "record": "record", "records": "record"}
# Sub-keys of a checker's result that count anomalies: their anomaly class.
SUBKEY_CLASS = {"unresolved": "unknown-result"}
HEX32 = re.compile(r"^[0-9a-f]{32}$")
OP_KEYS = ("op", "ops", "index", "indices", "indexes")


class BadInput(Exception):
    """The night is not what nightly.sh writes: refused whole (exit 1)."""


class Environment(Exception):
    """The state file, the token or GitHub (exit 2)."""


# ------------------------------------------------------------------------------------------------
# EDN: just enough to read what Jepsen's checkers print.


class Keyword(str):
    """`:valid?` is Keyword("valid?"); a string stays a plain str."""

    def __repr__(self):
        return ":" + str(self)


class Edn:
    TOKEN_END = set(' \t\r\n,()[]{}";')

    def __init__(self, text):
        self.text = text
        self.at = 0

    def skip(self):
        text, n = self.text, len(self.text)
        while self.at < n:
            c = text[self.at]
            if c in " \t\r\n,":
                self.at += 1
            elif c == ";":
                while self.at < n and text[self.at] != "\n":
                    self.at += 1
            else:
                return

    def parse(self):
        value = self.value(0)
        self.skip()
        if self.at != len(self.text):
            raise ValueError(f"EDN: trailing text at {self.at}")
        return value

    def value(self, depth):
        if depth > EDN_DEPTH_MAX:
            raise ValueError("EDN: nested too deep")
        self.skip()
        if self.at >= len(self.text):
            raise ValueError("EDN: unexpected end")
        c = self.text[self.at]
        if c == "{":
            items = self.items("}", depth)
            if len(items) % 2:
                raise ValueError("EDN: map with an odd number of forms")
            return {hashable(items[i]): items[i + 1] for i in range(0, len(items), 2)}
        if c in "[(":
            return self.items("]" if c == "[" else ")", depth)
        if c == '"':
            return self.string()
        if c == "#":
            return self.dispatch(depth)
        if c == "\\":
            return self.char()
        return self.atom()

    def items(self, close, depth):
        self.at += 1
        items = []
        while True:
            self.skip()
            if self.at >= len(self.text):
                raise ValueError("EDN: unterminated collection")
            if self.text[self.at] == close:
                self.at += 1
                return items
            if self.text[self.at] in "}])":
                raise ValueError("EDN: mismatched closing bracket")
            items.append(self.value(depth + 1))

    def string(self):
        out = []
        self.at += 1
        text = self.text
        escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "b": "\b", "f": "\f"}
        while self.at < len(text):
            c = text[self.at]
            if c == '"':
                self.at += 1
                return "".join(out)
            if c == "\\" and self.at + 1 < len(text):
                nxt = text[self.at + 1]
                if nxt == "u" and self.at + 5 < len(text):
                    out.append(chr(int(text[self.at + 2:self.at + 6], 16)))
                    self.at += 6
                    continue
                out.append(escapes.get(nxt, nxt))
                self.at += 2
                continue
            out.append(c)
            self.at += 1
        raise ValueError("EDN: unterminated string")

    def char(self):
        start = self.at
        self.at += 2
        while self.at < len(self.text) and self.text[self.at] not in self.TOKEN_END:
            self.at += 1
        return self.text[start + 1:self.at]

    def dispatch(self, depth):
        self.at += 1
        if self.at >= len(self.text):
            raise ValueError("EDN: unexpected end after #")
        c = self.text[self.at]
        if c == "{":
            return self.items("}", depth)  # a set, as a list
        if c == "_":
            self.at += 1
            self.value(depth + 1)
            return self.value(depth + 1)
        if c == "#":  # ##Inf, ##NaN
            return self.atom()
        self.atom()  # a tag: `#inst "..."`, `#object[...]`, `#jepsen.x.Y{...}`: the value stays
        return self.value(depth + 1)

    def atom(self):
        start = self.at
        while self.at < len(self.text) and self.text[self.at] not in self.TOKEN_END:
            self.at += 1
        token = self.text[start:self.at]
        if not token:
            raise ValueError(f"EDN: unexpected character {self.text[start]!r}")
        if token == "nil":
            return None
        if token == "true":
            return True
        if token == "false":
            return False
        if token.startswith(":"):
            return Keyword(token[1:])
        if re.fullmatch(r"[+-]?\d+N?", token):
            return int(token.rstrip("N"))
        if re.fullmatch(r"[+-]?\d+\.?\d*([eE][+-]?\d+)?M?", token):
            return float(token.rstrip("M"))
        return token  # a symbol, a ratio, ##Inf


def hashable(value):
    if isinstance(value, list):
        return tuple(hashable(item) for item in value)
    if isinstance(value, dict):
        return repr(sorted((repr(k), repr(v)) for k, v in value.items()))
    return value


def parse_edn(text):
    return Edn(text).parse()


def kw(mapping, name, default=None):
    """The value of keyword `name` in a parsed map."""
    for key, value in mapping.items():
        if isinstance(key, Keyword) and key == name:
            return value
    return default


def is_valid(value):
    """True, False or "unknown" from a `:valid?`."""
    if value is True:
        return True
    if value is False:
        return False
    return "unknown"


# ------------------------------------------------------------------------------------------------
# One run.


def read_head(path, limit):
    try:
        with open(path, "rb") as file:
            return file.read(limit).decode("utf-8", "replace")
    except OSError:
        return ""


def read_tail(path, limit):
    try:
        with open(path, "rb") as file:
            file.seek(0, os.SEEK_END)
            file.seek(max(0, file.tell() - limit))
            return file.read(limit).decode("utf-8", "replace")
    except OSError:
        return ""


def command_of(log_head):
    """The `lein run ...` line Jepsen logs first, as words, or None."""
    match = re.search(r"Command line:\n(lein run .*)", log_head)
    if not match:
        return None
    try:
        return shlex.split(match.group(1))
    except ValueError:
        return None


def option(words, name):
    """The value of `--name V` or `--name=V` in words."""
    for i, word in enumerate(words):
        if word == f"--{name}" and i + 1 < len(words):
            return words[i + 1]
        if word.startswith(f"--{name}="):
            return word.split("=", 1)[1]
    return None


def workload_of(words):
    """The workload a command runs, as findings name it: the unkeyed `bank` is its own (P239b),
    so its failures do not share a fingerprint with the keyed run's."""
    workload = option(words, "workload")
    return "bank-no-keys" if workload == "bank" and "--no-keys" in words else workload


MACHINE_OPTIONS = ("nodes", "username", "ssh-private-key", "nerva-binary")


def reproduce_words(words):
    """The command's words without `lein run` and the options that name this machine."""
    out = []
    skip = False
    for word in words[2:]:
        if skip:
            skip = False
            continue
        name = word[2:].split("=", 1)[0] if word.startswith("--") else None
        if name in MACHINE_OPTIONS:
            skip = "=" not in word
            continue
        out.append(word)
    return out


def leaf_name(path):
    return path.rsplit(".", 1)[-1]


def checker_classes(checker, result):
    """The anomaly classes of a failing (leaf) checker's result. `checker` is its path
    (`workload.source`); the table is keyed by its last key."""
    if leaf_name(checker) in CHECKER_CLASS:
        return [CHECKER_CLASS[leaf_name(checker)]]
    classes = []
    if isinstance(result, dict):
        violations = kw(result, "violations")
        if isinstance(violations, int) and not isinstance(violations, bool) and violations > 0:
            classes.append("violations")  # the protocol checker: a count at its own level
        for key, value in result.items():
            if not isinstance(key, Keyword) or not isinstance(value, dict):
                continue
            count = kw(value, "count")
            violations = kw(value, "violations")
            if isinstance(count, int) and count > 0:
                classes.append(SUBKEY_CLASS.get(str(key), str(key)))
            elif isinstance(violations, int) and violations > 0:
                classes.append(str(key))
        for key, value in result.items():
            if isinstance(key, Keyword) and str(key) == "unresolved" \
                    and isinstance(value, int) and value > 0:
                classes.append("unknown-result")
    if not classes:
        classes = ["invalid" if is_valid(kw(result, "valid?")) is False else "unknown-result"]
    seen = []
    for name in classes:
        if name not in seen:
            seen.append(name)
    return seen


def failing_leaves(path, value, depth):
    """[(path, verdict, result)]: the checkers below `value` that fail. A checker composed of
    checkers (Jepsen's `compose`, as `:workload` is for bank) is walked into, so the leaf that
    failed (`workload.source`) is named, not the composition; a result with no failing
    `:valid?` child is a leaf itself."""
    verdict = is_valid(kw(value, "valid?"))
    if verdict is True:
        return []
    children = [(k, v) for k, v in value.items()
                if isinstance(k, Keyword) and str(k) != "valid?" and isinstance(v, dict)
                and kw(v, "valid?") is not None]
    if children and depth < FINDINGS_DEPTH_MAX:
        below = []
        for k, v in children:
            below.extend(failing_leaves(f"{path}.{k}", v, depth + 1))
        if below:
            return below
    return [(path, verdict, value)]


def findings_of(results):
    """[(checker, class, result)] the verdict fails on, and whether only the host's graphs
    failed. `checker` is a path: `protocol`, `workload`, `workload.source`."""
    failing = []
    for key, value in results.items():
        if isinstance(key, Keyword) and str(key) != "valid?" and isinstance(value, dict):
            for leaf in failing_leaves(str(key), value, 1):
                failing.append((str(key), *leaf))
    real = [f for f in failing if f[0] not in HOST_CHECKERS]
    if not real:
        return [], bool(failing)
    firm = [f for f in real if f[2] is False] or real
    found = []
    for _, checker, _, value in firm:
        for name in checker_classes(checker, value):
            if len(found) < FINDINGS_MAX:
                found.append((checker, name, value))
    return found, False


def anomaly_ids(subtrees):
    """Keys (32 hex) and operation numbers named by the failing checkers' examples."""
    keys, numbers = set(), set()

    def walk(node, name, depth):
        if depth > EDN_DEPTH_MAX or len(keys) + len(numbers) > ANOMALIES_MAX:
            return
        if isinstance(node, dict):
            for k, v in node.items():
                walk(v, str(k) if isinstance(k, Keyword) else None, depth + 1)
        elif isinstance(node, list):
            for v in node:
                walk(v, name, depth + 1)
        elif isinstance(node, str) and not isinstance(node, Keyword) and HEX32.match(node):
            keys.add(node)
        elif isinstance(node, int) and not isinstance(node, bool) and name in OP_KEYS:
            numbers.add(node)

    for subtree in subtrees:
        walk(subtree, None, 0)
    return keys, numbers


def read_history(path):
    """The history's lines (bytes) and whether it was cut at a bound."""
    lines = []
    size = 0
    try:
        with open(path, "rb") as file:
            for line in file:
                size += len(line)
                if size > HISTORY_BYTES_MAX or len(lines) >= HISTORY_LINES_MAX:
                    return lines, True
                lines.append(line.rstrip(b"\r\n"))
    except OSError:
        return [], False
    return lines, False


def anomalous_lines(lines, keys, numbers):
    """Positions of the history lines that carry an anomalous key or operation number."""
    key_re = re.compile(rb':key "(?:' + b"|".join(re.escape(k.encode()) for k in sorted(keys))
                        + rb')"') if keys else None
    op_re = re.compile(rb"(?::op|^\{:index) (\d+)")
    found = []
    for position, line in enumerate(lines):
        hit = bool(key_re and key_re.search(line))
        if not hit and numbers:
            hit = any(int(n) in numbers for n in op_re.findall(line))
        if hit:
            found.append(position)
            if len(found) >= ANOMALIES_MAX:
                break
    return found


def render_line(line):
    """One history line as it is shown: cut at HISTORY_LINE_BYTES, decoded (a bad byte may
    become 3), and with no fence in it."""
    if len(line) > HISTORY_LINE_BYTES:
        text = line[:HISTORY_LINE_BYTES].decode("utf-8", "replace") + " ..."
    else:
        text = line.decode("utf-8", "replace")
    return text.replace("```", "'''")


def omitted_marker(count):
    return f"... {count} operations omitted ..."


def excerpt_cost(lines, positions, rendered):
    """The bytes of render_excerpt(positions): lines, omission markers and newlines."""
    total = 0
    previous = None
    for position in positions:
        if previous is not None and position != previous + 1:
            total += len(omitted_marker(position - previous - 1)) + 1
        if position not in rendered:
            rendered[position] = len(render_line(lines[position]).encode()) + 1
        total += rendered[position]
        previous = position
    return total


def select_lines(lines, anomalies, budget):
    """Positions to show: the anomalous ones with HISTORY_CONTEXT lines on each side, the context
    shrunk until the excerpt fits the budget; returns (positions, radius, all_anomalies_shown).
    The cost is that of the rendered excerpt: markers and decoding included."""
    rendered = {}
    for radius in (HISTORY_CONTEXT, 20, 10, 5, 2, 1, 0):
        shown = set()
        for position in anomalies:
            shown.update(range(max(0, position - radius), min(len(lines), position + radius + 1)))
        ordered = sorted(shown)
        if excerpt_cost(lines, ordered, rendered) <= budget:
            return ordered, radius, True
    kept = []
    for position in anomalies:
        if excerpt_cost(lines, kept + [position], rendered) > budget:
            break
        kept.append(position)
    return kept, 0, False


def render_excerpt(lines, positions):
    out = []
    previous = None
    for position in positions:
        if previous is not None and position != previous + 1:
            out.append(omitted_marker(position - previous - 1))
        out.append(render_line(lines[position]))
        previous = position
    return "\n".join(out)


def fence(text):
    return "```\n" + text.replace("```", "'''") + "\n```"


def bounded_text(text, limit):
    data = text.encode("utf-8", "replace")
    if len(data) <= limit:
        return text
    return data[:limit].decode("utf-8", "ignore") + f"\n... (cut at {limit} bytes)"


class Run:
    """One Jepsen run: what it was, how it ended, and what it found."""

    def __init__(self, label):
        self.label = label  # `runs`' n, or the test directory's name
        self.exit_code = None
        self.seconds = None
        self.args = None  # the `runs` line's arguments, when the log has no command line
        self.dir = None  # the test directory (`<test>/<time>`)
        self.name = None
        self.kind = None  # valid, invalid, unknown or host
        self.host_reason = None
        self.workload = "bank"  # the suite's default
        self.nemesis = ""
        self.seed = None
        self.reproduce = None
        self.results_text = ""
        self.findings = []  # (checker, class, subtree)
        self.history_path = None
        self.history = None  # (lines, cut), read once per run

    def summary(self):
        what = f"{self.workload}" + (f" ({self.nemesis})" if self.nemesis else "")
        took = f", {self.seconds} s" if self.seconds is not None else ""
        if self.kind == "host":
            return f"{what}: the host's, {self.host_reason}{took}"
        found = ", ".join(sorted({f"{c}/{k}" for c, k, _ in self.findings}))
        return f"{what}: {self.kind}{' (' + found + ')' if found else ''}{took}"


def read_test(run, directory):
    """Fills `run` from a test directory (`results.edn`, `jepsen.log`)."""
    run.dir = directory
    run.name = "/".join(directory.split(os.sep)[-2:])
    words = command_of(read_head(os.path.join(directory, "jepsen.log"), LOG_HEAD_BYTES))
    if words is None and run.args is not None:
        words = ["lein", "run"] + run.args
    if words is not None:
        run.workload = workload_of(words) or run.workload
        run.nemesis = option(words, "nemesis") or ""
        run.seed = option(words, "seed")
        run.reproduce = " ".join(shlex.quote(w) for w in reproduce_words(words))
    path = os.path.join(directory, "results.edn")
    try:
        with open(path, "rb") as file:
            data = file.read(EDN_BYTES_MAX + 1)
    except OSError:
        run.kind, run.host_reason = "host", "the run left no results.edn"
        return
    if len(data) > EDN_BYTES_MAX:
        run.kind, run.host_reason = "host", f"results.edn is larger than {EDN_BYTES_MAX} bytes"
        return
    run.results_text = data.decode("utf-8", "replace")
    try:
        results = parse_edn(run.results_text)
        if not isinstance(results, dict):
            raise ValueError("not a map")
    except (ValueError, RecursionError) as err:
        run.kind, run.host_reason = "host", f"results.edn cannot be read ({err})"
        return
    verdict = is_valid(kw(results, "valid?"))
    run.history_path = os.path.join(directory, "history.edn")
    if verdict is True:
        run.kind = "valid"
        return
    run.findings, graphs_only = findings_of(results)
    if graphs_only or not run.findings:
        run.kind = "host"
        run.host_reason = "Jepsen's graphs did not draw (gnuplot?)" if graphs_only \
            else "the verdict names no failing checker"
        return
    run.kind = "invalid" if verdict is False else "unknown"


def find_tests(root, started=False):
    """Test directories (`<root>/.../<test>/<time>/results.edn`) below root, symlinks not
    followed (`latest` and `current` point at a test already listed). With `started`, a
    directory with a `jepsen.log` and no `results.edn` counts too: Jepsen began and died."""
    found = []
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        if ("results.edn" in files or started) and "jepsen.log" in files \
                and not os.path.islink(base):
            found.append(base)
            dirs[:] = []
        if len(found) > TESTS_MAX:
            raise BadInput(f"more than {TESTS_MAX} test directories")
    return found


def read_runs_file(path):
    runs = []
    with open(path, encoding="utf-8", errors="replace") as file:
        for line in file:
            if not line.strip():
                continue
            if len(runs) >= RUNS_MAX:
                raise BadInput(f"more than {RUNS_MAX} lines in {path}")
            fields = line.split()
            if len(fields) < 3 or not (fields[0].isalnum() and fields[1].isdigit()
                                       and fields[2].isdigit()):
                raise BadInput(f"{path}: not `<n> <exit code> <seconds> <arguments...>`: {line!r}")
            runs.append((fields[0], int(fields[1]), int(fields[2]), fields[3:]))
    return runs


def settle_run(run, code, tests):
    """The run's kind once its exit code is known (P235b). A verdict that was written
    (invalid or unknown) outranks every exit code. Otherwise: the host's exit codes (124, 125,
    126, 137, 143) are the host's; no jepsen.log at all means Jepsen never started (the build,
    Docker): the host's; a jepsen.log and no results.edn means the test threw (nerva died at
    setup, say): Nerva's, fingerprint `<workload>|run|crashed`, with the log's end in the issue."""
    if run.kind in ("invalid", "unknown"):
        return
    has_results = bool(tests) and os.path.exists(os.path.join(tests[0], "results.edn"))
    if code in HOST_CODES:
        run.kind, run.host_reason, run.findings = "host", HOST_CODES[code], []
    elif not tests:
        run.kind, run.host_reason = "host", f"exit {code} and Jepsen never started"
    elif not has_results:
        tail = read_tail(os.path.join(tests[0], "jepsen.log"), LOG_SIGNATURE_BYTES)
        if HOST_LOG_SIGNATURES.search(tail):
            run.kind, run.findings = "host", []
            run.host_reason = f"exit {code}, and jepsen.log ends in a host failure"
            return
        run.kind, run.host_reason = "crashed", None
        run.findings = [("run", "crashed", None)]
        run.results_text = tail[-LOG_TAIL_BYTES:]


def read_night(store, runs_file):
    """(runs, night host failure or None)."""
    if not os.path.isdir(store):
        raise BadInput(f"{store} is not a directory")
    failure = None
    failure_path = os.path.join(store, "host-failure")
    if os.path.exists(failure_path):
        failure = read_head(failure_path, 512).strip().splitlines()[:1]
        failure = failure[0] if failure else "the night did not run"
    if runs_file is None and os.path.exists(os.path.join(store, "runs")):
        runs_file = os.path.join(store, "runs")
    runs = []
    if runs_file is not None:
        try:
            lines = read_runs_file(runs_file)
        except OSError as err:
            raise BadInput(f"cannot read {runs_file}: {err}")
        for label, code, seconds, args in lines:
            run = Run(label)
            run.exit_code, run.seconds, run.args = code, seconds, args
            where = os.path.join(store, label)
            tests = find_tests(where, started=True) if os.path.isdir(where) else []
            if tests:
                read_test(run, tests[0])
            else:
                words = ["lein", "run"] + args
                run.workload = workload_of(words) or run.workload
                run.nemesis = option(words, "nemesis") or ""
            settle_run(run, code, tests)
            runs.append(run)
        return runs, failure
    for directory in find_tests(store):
        run = Run(os.path.basename(os.path.dirname(directory)))
        read_test(run, directory)
        runs.append(run)
    return runs, failure


# ------------------------------------------------------------------------------------------------
# Fingerprints and text.


def fingerprint_key(canary, workload, checker, name):
    """What a fingerprint hashes: never the seed, the commit or the time."""
    return f"{'canary' if canary else 'jepsen'}|{workload}|{checker}|{name}"


def fingerprint_of(key):
    return hashlib.sha256(key.encode()).hexdigest()[:32]


def title_of(canary, workload, checker, name):
    if canary:
        if name == "blind":
            title = f"Jepsen canary {workload}: blind, it saw no duplicate"
        elif name == "crashed":
            title = f"Jepsen canary {workload}: crashed before a verdict (checker {checker})"
        else:
            title = f"Jepsen canary {workload}: {name} seen (expected), checker {checker}"
    else:
        title = f"Jepsen {workload}: {name} (checker {checker})"
    return title[:TITLE_BYTES_MAX - 3] + "..." if len(title) > TITLE_BYTES_MAX else title


def make_findings(run, canary):
    """The failures to report for a run: dicts with fingerprint, title, class, checker."""
    out = []
    if not canary:
        if run.kind in ("invalid", "unknown", "crashed"):
            for checker, name, subtree in run.findings:
                out.append((checker, name, subtree))
        return [finding(run, canary, c, n, s) for c, n, s in out]
    names = {n for _, n, _ in run.findings}
    if run.kind == "invalid" and "duplicate" in names:
        for checker, name, subtree in run.findings:
            out.append(finding(run, True, checker, name, subtree))
    elif run.kind == "crashed":
        # The run threw before it could see anything: a crash, not a blind canary.
        # The canary's own fingerprint: a test build's crash is not a crash on main (P235).
        for checker, name, subtree in run.findings:
            out.append(finding(run, True, checker, name, subtree))
    elif run.kind in ("invalid", "unknown", "valid"):
        # Whatever else it saw is a real finding; the canary itself saw no duplicate.
        for checker, name, subtree in run.findings:
            out.append(finding(run, False, checker, name, subtree))
        out.append(finding(run, True, "workload", "blind", None))
    return out


def finding(run, canary, checker, name, subtree):
    key = fingerprint_key(canary, run.workload, checker, name)
    return {"run": run, "canary": canary, "checker": checker, "class": name, "subtree": subtree,
            "key": key, "fingerprint": fingerprint_of(key),
            "title": title_of(canary, run.workload, checker, name)}


def html_comment_safe(text):
    return text.replace("--", "- -")


def report_text(item, commit, archive, first):
    """An issue body (`first`) or a comment: the same facts, the marker only in the body."""
    run = item["run"]
    canary = item["canary"]
    out = []
    if first and canary and item["class"] == "crashed":
        out.append("The Jepsen canary (a build with commit-key deduplication off,"
                   " ops/jepsen/README.md) **crashed** on `main`: the test threw before it wrote"
                   " a verdict, so the canary could not show whether Jepsen sees a duplicate."
                   " This is the canary build's crash, not the nightly's.\n")
    elif first and canary:
        out.append("The Jepsen canary (a build with commit-key deduplication off,"
                   " ops/jepsen/README.md) ran on `main`. A duplicate is what it **expects**:"
                   " this issue shows the pipeline, and is closed by hand.\n")
    elif first:
        out.append("The Jepsen nightly (ops/jepsen/README.md) found this on `main`.\n")
    else:
        out.append(f"Failed again, on commit `{commit}`.\n")
    out.append(f"- **Workload:** `{run.workload}`" + (f", nemesis `{run.nemesis}`" if run.nemesis
                                                       else ""))
    if item["class"] == "blind":
        out.append("- **Verdict:** the canary run found no `duplicate`: Jepsen cannot see a "
                   "resent key committing twice")
    else:
        out.append(f"- **Checker:** `{item['checker']}`, anomaly `{item['class']}`")
    others = sorted({f"{c}/{n}" for c, n, _ in run.findings} - {f"{item['checker']}/{item['class']}"})
    if others:
        out.append("- **Also in this run:** " + ", ".join(f"`{o}`" for o in others))
    out.append(f"- **Commit:** `{commit}`")
    out.append(f"- **Seed:** `{run.seed if run.seed else 'not recorded: the run had no --seed'}`"
               " (it steers Jepsen's generators; a run does not replay, N82)")
    took = f" after {run.seconds} s" if run.seconds is not None else ""
    out.append(f"- **Run:** `{run.name or run.label}`, verdict {run.kind}"
               + (f", exit {run.exit_code}{took}" if run.exit_code is not None else ""))
    if archive:
        out.append(f"- **The whole store, on the host:** `{archive}` (kept 90 days)")
    out.append("")
    if run.reproduce:
        out.append("The command (the checker's verdict is a hint; reproduce it as a VOPR seed or "
                   "a unit test before fixing, N82):")
        out.append("")
        out.append(fence(f"git checkout {commit} && ./zig/zig build -Drelease"
                         + (" -Dtest-commit-keys=off" if canary else "")
                         + f" && tests/jepsen/run.sh zig-out/bin/nerva {run.reproduce}"))
    verdict = bounded_text(run.results_text, VERDICT_BYTES)
    if verdict and run.kind == "crashed":
        out.append("")
        out.append("The test died before it wrote a verdict (no `results.edn`): Jepsen threw, e.g."
                   " `nerva` died while the test set it up. The end of `jepsen.log`:")
        out.append("")
        out.append(fence(verdict))
    elif verdict:
        out.append("")
        out.append(f"Verdict (`results.edn`, at most {VERDICT_BYTES // 1024} KiB):")
        out.append("")
        out.append(fence(verdict))
    text = "\n".join(out) + "\n"
    tail = ""
    if first:
        tail = (f"\n<!-- jepsen fingerprint: {item['fingerprint']} -->\n"
                f"<!-- jepsen key: {html_comment_safe(item['key'])} -->\n")
    room = min(HISTORY_BYTES_ISSUE, BODY_BYTES_MAX - len(text.encode()) - len(tail.encode()) - 1024)
    text += history_text(item, room)
    if len((text + tail).encode()) > BODY_BYTES_MAX:
        # Cannot happen while the parts above are bounded; if one grows, cut the body, never die.
        keep = BODY_BYTES_MAX - len(tail.encode()) - 64
        text = text.encode()[:keep].decode("utf-8", "ignore") + "\n... (cut at the size bound)\n"
    return text + tail


def history_text(item, room):
    """The history excerpt, at most `room` bytes as rendered (fence and note included): the
    budget is lowered until the rendered text fits, and the excerpt is left out, with a line
    saying so, rather than exceed it."""
    run = item["run"]
    if item["subtree"] is None or not run.history_path or room < 1024:
        return ""
    keys, numbers = anomaly_ids([s for _, _, s in run.findings if s is not None])
    if run.history is None:
        run.history = read_history(run.history_path)
    lines, cut = run.history
    anomalies = anomalous_lines(lines, keys, numbers) if lines else []
    if not anomalies:
        return "\nThe history: no operation could be tied to the verdict's examples.\n"
    budget = room - 512
    for _ in range(HISTORY_FIT_TRIES):
        if budget < 256:
            break
        positions, radius, complete = select_lines(lines, anomalies, budget)
        note = f"{len(anomalies)} anomalous operations, {radius} operations of context on each " \
            "side" if complete else f"the first {len(positions)} of {len(anomalies)} anomalous " \
            "operations, no context (the excerpt budget)"
        text = (f"\nThe history (`history.edn`, {note}; at most {HISTORY_BYTES_ISSUE // 1024} KiB"
                + ("; the file was read only up to its bound" if cut else "") + "):\n\n"
                + fence(render_excerpt(lines, positions)) + "\n")
        over = len(text.encode()) - room
        if over <= 0:
            return text
        budget -= over + 64
    return "\nThe history: the excerpt would not fit the issue's size bound; see the store.\n"


# ------------------------------------------------------------------------------------------------
# State.


def ymd(now):
    return datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y-%m-%d")


def new_state():
    return {"version": STATE_VERSION, "filed": {}, "days": {}, "verdicts": {}}


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
    state.setdefault("verdicts", {})  # Added after the first state files: optional.
    for key in ("filed", "days", "verdicts"):
        if not isinstance(state.get(key), dict):
            raise Environment(f"the state file {path} has no valid `{key}`")
    state["verdicts"] = {k: v for k, v in state["verdicts"].items()
                         if isinstance(v, dict) and v.get("state") in STATUS_RANK
                         and isinstance(v.get("day"), str)}
    # A dry run once saved the issue numbers it made up (negative): they are not issues.
    state["filed"] = {fp: entry for fp, entry in state["filed"].items()
                      if isinstance(entry, dict) and isinstance(entry.get("issue"), int)
                      and entry["issue"] > 0}
    if len(state["filed"]) > FILED_MAX:
        raise Environment(f"the state file {path} remembers more than {FILED_MAX} failures")
    return state


def save_state(path, state):
    assert len(state["filed"]) <= FILED_MAX
    data = json.dumps(state, indent=1, sort_keys=True).encode()
    assert len(data) <= STATE_BYTES_MAX
    temporary = path + ".new"
    with open(temporary, "wb") as file:
        file.write(data)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)


def settle_status(state, github, commit, context, new, today):
    """(status to post or None, why not). A commit's status only ever moves up error < success
    < failure (P235b), so a later night on the same commit (or one that could not run) never
    turns a failure green. The rank is the higher of the state file's and GitHub's own, read
    first (P235c): a post that timed out after GitHub stored it, or a lost state file, cannot
    hide it. If GitHub cannot be read, nothing is posted."""
    rank = -1
    old = state["verdicts"].get(f"{commit}:{context}")
    if old is not None:
        rank = STATUS_RANK[old["state"]]
    try:
        theirs = github.current_status(commit, context)
    except GitHubError as err:
        return None, f"could not read the commit's status from GitHub ({err.kind})"
    rank = max(rank, STATUS_RANK.get(theirs, -1))
    if rank >= STATUS_RANK[new]:
        return None, "the commit keeps a better-ranked one"
    return new, ""


def record_status(state, commit, context, new, today):
    """Remembers a status that GitHub accepted."""
    verdicts = state["verdicts"]
    verdicts[f"{commit}:{context}"] = {"state": new, "day": today}
    while len(verdicts) > VERDICTS_MAX:
        oldest = min(verdicts, key=lambda k: (verdicts[k]["day"], k))
        del verdicts[oldest]


def day_of(state, today):
    day = state["days"].get(today)
    if day is None:
        day = {"nights": 0, "reported": False, "commit": "", "seen": {}, "overflow": 0}
        state["days"][today] = day
        for old in sorted(state["days"])[:-DAYS_KEPT]:
            del state["days"][old]
    return day


def see(day, fingerprint):
    """Today's entry for a failure, or None past the day's cap on distinct failures."""
    seen = day["seen"].get(fingerprint)
    if seen is None:
        if len(day["seen"]) >= FAILURES_PER_DAY:
            day["overflow"] += 1
            return None
        seen = {"comments": 0}
        day["seen"][fingerprint] = seen
    return seen


def remember(state, fingerprint, number, first_commit, last_commit):
    assert number > 0
    if fingerprint not in state["filed"] and len(state["filed"]) >= FILED_MAX:
        oldest = min(state["filed"], key=lambda fp: state["filed"][fp]["issue"])
        del state["filed"][oldest]
    state["filed"][fingerprint] = {"issue": number, "first_commit": first_commit,
                                   "last_commit": last_commit}
    assert len(state["filed"]) <= FILED_MAX


# ------------------------------------------------------------------------------------------------
# GitHub.


class GitHubError(Exception):
    """`kind`: gone (404, 410, a redirect), forbidden (403, locked), limited (rate limit),
    refused (anything else), unreachable (no answer)."""

    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind


def classify_status(status, headers):
    """None for success, else the kind."""
    if status in (200, 201):
        return None
    lower = {key.lower(): value for key, value in headers.items()}
    limited = "retry-after" in lower or lower.get("x-ratelimit-remaining") == "0"
    if status == 429 or (status == 403 and limited):
        return "limited"
    if status == 403:
        return "forbidden"
    if status in (404, 410) or 300 <= status < 400:
        return "gone"
    return "refused"


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
            "User-Agent": "nerva-jepsen",
            **({"Content-Type": "application/json"} if data is not None else {}),
        })
        try:
            with self.opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
                status, headers = response.status, dict(response.headers)
                body = response.read(RESPONSE_BYTES_MAX + 1)
        except urllib.error.HTTPError as err:
            status, headers, body = err.code, dict(err.headers or {}), b""
        except (urllib.error.URLError, OSError) as err:
            # Never the request's headers: only the method, the path and why.
            self.log(f"{method} {path}: no answer from GitHub ({type(err).__name__})")
            raise GitHubError("unreachable", "no answer")
        if len(body) > RESPONSE_BYTES_MAX:
            raise GitHubError("refused", "response too large")
        kind = classify_status(status, headers)
        if kind is None:
            return json.loads(body) if body else None
        meaning = {"gone": "the issue was deleted or moved; it is filed again",
                   "forbidden": "forbidden; the issue may be locked; skipped",
                   "limited": "rate limited; the writes stop"}.get(
                       kind, "the token is wrong or expired" if status == 401 else "refused")
        self.log(f"{method} {path}: HTTP {status}: {meaning}")
        raise GitHubError(kind, f"HTTP {status}")

    def markers(self):
        """Fingerprint -> issue number, from the issues labelled `jepsen` (the latest
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

    def current_status(self, commit, context):
        """GitHub's latest state for the context on the commit, or None: one bounded GET."""
        assert re.fullmatch(r"[0-9a-f]{40}", commit)
        reply = self.request("GET", f"/commits/{commit}/status?per_page=100")
        rows = reply.get("statuses") if isinstance(reply, dict) else None
        if not isinstance(rows, list):
            raise GitHubError("refused", "not a combined status")
        for row in rows:
            if isinstance(row, dict) and row.get("context") == context:
                return row.get("state")
        return None

    def status(self, commit, state, context, description, target_url):
        assert state in ("success", "failure", "error")
        payload = {"state": state, "context": context,
                   "description": description[:STATUS_DESCRIPTION_MAX]}
        if target_url:
            payload["target_url"] = target_url
        self.request("POST", f"/statuses/{commit}", payload)


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

    def current_status(self, commit, context):
        return None

    def status(self, commit, state, context, description, target_url):
        self.out(f"--- would set status {context} = {state} on {commit}: {description}"
                 + (f" ({target_url})" if target_url else ""))


# ------------------------------------------------------------------------------------------------
# Ingest.


def night_state(runs, host_failure, canary):
    """(commit status state, description) for the night."""
    if host_failure is not None:
        return "error", f"the host's: {host_failure}"
    if not runs:
        return "error", "the host's: no run was recorded"
    kinds = [run.kind for run in runs]
    verdicts = [(run.kind, run) for run in runs]
    total = len(runs)
    if canary:
        crashed = [r for k, r in verdicts if k == "crashed"]
        blind = [r for k, r in verdicts if k not in ("host", "crashed")
                 and not (k == "invalid" and "duplicate" in {n for _, n, _ in r.findings})]
        if crashed or blind:
            parts = []
            if crashed:
                parts.append(f"canary crashed: {len(crashed)} of {total} run(s) threw before "
                             "a verdict")
            if blind:
                parts.append(f"canary blind: {len(blind)} of {total} run(s) saw no duplicate")
            return "failure", "; ".join(parts)
        if "host" in kinds:
            return "error", f"the host's: {kinds.count('host')} of {total} run(s) did not finish"
        return "success", f"canary: Jepsen saw the duplicate in {total} of {total} run(s)"
    bad = [r for k, r in verdicts if k in ("invalid", "unknown", "crashed")]
    if bad:
        return "failure", f"{len(bad)} of {total} run(s) invalid or unknown: " + ", ".join(
            sorted({r.workload for r in bad}))
    if "host" in kinds:
        return "error", f"the host's: {kinds.count('host')} of {total} run(s) did not finish"
    return "success", f"{total} of {total} run(s) valid: " + ", ".join(
        sorted({r.workload for r in runs}))


def tracker_text(today, commit, runs, host_failure, state_name, description, filed_numbers):
    out = [f"{today} (UTC): commit `{commit}`: **{state_name}**, {description}.", ""]
    if host_failure is not None:
        out.append(f"- the night did not run: {host_failure}")
    for run in runs:
        out.append(f"- {run.summary()}" + (f", seed `{run.seed}`" if run.seed else ""))
    if filed_numbers:
        out.append("")
        out.append("Issues: " + ", ".join(f"#{n}" for n in sorted(filed_numbers) if n > 0))
    out.append("")
    out.append("A day with no comment here means the nightly did not run.")
    return "\n".join(out) + "\n"


def ingest(github, state, runs, host_failure, commit, tracker, archive, canary, now, repo, log,
           status=True):
    """Counts the night, sets its status, files or comments, posts the day. Returns a summary
    dict. Stops the writes at the first rate limit or unreachable GitHub."""
    summary = {"filed": 0, "commented": 0, "throttled": 0, "dropped": 0, "forbidden": 0,
               "status": None, "tracker": False, "stopped": None, "numbers": []}
    today = ymd(now)
    day = day_of(state, today)
    day["nights"] += 1
    day["commit"] = commit
    state_name, description = night_state(runs, host_failure, canary)
    summary["status"] = state_name
    posted, why = (None, "no status for this night")
    if status:
        posted, why = settle_status(state, github, commit,
                                    CONTEXT_CANARY if canary else CONTEXT_NIGHTLY,
                                    state_name, today)
    if posted is None:
        summary["status"] = f"{state_name} (not posted: {why})"
    items = []
    if host_failure is None:
        for run in runs:
            items.extend(make_findings(run, canary))
    groups = {}
    for item in items:
        groups.setdefault(item["fingerprint"], []).append(item)
    seen = {fp: see(day, fp) for fp in groups}
    context = CONTEXT_CANARY if canary else CONTEXT_NIGHTLY
    target = None
    try:
        if posted is not None:
            github.status(commit, state_name, context, description, target)
            record_status(state, commit, context, state_name, today)
        # A group reports its first item's run, and a run's groups are contiguous: free each
        # run's history after its last group, so the peak is one run's history (P240).
        last = {id(group[0]["run"]): n for n, group in enumerate(groups.values())
                if group[0]["run"] is not None}
        for n, (fingerprint, group) in enumerate(groups.items()):
            report_group(github, state, group[0], seen[fingerprint], commit, archive, summary)
            run = group[0]["run"]
            if run is not None and last[id(run)] == n:
                run.history = None
        if tracker is not None and not day["reported"]:
            note = description if status else (
                f"{description}; no status posted, the commit is the last the host knew")
            if status and posted is None and why.startswith("could not read"):
                note = f"{description}; no status posted: {why}"
            github.comment(tracker, tracker_text(today, commit, runs, host_failure, state_name,
                                                 note, summary["numbers"]))
            day["reported"] = True
            summary["tracker"] = True
    except GitHubError as err:
        summary["stopped"] = err.kind
    return summary


def report_group(github, state, item, seen, commit, archive, summary):
    fingerprint = item["fingerprint"]
    filed = state["filed"].get(fingerprint)
    if filed is None:
        if seen is None:
            summary["throttled"] += 1
            return
        open_item(github, state, item, commit, archive, summary)
        return
    summary["numbers"].append(filed["issue"])
    if seen is None or filed["last_commit"] == commit or \
            seen["comments"] >= COMMENTS_PER_FAILURE_PER_DAY:
        summary["throttled"] += 1
        return
    try:
        github.comment(filed["issue"], report_text(item, commit, archive, first=False))
    except GitHubError as err:
        if err.kind == "gone":
            del state["filed"][fingerprint]
            summary["numbers"].remove(filed["issue"])
            summary["dropped"] += 1
            open_item(github, state, item, commit, archive, summary)
            return
        if err.kind == "forbidden":
            filed["last_commit"] = commit
            summary["forbidden"] += 1
            return
        raise
    filed["last_commit"] = commit
    seen["comments"] += 1
    summary["commented"] += 1


def open_item(github, state, item, commit, archive, summary):
    assert item["fingerprint"] not in state["filed"]
    number = github.open(item["title"], report_text(item, commit, archive, first=True))
    if number > 0:  # a dry run's made-up numbers are never remembered
        remember(state, item["fingerprint"], number, commit, commit)
    summary["filed"] += 1
    summary["numbers"].append(number)


def summary_line(runs, host_failure, summary):
    kinds = {}
    for run in runs:
        kinds[run.kind] = kinds.get(run.kind, 0) + 1
    ran = ", ".join(f"{k} {n}" for k, n in sorted(kinds.items())) or "none"
    host = f" (the night did not run: {host_failure})" if host_failure else ""
    stopped = f" (writes stopped: {summary['stopped']})" if summary["stopped"] else ""
    return (f"jepsen: runs: {ran}{host}; status {summary['status']}; filed {summary['filed']}, "
            f"commented {summary['commented']}, throttled {summary['throttled']}, tracker "
            f"{'posted' if summary['tracker'] else 'not posted'}{stopped}")


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


def main(argv, now=None):
    parser = argparse.ArgumentParser(prog="jepsen_report.py")
    sub = parser.add_subparsers(dest="command", required=True)
    cmd = sub.add_parser("ingest")
    cmd.add_argument("--store", required=True)
    cmd.add_argument("--commit", required=True)
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--runs")
    cmd.add_argument("--archive")
    cmd.add_argument("--repo")
    cmd.add_argument("--token-file")
    cmd.add_argument("--tracker", type=int)
    cmd.add_argument("--expect-invalid", action="store_true")
    cmd.add_argument("--dry-run", action="store_true")
    cmd.add_argument("--no-status", action="store_true")
    args = parser.parse_args(argv)
    now = int(time.time()) if now is None else now

    def log(message):
        print(f"jepsen: {message}", file=sys.stderr, flush=True)

    if not re.fullmatch(r"[0-9a-f]{7,64}", args.commit):
        log("--commit must be a hex commit")
        return 1
    if args.tracker is not None and args.tracker <= 0:
        log("--tracker must be an issue number")
        return 1
    if not args.dry_run and not (args.repo and args.token_file):
        log("--repo and --token-file are required unless --dry-run")
        return 1
    if args.archive is not None and (len(args.archive) > 512 or "`" in args.archive
                                     or "\n" in args.archive):
        log("--archive must be a path of at most 512 characters")
        return 1
    try:
        runs, host_failure = read_night(args.store, args.runs)
    except BadInput as err:
        log(f"night refused, nothing reported: {err}")
        return 1
    try:
        if args.dry_run:
            github = DryRun(print)
        else:
            github = GitHub(args.repo, read_token(args.token_file), log)
        state = load_state(args.state)
    except Environment as err:
        log(str(err))
        return 2
    if state is None:
        state = new_state()
        try:
            for fingerprint, number in github.markers().items():
                if len(state["filed"]) < FILED_MAX:
                    remember(state, fingerprint, number, "", "")
        except GitHubError as err:
            log(f"the state file is missing and the issues could not be read ({err}); "
                "nothing is reported this run")
            return 2
        source = "a dry run reads no issues" if args.dry_run else "issue markers"
        log(f"the state file was missing: rebuilt from {len(state['filed'])} ({source})")
    try:
        summary = ingest(github, state, runs, host_failure, args.commit, args.tracker,
                         args.archive, args.expect_invalid, now, args.repo, log,
                         status=not args.no_status)
    except Exception:
        # Whatever was posted before the fault is remembered, so the next night does not repeat it.
        with contextlib.suppress(OSError):
            save_state(args.state, state)
        raise
    try:
        save_state(args.state, state)
    except OSError as err:
        log(f"cannot save the state file: {err}")
        return 2
    print(summary_line(runs, host_failure, summary), flush=True)
    return 2 if summary["stopped"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
