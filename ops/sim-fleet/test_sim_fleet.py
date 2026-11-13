#!/usr/bin/env python3
"""Tests for sim_fleet.py (P147h), without network. Run from the repository root:
python3 ops/sim-fleet/test_sim_fleet.py"""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
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
            code = fleet.main(["ingest", "--round", rnd.path, "--commit", "abcdef1",
                               "--state", self.path, "--dry-run"], now=DAY_ONE)
        self.assertEqual(code, 0)
        self.assertIn("would open issue [sim-fleet] 'VOPR nerva liveness: no state convergence: "
                      "pending replica convergence'", out.getvalue())
        self.assertIn("sim-fleet: 2 seeds, 1 failed", out.getvalue())
        self.assertEqual(json.loads(Path(self.path).read_text())["days"]["2026-11-02"]["rounds"],
                         1)

    def test_main_refuses_a_bad_round_with_the_refused_exit(self):
        rnd = Round(self)
        os.makedirs(os.path.join(rnd.path, "w0"))
        Path(rnd.path, "w0", "results").write_text("garbage\n")
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            code = fleet.main(["ingest", "--round", rnd.path, "--commit", "abcdef1",
                               "--state", self.path, "--dry-run"], now=DAY_ONE)
        self.assertEqual(code, fleet.EXIT_REFUSED)
        # No seed is counted, but the round is: against its commit, as refused (#370).
        state = fleet.load_state(self.path)
        self.assertEqual(state["days"], {})
        self.assertEqual(state["commits"]["abcdef1"]["refused"], 1)
        self.assertEqual(state["commits"]["abcdef1"]["rounds"], 0)


