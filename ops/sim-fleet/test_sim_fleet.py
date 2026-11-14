#!/usr/bin/env python3
"""Tests for sim_fleet.py (P147h), without network. Run from the repository root:
python3 ops/sim-fleet/test_sim_fleet.py"""
import contextlib
import hashlib
import http.client
import importlib.util
import io
import json
import os
import signal
import stat
import subprocess
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sim_fleet", HERE / "sim_fleet.py")
fleet = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fleet)

DAY_ONE = 1_793_581_200  # 2026-11-02 01:00 UTC.
DAY = 24 * 3600

PANIC_LOG = """\
          4V  1 [  12:   12]  ...
thread 41234 panic: reached unreachable code
/var/lib/sim-fleet/nerva/lib/std/debug.zig:550:14: 0x10b4f1c in assert (vopr)
/var/lib/sim-fleet/nerva/src/vsr/replica.zig:4021:19: 0x1203a4b in on_prepare_ok (vopr)
/var/lib/sim-fleet/nerva/src/vsr/replica.zig:1530:41: 0x1210c11 in on_message (vopr)
/var/lib/sim-fleet/nerva/src/testing/cluster.zig:880:37: 0x12aa001 in cluster_tick (vopr)
/var/lib/sim-fleet/nerva/src/vopr.zig:271:27: 0x12bb002 in main (vopr)
"""

LIVENESS_LOG = """\
no liveness, final cluster state (core=111):
you can reproduce this failure with seed=9182736455
no state convergence: pending replica convergence
"""


class Round:
    """A round directory as run.sh writes it."""

    def __init__(self, test):
        self.dir = tempfile.TemporaryDirectory()
        test.addCleanup(self.dir.cleanup)
        self.path = self.dir.name

    def seed(self, worker, target, seed, code, tail="", errors=None, seconds=3):
        wdir = os.path.join(self.path, f"w{worker}")
        os.makedirs(wdir, exist_ok=True)
        with open(os.path.join(wdir, "results"), "a") as file:
            file.write(f"{target} {seed} {code} {seconds}\n")
        if code not in (0, 124, 137):
            fail = os.path.join(wdir, f"fail-{target.replace(':', '-')}-{seed}")
            os.makedirs(fail, exist_ok=True)
            Path(fail, "tail.log").write_text(tail)
            if errors is not None:
                Path(fail, "errors.log").write_text(errors)


class Recorder:
    """A GitHub that records the writes and answers as told."""

    def __init__(self, fail=None, markers=None):
        self.opened = []
        self.comments = []
        self.fail = fail or {}
        self.number = 100
        self._markers = markers or {}

    def markers(self):
        return dict(self._markers)

    def open(self, title, body):
        if "open" in self.fail:
            raise self.fail.pop("open")
        self.number += 1
        self.opened.append((self.number, title, body))
        return self.number

    def comment(self, number, body):
        key = ("comment", number)
        if key in self.fail:
            raise self.fail.pop(key)
        self.comments.append((number, body))


def ingest(test, github, state, rnd, commit, now, tracker=None):
    counts, failures = fleet.read_round(rnd.path)
    return fleet.ingest(github, state, counts, failures, commit, tracker, now, lambda m: None)


class Fingerprints(unittest.TestCase):
    def failure(self, target, code, tail="", errors=None, seed=7):
        rnd = Round(self)
        rnd.seed(0, target, seed, code, tail, errors)
        _, failures = fleet.read_round(rnd.path)
        self.assertEqual(len(failures), 1)
        return failures[0]

    def test_a_panic_is_its_message_and_top_frames_inside_src(self):
        failure = self.failure("vopr-nerva", 134, PANIC_LOG)
        self.assertEqual(failure["class"], "crash")
        self.assertEqual(failure["signature"],
                         "reached unreachable code at src/vsr/replica.zig:on_prepare_ok < "
                         "src/vsr/replica.zig:on_message < src/testing/cluster.zig:cluster_tick")
        self.assertEqual(fleet.title_of("vopr-nerva", "crash", failure["signature"]),
                         "VOPR nerva crash: reached unreachable code at "
                         "src/vsr/replica.zig:on_prepare_ok")

    def test_line_numbers_addresses_thread_ids_and_checkout_path_do_not_matter(self):
        moved = (PANIC_LOG.replace("4021:19", "4100:3").replace("0x1203a4b", "0x99")
                 .replace("41234", "7").replace("/var/lib/sim-fleet/nerva", "/home/x/src/n"))
        a = self.failure("vopr-nerva", 134, PANIC_LOG, seed=1)
        b = self.failure("vopr-nerva", 134, moved, seed=2)
        self.assertEqual(a["fingerprint"], b["fingerprint"])

    def test_with_a_source_root_only_its_src_frames_count(self):
        lines = PANIC_LOG.replace("lib/std", "zig/lib/std").splitlines()
        root = "/var/lib/sim-fleet/nerva"
        self.assertEqual(fleet.frames_of(lines, root)[0], "src/vsr/replica.zig:on_prepare_ok")
        self.assertEqual(fleet.frames_of(lines, "/elsewhere"), [])

    def test_digits_in_a_panic_message_become_N(self):
        a = self.failure("fuzz:lsm_tree", 134, "panic: index 12 out of bounds 0x7ff1\n")
        b = self.failure("fuzz:lsm_tree", 134, "panic: index 900 out of bounds 0x1\n")
        self.assertEqual(a["signature"], "index N out of bounds ADDR")
        self.assertEqual(a["fingerprint"], b["fingerprint"])

    def test_target_and_class_are_part_of_the_fingerprint(self):
        a = self.failure("vopr-nerva", 134, PANIC_LOG)
        b = self.failure("vopr-testing", 134, PANIC_LOG)
        c = self.failure("fuzz:storage", 134, PANIC_LOG)
        self.assertEqual(len({a["fingerprint"], b["fingerprint"], c["fingerprint"]}), 3)

    def test_the_vopr_exit_127_is_a_crash(self):
        failure = self.failure("vopr-nerva", 127, PANIC_LOG)
        self.assertEqual(failure["class"], "crash")

    def test_liveness_is_the_convergence_reason(self):
        failure = self.failure("vopr-nerva", 128, LIVENESS_LOG)
        self.assertEqual(failure["class"], "liveness")
        self.assertEqual(failure["signature"], "no state convergence: pending replica convergence")
        self.assertNotIn("9182736455", failure["key"])

    def test_correctness_is_the_last_err_line_of_the_full_log_replay(self):
        errors = ("[err] (client): 3402823669N: session evicted: reason=no_session\n"
                  "[err] (state_checker): state checker error: error.ReplicaStateDiverged\n")
        failure = self.failure("vopr-testing", 129, "short log\n", errors)
        self.assertEqual(failure["class"], "correctness")
        self.assertEqual(failure["signature"],
                         "(state_checker): state checker error: error.ReplicaStateDiverged")

    def test_client_evictions_are_never_the_signature(self):
        errors = "[err] (client): 3402823669: session evicted: reason=no_session\n"
        failure = self.failure("vopr-nerva", 129, "x\n", errors)
        self.assertEqual(failure["signature"], "no [err] line (the full-log replay found none)")

    def test_correctness_without_a_replay_has_a_stable_signature(self):
        a = self.failure("vopr-nerva", 129, "x\n", "")
        self.assertEqual(a["signature"], "no [err] line (the full-log replay found none)")

    def test_a_fuzzer_on_a_fuzzer_code_129_is_a_crash(self):
        failure = self.failure("fuzz:ewah", 129, "")
        self.assertEqual(failure["class"], "crash")
        self.assertEqual(failure["signature"], "killed by signal 1")

    def test_a_returned_error_and_an_unknown_exit(self):
        self.assertEqual(self.failure("fuzz:ewah", 1, "error: OutOfMemory\n")["signature"],
                         "OutOfMemory")
        self.assertEqual(self.failure("fuzz:ewah", 3, "nothing\n")["signature"], "exit 3")

    def test_timeouts_and_host_kills_are_counted_not_filed(self):
        rnd = Round(self)
        rnd.seed(0, "vopr-nerva", 1, 0)
        rnd.seed(0, "vopr-nerva", 2, 124)
        rnd.seed(1, "vopr-nerva", 3, 137)
        counts, failures = fleet.read_round(rnd.path)
        self.assertEqual(failures, [])
        self.assertEqual(counts["vopr-nerva"], {"seeds": 3, "failed": 0, "timeouts": 1, "host": 1})

    def test_a_malformed_round_is_refused(self):
        for line in ("vopr-nerva 1 0\n", "vopr-bogus 1 0 3\n", "vopr-nerva x 0 3\n",
                     "fuzz:Bad-Name 1 0 3\n", "vopr-nerva 1 300 3\n"):
            rnd = Round(self)
            os.makedirs(os.path.join(rnd.path, "w0"))
            Path(rnd.path, "w0", "results").write_text(line)
            with self.assertRaises(fleet.BadInput, msg=line):
                fleet.read_round(rnd.path)

    def test_every_collection_of_a_round_is_bounded(self):
        # Each bound is checked as the collection grows, not after: lowered here to 2.
        rnd = Round(self)
        for worker in range(3):
            rnd.seed(worker, "vopr-nerva", worker, 134)
        for name, value in (("WORKERS_MAX", 2), ("ROUND_FAILURES_MAX", 2),
                            ("RESULTS_LINES_MAX", 2), ("RESULTS_BYTES_MAX", 40)):
            saved = getattr(fleet, name)
            setattr(fleet, name, value)
            try:
                with self.assertRaisesRegex(fleet.BadInput, f"more than {value} ", msg=name):
                    fleet.read_round(rnd.path)
            finally:
                setattr(fleet, name, saved)
        self.assertEqual(len(fleet.read_round(rnd.path)[1]), 3)

    def test_the_issue_body_carries_seed_commit_replay_tail_and_marker(self):
        failure = self.failure("vopr-nerva", 128, LIVENESS_LOG, seed=42)
        body = fleet.report_text([failure], "abc1234", first=True)
        self.assertIn("`42`", body)
        self.assertIn("git checkout abc1234 && ./zig/zig build -Drelease vopr "
                      "-Dvopr-state-machine=nerva -- 42", body)
        self.assertIn("no state convergence: pending replica convergence", body)
        self.assertIn(f"<!-- vopr-fleet fingerprint: {failure['fingerprint']} -->", body)
        self.assertEqual(fleet.MARKER.search(body).group(1), failure["fingerprint"])
        comment = fleet.report_text([failure], "def5678", first=False)
        self.assertNotIn("fingerprint:", comment)
        fuzz = fleet.replay_of("fuzz:lsm_tree", 5)
        self.assertEqual(fuzz, "./zig/zig build -Drelease fuzz -- lsm_tree 5")

    def test_the_log_excerpt_is_bounded_and_cannot_close_the_fence(self):
        lines = ["```"] + ["x" * 500] * 1000
        excerpt = fleet.log_excerpt(lines)
        self.assertLessEqual(len(excerpt), fleet.ISSUE_LOG_BYTES_MAX)
        self.assertLessEqual(excerpt.count("\n") + 1, fleet.ISSUE_LOG_LINES_MAX)
        self.assertNotIn("```", fleet.log_excerpt(["a```b"]))

    def test_titles_are_bounded(self):
        title = fleet.title_of("fuzz:lsm_tree", "crash", "y" * 400)
        self.assertEqual(len(title), fleet.TITLE_BYTES_MAX)


class Dedup(unittest.TestCase):
    def crash_round(self, seeds=(1,), target="vopr-nerva"):
        rnd = Round(self)
        for seed in seeds:
            rnd.seed(0, target, seed, 134, PANIC_LOG)
        return rnd

    def test_one_issue_per_fingerprint_with_the_other_seeds_listed(self):
        github, state = Recorder(), fleet.new_state()
        summary = ingest(self, github, state, self.crash_round((1, 2, 3)), "aaaaaaa", DAY_ONE)
        self.assertEqual(summary["filed"], 1)
        self.assertEqual(len(github.opened), 1)
        self.assertIn("`2`, `3`", github.opened[0][2])

    def test_a_known_failure_gets_one_comment_per_new_commit(self):
        github, state = Recorder(), fleet.new_state()
        ingest(self, github, state, self.crash_round(), "aaaaaaa", DAY_ONE)
        ingest(self, github, state, self.crash_round(), "aaaaaaa", DAY_ONE + 60)
        self.assertEqual(github.comments, [])
        ingest(self, github, state, self.crash_round(), "bbbbbbb", DAY_ONE + 120)
        self.assertEqual([n for n, _ in github.comments], [101])
        ingest(self, github, state, self.crash_round(), "bbbbbbb", DAY_ONE + 180)
        self.assertEqual(len(github.comments), 1)

    def test_comments_are_capped_per_failure_per_day(self):
        github, state = Recorder(), fleet.new_state()
        ingest(self, github, state, self.crash_round(), "a000000", DAY_ONE)
        cap = fleet.COMMENTS_PER_FAILURE_PER_DAY
        for i in range(cap + 3):
            ingest(self, github, state, self.crash_round(), f"b{i:06d}", DAY_ONE + 60 * (i + 1))
        self.assertEqual(len(github.comments), cap)
        ingest(self, github, state, self.crash_round(), "c000000", DAY_ONE + DAY)
        self.assertEqual(len(github.comments), cap + 1)

    def test_distinct_failures_are_capped_per_day(self):
        github, state = Recorder(), fleet.new_state()
        rnd = Round(self)
        for i in range(fleet.FAILURES_PER_DAY + 5):
            rnd.seed(0, "fuzz:ewah", i, 134, f"panic: bug kind {chr(65 + i % 26)}{i // 26}x\n"
                     .replace("0x", "zx"))
        counts, failures = fleet.read_round(rnd.path)
        # Digits normalise to N, so make the messages distinct with letters only.
        for i, failure in enumerate(failures):
            failure["signature"] = "bug " + "".join(chr(97 + int(d)) for d in str(i))
            failure["key"] = fleet.fingerprint_key("fuzz:ewah", "crash", failure["signature"])
            failure["fingerprint"] = fleet.fingerprint_of(failure["key"])
        fleet.ingest(github, state, counts, failures, "aaaaaaa", None, DAY_ONE, lambda m: None)
        self.assertEqual(len(github.opened), fleet.FAILURES_PER_DAY)
        day = state["days"][fleet.ymd(DAY_ONE)]
        self.assertEqual(day["overflow"], 5)

    def test_daily_totals_go_first_once_and_then_the_failures(self):
        github, state = Recorder(), fleet.new_state()
        ingest(self, github, state, self.crash_round(), "aaaaaaa", DAY_ONE, tracker=9)
        self.assertEqual(github.comments, [])
        ingest(self, github, state, self.crash_round(), "bbbbbbb", DAY_ONE + DAY, tracker=9)
        self.assertEqual(github.comments[0][0], 9)
        self.assertIn("2026-11-02 (UTC): 1 seeds run, 1 failed", github.comments[0][1])
        self.assertIn("- #101: 1 seeds", github.comments[0][1])
        self.assertEqual(github.comments[1][0], 101)
        ingest(self, github, state, self.crash_round(), "ccccccc", DAY_ONE + DAY + 60, tracker=9)
        self.assertEqual([n for n, _ in github.comments].count(9), 1)

    def test_a_rate_limit_holds_every_write_until_the_wait_is_over(self):
        limited = fleet.GitHubError("limited", "HTTP 429", wait=600)
        github, state = Recorder(fail={"open": limited}), fleet.new_state()
        summary = ingest(self, github, state, self.crash_round(), "aaaaaaa", DAY_ONE)
        self.assertEqual(summary["stopped"], "limited")
        self.assertEqual(state["hold_until"], DAY_ONE + 600)
        summary = ingest(self, github, state, self.crash_round(), "aaaaaaa", DAY_ONE + 300)
        self.assertTrue(summary["held"])
        self.assertEqual(github.opened, [])
        ingest(self, github, state, self.crash_round(), "aaaaaaa", DAY_ONE + 601)
        self.assertEqual(len(github.opened), 1)
        self.assertEqual(state["days"][fleet.ymd(DAY_ONE)]["rounds"], 3)

    def test_a_gone_issue_is_filed_again_and_a_locked_one_skipped(self):
        github, state = Recorder(), fleet.new_state()
        ingest(self, github, state, self.crash_round(), "aaaaaaa", DAY_ONE)
        github.fail[("comment", 101)] = fleet.GitHubError("gone", "HTTP 404")
        summary = ingest(self, github, state, self.crash_round(), "bbbbbbb", DAY_ONE + 60)
        self.assertEqual(summary["dropped"], 1)
        self.assertEqual(len(github.opened), 2)
        github.fail[("comment", 102)] = fleet.GitHubError("forbidden", "HTTP 403")
        summary = ingest(self, github, state, self.crash_round(), "ccccccc", DAY_ONE + 120)
        self.assertEqual(summary["forbidden"], 1)
        summary = ingest(self, github, state, self.crash_round(), "ccccccc", DAY_ONE + 180)
        self.assertEqual(summary["throttled"], 1)

    def test_statuses_and_rate_headers(self):
        self.assertIsNone(fleet.classify_status(201, {}, 0))
        self.assertEqual(fleet.classify_status(429, {}, 0), ("limited", 0))
        self.assertEqual(fleet.classify_status(403, {"Retry-After": "120"}, 0), ("limited", 120))
        self.assertEqual(fleet.classify_status(
            403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000"}, 400),
            ("limited", 600))
        self.assertEqual(fleet.classify_status(403, {"X-RateLimit-Remaining": "4"}, 0),
                         ("forbidden", 0))
        self.assertEqual(fleet.classify_status(404, {}, 0), ("gone", 0))
        self.assertEqual(fleet.classify_status(301, {}, 0), ("gone", 0))
        self.assertEqual(fleet.classify_status(401, {}, 0), ("refused", 0))
        self.assertEqual(fleet.classify_status(429, {"Retry-After": "999999"}, 0),
                         ("limited", fleet.HOLD_SECONDS_MAX))

    def test_redirects_are_never_followed(self):
        handler = fleet.NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 301, "", {}, "https://evil/"))


