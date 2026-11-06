#!/usr/bin/env python3
"""Tests for jepsen_report.py (R1 slice 6), without network. Run from the repository root:
python3 -I ops/jepsen/test_jepsen_report.py"""
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("jepsen_report", HERE / "jepsen_report.py")
rep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rep)

NOW = 1_793_581_200  # 2026-11-02 01:00 UTC.
DAY = 24 * 3600
COMMIT = "0123456789abcdef0123456789abcdef01234567"
OTHER = "fedcba9876543210fedcba9876543210fedcba98"

VALID = "{:valid? true, :perf {:valid? true}, :timeline {:valid? true}}"


def invalid(checker="workload", name="duplicate", keys=("aaaa",), extra=""):
    examples = " ".join(f'{{:key "{k}", :ops [3 5]}}' for k in keys)
    return (f"{{:valid? false, :perf {{:valid? true}}, :{checker} {{:valid? false, "
            f":{name} {{:count {len(keys)}, :examples [{examples}]}}{extra}}}}}")


class Store:
    """A store/ directory as Jepsen and nightly.sh write it."""

    def __init__(self, test):
        self.dir = tempfile.TemporaryDirectory()
        test.addCleanup(self.dir.cleanup)
        self.path = self.dir.name
        self.runs = []

    def test(self, label, results, args="--workload retry --time-limit 300", history=(),
             code=0, with_results=True):
        directory = os.path.join(self.path, label, "nerva-" + label, "2026-11-02T01:00:00Z")
        os.makedirs(directory)
        Path(directory, "jepsen.log").write_text(
            f"INFO jepsen.cli - Command line:\nlein run test {args}\nINFO more\n")
        if with_results:
            Path(directory, "results.edn").write_text(results)
        Path(directory, "history.edn").write_text("".join(h + "\n" for h in history))
        self.runs.append(f"{label} {code} 100 {args}\n")
        return directory

    def host(self, label, code, args="--workload bank"):
        self.runs.append(f"{label} {code} 100 {args}\n")

    def write_runs(self):
        path = os.path.join(self.path, "runs")
        Path(path).write_text("".join(self.runs))
        return path


class Recorder:
    def __init__(self, fail=None, markers=None):
        self.opened, self.comments, self.statuses = [], [], []
        self.fail = fail or {}
        self.number = 100
        self._markers = markers or {}

    def markers(self):
        return dict(self._markers)

    def open(self, title, body):
        self.number += 1
        self.opened.append((self.number, title, body))
        return self.number

    def comment(self, number, body):
        key = ("comment", number)
        if key in self.fail:
            raise self.fail.pop(key)
        self.comments.append((number, body))

    def status(self, commit, state, context, description, target_url):
        if "status" in self.fail:
            raise self.fail.pop("status")
        self.statuses.append((commit, state, context, description))


def night(test, store, github=None, state=None, commit=COMMIT, now=NOW, tracker=None,
          canary=False):
    runs, host = rep.read_night(store.path, store.write_runs())
    github = github or Recorder()
    state = state or rep.new_state()
    summary = rep.ingest(github, state, runs, host, commit, tracker, None, canary, now,
                         "o/r", lambda m: None)
    return github, state, summary


class Statuses(unittest.TestCase):
    def test_a_valid_night_is_success(self):
        store = Store(self)
        store.test("1", VALID)
        github, _, _ = night(self, store)
        self.assertEqual(github.statuses[0][1:3], ("success", "jepsen/nightly"))
        self.assertEqual(github.opened, [])

    def test_an_invalid_run_is_failure_and_is_filed(self):
        store = Store(self)
        store.test("1", invalid(), history=['{:index 0, :type :ok, :key "aaaa", :f :pay}'])
        github, _, summary = night(self, store)
        self.assertEqual(github.statuses[0][1], "failure")
        self.assertEqual(summary["filed"], 1)
        self.assertEqual(github.opened[0][1], "Jepsen retry: duplicate (checker workload)")

    def test_failure_outranks_a_host_failure_in_the_same_night(self):
        store = Store(self)
        store.test("1", invalid())
        store.host("2", 124)
        github, _, _ = night(self, store)
        self.assertEqual(github.statuses[0][1], "failure")

    def test_a_host_failure_alone_is_error_and_never_filed(self):
        store = Store(self)
        store.host("1", 137)
        github, _, summary = night(self, store)
        self.assertEqual(github.statuses[0][1], "error")
        self.assertEqual(github.opened, [])
        self.assertEqual(summary["filed"], 0)

    def test_a_missing_results_file_is_the_hosts(self):
        store = Store(self)
        store.test("1", "", with_results=False)
        runs, _ = rep.read_night(store.path, store.write_runs())
        self.assertEqual(runs[0].kind, "host")

    def test_a_night_that_did_not_run_is_error(self):
        store = Store(self)
        Path(store.path, "host-failure").write_text("the build failed\n")
        github, _, _ = night(self, store)
        self.assertEqual(github.statuses[0][1], "error")
        self.assertEqual(github.opened, [])

    def test_the_canary_succeeds_only_if_jepsen_saw_the_duplicate(self):
        store = Store(self)
        store.test("1", invalid())
        github, _, _ = night(self, store, canary=True)
        self.assertEqual(github.statuses[0][1:3], ("success", "jepsen/canary"))
        blind = Store(self)
        blind.test("1", VALID)
        github, _, _ = night(self, blind, canary=True)
        self.assertEqual(github.statuses[0][1], "failure")


