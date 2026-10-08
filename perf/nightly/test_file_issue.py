#!/usr/bin/env python3
"""Tests for file_issue.py, without network (a fake stands in for `gh`):
python3 perf/nightly/test_file_issue.py"""

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare  # noqa: E402
import file_issue  # noqa: E402

BASE = "b" * 40
CAND = "c" * 40
URL = "https://github.com/Botpike/nerva-ledger/actions/runs/"


def line(role, round_, kind, result, commit=None):
    commit = commit or (BASE if role == "baseline" else CAND)
    return json.dumps({"role": role, "commit": commit, "round": round_, "kind": kind, "result": result})


def night(ops=1000, p99=5000, encode=100, base=BASE, error=False):
    """A verdict from compare.py: the baseline at 1000 ops/s, p99 5000 µs, encode 100 ns."""
    lines = []
    for r in (1, 2, 3):
        for role, (o, p, e) in (("baseline", (1000, 5000, 100)), ("candidate", (ops, p99, encode))):
            commit = base if role == "baseline" else CAND
            lines.append(line(role, r, "load", {"key": "c4/b1", "operations_per_s": o,
                                                "latency_us": {"p50": 1000, "p99": p}}, commit))
            lines.append(line(role, r, "micro", {"name": "documents.encode_ns_per_document",
                                                 "value": e, "unit": "ns"}, commit))
    if error:
        lines.append(line("candidate", 1, "error", {"key": "c7", "error": "timeout"}))
    verdict = compare.compare(lines)
    return verdict, compare.summary(verdict)


class FakeGh:
    """Issues in memory; records every call, writes included."""

    def __init__(self, issues=()):
        self.store = [dict(issue, comments=list(issue.get("comments", []))) for issue in issues]
        self.calls = []

    def issues(self):
        self.calls.append(("list",))
        return json.loads(json.dumps(self.store))

    def find(self, number):
        return next(issue for issue in self.store if issue["number"] == number)

    def ensure_label(self):
        self.calls.append(("label",))

    def create(self, title, body):
        number = max([issue["number"] for issue in self.store] + [100]) + 1
        self.store.append({"number": number, "state": "OPEN", "title": title, "body": body, "comments": []})
        self.calls.append(("create", number))
        return number

    def comment(self, number, body):
        self.find(number)["comments"].append({"body": body})
        self.calls.append(("comment", number))

    def reopen(self, number):
        self.find(number)["state"] = "OPEN"
        self.calls.append(("reopen", number))

    def close(self, number):
        self.find(number)["state"] = "CLOSED"
        self.calls.append(("close", number))

    def writes(self):
        return [call for call in self.calls if call[0] != "list"]


def sync(gh, verdict_summary, run_id, **kwargs):
    verdict, summary = verdict_summary
    out = io.StringIO()
    with redirect_stdout(out):
        results = file_issue.sync(verdict, summary, gh, run_id, URL + run_id, **kwargs)
    return results, out.getvalue()


class Fingerprints(unittest.TestCase):
    def test_slug_keeps_only_safe_characters(self):
        self.assertEqual(file_issue.slug("load c4/b1 p99 µs"), "load-c4-b1-p99-us")
        self.assertEqual(file_issue.slug("load c4/b1 ops/s"), "load-c4-b1-ops-s")
        self.assertEqual(file_issue.slug("micro documents.encode_ns_per_document"),
                         "micro-documents.encode_ns_per_document")

    def test_one_fingerprint_per_failing_metric_with_the_baseline(self):
        verdict, _ = night(ops=800, p99=8000)  # ops/s 20% worse, p99 60% worse: both fail
        self.assertEqual(file_issue.fingerprints(verdict),
                         ["load-c4-b1-ops-s:" + BASE[:12], "load-c4-b1-p99-us:" + BASE[:12]])

    def test_errors_and_forced_failures_have_fingerprints(self):
        verdict, _ = night(error=True)
        self.assertEqual(file_issue.fingerprints(verdict), ["errors:" + BASE[:12]])
        verdict, _ = night()
        self.assertEqual(file_issue.fingerprints(verdict), ["overall:" + BASE[:12]])

    def test_fingerprints_match_the_marker_pattern(self):
        verdict, _ = night(ops=800, p99=8000, encode=200)
        for fp in file_issue.fingerprints(verdict):
            self.assertRegex(f"<!-- nerva-perf:fingerprint={fp} -->", file_issue.FINGERPRINT)