class StateFile(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "state.json")

    def test_round_trip_and_an_unreadable_file_is_an_error_not_empty(self):
        self.assertIsNone(fleet.load_state(self.path))
        state = fleet.new_state()
        fleet.remember(state, "f" * 32, 5, "a", "a")
        fleet.save_state(self.path, state)
        self.assertEqual(fleet.load_state(self.path), state)
        Path(self.path).write_text("{not json")
        with self.assertRaises(fleet.Environment):
            fleet.load_state(self.path)

    def test_a_missing_state_is_rebuilt_from_markers_and_not_filed_twice(self):
        rnd = Round(self)
        rnd.seed(0, "vopr-nerva", 1, 134, PANIC_LOG)
        _, failures = fleet.read_round(rnd.path)
        github = Recorder(markers={failures[0]["fingerprint"]: 77})
        # main() rebuilds through `markers`; do the same here as main does.
        state = fleet.new_state()
        for fingerprint, number in github.markers().items():
            fleet.remember(state, fingerprint, number, "", "")
        ingest(self, github, state, rnd, "aaaaaaa", DAY_ONE)
        self.assertEqual(github.opened, [])
        self.assertEqual([n for n, _ in github.comments], [77])

    def test_remembered_failures_are_bounded(self):
        state = fleet.new_state()
        for i in range(fleet.FILED_MAX + 10):
            fleet.remember(state, f"{i:032x}", i + 1, "a", "a")
        self.assertEqual(len(state["filed"]), fleet.FILED_MAX)
        self.assertNotIn(f"{0:032x}", state["filed"])

    def test_days_kept_are_bounded(self):
        state = fleet.new_state()
        for i in range(fleet.DAYS_KEPT + 5):
            fleet.day_of(state, fleet.ymd(DAY_ONE + i * DAY))
        self.assertEqual(len(state["days"]), fleet.DAYS_KEPT)

    def test_dry_run_end_to_end_prints_and_needs_no_token(self):
        rnd = Round(self)
        rnd.seed(0, "vopr-nerva", 1, 128, LIVENESS_LOG)
        rnd.seed(1, "vopr-nerva", 2, 0)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = fleet.main(["ingest", "--round", rnd.path, "--round-id", ID_A, "--commit",
                               "abcdef1", "--state", self.path, "--dry-run"], now=DAY_ONE)
        self.assertEqual(code, 0)
        self.assertIn("would open issue [sim-fleet] 'VOPR nerva liveness: no state convergence: "
                      "pending replica convergence'", out.getvalue())
        self.assertIn("sim-fleet: 2 seeds, 1 failed", out.getvalue())
        self.assertEqual(json.loads(Path(self.path).read_text())["days"]["2026-11-02"]["rounds"],
                         1)

    def test_main_refuses_a_bad_round(self):
        rnd = Round(self)
        os.makedirs(os.path.join(rnd.path, "w0"))
        Path(rnd.path, "w0", "results").write_text("garbage\n")
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            code = fleet.main(["ingest", "--round", rnd.path, "--round-id", ID_A, "--commit",
                               "abcdef1", "--state", self.path, "--dry-run"], now=DAY_ONE)
        self.assertEqual(code, 1)
        # No seed is counted, but the round is: against its commit and its day, as refused
        # (#370), and the day's totals on the tracker say so.
        state = fleet.load_state(self.path)
        day = state["days"][fleet.ymd(DAY_ONE)]
        self.assertEqual((day["rounds"], day["refused"], day["targets"]), (0, 1, {}))
        self.assertEqual(state["commits"]["abcdef1"]["refused"], 1)
        self.assertEqual(state["commits"]["abcdef1"]["rounds"], 0)
        text = fleet.totals_text(state, fleet.ymd(DAY_ONE), day)
        self.assertIn("in 0 rounds, and 1 rounds refused (their seeds unknown;", text)
        state["days"][fleet.ymd(DAY_ONE)]["refused"] = 0
        self.assertNotIn("refused", fleet.totals_text(state, fleet.ymd(DAY_ONE), day))


SHA_A = "1a2b3c4" + "0" * 33
SHA_B = "9f8e7d6" + "0" * 33
ID_A = "1793581200-0123456789abcdef"
ID_B = "1793581260-fedcba9876543210"
_ids = iter(range(1, 1 << 30))


def new_id():
    """A fresh round id, as run.sh makes them."""
    return f"{DAY_ONE}-{next(_ids):016x}"