class Fingerprints(unittest.TestCase):
    def filed(self, results, args="--workload retry --time-limit 300"):
        store = Store(self)
        store.test("1", results, args=args)
        github, _, _ = night(self, store)
        return github.opened[0][2]

    def fingerprint(self, body):
        return rep.MARKER.search(body).group(1)

    def test_seed_commit_and_examples_do_not_change_it(self):
        a = self.filed(invalid(keys=("aaaa",)), "--workload retry --seed 1")
        b = self.filed(invalid(keys=("bbbb", "cccc")), "--workload retry --seed 2")
        self.assertEqual(self.fingerprint(a), self.fingerprint(b))

    def test_workload_checker_and_class_are_part_of_it(self):
        a = self.fingerprint(self.filed(invalid(), "--workload retry"))
        b = self.fingerprint(self.filed(invalid(), "--workload bank"))
        c = self.fingerprint(self.filed(invalid(name="applied-lie"), "--workload retry"))
        d = self.fingerprint(self.filed(invalid(checker="bank"), "--workload retry"))
        self.assertEqual(len({a, b, c, d}), 4)

    def test_the_canary_has_its_own_fingerprints(self):
        store = Store(self)
        store.test("1", invalid())
        normal, _, _ = night(self, store)
        canary, _, _ = night(self, store, canary=True)
        self.assertNotEqual(self.fingerprint(normal.opened[0][2]),
                            self.fingerprint(canary.opened[0][2]))

    def test_the_body_names_the_command_without_machine_options(self):
        body = self.filed(invalid(), "--workload retry --nodes 10.0.0.1 --seed 9")
        self.assertIn("--workload retry", body)
        self.assertNotIn("10.0.0.1", body)


class Dedup(unittest.TestCase):
    def test_a_known_failure_gets_one_comment_per_commit(self):
        store = Store(self)
        store.test("1", invalid())
        github, state, _ = night(self, store)
        self.assertEqual(len(github.opened), 1)
        github, state, summary = night(self, store, github, state, commit=OTHER, now=NOW + DAY)
        self.assertEqual(len(github.opened), 1)
        self.assertEqual(summary["commented"], 1)
        github, state, summary = night(self, store, github, state, commit=OTHER, now=NOW + DAY)
        self.assertEqual(summary["commented"], 0)
        self.assertEqual(len(github.comments), 1)

    def test_comments_per_failure_per_day_are_capped(self):
        store = Store(self)
        store.test("1", invalid())
        github, state, _ = night(self, store)
        total = 0
        for i in range(rep.COMMENTS_PER_FAILURE_PER_DAY + 3):
            commit = f"{i + 1:040x}"
            github, state, summary = night(self, store, github, state, commit=commit)
            total += summary["commented"]
        self.assertEqual(total, rep.COMMENTS_PER_FAILURE_PER_DAY)

    def test_the_markers_rebuild_a_missing_state(self):
        store = Store(self)
        store.test("1", invalid())
        first, _, _ = night(self, store)
        marker = rep.MARKER.search(first.opened[0][2]).group(1)
        state = rep.new_state()
        rep.remember(state, marker, 101, "", "")
        github, _, summary = night(self, store, state=state)
        self.assertEqual(github.opened, [])
        self.assertEqual(summary["commented"], 1)

    def test_a_deleted_issue_is_filed_again(self):
        store = Store(self)
        store.test("1", invalid())
        github, state, _ = night(self, store)
        github.fail[("comment", 101)] = rep.GitHubError("gone", "HTTP 404")
        github, state, summary = night(self, store, github, state, commit=OTHER)
        self.assertEqual(summary["dropped"], 1)
        self.assertEqual(len(github.opened), 2)

    def test_the_tracker_gets_one_line_a_day(self):
        store = Store(self)
        store.test("1", VALID)
        github, state, summary = night(self, store, tracker=7)
        self.assertTrue(summary["tracker"])
        github, state, summary = night(self, store, github, state, tracker=7)
        self.assertFalse(summary["tracker"])
        self.assertEqual([n for n, _ in github.comments], [7])