SHA_A = "1a2b3c4" + "0" * 33
SHA_B = "9f8e7d6" + "0" * 33


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
        path = os.path.join(tempfile.mkdtemp(), "state.json")
        self.addCleanup(lambda: [os.path.exists(f) and os.unlink(f) for f in (path, path + ".new")])
        return path

    def ingest_main(self, path, rnd, commit=SHA_A):
        return self.run_main("ingest", "--round", rnd.path, "--commit", commit, "--state", path,
                             "--dry-run")

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
        self.assertEqual(code, fleet.EXIT_REFUSED)
        self.assertIn("refused", err)
        self.assertEqual(self.ingest_main(path, self.clean_round())[0], 0)
        code, line, err = self.run_main("soak", "--commit", SHA_A, "--state", path)
        self.assertEqual(code, 1)
        self.assertIn("vopr-nerva 300 seeds", line)
        self.assertTrue(line.endswith("; 1 rounds refused or lost by the reporter, "
                                      "their seeds unknown"), line)
        self.assertIn("not clean", err)

    def test_a_malformed_results_line_is_a_refused_round_too(self):
        path = self.state_path()
        rnd = self.clean_round()
        with open(os.path.join(rnd.path, "w0", "results"), "a") as file:
            file.write("vopr-nerva not-a-seed\n")
        self.assertEqual(self.ingest_main(path, rnd)[0], fleet.EXIT_REFUSED)
        self.assertEqual(self.ingest_main(path, self.clean_round())[0], 0)
        self.assertEqual(self.run_main("soak", "--commit", SHA_A, "--state", path)[0], 1)

    def test_a_refused_round_counts_against_its_own_commit_only(self):
        path = self.state_path()
        self.assertEqual(self.ingest_main(path, self.clean_round(), SHA_B)[0], 0)
        self.assertEqual(self.ingest_main(path, self.too_many_failures(), SHA_A)[0],
                         fleet.EXIT_REFUSED)
        self.assertEqual(self.run_main("soak", "--commit", SHA_B, "--state", path)[0], 0)
        self.assertEqual(self.run_main("soak", "--commit", SHA_A, "--state", path)[0], 1)

    def test_a_commit_with_only_a_refused_round_is_exit_1_and_says_why(self):
        path = self.state_path()
        self.ingest_main(path, self.too_many_failures())
        code, line, err = self.run_main("soak", "--commit", SHA_A, "--state", path)
        self.assertEqual(code, 1)
        self.assertIn("0.0 h", line)
        self.assertIn("1 rounds refused", line)
        self.assertNotIn("no rounds of", err)

    def test_refuse_counts_a_round_the_reporter_lost(self):
        path = self.state_path()
        self.assertEqual(self.ingest_main(path, self.clean_round())[0], 0)
        self.assertEqual(self.run_main("soak", "--commit", SHA_A, "--state", path)[0], 0)
        for _ in range(2):
            self.assertEqual(self.run_main("refuse", "--commit", SHA_A, "--state", path)[0], 0)
        code, line, _ = self.run_main("soak", "--commit", SHA_A, "--state", path)
        self.assertEqual(code, 1)
        self.assertIn("; 2 rounds refused or lost", line)
        self.assertEqual(self.run_main("refuse", "--commit", "xyz", "--state", path)[0], 1)

    def live_main(self, path, rnd, token_file, commit=SHA_A):
        return self.run_main("ingest", "--round", rnd.path, "--commit", commit, "--state", path,
                             "--repo", "NervaLog/nerva", "--token-file", token_file)

    def failing_round(self):
        rnd = Round(self)
        for seed in range(3):
            rnd.seed(0, "vopr-nerva", seed, 134, tail="boom")
        return rnd

    def test_a_missing_token_file_counts_the_round_as_refused(self):
        # Was exit 2 with nothing counted: a later clean round read the commit clean (#370).
        path = self.state_path()
        self.assertEqual(self.ingest_main(path, self.clean_round())[0], 0)
        code, _, err = self.live_main(path, self.failing_round(), "/nonexistent/token")
        self.assertEqual(code, fleet.EXIT_REFUSED)
        self.assertIn("cannot read the token file", err)
        self.assertEqual(self.ingest_main(path, self.clean_round())[0], 0)
        self.assertEqual(self.run_main("soak", "--commit", SHA_A, "--state", path)[0], 1)
        self.assertEqual(fleet.load_state(path)["commits"][SHA_A]["refused"], 1)

    def test_github_unreachable_while_rebuilding_counts_the_round_as_refused(self):
        class Down:
            def __init__(self, *args):
                pass

            def markers(self):
                raise fleet.GitHubError("unreachable", "no answer")

        path = self.state_path()
        token = os.path.join(os.path.dirname(path), "token")
        Path(token).write_text("t0ken\n")
        original = fleet.GitHub
        fleet.GitHub = Down
        self.addCleanup(setattr, fleet, "GitHub", original)
        code, _, err = self.live_main(path, self.failing_round(), token)
        self.assertEqual(code, fleet.EXIT_REFUSED)
        self.assertIn("could not be read", err)
        # The state exists now, and says `rebuild`; the next round still counts.
        state = fleet.load_state(path)
        self.assertEqual(state["commits"][SHA_A]["refused"], 1)
        self.assertEqual(self.ingest_main(path, self.clean_round())[0], 0)
        self.assertEqual(self.run_main("soak", "--commit", SHA_A, "--state", path)[0], 1)

    def test_a_usage_error_is_not_the_refused_exit(self):
        code, _, _ = self.run_main("ingest", "--round", "r", "--commit", "xyz", "--state",
                                   self.state_path(), "--dry-run")
        self.assertEqual(code, fleet.EXIT_USAGE)
        code, _, _ = self.run_main("ingest", "--round", "r", "--commit", SHA_A, "--state",
                                   self.state_path())
        self.assertEqual(code, fleet.EXIT_USAGE)

    def test_an_uncaught_exception_in_the_reporter_exits_70(self):
        rnd = Round(self)
        os.makedirs(os.path.join(rnd.path, "w0", "results"))  # A directory: open() raises.
        out = subprocess.run(
            ["python3", "-I", str(HERE / "sim_fleet.py"), "ingest", "--round", rnd.path,
             "--commit", SHA_A, "--state", self.state_path(), "--dry-run"],
            capture_output=True, text=True)
        self.assertEqual(out.returncode, 70)
        self.assertIn("Traceback", out.stderr)

    def test_a_refusal_with_no_state_starts_one_the_next_ingest_rebuilds(self):
        path = self.state_path()
        self.assertEqual(self.run_main("refuse", "--commit", SHA_A, "--state", path)[0], 0)
        self.assertEqual(self.run_main("soak", "--commit", SHA_A, "--state", path)[0], 1)
        code, _, err = self.ingest_main(path, self.clean_round())
        self.assertEqual(code, 0)
        self.assertIn("the state file was missing: rebuilt", err)
        state = fleet.load_state(path)
        self.assertNotIn("rebuild", state)
        self.assertEqual(state["commits"][SHA_A]["refused"], 1)
        self.assertNotIn("the state file was missing", self.ingest_main(path, self.clean_round())[2])

    def test_an_unreadable_state_is_not_overwritten_by_a_refusal(self):
        path = self.state_path()
        with open(path, "w") as file:
            file.write("not json")
        self.assertEqual(self.run_main("refuse", "--commit", SHA_A, "--state", path)[0], 2)
        with open(path) as file:
            self.assertEqual(file.read(), "not json")
        self.assertEqual(self.ingest_main(path, self.too_many_failures())[0],
                         fleet.EXIT_UNRECORDED)

    def test_a_save_that_fails_after_counting_is_exit_4_not_counted(self):
        path = self.state_path()
        with mock.patch.object(fleet, "save_state", side_effect=OSError("disk full")):
            code = self.ingest_main(path, self.clean_round())[0]
        self.assertEqual(code, fleet.EXIT_UNRECORDED)
        self.assertNotEqual(code, fleet.EXIT_COUNTED)

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
                self.assertEqual(fleet.main(["ingest", "--round", rnd.path, "--commit", SHA_A,
                                             "--state", state_path, "--dry-run"],
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


class RunShRefuse(unittest.TestCase):
    """run.sh's `ingest` and `run_round` count a round the reporter did not (#370), with a stub
    in place of the interpreter that ends `ingest` with $STUB_CODE and runs the real `refuse`."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", self.dir]))
        self.state = os.path.join(self.dir, "state")
        os.makedirs(self.state)
        self.stub = os.path.join(self.dir, "python")
        with open(self.stub, "w") as f:
            f.write("#!/bin/sh\nshift 2\nif [ \"$1\" = ingest ]; then exit \"$STUB_CODE\"; fi\n"
                    "if [ \"$1\" = refuse ] && [ -n \"$STUB_REFUSE_FAILS\" ]; then exit 2; fi\n"
                    f"exec python3 -I \"{HERE}/sim_fleet.py\" \"$@\"\n")
        os.chmod(self.stub, 0o755)

    def sh(self, script, code=0, refuse_fails=False):
        env = {"PATH": os.environ["PATH"], "STUB_CODE": str(code)}
        if refuse_fails:
            env["STUB_REFUSE_FAILS"] = "1"
        return subprocess.run(
            ["bash", "-c", f'source "{HERE}/run.sh"; STATE="{self.state}"; bin="{HERE}"; '
             f'built={SHA_A}; round="$STATE/round"; SIM_FLEET_PYTHON="{self.stub}"; '
             'SIM_FLEET_REPORT_TIMEOUT=30; SIM_FLEET_REPO_DIR=/x; SIM_FLEET_DRY_RUN=1; '
             f'SIM_FLEET_ROUND_SECONDS=0; SIM_FLEET_TRACKER=; token_file=/x; SIM_FLEET_WORKERS_VOPR_NERVA=0; SIM_FLEET_WORKERS_VOPR_TESTING=0; SIM_FLEET_WORKERS_FUZZ=0; SIM_FLEET_WORKERS_MIXED=0; log() {{ echo "$*" >&2; }}; {script}'],
            env=env, capture_output=True, text=True)

    def refused(self):
        path = os.path.join(self.state, "state.json")
        return fleet.load_state(path)["commits"].get(SHA_A, {}).get("refused", 0) \
            if os.path.exists(path) else 0

    def ingest(self, code):
        os.makedirs(os.path.join(self.state, "round"), exist_ok=True)
        out = self.sh("ingest", code)
        self.assertEqual(out.returncode, 0, out.stderr)
        return self.refused()

    def test_the_exits_that_recorded_the_round_are_not_counted_again(self):
        for code in (0, 2, 3):
            self.assertEqual(self.ingest(code), 0, code)

    def test_every_other_exit_counts_the_round_as_refused(self):
        # 1 is a usage error or an import error of the reporter; it records nothing.
        for n, code in enumerate((1, 4, 64, 70, 124, 137), 1):
            self.assertEqual(self.ingest(code), n, code)

    def test_a_round_left_by_a_killed_run_is_counted_before_it_is_deleted(self):
        rnd = os.path.join(self.state, "round")
        os.makedirs(os.path.join(rnd, "w0"))
        Path(rnd, "commit").write_text(SHA_A + "\n")
        out = self.sh("run_round")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.refused(), 1)
        self.assertIn("never reported", out.stderr)

    def soak_code(self):
        return fleet.main(["soak", "--commit", SHA_A, "--state",
                           os.path.join(self.state, "state.json")], now=DAY_ONE)

    def test_two_clean_rounds_in_a_row_are_not_refused_and_soak_is_clean(self):
        state = fleet.new_state()
        rnd = Round(self)
        rnd.seed(0, "vopr-nerva", 1, 0, seconds=3600)
        ingest(self, Recorder(), state, rnd, SHA_A, DAY_ONE)
        fleet.save_state(os.path.join(self.state, "state.json"), state)
        for _ in range(2):
            out = self.sh("run_round", 0)  # runs ingest itself
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertFalse(os.path.exists(os.path.join(self.state, "round")))
        self.assertEqual(self.refused(), 0)
        self.assertNotIn("never reported", out.stderr)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(self.soak_code(), 0)

    def test_a_round_killed_midway_is_counted_refused_by_the_next_round(self):
        rnd = os.path.join(self.state, "round")  # begun, then killed before any outcome
        os.makedirs(os.path.join(rnd, "w0"))
        Path(rnd, "commit").write_text(SHA_A + "\n")
        out = self.sh("run_round", 0)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.refused(), 1)

    def test_a_round_nothing_could_record_leaves_a_marker_soak_reads_not_clean(self):
        state = fleet.new_state()
        rnd = Round(self)
        rnd.seed(0, "vopr-nerva", 1, 0, seconds=3600)
        ingest(self, Recorder(), state, rnd, SHA_A, DAY_ONE)
        fleet.save_state(os.path.join(self.state, "state.json"), state)
        os.makedirs(os.path.join(self.state, "round"))
        out = self.sh("ingest", 4, refuse_fails=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertTrue(os.path.exists(os.path.join(self.state, "unrecorded-" + SHA_A)))
        self.assertEqual(self.refused(), 0)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(self.soak_code(), 1)
        os.unlink(os.path.join(self.state, "unrecorded-" + SHA_A))
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(self.soak_code(), 0)

    def test_a_round_left_with_no_commit_is_deleted_and_says_so(self):
        os.makedirs(os.path.join(self.state, "round", "w0"))
        out = self.sh("run_round")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.refused(), 0)
        self.assertIn("cannot be counted", out.stderr)


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


if __name__ == "__main__":
    unittest.main()