def soak_round(test, seconds=1800):
    """A round of two workers, each busy for `seconds`: 2 vopr-nerva, 1 vopr-testing, 1 fuzz seed
    and one failing vopr-nerva seed."""
    rnd = Round(test)
    rnd.seed(0, "vopr-nerva", 1, 0, seconds=seconds // 2)
    rnd.seed(0, "vopr-nerva", 2, 134, PANIC_LOG, seconds=seconds // 2)
    rnd.seed(1, "vopr-testing", 3, 0, seconds=seconds // 2)
    rnd.seed(1, "fuzz:lsm_tree", 4, 0, seconds=seconds // 2)
    return rnd


def soak(test, state, commit):
    path = os.path.join(tempfile.mkdtemp(), "state.json")
    test.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
    fleet.save_state(path, state)
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = fleet.main(["soak", "--commit", commit, "--state", path], now=DAY_ONE)
    return code, out.getvalue().strip(), err.getvalue()


class Soak(unittest.TestCase):
    def test_hours_and_seeds_are_counted_per_commit_from_rounds_that_span_two_commits(self):
        github, state = Recorder(), fleet.new_state()
        for i in range(2):
            ingest(self, github, state, soak_round(self), SHA_A, DAY_ONE + 60 * i)
        ingest(self, github, state, soak_round(self, 900), SHA_B, DAY_ONE + 600)
        ingest(self, github, state, soak_round(self), SHA_A, DAY_ONE + 700)
        a, b = state["commits"][SHA_A], state["commits"][SHA_B]
        # The busiest worker's seconds: 1800 each time, never the two workers' sum.
        self.assertEqual((a["seconds"], a["rounds"]), (3 * 1800, 3))
        self.assertEqual((b["seconds"], b["rounds"]), (900, 1))
        self.assertEqual(a["kinds"]["vopr-nerva"], {"seeds": 6, "failed": 3, "timeouts": 0, "host": 0})
        self.assertEqual(a["kinds"]["fuzz"], {"seeds": 3, "failed": 0, "timeouts": 0, "host": 0})
        self.assertEqual(b["kinds"]["vopr-testing"], {"seeds": 1, "failed": 0, "timeouts": 0, "host": 0})

    def test_the_soak_line_is_the_one_the_release_quotes(self):
        github, state = Recorder(), fleet.new_state()
        for i in range(2):
            ingest(self, github, state, soak_round(self, 3600), SHA_A, DAY_ONE + 60 * i)
        code, line, _ = soak(self, state, SHA_A)
        self.assertEqual(code, 1)  # Not clean: two seeds failed.
        # The seed's own 134 failure is filed on the first round, so it is listed too.
        self.assertEqual(line, "soak 1a2b3c4: 2.0 h, vopr-nerva 4 seeds, vopr-testing 2, fuzz 2; "
                               "2 failures, 0 past the deadline, 0 killed by the host; "
                               "sim-fleet issues its rounds hit: #101")
        # A prefix names the commit as well.
        self.assertEqual(soak(self, state, "1a2b3c4")[1], line)

    def test_a_commit_with_no_failure_says_none(self):
        github, state = Recorder(), fleet.new_state()
        rnd = Round(self)
        rnd.seed(0, "vopr-nerva", 1, 0, seconds=45 * 60)
        rnd.seed(0, "vopr-nerva", 2, 0, seconds=45 * 60)
        ingest(self, github, state, rnd, SHA_A, DAY_ONE)
        code, line, _ = soak(self, state, SHA_A)
        self.assertEqual((code, line), (0, "soak 1a2b3c4: 1.5 h, vopr-nerva 2 seeds, "
                                           "vopr-testing 0, fuzz 0; 0 failures, 0 past "
                                           "the deadline, 0 killed by the host; "
                                           "sim-fleet issues its rounds hit: none"))

    def test_a_fingerprint_a_commit_hit_is_listed(self):
        github, state = Recorder(), fleet.new_state()
        ingest(self, github, state, soak_round(self), SHA_A, DAY_ONE)
        ingest(self, github, state, soak_round(self), SHA_B, DAY_ONE + 60)
        self.assertIn("sim-fleet issues its rounds hit: #101", soak(self, state, SHA_B)[1])
        # The rounds of A hit it as well: the record is by round, not by last report.
        self.assertIn("sim-fleet issues its rounds hit: #101", soak(self, state, SHA_A)[1])

    def test_a_fingerprint_is_listed_though_no_report_was_posted(self):
        github, state = Recorder(), fleet.new_state()
        state["hold_until"] = DAY_ONE + 3600
        ingest(self, github, state, soak_round(self), SHA_A, DAY_ONE)
        self.assertEqual(github.opened if hasattr(github, "opened") else [], [])
        code, line, _ = soak(self, state, SHA_A)
        self.assertEqual(code, 1)
        self.assertRegex(line, r"sim-fleet issues its rounds hit: not filed \([0-9a-f]{12}\)$")

    def test_hung_and_killed_seeds_are_not_a_clean_soak(self):
        github, state = Recorder(), fleet.new_state()
        rnd = Round(self)
        for seed in range(144):
            rnd.seed(0, "vopr-nerva", seed, 124, seconds=600)
        rnd.seed(1, "vopr-nerva", 999, 137, seconds=30)
        ingest(self, github, state, rnd, SHA_A, DAY_ONE)
        code, line, err = soak(self, state, SHA_A)
        self.assertEqual(code, 1)
        self.assertIn("0 failures, 144 past the deadline, 1 killed by the host", line)
        self.assertIn("not clean", err)

    def test_a_seed_counts_for_at_most_its_cap(self):
        github, state = Recorder(), fleet.new_state()
        rnd = Round(self)
        rnd.seed(0, "fuzz:ewah", 3, 0, seconds=86400)
        ingest(self, github, state, rnd, SHA_A, DAY_ONE)
        self.assertEqual(state["commits"][SHA_A]["seconds"], fleet.SEED_SECONDS_MAX)
        self.assertEqual(soak(self, state, SHA_A)[0], 0)

    def test_hours_are_floored(self):
        self.assertEqual(fleet.hours_text(86256), "23.9")
        self.assertEqual(fleet.hours_text(86400), "24.0")

    def test_an_unknown_commit_is_0_hours_and_exit_1(self):
        github, state = Recorder(), fleet.new_state()
        ingest(self, github, state, soak_round(self), SHA_A, DAY_ONE)
        code, line, err = soak(self, state, "deadbee" + "0" * 33)
        self.assertEqual(code, 1)
        self.assertEqual(line, "soak deadbee: 0.0 h, vopr-nerva 0 seeds, vopr-testing 0, fuzz 0; "
                               "0 failures, 0 past the deadline, 0 killed by the host; "
                               "sim-fleet issues its rounds hit: none")
        self.assertIn("no rounds of deadbee", err)

    def test_a_prefix_of_two_commits_is_refused(self):
        github, state = Recorder(), fleet.new_state()
        ingest(self, github, state, soak_round(self), "abcdef1" + "0" * 33, DAY_ONE)
        ingest(self, github, state, soak_round(self), "abcdef1" + "1" * 33, DAY_ONE + 60)
        self.assertEqual(soak(self, state, "abcdef1")[0], 1)

    def test_a_bad_commit_or_a_missing_state_is_refused(self):
        self.assertEqual(soak(self, fleet.new_state(), "xyz")[0], 1)
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(fleet.main(["soak", "--commit", SHA_A, "--state",
                                         "/nonexistent/state.json"]), 2)

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = fleet.main(list(argv), now=DAY_ONE)
        return code, out.getvalue().strip(), err.getvalue()

    def state_path(self):
        folder = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", folder])
        return os.path.join(folder, "state.json")

    def ingest_main(self, path, rnd, commit=SHA_A, round_id=None):
        return self.run_main("ingest", "--round", rnd.path, "--round-id", round_id or new_id(),
                             "--commit", commit, "--state", path, "--dry-run")

    def refuse_main(self, path, round_id=None, commit=SHA_A):
        return self.run_main("refuse", "--round-id", round_id or new_id(), "--commit", commit,
                             "--state", path)

    def soak_code(self, path, commit=SHA_A):
        return self.run_main("soak", "--commit", commit, "--state", path)[0]

    def too_many_failures(self):
        rnd = Round(self)
        wdir = os.path.join(rnd.path, "w0")
        os.makedirs(wdir)
        with open(os.path.join(wdir, "results"), "w") as file:
            for seed in range(fleet.ROUND_FAILURES_MAX + 1):
                file.write(f"vopr-nerva {seed} 134 2\n")
        return rnd

    def clean_round(self):
        rnd = Round(self)
        for seed in range(300):
            rnd.seed(0, "vopr-nerva", seed, 0, seconds=1)
        return rnd

    def test_a_refused_round_then_a_clean_one_is_not_a_clean_soak(self):
        path = self.state_path()
        code, _, err = self.ingest_main(path, self.too_many_failures())
        self.assertEqual(code, 1)
        self.assertIn("refused", err)
        self.assertEqual(self.ingest_main(path, self.clean_round())[0], 0)
        code, line, err = self.run_main("soak", "--commit", SHA_A, "--state", path)
        self.assertEqual(code, 1)
        self.assertIn("vopr-nerva 300 seeds", line)
        self.assertTrue(line.endswith("; 1 rounds refused or lost by the reporter, "
                                      "their seeds unknown"), line)
        self.assertIn("not clean", err)

    def test_a_refused_round_is_recorded_with_its_id(self):
        path = self.state_path()
        self.ingest_main(path, self.too_many_failures(), round_id=ID_A)
        self.assertEqual(fleet.load_state(path)["last_round"],
                         {"id": ID_A, "commit": SHA_A, "outcome": "refused"})

    def test_a_malformed_results_line_is_a_refused_round_too(self):
        path = self.state_path()
        rnd = self.clean_round()
        with open(os.path.join(rnd.path, "w0", "results"), "a") as file:
            file.write("vopr-nerva not-a-seed\n")
        self.assertEqual(self.ingest_main(path, rnd)[0], 1)
        self.assertEqual(self.ingest_main(path, self.clean_round())[0], 0)
        self.assertEqual(self.soak_code(path), 1)

    def test_a_refused_round_counts_against_its_own_commit_only(self):
        path = self.state_path()
        self.assertEqual(self.ingest_main(path, self.clean_round(), SHA_B)[0], 0)
        self.assertEqual(self.ingest_main(path, self.too_many_failures(), SHA_A)[0], 1)
        self.assertEqual(self.soak_code(path, SHA_B), 0)
        self.assertEqual(self.soak_code(path, SHA_A), 1)

    def test_a_commit_with_only_a_refused_round_is_exit_1_and_says_why(self):
        path = self.state_path()
        self.ingest_main(path, self.too_many_failures())
        code, line, err = self.run_main("soak", "--commit", SHA_A, "--state", path)
        self.assertEqual(code, 1)
        self.assertIn("0.0 h", line)
        self.assertIn("1 rounds refused", line)
        self.assertNotIn("no rounds of", err)

    def test_refuse_counts_each_round_once(self):
        path = self.state_path()
        self.assertEqual(self.ingest_main(path, self.clean_round())[0], 0)
        self.assertEqual(self.soak_code(path), 0)
        for round_id in (ID_A, ID_A, ID_B):
            self.assertEqual(self.refuse_main(path, round_id)[0], 0)
        code, line, _ = self.run_main("soak", "--commit", SHA_A, "--state", path)
        self.assertEqual(code, 1)
        self.assertIn("; 2 rounds refused or lost", line)
        self.assertEqual(self.refuse_main(path, "not-an-id")[0], 1)
        self.assertEqual(fleet.load_state(path)["commits"][SHA_A]["refused"], 2)

    def test_ingest_counts_each_round_once_and_refuse_leaves_a_counted_round_alone(self):
        path = self.state_path()
        rnd = self.clean_round()
        for _ in range(2):
            self.assertEqual(self.ingest_main(path, rnd, round_id=ID_A)[0], 0)
        self.assertEqual(self.refuse_main(path, ID_A)[0], 0)
        state = fleet.load_state(path)
        self.assertEqual(state["commits"][SHA_A]["rounds"], 1)
        self.assertEqual(state["commits"][SHA_A]["refused"], 0)
        self.assertEqual(state["last_round"]["outcome"], "counted")
        # A refused round is not counted by a later ingest of the same id either, and that
        # ingest exits 1, so run.sh keeps the round for a look.
        self.ingest_main(path, self.too_many_failures(), round_id=ID_B)
        self.assertEqual(self.ingest_main(path, rnd, round_id=ID_B)[0], 1)
        state = fleet.load_state(path)
        self.assertEqual((state["commits"][SHA_A]["rounds"], state["commits"][SHA_A]["refused"]),
                         (1, 1))

    def live_main(self, path, rnd, token_file, commit=SHA_A, round_id=None):
        return self.run_main("ingest", "--round", rnd.path, "--round-id", round_id or new_id(),
                             "--commit", commit, "--state", path, "--repo", "NervaLog/nerva",
                             "--token-file", token_file)

    def failing_round(self):
        rnd = Round(self)
        for seed in range(3):
            rnd.seed(0, "vopr-nerva", seed, 134, tail="boom")
        return rnd

    def test_a_missing_token_file_still_counts_the_round(self):
        # A token is needed only to report: the round is counted, and recorded, without it.
        path = self.state_path()
        code, out, err = self.live_main(path, self.clean_round(), "/nonexistent/token",
                                        round_id=ID_A)
        self.assertEqual(code, 0)
        self.assertIn("cannot read the token file", err)
        self.assertIn("(writes stopped: token)", out)
        state = fleet.load_state(path)
        self.assertEqual(state["last_round"]["id"], ID_A)
        self.assertEqual(state["commits"][SHA_A]["refused"], 0)
        self.assertEqual(self.soak_code(path), 0)
        # The failures of a round counted without a token still make its commit not clean.
        self.live_main(path, self.failing_round(), "/nonexistent/token")
        self.assertEqual(self.soak_code(path), 1)

    def test_the_issues_unreadable_while_rebuilding_count_the_round_and_file_nothing(self):
        failing = self.failing_round()
        _, failures = fleet.read_round(failing.path)
        fingerprint = failures[0]["fingerprint"]

        class Flaky(Recorder):
            down = True

            def __init__(self, *args):
                super().__init__(markers={fingerprint: 7})
                calls.append(self)

            def markers(self):
                if Flaky.down:
                    raise fleet.GitHubError("unreachable", "no answer")
                return super().markers()

        calls = []
        path = self.state_path()
        token = os.path.join(os.path.dirname(path), "token")
        Path(token).write_text("t0ken\n")
        with mock.patch.object(fleet, "GitHub", Flaky):
            code, out, err = self.live_main(path, failing, token)
            self.assertEqual(code, 0)
            self.assertIn("could not be read", err)
            self.assertEqual(calls[0].opened, [])
            state = fleet.load_state(path)
            self.assertTrue(state["rebuild"])
            self.assertEqual(state["filed"], {})
            self.assertEqual(state["commits"][SHA_A]["refused"], 0)
            self.assertEqual(state["commits"][SHA_A]["rounds"], 1)
            Flaky.down = False
            self.assertEqual(self.live_main(path, self.failing_round(), token)[0], 0)
        # The marker was read before anything was filed: a comment on #7, no second issue.
        self.assertEqual(calls[1].opened, [])
        self.assertEqual([number for number, _ in calls[1].comments], [7])
        self.assertNotIn("rebuild", fleet.load_state(path))

    def test_a_bad_commit_is_a_usage_error_and_records_nothing(self):
        path = self.state_path()
        for command in (["ingest", "--round", "r", "--round-id", ID_A], ["refuse",
                                                                         "--round-id", ID_A]):
            with self.assertRaises(SystemExit) as caught, \
                    contextlib.redirect_stderr(io.StringIO()):
                fleet.main(command + ["--commit", "xyz", "--state", path])
            self.assertEqual(caught.exception.code, 2)
        self.assertFalse(os.path.exists(path))

    def test_a_missing_repo_or_a_bad_round_id_or_tracker_records_nothing(self):
        path = self.state_path()
        rnd = self.clean_round()
        self.assertEqual(self.run_main("ingest", "--round", rnd.path, "--round-id", ID_A,
                                       "--commit", SHA_A, "--state", path)[0], 1)
        self.assertEqual(self.run_main("ingest", "--round", rnd.path, "--round-id", "1-abc",
                                       "--commit", SHA_A, "--state", path, "--dry-run")[0], 1)
        self.assertEqual(self.run_main("ingest", "--round", rnd.path, "--round-id", ID_A,
                                       "--commit", SHA_A, "--state", path, "--dry-run",
                                       "--tracker", "0")[0], 1)
        self.assertFalse(os.path.exists(path))

    def test_an_uncaught_exception_in_the_reporter_records_nothing(self):
        rnd = Round(self)
        os.makedirs(os.path.join(rnd.path, "w0", "results"))  # A directory: open() raises.
        path = self.state_path()
        out = subprocess.run(
            ["python3", "-I", str(HERE / "sim_fleet.py"), "ingest", "--round", rnd.path,
             "--round-id", ID_A, "--commit", SHA_A, "--state", path, "--dry-run"],
            capture_output=True, text=True)
        self.assertEqual(out.returncode, 1)
        self.assertIn("Traceback", out.stderr)
        self.assertFalse(os.path.exists(path))

    def test_a_refusal_with_no_state_starts_one_the_next_ingest_rebuilds(self):
        path = self.state_path()
        self.assertEqual(self.refuse_main(path)[0], 0)
        self.assertEqual(self.soak_code(path), 1)
        code, _, err = self.ingest_main(path, self.clean_round())
        self.assertEqual(code, 0)
        self.assertIn("the state file was missing: rebuilt", err)
        state = fleet.load_state(path)
        self.assertNotIn("rebuild", state)
        self.assertEqual(state["commits"][SHA_A]["refused"], 1)
        self.assertNotIn("the state file was missing", self.ingest_main(path, self.clean_round())[2])

    def test_an_unreadable_state_is_not_overwritten(self):
        path = self.state_path()
        with open(path, "w") as file:
            file.write("not json")
        self.assertEqual(self.refuse_main(path)[0], 1)
        self.assertEqual(self.ingest_main(path, self.too_many_failures())[0], 1)
        self.assertEqual(self.ingest_main(path, self.clean_round())[0], 1)
        with open(path) as file:
            self.assertEqual(file.read(), "not json")

    def test_a_save_that_fails_records_nothing(self):
        path = self.state_path()
        with mock.patch.object(fleet, "save_state", side_effect=OSError("disk full")):
            self.assertEqual(self.ingest_main(path, self.clean_round())[0], 1)
            self.assertEqual(self.ingest_main(path, self.too_many_failures())[0], 1)
            self.assertEqual(self.refuse_main(path)[0], 1)
        self.assertFalse(os.path.exists(path))

    def test_a_save_fsyncs_the_file_and_then_its_directory(self):
        path = self.state_path()
        synced = []
        real = os.fsync

        def fsync(fd):
            synced.append(stat.S_ISDIR(os.fstat(fd).st_mode))
            real(fd)

        with mock.patch.object(fleet.os, "fsync", side_effect=fsync):
            fleet.save_state(path, fleet.new_state())
        self.assertEqual(synced, [False, True])

    def test_a_state_written_before_the_counter_loads_and_reads_clean(self):
        github, state = Recorder(), fleet.new_state()
        rnd = Round(self)
        rnd.seed(0, "vopr-nerva", 1, 0, seconds=3600)
        ingest(self, github, state, rnd, SHA_A, DAY_ONE)
        del state["commits"][SHA_A]["refused"]
        self.assertEqual(soak(self, state, SHA_A)[0], 0)

    def test_the_65th_commit_drops_the_oldest(self):
        github, state = Recorder(), fleet.new_state()
        for i in range(fleet.COMMITS_KEPT + 1):
            rnd = Round(self)
            rnd.seed(0, "vopr-nerva", 1, 0, seconds=60)
            ingest(self, github, state, rnd, f"{i:040x}", DAY_ONE + i)
        self.assertEqual(len(state["commits"]), 64)
        self.assertNotIn(f"{0:040x}", state["commits"])
        self.assertIn(f"{1:040x}", state["commits"])
        self.assertIn(f"{64:040x}", state["commits"])
        # Counting an old commit again keeps it: the entry dropped is the least recently counted.
        rnd = Round(self)
        rnd.seed(0, "vopr-nerva", 1, 0, seconds=60)
        ingest(self, github, state, rnd, f"{1:040x}", DAY_ONE + 100)
        rnd = Round(self)
        rnd.seed(0, "vopr-nerva", 1, 0, seconds=60)
        ingest(self, github, state, rnd, f"{65:040x}", DAY_ONE + 101)
        self.assertIn(f"{1:040x}", state["commits"])
        self.assertNotIn(f"{2:040x}", state["commits"])
        self.assertEqual(len(state["commits"]), 64)
        self.assertEqual(soak(self, state, f"{2:040x}")[0], 1)

    def test_the_daily_comment_has_one_line_per_commit_that_ran(self):
        github, state = Recorder(), fleet.new_state()
        ingest(self, github, state, soak_round(self, 3600), SHA_A, DAY_ONE, tracker=9)
        ingest(self, github, state, soak_round(self, 1800), SHA_B, DAY_ONE + 60, tracker=9)
        ingest(self, github, state, soak_round(self, 3600), SHA_A, DAY_ONE + DAY, tracker=9)
        ingest(self, github, state, soak_round(self), SHA_A, DAY_ONE + DAY + 60, tracker=9)
        text = [body for number, body in github.comments if number == 9][0]
        self.assertIn("Commits that ran:\n"
                      "- `1a2b3c4`: 1.0 h that day, 2.0 h in all, 4 seeds that day\n"
                      "- `9f8e7d6`: 0.5 h that day, 0.5 h in all, 4 seeds that day\n", text)

    def test_an_evicted_commit_has_no_total_in_the_daily_comment(self):
        github, state = Recorder(), fleet.new_state()
        ingest(self, github, state, soak_round(self, 3600), SHA_A, DAY_ONE)
        del state["commits"][SHA_A]
        day = state["days"][fleet.ymd(DAY_ONE)]
        text = fleet.totals_text(state, fleet.ymd(DAY_ONE), day)
        self.assertIn("- `1a2b3c4`: 1.0 h that day, total forgotten, 4 seeds that day\n", text)
        self.assertNotIn("h in all", text)

    def test_a_state_from_before_the_counting_loads_and_starts_counting(self):
        path = os.path.join(tempfile.mkdtemp(), "state.json")
        Path(path).write_text(json.dumps({"version": 1, "filed": {}, "days": {}, "hold_until": 0}))
        state = fleet.load_state(path)
        self.assertEqual(state["commits"], {})
        github = Recorder()
        ingest(self, github, state, soak_round(self), SHA_A, DAY_ONE)
        self.assertEqual(state["commits"][SHA_A]["rounds"], 1)

    def test_two_recorded_rounds_through_the_dry_run_print_the_soak_line(self):
        state_path = os.path.join(tempfile.mkdtemp(), "state.json")
        for i in range(2):
            rnd = soak_round(self, 3600)
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(fleet.main(["ingest", "--round", rnd.path, "--round-id", new_id(),
                                             "--commit", SHA_A, "--state", state_path,
                                             "--dry-run"],
                                            now=DAY_ONE + 900 * i), 0)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            # Not clean (the rounds hold failing seeds), so exit 1; the line is what is quoted.
            self.assertEqual(fleet.main(["soak", "--commit", SHA_A, "--state", state_path]), 1)
        self.assertTrue(out.getvalue().startswith("soak 1a2b3c4: 2.0 h, vopr-nerva 4 seeds, "))


class WorkerPlan(unittest.TestCase):
    """run.sh's worker count and split (P179), by sourcing it and calling its functions."""

    def sh(self, script, **env):
        full = {"PATH": os.environ["PATH"], "SIM_FLEET_SEED_MEMORY_MB": "4096",
                "SIM_FLEET_RESERVE_MB": "1024"}
        full.update(env)
        out = subprocess.run(["bash", "-c", f'set -euo pipefail; source "{HERE}/run.sh"; {script}'],
                             env=full, capture_output=True, text=True, check=True)
        return out.stdout.strip()

    def count(self, cores, mem_mb, source="MemTotal"):
        return int(self.sh(f"default_workers {cores} {mem_mb} '{source}'"))

    def test_memory_limits_the_default_count(self):
        self.assertEqual(self.count(4, 7168), 1)   # The first host: 4 cores, 7 GiB.
        self.assertEqual(self.count(4, 16384), 3)  # Cores are the limit.
        self.assertEqual(self.count(16, 65536), 15)
        self.assertEqual(self.count(16, 32768), 7)

    def test_a_cgroup_limit_already_leaves_the_reserve(self):
        # setup.sh's MemoryMax is MemTotal - 1 GiB, at most 56G = 57344 MB: nothing more is taken.
        self.assertEqual(self.count(16, 57344, "cgroup memory.max"), 14)   # A 64 GB host.
        self.assertEqual(self.count(16, 8276, "cgroup memory.max"), 2)     # MemTotal 9300.
        self.assertEqual(self.count(4, 6144, "cgroup memory.max"), 1)      # The first host.
        # The same figure from MemTotal pays the reserve: 57344 - 1024 holds 13.
        self.assertEqual(self.count(16, 57344, "MemTotal"), 13)

    def test_the_count_is_at_least_one(self):
        self.assertEqual(self.count(1, 512), 1)
        self.assertEqual(self.count(8, 2048), 1)
        self.assertEqual(self.count(8, 512, "cgroup memory.max"), 1)

    def test_fewer_than_three_workers_are_all_mixed(self):
        self.assertEqual(self.sh("split_workers 1"), "0 0 0 1")
        self.assertEqual(self.sh("split_workers 2"), "0 0 0 2")

    def test_three_or_more_split_as_before(self):
        self.assertEqual(self.sh("split_workers 3"), "1 1 1 0")
        self.assertEqual(self.sh("split_workers 15"), "13 1 1 0")
        self.assertEqual(self.sh("split_workers 14"), "12 1 1 0")  # A 64 GB host.

    def test_the_split_never_exceeds_the_total(self):
        for total in range(1, 40):
            n, t, f, m = map(int, self.sh(f"split_workers {total}").split())
            self.assertEqual(n + t + f + m, total)

    def test_explicit_settings_win(self):
        self.assertEqual(self.sh("split_workers 1", SIM_FLEET_WORKERS_FUZZ="0",
                                 SIM_FLEET_WORKERS_VOPR_TESTING="0"), "1 0 0 0")
        self.assertEqual(self.sh("split_workers 2", SIM_FLEET_WORKERS_MIXED="3"), "0 0 0 3")
        self.assertEqual(self.sh("split_workers 15", SIM_FLEET_WORKERS_FUZZ="4"), "10 1 4 0")

    def test_one_kind_set_by_hand_adds_no_workers(self):
        self.assertEqual(self.sh("split_workers 1", SIM_FLEET_WORKERS_FUZZ="0"), "1 0 0 0")
        self.assertEqual(self.sh("split_workers 1", SIM_FLEET_WORKERS_VOPR_TESTING="0"),
                         "1 0 0 0")
        self.assertEqual(self.sh("split_workers 1", SIM_FLEET_WORKERS_VOPR_NERVA="1"), "1 0 0 0")
        self.assertEqual(self.sh("split_workers 2", SIM_FLEET_WORKERS_FUZZ="0"), "1 1 0 0")
        for total in range(1, 20):
            for var in ("FUZZ", "VOPR_TESTING", "VOPR_NERVA"):
                for v in ("0", "1"):
                    n, t, f, m = map(int, self.sh(
                        f"split_workers {total}", **{f"SIM_FLEET_WORKERS_{var}": v}).split())
                    self.assertLessEqual(n + t + f + m, max(total, int(v)))

    def test_hand_set_kinds_above_the_total_are_kept(self):
        self.assertEqual(self.sh("split_workers 1", SIM_FLEET_WORKERS_VOPR_NERVA="3"), "3 0 0 0")

    def test_a_warning_when_hand_set_kinds_exceed_the_computed_total(self):
        home = tempfile.mkdtemp()
        meminfo = os.path.join(home, "meminfo")
        with open(meminfo, "w") as f:
            f.write("MemTotal: 7340032 kB\n")  # 7168 MB: one worker.
        out = subprocess.run(
            ["bash", "-c", f'source "{HERE}/run.sh"; main'],
            env={"PATH": os.environ["PATH"], "SIM_FLEET_DRY_RUN": "1", "SIM_FLEET_HOME": home,
                 "SIM_FLEET_MEMINFO": meminfo, "SIM_FLEET_PROC_CGROUP": "/nonexistent",
                 "SIM_FLEET_REMOTE": "/nonexistent", "SIM_FLEET_GIT_TIMEOUT": "5",
                 "SIM_FLEET_WORKERS_VOPR_NERVA": "3"},
            capture_output=True, text=True)
        warnings = [l for l in out.stdout.splitlines() if "warning" in l]
        self.assertEqual(len(warnings), 1, out.stdout)
        self.assertIn("add up to 3", warnings[0])
        self.assertIn("above the 1", warnings[0])

    def test_a_plan_of_zero_workers_is_refused_with_one_line(self):
        home = tempfile.mkdtemp()
        for env in ({"SIM_FLEET_WORKERS": "2", "SIM_FLEET_WORKERS_MIXED": "0"},
                    {"SIM_FLEET_WORKERS": "2", "SIM_FLEET_WORKERS_VOPR_NERVA": "0",
                     "SIM_FLEET_WORKERS_VOPR_TESTING": "0", "SIM_FLEET_WORKERS_FUZZ": "0",
                     "SIM_FLEET_WORKERS_MIXED": "0"}):
            out = subprocess.run(
                ["bash", "-c", f'source "{HERE}/run.sh"; main'],
                env={"PATH": os.environ["PATH"], "SIM_FLEET_DRY_RUN": "1",
                     "SIM_FLEET_HOME": home, **env},
                capture_output=True, text=True)
            self.assertEqual(out.returncode, 2, (env, out.stdout, out.stderr))
            self.assertIn("0 workers in total", out.stdout)
            self.assertEqual(len(out.stdout.strip().splitlines()), 1, out.stdout)

    def test_a_bad_memory_setting_is_refused_with_one_line(self):
        for var in ("SIM_FLEET_SEED_MEMORY_MB", "SIM_FLEET_RESERVE_MB"):
            for bad in ("0", "abc", "-5", "4G"):
                out = subprocess.run(
                    ["bash", "-c", f'source "{HERE}/run.sh"; main'],
                    env={"PATH": os.environ["PATH"], "SIM_FLEET_DRY_RUN": "1",
                         "SIM_FLEET_HOME": tempfile.mkdtemp(), var: bad},
                    capture_output=True, text=True)
                self.assertEqual(out.returncode, 2, (var, bad, out.stderr))
                self.assertIn(f"{var} must be a positive whole number", out.stdout)
                self.assertEqual(len(out.stdout.strip().splitlines()), 1)
                self.assertEqual(out.stderr, "")


class MemoryLimit(unittest.TestCase):
    """memory_mb against fake /proc and /sys files."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.meminfo = os.path.join(self.dir, "meminfo")
        self.proc = os.path.join(self.dir, "cgroup")
        self.root = os.path.join(self.dir, "sys")
        os.makedirs(self.root)
        self.write(self.meminfo, "MemTotal:       65536000 kB\nMemFree: 1 kB\n")  # 64000 MB.

    def write(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def limit(self, path, value):
        self.write(os.path.join(self.root + path, "memory.max"), f"{value}\n")

    def memory(self, cgroup="0::/system.slice/sim-fleet.service\n"):
        if cgroup is not None:
            self.write(self.proc, cgroup)
        out = subprocess.run(
            ["bash", "-c", f'set -euo pipefail; source "{HERE}/run.sh"; memory_mb'],
            env={"PATH": os.environ["PATH"], "SIM_FLEET_MEMINFO": self.meminfo,
                 "SIM_FLEET_PROC_CGROUP": self.proc, "SIM_FLEET_CGROUP_ROOT": self.root},
            capture_output=True, text=True, check=True)
        return out.stdout.strip()

    def test_max_means_memtotal(self):
        self.limit("/system.slice/sim-fleet.service", "max")
        self.assertEqual(self.memory(), "64000 MemTotal")

    def test_a_limit_below_memtotal_wins(self):
        self.limit("/system.slice/sim-fleet.service", 57344 * 1048576)
        self.assertEqual(self.memory(), "57344 cgroup memory.max")

    def test_a_limit_above_memtotal_or_a_huge_one_is_ignored(self):
        self.limit("/system.slice/sim-fleet.service", 128000 * 1048576)
        self.assertEqual(self.memory(), "64000 MemTotal")
        self.limit("/system.slice/sim-fleet.service", "9223372036854771712")
        self.assertEqual(self.memory(), "64000 MemTotal")

    def test_a_missing_file_means_memtotal(self):
        self.assertEqual(self.memory(), "64000 MemTotal")
        self.assertEqual(self.memory(cgroup=""), "64000 MemTotal")

    def test_cgroup_v1_has_no_unified_line(self):
        self.limit("", 1000 * 1048576)  # Even a stray file at the root of the fake tree.
        self.assertEqual(self.memory("4:memory:/docker/abc\n1:name=systemd:/\n"),
                         "1000 cgroup memory.max")
        self.write(self.proc, "4:memory:/docker/abc\n")
        os.remove(os.path.join(self.root, "memory.max"))
        self.assertEqual(self.memory(None), "64000 MemTotal")

    def test_the_lowest_limit_up_the_path_wins(self):
        self.limit("/system.slice/sim-fleet.service", "max")
        self.limit("/system.slice", 8000 * 1048576)
        self.limit("", 20000 * 1048576)
        self.assertEqual(self.memory(), "8000 cgroup memory.max")
        self.limit("/system.slice/sim-fleet.service", 6000 * 1048576)
        self.assertEqual(self.memory(), "6000 cgroup memory.max")

    def test_the_real_host_gives_a_figure(self):
        out = self.sh_real()
        mem, source = out.split(maxsplit=1)
        self.assertGreater(int(mem), 0)
        self.assertIn(source, ("MemTotal", "cgroup memory.max"))

    def sh_real(self):
        return subprocess.run(
            ["bash", "-c", f'set -euo pipefail; source "{HERE}/run.sh"; memory_mb'],
            env={"PATH": os.environ["PATH"]}, capture_output=True, text=True,
            check=True).stdout.strip()


class GitHubRequest(unittest.TestCase):
    """Every way an answer can go wrong is a GitHubError, never an exception that escapes."""

    def github(self, opened):
        class Opener:
            def open(self, request, timeout):
                return opened()

        github = fleet.GitHub("NervaLog/nerva", "t0ken", lambda message: None)
        github.opener = Opener()
        return github

    def test_a_dropped_connection_is_unreachable(self):
        def opened():
            raise http.client.RemoteDisconnected("closed")  # An OSError too.

        with self.assertRaises(fleet.GitHubError) as caught:
            self.github(opened).markers()
        self.assertEqual(caught.exception.kind, "unreachable")

    def test_an_answer_cut_short_is_unreachable(self):
        class Response:
            status, headers = 200, {}

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self, limit):
                raise http.client.IncompleteRead(b"[")  # Not an OSError.

        def opened():
            return Response()

        with self.assertRaises(fleet.GitHubError) as caught:
            self.github(opened).markers()
        self.assertEqual(caught.exception.kind, "unreachable")

    def test_an_answer_that_is_not_json_is_refused(self):
        class Response:
            status, headers = 200, {}

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self, limit):
                return b"<html>not json"

        with self.assertRaises(fleet.GitHubError) as caught:
            self.github(Response).markers()
        self.assertEqual(caught.exception.kind, "refused")


class RunShSettle(unittest.TestCase):
    """run.sh settles every round by the record in the state file, never by an exit code (#370,
    P382). The interpreter is a stub that runs the real sim_fleet.py unless told to fail:
    STUB_INGEST or STUB_REFUSE `fail:N` exits N without running it, `after:N` runs it, then
    exits N."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", self.dir])
        self.state = os.path.join(self.dir, "state")
        self.round = os.path.join(self.state, "round")
        self.bin = os.path.join(self.dir, "bin")
        os.makedirs(self.state)
        os.makedirs(self.bin)
        os.symlink(HERE / "sim_fleet.py", os.path.join(self.bin, "sim_fleet.py"))
        # A seed of a second that passes.
        self.script(os.path.join(self.bin, "vopr-nerva"), "sleep 1\n")
        self.stub = os.path.join(self.dir, "python")
        self.script(self.stub, 'case "$3" in ingest) mode=$STUB_INGEST;; '
                               'refuse) mode=$STUB_REFUSE;; *) mode=;; esac\n'
                               'case "$mode" in fail:*) exit "${mode#fail:}";;\n'
                               'after:*) python3 "$@"; exit "${mode#after:}";; esac\n'
                               'exec python3 "$@"\n')

    def script(self, path, body):
        Path(path).write_text("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)

    def sh(self, script, ingest="", refuse="", workers=0, tracker=""):
        env = {"PATH": os.environ["PATH"], "STUB_INGEST": ingest, "STUB_REFUSE": refuse}
        return subprocess.run(
            ["bash", "-c", f'set -euo pipefail; source "{HERE}/run.sh"; STATE="{self.state}"; '
             f'built={SHA_A}; SIM_FLEET_PYTHON="{self.stub}"; SIM_FLEET_REPORT_TIMEOUT=30; '
             f'SIM_FLEET_REPO_DIR=/x; SIM_FLEET_DRY_RUN=1; SIM_FLEET_ROUND_SECONDS=1; '
             f'SIM_FLEET_TRACKER="{tracker}"; token_file=/x; SIM_FLEET_VOPR_SEED_TIMEOUT=30; '
             f'SIM_FLEET_TAIL_BYTES=100; SIM_FLEET_WORKERS_VOPR_NERVA={workers}; '
             'SIM_FLEET_WORKERS_VOPR_TESTING=0; SIM_FLEET_WORKERS_FUZZ=0; '
             'SIM_FLEET_WORKERS_MIXED=0; log() { echo "$*" >&2; }; '
             f'{script}'],
            env=env, capture_output=True, text=True, timeout=120)

    def run_round(self, prefix="", **kwargs):
        # run_round sets `bin` from `built`; the binaries of SHA_A are the stub's.
        os.makedirs(os.path.join(self.state, "bin"), exist_ok=True)
        link = os.path.join(self.state, "bin", SHA_A)
        if not os.path.exists(link):
            os.symlink(self.bin, link)
        return self.sh(prefix + "run_round", **kwargs)

    def leftover(self, lines, round_id=ID_A, commit=SHA_A):
        os.makedirs(os.path.join(self.round, "w0"))
        Path(self.round, "id").write_text(round_id + "\n")
        Path(self.round, "commit").write_text(commit + "\n")
        Path(self.round, "w0", "results").write_text("".join(f"{line}\n" for line in lines))
        for line in lines:
            target, seed, code, _ = line.split()
            if code != "0":
                fail = os.path.join(self.round, "w0", f"fail-{target}-{seed}")
                os.makedirs(fail)
                Path(fail, "tail.log").write_text("panic: boom\n")

    def state_json(self):
        return fleet.load_state(os.path.join(self.state, "state.json"))

    def entry(self):
        state = self.state_json()
        return state["commits"].get(SHA_A, {}) if state else {}

    def seeds(self):
        return fleet.seeds_of(self.entry()) if self.entry() else 0

    def failed(self):
        return sum(kind["failed"] for kind in self.entry()["kinds"].values())

    def soak_code(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return fleet.main(["soak", "--commit", SHA_A, "--state",
                               os.path.join(self.state, "state.json")])

    def kept(self):
        return os.path.exists(os.path.join(self.state, "last-failed-round"))

    def test_two_clean_rounds_then_soak_is_clean(self):
        for _ in range(2):
            out = self.run_round(workers=1)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertFalse(os.path.exists(self.round))
        self.assertEqual(self.entry()["rounds"], 2)
        self.assertEqual(self.entry()["refused"], 0)
        self.assertGreater(self.seeds(), 0)
        self.assertFalse(self.kept())
        self.assertEqual(self.soak_code(), 0)

    def test_a_round_is_made_with_its_id_and_commit(self):
        # Nothing can record it, so it stays in place: what run.sh wrote is still there.
        out = self.run_round(ingest="fail:1", refuse="fail:1")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("recorded nowhere", out.stderr)
        self.assertRegex(Path(self.round, "id").read_text(), r"^[0-9]{1,20}-[0-9a-f]{16}\n$")
        self.assertEqual(Path(self.round, "commit").read_text(), SHA_A + "\n")
        self.assertFalse(os.path.exists(self.round + ".new"))

    def test_a_restart_mid_round_with_passing_results_stays_clean(self):
        self.leftover(["vopr-nerva 5 0 3600", "vopr-nerva 6 0 600"])
        out = self.run_round()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn(f"settling round {ID_A}", out.stderr)
        self.assertEqual(self.seeds(), 2)
        self.assertEqual(self.entry()["refused"], 0)
        self.assertEqual(self.soak_code(), 0)

    def test_a_restart_mid_round_with_a_failing_result_is_not_clean(self):
        self.leftover(["vopr-nerva 5 0 3600", "vopr-nerva 6 134 600"])
        out = self.run_round()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.entry()["kinds"]["vopr-nerva"]["failed"], 1)
        self.assertEqual(self.soak_code(), 1)

    def test_a_restart_before_any_seed_ended_counts_an_empty_round(self):
        self.leftover([])
        out = self.run_round()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.entry()["refused"], 0)
        self.assertEqual(self.entry()["rounds"], 2)

    def test_a_round_recorded_before_a_crash_is_not_counted_twice(self):
        # Killed after `ingest` saved, before the round was deleted.
        self.leftover(["vopr-nerva 5 0 3600"])
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(fleet.main(["ingest", "--round", self.round, "--round-id", ID_A,
                                         "--commit", SHA_A, "--state",
                                         os.path.join(self.state, "state.json"), "--dry-run"]),
                             0)
        out = self.run_round()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("already recorded", out.stderr)
        self.assertEqual(self.seeds(), 1)
        self.assertEqual(self.entry()["rounds"], 2)  # It and the new, empty round.
        self.assertFalse(os.path.exists(self.round))

    def test_a_usage_error_from_ingest_is_refused(self):
        for n, tracker in enumerate(("abc", "0"), 1):  # argparse's exit 2, then ingest's 1.
            self.leftover(["vopr-nerva 5 0 3600"], round_id=f"{n}-{n:016x}")
            out = self.sh(f'round="{self.round}"; bin="{self.bin}"; settle {n}-{n:016x} {SHA_A}',
                          tracker=tracker)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertIn("refusing it", out.stderr)
            self.assertEqual(self.entry()["refused"], n)
            self.assertEqual(self.seeds(), 0)
            self.assertFalse(os.path.exists(self.round))
            self.assertTrue(self.kept())
        self.assertEqual(self.soak_code(), 1)

    def test_a_crash_in_ingest_is_refused(self):
        self.leftover(["vopr-nerva 5 0 3600"])
        os.unlink(os.path.join(self.round, "w0", "results"))
        os.makedirs(os.path.join(self.round, "w0", "results"))  # The real reporter raises.
        out = self.run_round()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("Traceback", out.stderr)
        self.assertEqual(self.entry()["refused"], 1)
        self.assertEqual(self.soak_code(), 1)

    def test_ingest_killed_or_exiting_0_without_a_record_is_refused(self):
        for n, mode in enumerate(("fail:137", "fail:124", "fail:0", "fail:2"), 1):
            subprocess.run(["rm", "-rf", os.path.join(self.state, "last-failed-round")])
            self.leftover(["vopr-nerva 5 0 3600"], round_id=f"{n}-{n:016x}")
            out = self.sh(f'round="{self.round}"; bin="{self.bin}"; settle {n}-{n:016x} {SHA_A}',
                          ingest=mode)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertEqual(self.entry()["refused"], n, mode)
            self.assertTrue(self.kept())

    def test_an_exit_after_the_record_is_saved_is_not_refused(self):
        for n, mode in enumerate(("after:124", "after:2", "after:75"), 1):
            self.leftover(["vopr-nerva 5 0 3600"], round_id=f"{n}-{n:016x}")
            out = self.sh(f'round="{self.round}"; bin="{self.bin}"; settle {n}-{n:016x} {SHA_A}',
                          ingest=mode)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertNotIn("refusing", out.stderr)
            self.assertEqual(self.entry()["refused"], 0, mode)
            self.assertEqual(self.seeds(), n)
            self.assertTrue(self.kept())  # A copy to look at; it is counted.
        self.assertEqual(self.soak_code(), 0)

    def test_a_round_nothing_could_record_stays_and_the_next_start_settles_it(self):
        self.leftover(["vopr-nerva 5 0 3600"])
        out = self.sh(f'round="{self.round}"; bin="{self.bin}"; settle {ID_A} {SHA_A}',
                      ingest="fail:1", refuse="fail:1")
        self.assertEqual(out.returncode, 1)
        self.assertTrue(os.path.exists(os.path.join(self.round, "w0", "results")))
        self.assertIsNone(self.state_json())
        out = self.run_round()  # systemd's restart.
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.seeds(), 1)
        self.assertEqual(self.entry()["refused"], 0)
        self.assertEqual(self.soak_code(), 0)

    def test_an_unreadable_state_stops_the_loop_and_is_kept(self):
        Path(self.state, "state.json").write_text("not json")
        self.leftover(["vopr-nerva 5 0 3600"])
        out = self.run_round()
        self.assertEqual(out.returncode, 1)
        self.assertIn("recorded nowhere", out.stderr)
        self.assertTrue(os.path.isdir(self.round))
        self.assertEqual(Path(self.state, "state.json").read_text(), "not json")

    def test_a_half_made_round_or_one_with_no_id_is_deleted_uncounted(self):
        os.makedirs(self.round + ".new")
        os.makedirs(os.path.join(self.round, "w0"))
        Path(self.round, "commit").write_text(SHA_A + "\n")
        out = self.run_round()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("deleting a round with no id or commit", out.stderr)
        self.assertEqual(self.entry()["rounds"], 1)  # Only the new round.
        self.assertFalse(os.path.exists(self.round + ".new"))

    def test_an_id_that_is_not_one_is_never_found_recorded(self):
        Path(self.state, "state.json").write_text('{"x": ""}')
        for bad in ("", "x", '1-abc'):
            self.assertNotEqual(self.sh(f"recorded '{bad}'").returncode, 0)
        self.assertNotEqual(self.sh(f"recorded {ID_A}").returncode, 0)
        Path(self.state, "state.json").write_text(f'{{"id": "{ID_A}"}}')
        self.assertEqual(self.sh(f"recorded {ID_A}").returncode, 0)

    def test_a_seed_that_exits_143_is_recorded_as_a_failure(self):
        # A stop kills the worker's bash with the seed, so a 143 here was a signal from
        # something else: a failure, as before.
        self.script(os.path.join(self.bin, "vopr-nerva"), "exit 143\n")
        out = self.sh(f'round="{self.round}"; bin="{self.bin}"; mkdir -p "$STATE/rotation"; '
                      'worker 0 vopr-nerva $(( $(date +%s) + 1 ))')
        self.assertEqual(out.returncode, 0, out.stderr)
        line = Path(self.round, "w0", "results").read_text().split()
        self.assertEqual(line[0], "vopr-nerva")
        self.assertEqual(line[2], "143")
        self.assertTrue(any(n.startswith("fail-") for n in os.listdir(self.round + "/w0")))

    def test_a_stop_during_the_replay_of_a_failure_does_not_lose_it(self):
        self.script(os.path.join(self.bin, "vopr-nerva"), "exit 129\n")
        self.script(os.path.join(self.bin, "vopr-nerva-full"), "sleep 60\n")
        os.makedirs(os.path.join(self.state, "bin"), exist_ok=True)
        os.symlink(self.bin, os.path.join(self.state, "bin", SHA_A))
        proc = subprocess.Popen(
            ["bash", "-c", f'set -euo pipefail; source "{HERE}/run.sh"; STATE="{self.state}"; '
             f'built={SHA_A}; SIM_FLEET_PYTHON="{self.stub}"; SIM_FLEET_REPORT_TIMEOUT=30; '
             'SIM_FLEET_REPO_DIR=/x; SIM_FLEET_DRY_RUN=1; SIM_FLEET_ROUND_SECONDS=30; '
             'SIM_FLEET_TRACKER=; token_file=/x; SIM_FLEET_VOPR_SEED_TIMEOUT=30; '
             'SIM_FLEET_REPLAY_TIMEOUT=60; SIM_FLEET_TAIL_BYTES=100; '
             'SIM_FLEET_WORKERS_VOPR_NERVA=1; SIM_FLEET_WORKERS_VOPR_TESTING=0; '
             'SIM_FLEET_WORKERS_FUZZ=0; SIM_FLEET_WORKERS_MIXED=0; '
             'log() { echo "$*" >&2; }; run_round'],
            env={"PATH": os.environ["PATH"]}, start_new_session=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not os.path.exists(
                os.path.join(self.round, "w0", "results")):
            time.sleep(0.1)
        self.assertTrue(os.path.exists(os.path.join(self.round, "w0", "results")))
        os.killpg(proc.pid, signal.SIGKILL)  # No trap runs, as when systemd stops the group.
        proc.wait()
        subprocess.run(["pkill", "-9", "-f", "vopr-nerva-full"])
        out = self.run_round()  # Settles the leftover round, then runs an empty one.
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.failed(), 1)
        self.assertEqual(self.soak_code(), 1)

    def test_a_torn_last_results_line_is_a_failure_when_it_names_one(self):
        for n, torn in enumerate(("vopr-nerva 66 12", "vopr-nerva 66 134 1"), 1):
            subprocess.run(["rm", "-rf", self.round, os.path.join(self.state, "state.json")])
            self.leftover(["vopr-nerva 5 0 3600"], round_id=f"{n}-{n:016x}")
            with open(os.path.join(self.round, "w0", "results"), "a") as f:
                f.write(torn)  # No newline: cut short.
            out = self.sh(f'round="{self.round}"; bin="{self.bin}"; settle {n}-{n:016x} {SHA_A}')
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertEqual((self.seeds(), self.failed()), (2, 1), torn)
            self.assertEqual(self.entry()["refused"], 0)

    def test_a_torn_last_results_line_that_names_no_failure_is_dropped(self):
        # A power cut tears an unsynced (passing) line, or leaves a NUL tail: the round still
        # counts, without that seed. A cut seed number ("vopr-nerva 12") is never a failure.
        for n, torn in enumerate(("vopr-ne", "vopr-nerva 12", "vopr-nerva 66 0 3",
                                  "\0\0\0\0", "vopr-nerva 66 x"), 1):
            subprocess.run(["rm", "-rf", self.round, os.path.join(self.state, "state.json")])
            self.leftover(["vopr-nerva 5 0 3600"], round_id=f"{n}-{n:016x}")
            with open(os.path.join(self.round, "w0", "results"), "a") as f:
                f.write(torn)
            out = self.sh(f'round="{self.round}"; bin="{self.bin}"; settle {n}-{n:016x} {SHA_A}')
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertEqual((self.seeds(), self.failed()), (1, 0), repr(torn))
            self.assertEqual(self.entry()["refused"], 0)
            self.assertFalse(self.kept())

    def test_a_malformed_terminated_line_still_refuses_the_round(self):
        self.leftover(["vopr-nerva 5 0 3600"])
        with open(os.path.join(self.round, "w0", "results"), "a") as f:
            f.write("vopr-ne\n")
        out = self.sh(f'round="{self.round}"; bin="{self.bin}"; settle {ID_A} {SHA_A}')
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.entry()["refused"], 1)
        self.assertTrue(self.kept())

    def test_a_leftover_round_is_settled_under_its_own_commit(self):
        # `systemctl restart` to move the pin: the new pin is built before the old candidate's
        # round is settled, and that round's failure is the old candidate's.
        self.leftover(["vopr-nerva 6 134 600"], commit=SHA_B)
        out = self.run_round()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.failed(), 0)  # The new pin, SHA_A: one empty round.
        self.assertEqual(self.entry()["rounds"], 1)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(fleet.main(["soak", "--commit", SHA_B, "--state",
                                         os.path.join(self.state, "state.json")]), 1)
        self.assertEqual(self.state_json()["commits"][SHA_B]["kinds"]["vopr-nerva"]["failed"], 1)

    DIE = ('worker() { if [[ $1 == 1 ]]; then return 3; fi; mkdir -p "$round/w$1"; '
           'echo "vopr-nerva 9 0 3600" >>"$round/w$1/results"; }; ')

    def test_a_round_a_worker_died_in_is_refused_even_if_refuse_cannot_write(self):
        # A full disk: the worker dies, `refuse` cannot save the state, run.sh stops with the
        # round kept. The restart must refuse it, not count its surviving lines.
        out = self.run_round(self.DIE, workers=2, refuse="fail:1")
        self.assertEqual(out.returncode, 1, out.stderr)
        self.assertIn("recorded nowhere", out.stderr)
        out = self.run_round()  # systemd's restart.
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("(refuse)", out.stderr)
        self.assertEqual(self.entry()["refused"], 1)
        self.assertEqual(self.soak_code(), 1)

    def test_a_leftover_is_settled_before_the_build_and_even_if_it_dies(self):
        # `systemctl restart`: the old round is settled with the built reporter before
        # follow_main, which can take an hour or die on a full disk.
        self.leftover(["vopr-nerva 6 134 600"])
        os.makedirs(os.path.join(self.state, "bin"))
        os.symlink(self.bin, os.path.join(self.state, "bin", SHA_A))
        Path(self.state, "built").write_text(SHA_A + "\n")
        self.script(os.path.join(self.bin, "fuzz"), "exit 0\n")
        os.makedirs(os.path.join(self.dir, ".git"))
        out = subprocess.run(
            ["bash", "-c", f'source "{HERE}/run.sh"; follow_main() {{ echo FOLLOW >&2; exit 7; }}; '
             'log() { echo "$*" >&2; }; main'],
            env={"PATH": os.environ["PATH"], "SIM_FLEET_DRY_RUN": "1",
                 "SIM_FLEET_HOME": self.dir, "SIM_FLEET_STATE_DIR": self.state,
                 "SIM_FLEET_REPO_DIR": self.dir, "SIM_FLEET_WORKERS_VOPR_NERVA": "1"},
            capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 7, out.stderr)
        self.assertLess(out.stderr.index("settling round"), out.stderr.index("FOLLOW"))
        self.assertEqual(self.failed(), 1)
        self.assertEqual(self.soak_code(), 1)

    def test_a_worker_that_dies_refuses_the_round(self):
        # A failing seed, then a full disk: `mkdir` of its directory fails and the worker dies
        # under `set -e` (#370, the review's reproduction). The round is refused, not clean.
        self.script(os.path.join(self.bin, "vopr-nerva"), "exit 134\n")
        mkdir = 'mkdir() { case "$*" in *fail-*) return 1;; esac; command mkdir "$@"; }; '
        out = self.run_round(mkdir, workers=2)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("2 of 2 workers of round", out.stderr)
        self.assertEqual(self.entry()["refused"], 1)
        self.assertEqual(self.entry()["rounds"], 0)
        self.assertTrue(self.kept())
        self.assertEqual(self.soak_code(), 1)

    def test_one_dead_worker_of_two_refuses_the_round(self):
        # The other worker's seeds pass; the round is refused all the same.
        self.script(os.path.join(self.bin, "vopr-nerva"), "exit 0\n")
        die = ('worker() { if [[ $1 == 1 ]]; then return 3; fi; '
               'mkdir -p "$round/w$1"; echo "vopr-nerva 9 0 3600" >>"$round/w$1/results"; }; ')
        out = self.run_round(die, workers=2)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("1 of 2 workers of round", out.stderr)
        self.assertEqual(self.entry()["refused"], 1)
        self.assertEqual(self.soak_code(), 1)

    def test_a_failing_seed_line_and_the_round_id_are_synced(self):
        # Power-cut durability cannot be tested here; this checks that the syncs are made, and
        # in order: the round's id before any seed, a failing seed's line before its log.
        self.script(os.path.join(self.bin, "vopr-nerva"), "exit 134\n")
        log = os.path.join(self.dir, "sync.log")
        spy = (f'sync() {{ echo "sync $*" >>"{log}"; }}; '
               f'tail() {{ echo "tail" >>"{log}"; command tail "$@"; }}; ')
        out = self.run_round(spy, workers=1)
        self.assertEqual(out.returncode, 0, out.stderr)
        calls = Path(log).read_text().splitlines()
        self.assertRegex(calls[0], r"^sync .*/round\.new/id .*/round\.new/commit")
        self.assertRegex(calls[1], r"^sync .*/round .*/state$")
        self.assertRegex(calls[2], r"^sync \S*/round/w0/results \S*/round/w0 \S*/round$")
        self.assertEqual(calls[3], "tail")



    def settle_one(self, n, ingest="fail:2", alarm_rounds=3):
        rid = f"{n}-{n:016x}"
        self.leftover(["vopr-nerva 5 0 3600"], round_id=rid)
        return self.sh(f'SIM_FLEET_ALARM_ROUNDS={alarm_rounds}; round="{self.round}"; '
                       f'bin="{self.bin}"; settle {rid} {SHA_A}', ingest=ingest)

    def streak(self):
        path = os.path.join(self.state, "failing-rounds")
        return Path(path).read_text().split() if os.path.exists(path) else None

    def test_the_third_failing_round_raises_the_alarm_once(self):
        for n in (1, 2):
            out = self.settle_one(n)
            self.assertNotIn("ALARM", out.stderr)
            self.assertNotIn("would open", out.stdout)
        out = self.settle_one(3)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("ALARM error[NRV-E0730]: 3 rounds in a row failed", out.stderr)
        self.assertIn("would open issue [sim-fleet]", out.stdout)
        self.assertEqual(self.streak(), ["3", "1"])
        out = self.settle_one(4)  # The same streak: no second issue.
        self.assertNotIn("ALARM", out.stderr)
        self.assertNotIn("would open", out.stdout)
        self.assertEqual(self.streak(), ["4", "1"])

    def test_a_counted_round_ends_the_streak(self):
        self.settle_one(1)
        self.settle_one(2)
        out = self.settle_one(3, ingest="")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIsNone(self.streak())
        for n in (4, 5):
            self.assertNotIn("ALARM", self.settle_one(n).stderr)

    def test_a_refused_round_counts_as_failing(self):
        for n in (1, 2, 3):
            self.leftover(["vopr-nerva 5 0 3600"], round_id=f"{n}-{n:016x}")
            out = self.sh(f'SIM_FLEET_ALARM_ROUNDS=3; round="{self.round}"; bin="{self.bin}"; '
                          f'settle {n}-{n:016x} {SHA_A} refuse')
        self.assertIn("ALARM", out.stderr)

    def test_an_alarm_that_cannot_be_filed_is_asked_for_again(self):
        # An old reporter that has no `alarm`: the link goes first, never its target.
        os.unlink(os.path.join(self.bin, "sim_fleet.py"))
        Path(self.bin, "sim_fleet.py").write_text(
            "import runpy, sys\nif sys.argv[1] == 'alarm':\n    sys.exit(2)\n"
            f"sys.argv[0] = r'{HERE / 'sim_fleet.py'}'\n"
            f"runpy.run_path(sys.argv[0], run_name='__main__')\n")
        for n in (1, 2, 3):
            out = self.settle_one(n)
        self.assertIn("the alarm was not filed", out.stderr)
        self.assertEqual(self.streak(), ["3", "0"])