class Caps(unittest.TestCase):
    def test_distinct_failures_are_capped_per_day(self):
        store = Store(self)
        count = rep.FAILURES_PER_DAY + 4
        for i in range(count):
            store.test(str(i), invalid(name=f"f{i}"), args="--workload retry")
        github, _, summary = night(self, store)
        self.assertEqual(summary["filed"], rep.FAILURES_PER_DAY)
        self.assertEqual(summary["throttled"], 4)

    def test_a_rate_limit_stops_the_writes(self):
        store = Store(self)
        store.test("1", invalid())
        github = Recorder(fail={"status": rep.GitHubError("limited", "HTTP 429")})
        github, _, summary = night(self, store, github)
        self.assertEqual(summary["stopped"], "limited")
        self.assertEqual(github.opened, [])


class Bounds(unittest.TestCase):
    def big_history(self, lines):
        return [f'{{:index {i}, :type :ok, :key "aaaa", :f :pay, :value "{"x" * 400}"}}'
                for i in range(lines)]

    def test_the_issue_is_bounded_and_the_excerpt_keeps_the_anomaly(self):
        store = Store(self)
        history = self.big_history(2000)
        history[1000] = '{:index 1000, :type :ok, :key "needle", :f :pay}'
        store.test("1", invalid(keys=("needle",)), history=history)
        github, _, _ = night(self, store)
        body = github.opened[0][2]
        self.assertLessEqual(len(body.encode()), rep.BODY_BYTES_MAX)
        self.assertIn('"needle"', body)
        excerpt = body[body.index("History"):] if "History" in body else body
        self.assertLessEqual(len(excerpt.encode()), rep.HISTORY_BYTES_ISSUE + 8 * 1024)

    def test_many_anomalies_still_fit(self):
        store = Store(self)
        keys = tuple(f"{i:032x}" for i in range(500))
        store.test("1", invalid(keys=keys), history=self.big_history(3000))
        github, _, _ = night(self, store)
        self.assertLessEqual(len(github.opened[0][2].encode()), rep.BODY_BYTES_MAX)

    def test_a_long_results_file_is_cut_to_the_verdict_budget(self):
        store = Store(self)
        store.test("1", invalid(extra=", :pad \"" + "p" * 100_000 + "\""))
        github, _, _ = night(self, store)
        self.assertLessEqual(len(github.opened[0][2].encode()), rep.BODY_BYTES_MAX)


class Files(unittest.TestCase):
    def test_a_bad_state_file_is_an_error_not_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "state.json")
            Path(path).write_text("{nope")
            with self.assertRaises(rep.Environment):
                rep.load_state(path)
            self.assertIsNone(rep.load_state(os.path.join(tmp, "missing.json")))

    def test_the_state_round_trips(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "state.json")
            state = rep.new_state()
            rep.remember(state, "a" * 32, 5, COMMIT, COMMIT)
            rep.save_state(path, state)
            self.assertEqual(rep.load_state(path), state)

    def test_a_malformed_runs_file_refuses_the_night(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "runs")
            Path(path).write_text("x y z\n")
            with self.assertRaises(rep.BadInput):
                rep.read_runs_file(path)

    def test_main_dry_run_prints_and_never_needs_a_token(self):
        store = Store(self)
        store.test("1", invalid())
        store.write_runs()
        with tempfile.TemporaryDirectory() as tmp:
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = rep.main(["ingest", "--dry-run", "--store", store.path, "--commit",
                                 COMMIT, "--state", os.path.join(tmp, "s.json")], now=NOW)
        self.assertEqual(code, 0)
        self.assertIn("would open issue", out.getvalue())

    def test_main_refuses_a_live_run_without_a_token_file(self):
        store = Store(self)
        store.test("1", VALID)
        with contextlib.redirect_stderr(io.StringIO()):
            code = rep.main(["ingest", "--store", store.path, "--commit", COMMIT,
                             "--state", "/nonexistent/s.json"], now=NOW)
        self.assertEqual(code, 1)

    def test_the_token_is_never_in_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "token")
            Path(path).write_text("two words\n")
            with self.assertRaises(rep.Environment) as caught:
                rep.read_token(path)
            self.assertNotIn("two", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
