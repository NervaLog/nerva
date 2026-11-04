#!/usr/bin/env python3
"""Tests for sim_fleet.py (P147h), without network. Run from the repository root:
python3 ops/sim-fleet/test_sim_fleet.py"""
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
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

    def seed(self, worker, target, seed, code, tail="", errors=None):
        wdir = os.path.join(self.path, f"w{worker}")
        os.makedirs(wdir, exist_ok=True)
        with open(os.path.join(wdir, "results"), "a") as file:
            file.write(f"{target} {seed} {code} 3\n")
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

    def test_main_refuses_a_bad_round_with_exit_1(self):
        rnd = Round(self)
        os.makedirs(os.path.join(rnd.path, "w0"))
        Path(rnd.path, "w0", "results").write_text("garbage\n")
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            code = fleet.main(["ingest", "--round", rnd.path, "--commit", "abcdef1",
                               "--state", self.path, "--dry-run"], now=DAY_ONE)
        self.assertEqual(code, 1)
        self.assertFalse(os.path.exists(self.path))


if __name__ == "__main__":
    unittest.main()