class Reexec(unittest.TestCase):
    """follow_main hands over to the run.sh of a commit it built, once (#424)."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", self.dir])
        self.repo = os.path.join(self.dir, "repo")
        os.makedirs(os.path.join(self.repo, "ops", "sim-fleet"))
        self.new = os.path.join(self.repo, "ops", "sim-fleet", "run.sh")
        # The "new" run.sh says what it got, and whether fd 9 (the lock) came with it.
        Path(self.new).write_text(
            '#!/usr/bin/env bash\necho "NEW args=$* marker=${SIM_FLEET_REEXEC:-} '
            'rounds=${SIM_FLEET_ROUNDS:-} extra=${EXTRA:-}"\n'
            'if { true >&9; } 2>/dev/null; then echo FD9; fi\n')

    mutate = ""

    def call(self, marker="", old_sum="0" * 64, rounds_setting="0", orig="", env_extra=None):
        env = {"PATH": os.environ["PATH"], "EXTRA": "kept", "SIM_FLEET_ROUNDS": rounds_setting}
        env.update(env_extra or {})
        if marker:
            env["SIM_FLEET_REEXEC"] = marker
        return subprocess.run(
            ["bash", "-c", f'source "{HERE}/run.sh"; log() {{ echo "$*" >&2; }}; '
             f'SIM_FLEET_REPO_DIR="{self.repo}"; RUN_ARGS=(a b); RUN_SH_SUM={old_sum}; rounds=2; '
             f'{self.mutate}ORIG_ENV=({orig}); '
             f'exec 9>"{self.dir}/lock"; reexec_if_changed {SHA_A}; echo RETURNED'],
            env=env, capture_output=True, text=True, timeout=30)

    def test_a_changed_run_sh_is_exec_d_with_its_arguments_and_environment(self):
        out = self.call(orig="SIM_FLEET_ROUNDS=0")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn(f"NEW args=a b marker={SHA_A} rounds=0 extra=kept", out.stdout)
        self.assertNotIn("RETURNED", out.stdout)
        self.assertNotIn("FD9", out.stdout)  # The lock is the new run.sh's to take.
        self.assertIn("differs from the one running", out.stderr)

    def test_an_unchanged_run_sh_is_not_exec_d(self):
        digest = hashlib.sha256(Path(self.new).read_bytes()).hexdigest()
        out = self.call(old_sum=digest)
        self.assertEqual(out.stdout.strip(), "RETURNED", out.stderr)

    def test_once_per_commit_the_marker_stops_a_loop(self):
        out = self.call(marker=SHA_A)
        self.assertEqual(out.stdout.strip(), "RETURNED", out.stderr)
        # Another commit's marker does not.
        out = self.call(marker="f" * 40)
        self.assertIn("NEW", out.stdout)

    def test_the_rounds_a_run_asked_for_are_not_started_again(self):
        out = self.call(rounds_setting="5")
        self.assertIn("rounds=4", out.stdout)  # Round 2 had not run: 5 - 2 + 1.

    def test_a_missing_run_sh_changes_nothing(self):
        os.unlink(self.new)
        self.assertEqual(self.call().stdout.strip(), "RETURNED")

    def test_the_new_run_sh_gets_the_environment_it_was_started_with(self):
        # fleet.env exports these empty; the old run.sh filled them with its own defaults.
        Path(self.new).write_text(
            '#!/usr/bin/env bash\necho "NEW fuzzers=[${SIM_FLEET_FUZZERS-unset}] '
            'workers=[${SIM_FLEET_WORKERS-unset}] split=[${SIM_FLEET_WORKERS_MIXED-unset}] '
            'kept=[${SIM_FLEET_KEPT-unset}]"\n')
        out = self.call(
            orig="SIM_FLEET_FUZZERS= SIM_FLEET_WORKERS= SIM_FLEET_KEPT=yes",
            env_extra={"SIM_FLEET_FUZZERS": "old default list", "SIM_FLEET_WORKERS": "3",
                       "SIM_FLEET_WORKERS_MIXED": "0"})
        # Empty stays empty (so the new defaults apply), a variable the old run.sh created is
        # gone, and one the unit set keeps its value.
        self.assertIn("NEW fuzzers=[] workers=[] split=[unset] kept=[yes]", out.stdout, out.stderr)

    def test_a_run_sh_that_does_not_parse_is_not_exec_d(self):
        Path(self.new).write_text("#!/usr/bin/env bash\nif then fi (\n")
        out = self.call()
        self.assertEqual(out.stdout.strip(), "RETURNED", out.stderr)
        self.assertIn("NRV-E0730", out.stderr)
        self.assertIn("does not parse", out.stderr)


class FailedBuild(unittest.TestCase):
    """A build that fails leaves the checkout at the built commit, not the broken one (#432)."""

    def git(self, cwd, *args):
        return subprocess.run(["git", "-C", cwd, "-c", "user.name=t", "-c", "user.email=t@t",
                               *args], capture_output=True, text=True, check=True).stdout.strip()

    def test_the_checkout_holds_the_built_commit_after_a_failed_build(self):
        d = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", d])
        remote, repo, state = (os.path.join(d, n) for n in ("remote", "repo", "state"))
        os.makedirs(remote)
        self.git(remote, "init", "-q", "-b", "main")
        Path(remote, "f").write_text("v1")
        self.git(remote, "add", "f")
        self.git(remote, "commit", "-q", "-m", "v1")
        v1 = self.git(remote, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", "-q", remote, repo], check=True)
        Path(remote, "f").write_text("v2")
        self.git(remote, "commit", "-q", "-a", "-m", "v2")
        v2 = self.git(remote, "rev-parse", "HEAD")
        os.makedirs(state)
        out = subprocess.run(
            ["bash", "-c", f'source "{HERE}/run.sh"; log() {{ echo "$*" >&2; }}; '
             f'build_into() {{ return 1; }}; export -f build_into; prune_cache() {{ :; }}; '
             f'STATE="{state}"; built={v1}; broken=""; cd "{repo}"; SIM_FLEET_BRANCH=main; '
             f'SIM_FLEET_GIT_TIMEOUT=60; SIM_FLEET_BUILD_TIMEOUT=60; '
             f'SIM_FLEET_REPO_DIR="{repo}"; RUN_ARGS=(a); RUN_SH_SUM=0; ORIG_ENV=(); '
             f'git checkout -q --detach {v1}; git remote set-url origin "{remote}"; '
             f'follow_main; echo "HEAD=$(git rev-parse HEAD) broken=$broken built=$built"'],
            env={"PATH": os.environ["PATH"], "HOME": d}, capture_output=True, text=True,
            timeout=60)
        self.assertIn(f"HEAD={v1} broken={v2} built={v1}", out.stdout, out.stderr)
        self.assertIn("FAILED", out.stderr)

    def test_broken_is_written_before_the_checkout_and_the_built_run_sh_takes_over(self):
        d = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", d])
        remote, repo, state = (os.path.join(d, n) for n in ("remote", "repo", "state"))
        os.makedirs(os.path.join(remote, "ops", "sim-fleet"))
        self.git(remote, "init", "-q", "-b", "main")
        run_sh = Path(remote, "ops", "sim-fleet", "run.sh")
        run_sh.write_text('#!/usr/bin/env bash\necho "BUILT-RUN-SH marker=${SIM_FLEET_REEXEC:-}"\n')
        self.git(remote, "add", "-A")
        self.git(remote, "commit", "-q", "-m", "v1")
        v1 = self.git(remote, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", "-q", remote, repo], check=True)
        run_sh.write_text('#!/usr/bin/env bash\necho "UNBUILT-RUN-SH"\n')
        self.git(remote, "commit", "-q", "-a", "-m", "v2")
        v2 = self.git(remote, "rev-parse", "HEAD")
        os.makedirs(state)
        # The running run.sh is the unbuilt head's (RUN_SH_SUM is another file's). `git checkout`
        # is a function that fails if `broken` is not on disk yet.
        out = subprocess.run(
            ["bash", "-c", f'source "{HERE}/run.sh"; log() {{ echo "$*" >&2; }}; '
             f'build_into() {{ return 1; }}; export -f build_into; prune_cache() {{ :; }}; '
             f'STATE="{state}"; built={v1}; broken=""; cd "{repo}"; SIM_FLEET_BRANCH=main; '
             f'SIM_FLEET_GIT_TIMEOUT=60; SIM_FLEET_BUILD_TIMEOUT=60; '
             f'SIM_FLEET_REPO_DIR="{repo}"; RUN_ARGS=(a); RUN_SH_SUM=0; ORIG_ENV=(); '
             f'git() {{ if [[ "$1" == checkout && "${{@: -1}}" == "{v1}" ]]; then '
             f'echo "BROKEN-ON-DISK=$(cat "{state}/broken")"; fi; command git "$@"; }}; '
             f'git checkout -q --detach {v1}; git remote set-url origin "{remote}"; '
             f'follow_main; echo NOT-REACHED'],
            env={"PATH": os.environ["PATH"], "HOME": d}, capture_output=True, text=True,
            timeout=60)
        self.assertIn(f"BROKEN-ON-DISK={v2}", out.stdout, out.stderr)
        self.assertIn(f"BUILT-RUN-SH marker={v1}", out.stdout, out.stderr)
        self.assertNotIn("UNBUILT-RUN-SH", out.stdout)
        self.assertNotIn("NOT-REACHED", out.stdout)

    def test_a_restart_on_the_unbuilt_head_goes_back_to_the_built_commit(self):
        # The loop died after writing `broken` and before the checkout back: the restart finds
        # head == broken, HEAD on the unbuilt head, and must still hand over to the built run.sh.
        d = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", d])
        remote, repo, state = (os.path.join(d, n) for n in ("remote", "repo", "state"))
        os.makedirs(os.path.join(remote, "ops", "sim-fleet"))
        self.git(remote, "init", "-q", "-b", "main")
        run_sh = Path(remote, "ops", "sim-fleet", "run.sh")
        run_sh.write_text('#!/usr/bin/env bash\necho "BUILT-RUN-SH marker=${SIM_FLEET_REEXEC:-}"\n')
        self.git(remote, "add", "-A")
        self.git(remote, "commit", "-q", "-m", "v1")
        v1 = self.git(remote, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", "-q", remote, repo], check=True)
        run_sh.write_text('#!/usr/bin/env bash\necho "UNBUILT-RUN-SH"\n')
        self.git(remote, "commit", "-q", "-a", "-m", "v2")
        v2 = self.git(remote, "rev-parse", "HEAD")
        os.makedirs(state)
        out = subprocess.run(
            ["bash", "-c", f'source "{HERE}/run.sh"; log() {{ echo "$*" >&2; }}; '
             f'build_into() {{ return 1; }}; export -f build_into; prune_cache() {{ :; }}; '
             f'STATE="{state}"; built={v1}; broken={v2}; cd "{repo}"; SIM_FLEET_BRANCH=main; '
             f'SIM_FLEET_GIT_TIMEOUT=60; SIM_FLEET_BUILD_TIMEOUT=60; '
             f'SIM_FLEET_REPO_DIR="{repo}"; RUN_ARGS=(a); RUN_SH_SUM=0; ORIG_ENV=(); '
             f'git remote set-url origin "{remote}"; git fetch -q origin main; '
             f'git checkout -q --detach {v2}; '
             f'follow_main; echo "NOT-REACHED"'],
            env={"PATH": os.environ["PATH"], "HOME": d}, capture_output=True, text=True,
            timeout=60)
        self.assertIn(f"BUILT-RUN-SH marker={v1}", out.stdout, out.stderr)
        self.assertNotIn("UNBUILT-RUN-SH", out.stdout)
        self.assertNotIn("NOT-REACHED", out.stdout)

    def _restore_case(self, set_remote_url, built_is_head):
        """HEAD is on the unbuilt v2 (a restart during its build); returns follow_main's output."""
        d = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", d])
        remote, repo, state = (os.path.join(d, n) for n in ("remote", "repo", "state"))
        os.makedirs(os.path.join(remote, "ops", "sim-fleet"))
        self.git(remote, "init", "-q", "-b", "main")
        run_sh = Path(remote, "ops", "sim-fleet", "run.sh")
        run_sh.write_text('#!/usr/bin/env bash\necho "BUILT-RUN-SH marker=${SIM_FLEET_REEXEC:-}"\n')
        self.git(remote, "add", "-A")
        self.git(remote, "commit", "-q", "-m", "v1")
        v1 = self.git(remote, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", "-q", remote, repo], check=True)
        run_sh.write_text('#!/usr/bin/env bash\necho "UNBUILT-RUN-SH"\n')
        self.git(remote, "commit", "-q", "-a", "-m", "v2")
        v2 = self.git(remote, "rev-parse", "HEAD")
        self.git(repo, "fetch", "-q", "origin", "main")
        if built_is_head:  # main was reverted to the built commit
            self.git(remote, "reset", "-q", "--hard", v1)
        os.makedirs(state)
        url = remote if set_remote_url else os.path.join(d, "gone")
        return subprocess.run(
            ["bash", "-c", f'source "{HERE}/run.sh"; log() {{ echo "$*" >&2; }}; '
             f'STATE="{state}"; built={v1}; broken=""; cd "{repo}"; SIM_FLEET_BRANCH=main; '
             f'SIM_FLEET_GIT_TIMEOUT=60; SIM_FLEET_REPO_DIR="{repo}"; RUN_ARGS=(a); '
             f'RUN_SH_SUM=0; ORIG_ENV=(); git checkout -q --detach {v2}; '
             f'git remote set-url origin "{url}"; follow_main; echo NOT-REACHED'],
            env={"PATH": os.environ["PATH"], "HOME": d}, capture_output=True, text=True,
            timeout=60)

    def test_a_failed_fetch_still_hands_over_to_the_built_run_sh(self):
        out = self._restore_case(set_remote_url=False, built_is_head=False)
        self.assertIn("BUILT-RUN-SH", out.stdout, out.stderr)
        self.assertNotIn("UNBUILT-RUN-SH", out.stdout)

    def test_a_main_reverted_to_the_built_commit_hands_over_to_the_built_run_sh(self):
        out = self._restore_case(set_remote_url=True, built_is_head=True)
        self.assertIn("BUILT-RUN-SH", out.stdout, out.stderr)
        self.assertNotIn("UNBUILT-RUN-SH", out.stdout)

    def _checkout_fails(self, lock, built_known, on_unbuilt):
        """follow_main under set -e when `git checkout` fails: returns, with one coded line."""
        d = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", d])
        remote, repo, state = (os.path.join(d, n) for n in ("remote", "repo", "state"))
        os.makedirs(remote)
        self.git(remote, "init", "-q", "-b", "main")
        Path(remote, "f").write_text("v1")
        self.git(remote, "add", "f")
        self.git(remote, "commit", "-q", "-m", "v1")
        v1 = self.git(remote, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", "-q", remote, repo], check=True)
        Path(remote, "f").write_text("v2")
        self.git(remote, "commit", "-q", "-a", "-m", "v2")
        v2 = self.git(remote, "rev-parse", "HEAD")
        self.git(repo, "fetch", "-q", "origin", "main")
        os.makedirs(state)
        built = v1 if built_known else "0123456789abcdef0123456789abcdef01234567"
        start = v2 if on_unbuilt else v1
        script = (f'source "{HERE}/run.sh"; log() {{ echo "$*" >&2; }}; '
                  f'build_into() {{ return 1; }}; export -f build_into; prune_cache() {{ :; }}; '
                  f'STATE="{state}"; built={built}; broken={v2 if on_unbuilt else ""}; '
                  f'cd "{repo}"; SIM_FLEET_BRANCH=main; SIM_FLEET_GIT_TIMEOUT=60; '
                  f'SIM_FLEET_BUILD_TIMEOUT=60; SIM_FLEET_REPO_DIR="{repo}"; RUN_ARGS=(a); '
                  f'RUN_SH_SUM=0; ORIG_ENV=(); git checkout -q --detach {start}; ')
        if lock:
            script += 'touch .git/index.lock; '
        out = subprocess.run(["bash", "-c", script + 'follow_main; echo "RETURNED rc=$?"'],
                             env={"PATH": os.environ["PATH"], "HOME": d}, capture_output=True,
                             text=True, timeout=60)
        self.assertIn("RETURNED rc=0", out.stdout, out.stderr)
        self.assertEqual(out.stderr.count("NRV-E0731"), 1, out.stderr)
        self.assertIn("error[NRV-E0731]: cannot check out", out.stderr)
        self.assertNotIn("\nfatal:", out.stderr)

    def test_a_stale_index_lock_does_not_end_the_loop_restoring_the_built_commit(self):
        self._checkout_fails(lock=True, built_known=True, on_unbuilt=True)

    def test_a_stale_index_lock_does_not_end_the_loop_checking_out_a_new_head(self):
        self._checkout_fails(lock=True, built_known=True, on_unbuilt=False)

    def test_an_unknown_built_commit_does_not_end_the_loop(self):
        self._checkout_fails(lock=False, built_known=False, on_unbuilt=True)

    def _dirty_case(self, dirty_after, status_fails=False):
        """A new head to check out; the tree is dirty before it, or git leaves it dirty (#439)."""
        d = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", d])
        remote, repo, state = (os.path.join(d, n) for n in ("remote", "repo", "state"))
        os.makedirs(remote)
        self.git(remote, "init", "-q", "-b", "main")
        Path(remote, "f").write_text("v1")
        self.git(remote, "add", "f")
        self.git(remote, "commit", "-q", "-m", "v1")
        v1 = self.git(remote, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", "-q", remote, repo], check=True)
        Path(remote, "f").write_text("v2")
        self.git(remote, "commit", "-q", "-a", "-m", "v2")
        os.makedirs(state)
        # build_into records what the tree held when it was built.
        script = (f'source "{HERE}/run.sh"; log() {{ echo "$*" >&2; }}; '
                  f'build_into() {{ cp f "{state}/tree-built"; return 0; }}; '
                  f'prune_cache() {{ :; }}; STATE="{state}"; built={v1}; broken=; '
                  f'cd "{repo}"; SIM_FLEET_BRANCH=main; SIM_FLEET_GIT_TIMEOUT=60; '
                  f'SIM_FLEET_BUILD_TIMEOUT=60; SIM_FLEET_REPO_DIR="{repo}"; RUN_ARGS=(a); '
                  f'RUN_SH_SUM=0; ORIG_ENV=(); ')
        if status_fails:
            # A corrupt index: `git status` exits 128 with nothing on stdout, so it must read as
            # dirty, not as clean.
            script += ('git() { if [[ "$1" == status ]]; then return 128; fi; '
                       'command git "$@"; }; ')
        elif dirty_after:
            # git exits 0 but a file was not written (a full disk).
            script += ('git() { command git "$@"; local rc=$?; '
                       'if [[ "$1" == checkout ]]; then echo torn > f; fi; return $rc; }; ')
        else:
            script += 'echo torn > f; '
        return subprocess.run(["bash", "-c", script + 'follow_main; echo "RC=$?"'],
                              env={"PATH": os.environ["PATH"], "HOME": d}, capture_output=True,
                              text=True, timeout=60), repo

    def test_a_dirty_tree_is_forced_clean_by_the_next_checkout(self):
        out, repo = self._dirty_case(dirty_after=False)
        tree_built = Path(os.path.dirname(repo), "state", "tree-built")
        self.assertEqual(tree_built.read_text(), "v2", out.stderr)
        self.assertNotIn("NRV-E0731", out.stderr)

    def test_a_checkout_that_leaves_the_tree_dirty_is_not_built(self):
        out, repo = self._dirty_case(dirty_after=True)
        self.assertIn("RC=0", out.stdout, out.stderr)
        tree_built = Path(os.path.dirname(repo), "state", "tree-built")
        self.assertFalse(tree_built.exists(), out.stderr)
        # The new head's checkout, then the restore of the built commit, both torn by the wrapper.
        self.assertEqual(out.stderr.count("NRV-E0731"), 2, out.stderr)
        self.assertIn("tree is not clean", out.stderr)
        # HEAD is back on the built commit, not left on the unbuilt head.
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"),
                         self.git(repo, "rev-parse", "origin/main~1"), out.stderr)

    def test_a_git_status_that_fails_reads_as_dirty_and_is_not_built(self):
        out, repo = self._dirty_case(dirty_after=False, status_fails=True)
        self.assertIn("RC=0", out.stdout, out.stderr)
        self.assertFalse(Path(os.path.dirname(repo), "state", "tree-built").exists(), out.stderr)
        self.assertIn("NRV-E0731", out.stderr)

    def test_a_torn_restore_is_forced_again_and_not_exec_d_until_clean(self):
        """Round 1 tears run.sh on the restore checkout; round 2 must heal it, not exec it."""
        d = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", d])
        remote, repo, state = (os.path.join(d, n) for n in ("remote", "repo", "state"))
        os.makedirs(os.path.join(remote, "ops", "sim-fleet"))
        self.git(remote, "init", "-q", "-b", "main")
        run_sh = Path(remote, "ops", "sim-fleet", "run.sh")
        run_sh.write_text('#!/usr/bin/env bash\necho "BUILT-RUN-SH"\n')
        self.git(remote, "add", "-A")
        self.git(remote, "commit", "-q", "-m", "v1")
        v1 = self.git(remote, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", "-q", remote, repo], check=True)
        run_sh.write_text('#!/usr/bin/env bash\necho "UNBUILT-RUN-SH"\n')
        self.git(remote, "commit", "-q", "-a", "-m", "v2")
        v2 = self.git(remote, "rev-parse", "HEAD")
        self.git(repo, "fetch", "-q", "origin", "main")
        os.makedirs(state)
        out = subprocess.run(
            ["bash", "-c", f'source "{HERE}/run.sh"; log() {{ echo "$*" >&2; }}; '
             f'prune_cache() {{ :; }}; STATE="{state}"; built={v1}; broken={v2}; cd "{repo}"; '
             f'SIM_FLEET_BRANCH=main; SIM_FLEET_GIT_TIMEOUT=60; SIM_FLEET_REPO_DIR="{repo}"; '
             f'SIM_FLEET_BROKEN_RETRIES=3; SIM_FLEET_BROKEN_RETRY_SECONDS=7200; broken_tries=0; '
             f'RUN_ARGS=(a); RUN_SH_SUM=0; ORIG_ENV=(); git checkout -q --detach {v2}; '
             # git exits 0 but writes run.sh short, in round 1 only (a full disk).
             f'tear=1; git() {{ command git "$@"; local rc=$?; if [[ "$1" == checkout && '
             f'$tear == 1 ]]; then echo "echo TORN-RUN-SH" > ops/sim-fleet/run.sh; fi; '
             f'return $rc; }}; '
             f'follow_main; echo "ROUND1 head=$(git rev-parse HEAD) '
             f'dirty=$(git status --porcelain -uno)"; tear=0; follow_main; echo NOT-REACHED'],
            env={"PATH": os.environ["PATH"], "HOME": d}, capture_output=True, text=True,
            timeout=60)
        self.assertIn("ROUND1", out.stdout, out.stderr)
        self.assertIn("dirty= M ops/sim-fleet/run.sh", out.stdout, out.stderr)
        self.assertNotIn("TORN-RUN-SH", out.stdout)
        self.assertIn("BUILT-RUN-SH", out.stdout, out.stderr)
        self.assertNotIn("NOT-REACHED", out.stdout)

    def test_a_restart_already_on_the_built_commit_stays_put(self):
        d = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", d])
        remote, repo, state = (os.path.join(d, n) for n in ("remote", "repo", "state"))
        os.makedirs(remote)
        self.git(remote, "init", "-q", "-b", "main")
        Path(remote, "f").write_text("v1")
        self.git(remote, "add", "f")
        self.git(remote, "commit", "-q", "-m", "v1")
        v1 = self.git(remote, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", "-q", remote, repo], check=True)
        Path(remote, "f").write_text("v2")
        self.git(remote, "commit", "-q", "-a", "-m", "v2")
        v2 = self.git(remote, "rev-parse", "HEAD")
        os.makedirs(state)
        out = subprocess.run(
            ["bash", "-c", f'source "{HERE}/run.sh"; log() {{ echo "$*" >&2; }}; '
             f'STATE="{state}"; built={v1}; broken={v2}; cd "{repo}"; SIM_FLEET_BRANCH=main; '
             f'SIM_FLEET_GIT_TIMEOUT=60; SIM_FLEET_REPO_DIR="{repo}"; '
             f'git remote set-url origin "{remote}"; git checkout -q --detach {v1}; '
             f'follow_main; echo "HEAD=$(git rev-parse HEAD)"'],
            env={"PATH": os.environ["PATH"], "HOME": d}, capture_output=True, text=True,
            timeout=60)
        self.assertIn(f"HEAD={v1}", out.stdout, out.stderr)
        self.assertNotIn("restoring", out.stderr)


class AlarmRoundsSetting(unittest.TestCase):
    """SIM_FLEET_ALARM_ROUNDS is a whole number from 1 to 999999 (NRV-E0730's threshold)."""

    def check(self, value):
        home = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", home])
        return subprocess.run(
            ["bash", f"{HERE}/run.sh"],
            env={"PATH": os.environ["PATH"], "SIM_FLEET_HOME": home,
                 "SIM_FLEET_ALARM_ROUNDS": value}, capture_output=True, text=True, timeout=30)

    def test_zero_text_and_too_many_digits_are_refused(self):
        for bad in ("0", "abc", "1000000", "-1"):
            out = self.check(bad)
            self.assertEqual(out.returncode, 2, (bad, out.stdout + out.stderr))
            self.assertIn("SIM_FLEET_ALARM_ROUNDS must be a positive whole number",
                          out.stdout + out.stderr)

    def test_the_largest_value_passes_this_check(self):
        # It stops later (no token), not at the alarm setting.
        out = self.check("999999")
        self.assertNotIn("SIM_FLEET_ALARM_ROUNDS must be", out.stdout + out.stderr)
        self.assertIn("no token", out.stdout + out.stderr)


class Alarm(unittest.TestCase):
    """`sim_fleet.py alarm` files one issue and comments on it after that."""

    ARGS = ["alarm", "--rounds", "3", "--round-id", ID_A, "--commit", SHA_A,
            "--repo", "NervaLog/nerva", "--token-file", "/x"]

    def run_alarm(self, github, argv=None):
        err = io.StringIO()
        with mock.patch.object(fleet, "GitHub", lambda *a: github), \
                mock.patch.object(fleet, "read_token", lambda path: "t"), \
                contextlib.redirect_stderr(err):
            return fleet.main(argv or self.ARGS), err.getvalue()

    def test_it_opens_the_issue_then_comments_on_it(self):
        github = Recorder()
        github.found = None
        github.find_open = lambda marker: github.found
        self.assertEqual(self.run_alarm(github)[0], 0)
        number, title, body = github.opened[0]
        self.assertIn("NRV-E0730", title)
        self.assertIn(fleet.ALARM_MARKER, body)
        github.found = number  # The next streak finds it open.
        self.assertEqual(self.run_alarm(github)[0], 0)
        self.assertEqual(len(github.opened), 1)
        self.assertEqual(github.comments[0][0], number)

    def test_the_alarm_marker_is_not_a_failure_fingerprint(self):
        self.assertIsNone(fleet.MARKER.search(fleet.ALARM_MARKER))

    def test_github_down_is_exit_1_not_a_crash(self):
        github = Recorder(fail={"open": fleet.GitHubError("unreachable", "no answer")})
        github.find_open = lambda marker: None
        code, err = self.run_alarm(github)
        self.assertEqual(code, 1)
        self.assertIn("alarm not filed", err)

    def test_a_bad_round_id_or_count_is_exit_1(self):
        github = Recorder()
        github.find_open = lambda marker: None
        argv = list(self.ARGS)
        argv[argv.index("--rounds") + 1] = str(fleet.ALARM_ROUNDS_MAX)  # The bound itself passes.
        self.assertEqual(self.run_alarm(github, argv)[0], 0)
        for bad in (["--round-id", "x"], ["--rounds", "0"],
                    ["--rounds", str(fleet.ALARM_ROUNDS_MAX + 1)]):
            argv = [a for a in self.ARGS]
            argv[argv.index(bad[0]) + 1] = bad[1]
            self.assertEqual(self.run_alarm(Recorder(), argv)[0], 1)

    def test_dry_run_prints_the_issue(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = fleet.main(["alarm", "--rounds", "3", "--round-id", ID_A, "--commit", SHA_A,
                               "--dry-run"])
        self.assertEqual(code, 0)
        self.assertIn("would open issue [sim-fleet]", out.getvalue())


class Rotation(unittest.TestCase):
    """A worker's rotation resumes where the last round left it."""

    def run_worker(self, state, kind, start, fuzzers):
        bindir = os.path.join(state, "fakebin")
        os.makedirs(bindir, exist_ok=True)
        for name in ("fuzz", "vopr-nerva", "vopr-testing"):
            path = os.path.join(bindir, name)
            with open(path, "w") as f:
                f.write("#!/bin/sh\nexit 0\n")
            os.chmod(path, 0o755)
        rnd = os.path.join(state, "round-" + str(len(os.listdir(state))))
        script = (f'source "{HERE}/run.sh"; STATE="{state}"; bin="{bindir}"; round="{rnd}"; '
                  f'FUZZERS=({fuzzers}); mkdir -p "$STATE/rotation"; '
                  f'worker 0 {kind} $(( $(date +%s) + 1 )) {start}')
        subprocess.run(["bash", "-c", script], check=True, capture_output=True,
                       env={"PATH": os.environ["PATH"], "SIM_FLEET_VOPR_SEED_TIMEOUT": "10",
                            "SIM_FLEET_FUZZ_SEED_TIMEOUT": "10", "SIM_FLEET_TAIL_BYTES": "100",
                            "SIM_FLEET_REPLAY_TIMEOUT": "10"})
        with open(os.path.join(rnd, "w0", "results")) as f:
            return [line.split()[0] for line in f]

    def test_a_fuzz_worker_continues_through_the_list_across_rounds(self):
        state = tempfile.mkdtemp()
        fuzzers = "a b c d e"
        first = self.run_worker(state, "fuzz", 0, fuzzers)
        second = self.run_worker(state, "fuzz", 0, fuzzers)
        names = fuzzers.split()
        both = [t.split(":")[1] for t in first + second]
        self.assertGreater(len(first), 0)
        self.assertEqual(both, [names[i % 5] for i in range(len(both))])

    def test_a_mixed_worker_continues_its_kinds_and_fuzzers_across_rounds(self):
        state = tempfile.mkdtemp()
        fuzzers = "a b c"
        both = self.run_worker(state, "mixed", 1, fuzzers) + \
            self.run_worker(state, "mixed", 1, fuzzers)
        kinds = ["vopr-nerva", "vopr-testing", "vopr-nerva", "fuzz"]
        want, fuzz_i = [], 1  # `next` starts at the worker's offset.
        for i in range(len(both)):
            kind = kinds[(1 + i) % 4]
            if kind == "fuzz":
                want.append("fuzz:" + fuzzers.split()[fuzz_i % 3])
                fuzz_i += 1
            else:
                want.append(kind)
        self.assertEqual(both, want)


class BrokenRetry(unittest.TestCase):
    """A commit whose build failed is retried after a bound, a bounded number of times (#289)."""

    def setUp(self):
        d = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", d])
        self.d = d
        self.remote, self.repo, self.state = (os.path.join(d, n)
                                              for n in ("remote", "repo", "state"))
        os.makedirs(self.remote)
        os.makedirs(self.state)
        self.git(self.remote, "init", "-q", "-b", "main")
        Path(self.remote, "f").write_text("v1")
        self.git(self.remote, "add", "f")
        self.git(self.remote, "commit", "-q", "-m", "v1")
        self.v1 = self.git(self.remote, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", "-q", self.remote, self.repo], check=True)
        Path(self.remote, "f").write_text("v2")
        self.git(self.remote, "commit", "-q", "-a", "-m", "v2")
        self.v2 = self.git(self.remote, "rev-parse", "HEAD")

    def git(self, cwd, *args):
        return subprocess.run(["git", "-C", cwd, "-c", "user.name=t", "-c", "user.email=t@t",
                               *args], capture_output=True, text=True, check=True).stdout.strip()

    def rounds(self, n, builds_ok=False, retries=2, seconds=0, kill=False):
        """Runs follow_main n times (a fresh shell each, as a restart); one line per round."""
        lines = []
        for _ in range(n):
            broken = Path(self.state, "broken")
            built = Path(self.state, "built")
            ok = "return 0" if builds_ok else "return 1"
            if kill:  # The loop dies (SIGKILL, as a restart or the OOM killer) mid-build.
                ok = 'kill -9 "$MAIN"; sleep 30'
            out = subprocess.run(
                ["bash", "-c", f'source "{HERE}/run.sh"; log() {{ echo "$*" >&2; }}; '
                 f'build_into() {{ echo x >>"{self.d}/builds"; {ok}; }}; '
                 f'export -f build_into; export d="{self.d}" MAIN=$$; prune_cache() {{ :; }}; '
                 f'STATE="{self.state}"; cd "{self.repo}"; SIM_FLEET_BRANCH=main; '
                 f'SIM_FLEET_GIT_TIMEOUT=60; SIM_FLEET_BUILD_TIMEOUT=60; '
                 f'SIM_FLEET_BROKEN_RETRIES={retries}; SIM_FLEET_BROKEN_RETRY_SECONDS={seconds}; '
                 f'SIM_FLEET_REPO_DIR="{self.repo}"; RUN_ARGS=(a); RUN_SH_SUM=0; ORIG_ENV=(); '
                 f'built=$(cat "{built}" 2>/dev/null || echo {self.v1}); '
                 f'broken=$(cat "{broken}" 2>/dev/null || true); broken_tries=0; '
                 f'git checkout -q --detach "$built"; git remote set-url origin "{self.remote}"; '
                 f'follow_main; echo "built=$built broken=$broken"'],
                env={"PATH": os.environ["PATH"], "HOME": self.d}, capture_output=True,
                text=True, timeout=60)
            lines.append(out)
        return lines

    def builds(self):
        p = Path(self.d, "builds")
        return len(p.read_text().split()) if p.exists() else 0

    def test_a_broken_commit_is_retried_up_to_the_bound_then_left(self):
        self.rounds(6)
        # One build, then two retries, and no more: the bound is retries + 1 builds.
        self.assertEqual(self.builds(), 3)
        self.assertTrue(Path(self.state, "broken-tries").read_text().startswith(
            f"{self.v2} 3 "))

    def test_a_retry_killed_midway_still_counts(self):
        self.rounds(1)  # The first build fails: v2 is broken.
        for _ in range(6):  # Six boots, each killed during its retry build.
            self.rounds(1, kill=True)
        # One build, then retries 2 and 3 (killed), and no more: retries + 1 builds in all.
        self.assertEqual(self.builds(), 3)
        self.assertTrue(Path(self.state, "broken-tries").read_text().startswith(f"{self.v2} 3 "))
        out = self.rounds(1)[0]
        self.assertNotIn("retrying", out.stderr)
        self.assertEqual(self.builds(), 3)

    def test_each_retry_keeps_its_own_build_log(self):
        self.rounds(6)
        logs = sorted(p.name for p in Path(self.state).glob("build.log*"))
        self.assertEqual(logs, ["build.log", "build.log.2", "build.log.3"])

    def test_a_broken_commit_is_not_retried_before_the_wait_is_over(self):
        self.rounds(4, seconds=3600)
        self.assertEqual(self.builds(), 1)

    def test_a_retry_that_builds_is_recorded_and_clears_the_attempts(self):
        self.rounds(1)
        out = self.rounds(1, builds_ok=True)[0]
        self.assertIn("retrying the build", out.stderr)
        self.assertIn(f"built={self.v2}", out.stdout, out.stderr)
        self.assertFalse(Path(self.state, "broken-tries").exists())

    def test_a_missing_attempts_file_is_rewritten_not_retried_in_a_loop(self):
        self.rounds(1)
        Path(self.state, "broken-tries").unlink()
        self.rounds(1, seconds=3600)
        self.assertEqual(self.builds(), 1)
        self.assertTrue(Path(self.state, "broken-tries").read_text().startswith(f"{self.v2} 1 "))

    def test_a_new_head_starts_its_own_count(self):
        self.rounds(6)
        Path(self.remote, "f").write_text("v3")
        self.git(self.remote, "commit", "-q", "-a", "-m", "v3")
        v3 = self.git(self.remote, "rev-parse", "HEAD")
        self.rounds(1)
        self.assertEqual(self.builds(), 4)
        self.assertTrue(Path(self.state, "broken-tries").read_text().startswith(f"{v3} 1 "))


class BrokenRetrySettings(unittest.TestCase):
    """The retry bound and wait are non-negative whole numbers."""

    def run_sh(self, **env):
        home = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", home])
        return subprocess.run(["bash", f"{HERE}/run.sh"],
                              env={"PATH": os.environ["PATH"], "SIM_FLEET_HOME": home, **env},
                              capture_output=True, text=True, timeout=30)

    def test_text_and_negatives_are_refused(self):
        for var in ("SIM_FLEET_BROKEN_RETRIES", "SIM_FLEET_BROKEN_RETRY_SECONDS"):
            for bad in ("three", "-1"):
                out = self.run_sh(**{var: bad})
                self.assertEqual(out.returncode, 2, (var, bad, out.stdout + out.stderr))
                self.assertIn(f"{var} must be a non-negative whole number",
                              out.stdout + out.stderr)

    def test_zero_passes_this_check(self):
        out = self.run_sh(SIM_FLEET_BROKEN_RETRIES="0", SIM_FLEET_BROKEN_RETRY_SECONDS="0")
        self.assertNotIn("must be a non-negative", out.stdout + out.stderr)
        self.assertIn("no token", out.stdout + out.stderr)


if __name__ == "__main__":
    unittest.main()