class Sync(unittest.TestCase):
    def test_first_failing_night_opens_one_issue_with_its_fingerprints(self):
        gh = FakeGh()
        results, _ = sync(gh, night(ops=800, p99=8000), "1")
        self.assertEqual(results, [("created", 101)])
        self.assertEqual(gh.writes(), [("label",), ("create", 101)])
        issue = gh.find(101)
        self.assertEqual(issue["title"], "Performance regression at " + CAND[:12])
        self.assertEqual(file_issue.markers(issue), (
            {"load-c4-b1-ops-s:" + BASE[:12], "load-c4-b1-p99-us:" + BASE[:12]}, {"1"}))
        self.assertIn("| fail | load c4/b1 ops/s |", issue["body"])
        self.assertIn(URL + "1", issue["body"])

    def test_two_failing_nights_make_one_issue_with_one_comment(self):
        gh = FakeGh()
        sync(gh, night(ops=800), "1")
        results, _ = sync(gh, night(ops=700), "2")
        self.assertEqual(results, [("commented", 101)])
        self.assertEqual(len(gh.store), 1)
        comments = gh.find(101)["comments"]
        self.assertEqual(len(comments), 1)
        self.assertIn("Failing again.", comments[0]["body"])
        self.assertIn(URL + "2", comments[0]["body"])
        self.assertIn("| fail | load c4/b1 ops/s | 1000 | 700 |", comments[0]["body"])  # the night's numbers

    def test_the_same_run_twice_changes_nothing(self):
        gh = FakeGh()
        sync(gh, night(ops=800), "1")
        sync(gh, night(ops=800), "2")
        before = list(gh.writes())
        results, _ = sync(gh, night(ops=800), "2")
        self.assertEqual(results, [("unchanged", 101)])
        self.assertEqual(gh.writes(), before)

    def test_a_closed_issue_is_reopened_by_its_fingerprint(self):
        gh = FakeGh()
        sync(gh, night(ops=800), "1")
        gh.find(101)["state"] = "CLOSED"
        results, _ = sync(gh, night(ops=800), "2")
        self.assertEqual(results, [("reopened", 101)])
        self.assertEqual(gh.writes()[-2:], [("reopen", 101), ("comment", 101)])
        self.assertEqual(gh.find(101)["state"], "OPEN")
        self.assertIn("so it is reopened", gh.find(101)["comments"][-1]["body"])

    def test_one_shared_fingerprint_is_enough_and_new_ones_are_recorded(self):
        gh = FakeGh()
        sync(gh, night(ops=800), "1")  # ops/s only
        results, _ = sync(gh, night(ops=800, p99=8000), "2")  # ops/s and p99
        self.assertEqual(results, [("commented", 101)])
        self.assertIn("load-c4-b1-p99-us:" + BASE[:12], file_issue.markers(gh.find(101))[0])
        results, _ = sync(gh, night(p99=8000), "3")  # p99 alone now finds the same issue
        self.assertEqual(results, [("commented", 101)])
        self.assertEqual(len(gh.store), 1)

    def test_an_open_issue_wins_over_a_closed_one(self):
        gh = FakeGh()
        sync(gh, night(ops=800), "1")
        gh.find(101)["state"] = "CLOSED"
        sync(gh, night(ops=800, p99=8000), "2")  # reopens 101
        gh.store.append({"number": 90, "state": "OPEN", "title": "older", "comments": [],
                         "body": "<!-- nerva-perf:fingerprint=load-c4-b1-ops-s:" + BASE[:12] + " -->"})
        gh.find(101)["state"] = "CLOSED"
        results, _ = sync(gh, night(ops=800), "3")
        self.assertEqual(results, [("commented", 90)])

    def test_another_baseline_is_another_regression(self):
        gh = FakeGh()
        sync(gh, night(ops=800), "1")
        results, _ = sync(gh, night(ops=800, base="d" * 40), "2")
        self.assertEqual(results, [("created", 102)])

    def test_a_passing_night_closes_every_open_issue_as_recovered(self):
        gh = FakeGh([
            {"number": 7, "state": "OPEN", "title": "Performance regression at old", "body": "no marker"},
            {"number": 8, "state": "CLOSED", "title": "closed", "body": ""},
        ])
        sync(gh, night(ops=800), "1")
        results, _ = sync(gh, night(), "2")
        self.assertEqual(results, [("closed", 7), ("closed", 101)])
        self.assertEqual(gh.writes()[-4:], [("comment", 7), ("close", 7), ("comment", 101), ("close", 101)])
        recovered = gh.find(101)["comments"][-1]["body"]
        self.assertIn("Recovered", recovered)
        self.assertIn(URL + "2", recovered)
        self.assertEqual(gh.find(8)["comments"], [])

    def test_a_passing_night_with_nothing_open_changes_nothing(self):
        gh = FakeGh([{"number": 8, "state": "CLOSED", "title": "closed", "body": ""}])
        results, out = sync(gh, night(), "1")
        self.assertEqual(results, [])
        self.assertEqual(gh.writes(), [])
        self.assertIn("no perf-regression issue is open", out)

    def test_warn_and_no_comparison_leave_issues_alone(self):
        gh = FakeGh([{"number": 7, "state": "OPEN", "title": "open", "body": ""}])
        verdict, summary = night()
        for overall in ("warn", "no-comparison"):
            results, _ = sync(gh, (dict(verdict, overall=overall), summary), "1")
            self.assertEqual(results, [])
        self.assertEqual(gh.calls, [])

    def test_forced_fail_on_a_clean_night_files_an_overall_issue_then_comments(self):
        gh = FakeGh()
        sync(gh, night(), "1", overall="fail")
        results, _ = sync(gh, night(), "2", overall="fail")
        self.assertEqual(results, [("commented", 101)])
        self.assertEqual(file_issue.markers(gh.find(101))[0], {"overall:" + BASE[:12]})

    def test_dry_run_reads_but_never_writes(self):
        gh = FakeGh()
        results, out = sync(gh, night(ops=800), "1", dry_run=True)
        self.assertEqual(results, [("created", None)])
        self.assertEqual(gh.writes(), [])
        self.assertIn("would be created", out)
        self.assertIn("<!-- nerva-perf:fingerprint=load-c4-b1-ops-s:" + BASE[:12] + " -->", out)
        gh = FakeGh([{"number": 7, "state": "OPEN", "title": "open", "body": ""}])
        results, out = sync(gh, night(), "2", dry_run=True)
        self.assertEqual(results, [("closed", 7)])
        self.assertEqual(gh.writes(), [])
        self.assertIn("would be closed", out)


class RealGh(unittest.TestCase):
    """The `gh` command lines, with subprocess.run stubbed."""

    def run_gh(self, method, *args, stdout="", returncode=0):
        with mock.patch.object(file_issue.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], returncode, stdout, "boom")
            result = getattr(file_issue.Gh("Botpike/nerva-ledger"), method)(*args)
        return result, run.call_args

    def test_create_posts_the_body_on_stdin_and_returns_the_number(self):
        number, call = self.run_gh("create", "T", "body",
                                   stdout="https://github.com/Botpike/nerva-ledger/issues/123\n")
        self.assertEqual(number, 123)
        self.assertEqual(call.args[0], ["gh", "issue", "create", "--title", "T", "--label", "perf-regression",
                                        "--body-file", "-", "--repo", "Botpike/nerva-ledger"])
        self.assertEqual(call.kwargs["input"], "body")

    def test_issues_reads_every_state_and_the_comments_with_rest(self):
        pages = {
            "repos/Botpike/nerva-ledger/issues?labels=perf-regression&state=all&per_page=100":
                [[{"number": 1, "state": "open", "body": "a", "comments": 2}],
                 [{"number": 2, "state": "closed", "body": "b", "comments": 0},
                  {"number": 3, "state": "open", "body": "pr", "pull_request": {}}]],
            "repos/Botpike/nerva-ledger/issues/1/comments?per_page=100": [[{"body": "c1"}], [{"body": "c2"}]],
        }

        def run(command, **kwargs):
            self.assertEqual(command[:4], ["gh", "api", "--paginate", "--slurp"])
            self.assertNotIn("--repo", command)
            return subprocess.CompletedProcess(command, 0, json.dumps(pages[command[4]]), "")

        with mock.patch.object(file_issue.subprocess, "run", side_effect=run):
            issues = file_issue.Gh("Botpike/nerva-ledger").issues()
        self.assertEqual([issue["number"] for issue in issues], [1, 2])
        self.assertEqual(issues[0]["comments"], [{"body": "c1"}, {"body": "c2"}])
        self.assertEqual(issues[1]["comments"], [])

    def test_close_marks_completed(self):
        _, call = self.run_gh("close", 5)
        self.assertEqual(call.args[0][:6], ["gh", "issue", "close", "5", "--reason", "completed"])

    def test_a_failing_gh_stops_the_script(self):
        with self.assertRaises(SystemExit) as stopped:
            self.run_gh("comment", 5, "x", returncode=1)
        self.assertIn("boom", str(stopped.exception))


class Main(unittest.TestCase):
    def test_main_reads_the_files_and_honours_dry_run(self):
        verdict, summary = night(ops=800)
        with tempfile.TemporaryDirectory() as directory:
            paths = {}
            for name, content in (("verdict.json", json.dumps(verdict)), ("summary.md", summary)):
                paths[name] = os.path.join(directory, name)
                with open(paths[name], "w") as file:
                    file.write(content)
            fake = FakeGh()
            out = io.StringIO()
            with mock.patch.object(file_issue, "Gh", return_value=fake), redirect_stdout(out):
                file_issue.main(["--verdict", paths["verdict.json"], "--summary", paths["summary.md"],
                                 "--run-id", "42", "--run-url", URL + "42", "--dry-run"])
        self.assertEqual(fake.writes(), [])
        self.assertIn("would be created", out.getvalue())

    def test_main_refuses_a_run_id_the_marker_cannot_hold(self):
        with self.assertRaises(SystemExit), redirect_stdout(io.StringIO()), \
                mock.patch("sys.stderr", io.StringIO()):
            file_issue.main(["--verdict", "v", "--summary", "s", "--run-id", "4 2", "--run-url", "u"])


if __name__ == "__main__":
    unittest.main()
