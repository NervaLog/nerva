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


def night(ops=1000, p99=5000, encode=100, base=BASE, error=False, ops_round3=None):
    """A verdict from compare.py: the baseline at 1000 ops/s, p99 5000 µs, encode 100 ns.
    `ops_round3` replaces the candidate's ops/s in the third round only."""
    lines = []
    for r in (1, 2, 3):
        o3 = ops if r < 3 or ops_round3 is None else ops_round3
        for role, (o, p, e) in (("baseline", (1000, 5000, 100)), ("candidate", (o3, p99, encode))):
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
        results, gh.open_after = file_issue.sync(verdict, summary, gh, run_id, URL + run_id, **kwargs)
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

    def test_a_closed_issue_against_another_baseline_is_another_regression(self):
        gh = FakeGh()
        sync(gh, night(ops=800), "1")
        gh.find(101)["state"] = "CLOSED"
        results, _ = sync(gh, night(ops=800, base="d" * 40), "2")
        self.assertEqual(results, [("created", 102)])

    def test_an_open_issue_is_found_by_its_metric_whatever_the_baseline(self):
        gh = FakeGh()
        sync(gh, night(ops=800), "1")
        results, _ = sync(gh, night(ops=800, base="d" * 40), "2")
        self.assertEqual(results, [("commented", 101)])
        self.assertIn("load-c4-b1-ops-s:" + "d" * 12, file_issue.markers(gh.find(101))[0])

    def test_an_old_format_fingerprint_still_matches(self):
        # Filed under P121, against a baseline the workflow has since moved past.
        old = {"number": 50, "state": "OPEN", "title": "Performance regression at old", "comments": [],
               "body": "<!-- nerva-perf:fingerprint=load-c4-b1-ops-s:0123456789ab -->\n"
                       "<!-- nerva-perf:run=1 -->\nold table"}
        gh = FakeGh([old])
        results, _ = sync(gh, night(ops=800), "2")
        self.assertEqual(results, [("commented", 50)])
        self.assertEqual(len(gh.store), 1)
        self.assertEqual(file_issue.metric("load-c4-b1-ops-s:0123456789ab"), "load-c4-b1-ops-s")
        # A closed one is still reopened by the exact fingerprint it carries.
        gh = FakeGh([dict(old, state="CLOSED")])
        verdict, summary = night(ops=800)
        verdict["commits"]["baseline"] = "0123456789ab" + "0" * 28
        results, _ = sync(gh, (verdict, summary), "3")
        self.assertEqual(results, [("reopened", 50)])

    def test_a_passing_night_closes_every_open_fingerprinted_issue_as_recovered(self):
        gh = FakeGh([
            {"number": 8, "state": "CLOSED", "title": "closed", "body": ""},
        ])
        sync(gh, night(ops=800), "1")
        sync(gh, night(p99=8000, base="d" * 40), "2")  # another metric, so another issue: 102
        results, _ = sync(gh, night(), "3")
        self.assertEqual(results, [("closed", 101), ("closed", 102)])
        self.assertEqual(gh.writes()[-4:], [("comment", 101), ("close", 101), ("comment", 102), ("close", 102)])
        recovered = gh.find(101)["comments"][-1]["body"]
        self.assertIn("Recovered", recovered)
        self.assertIn(URL + "3", recovered)
        self.assertEqual(gh.find(8)["comments"], [])
        self.assertFalse(gh.open_after)

    def test_a_passing_night_leaves_a_hand_filed_issue_open(self):
        gh = FakeGh([{"number": 7, "state": "OPEN", "title": "Encode looks slow", "body": "filed by hand"}])
        sync(gh, night(ops=800), "1")
        results, _ = sync(gh, night(), "2")
        self.assertEqual(results, [("closed", 101)])
        self.assertEqual(gh.find(7)["state"], "OPEN")
        self.assertEqual(gh.find(7)["comments"], [])
        self.assertFalse(gh.open_after)  # a hand-filed issue does not hold the baseline
        results, out = sync(gh, night(), "3")
        self.assertEqual(results, [])
        self.assertIn("no perf-regression issue with a fingerprint is open", out)

    def test_a_passing_night_with_nothing_open_changes_nothing(self):
        gh = FakeGh([{"number": 8, "state": "CLOSED", "title": "closed", "body": ""}])
        results, out = sync(gh, night(), "1")
        self.assertEqual(results, [])
        self.assertEqual(gh.writes(), [])
        self.assertIn("no perf-regression issue with a fingerprint is open", out)

    def test_warn_and_no_comparison_leave_issues_alone(self):
        gh = FakeGh([{"number": 7, "state": "OPEN", "title": "open", "body": ""}])
        verdict, summary = night()
        for overall in ("warn", "no-comparison"):
            results, _ = sync(gh, (dict(verdict, overall=overall), summary), "1")
            self.assertEqual(results, [])
            self.assertFalse(gh.open_after)  # issue 7 has no fingerprint
        self.assertEqual(gh.writes(), [])

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
        gh = FakeGh([{"number": 7, "state": "OPEN", "title": "open",
                      "body": "<!-- nerva-perf:fingerprint=overall:" + BASE[:12] + " -->"}])
        results, out = sync(gh, night(), "2", dry_run=True)
        self.assertEqual(results, [("closed", 7)])
        self.assertEqual(gh.writes(), [])
        self.assertIn("would be closed", out)


def warn_night(base=BASE):
    """A night that warns: ops/s 20% worse in two rounds of three (compare.py fails a metric only
    when every round is past its threshold, and warns when the median is)."""
    verdict, summary = night(ops=800, ops_round3=1000, base=base)
    assert verdict["overall"] == "warn", verdict["overall"]
    return verdict, summary


class Baseline(unittest.TestCase):
    """fail -> warn -> fail is one regression, and the warn night does not move the baseline."""

    def test_advance_baseline(self):
        self.assertFalse(file_issue.advance_baseline("fail", False))
        self.assertFalse(file_issue.advance_baseline("fail", True))
        self.assertTrue(file_issue.advance_baseline("pass", True))
        self.assertTrue(file_issue.advance_baseline("pass", False))
        for overall in ("warn", "no-comparison"):
            self.assertTrue(file_issue.advance_baseline(overall, False))
            self.assertFalse(file_issue.advance_baseline(overall, True))

    def test_fail_warn_fail_makes_one_issue_and_keeps_the_baseline(self):
        gh = FakeGh()
        baseline = BASE  # what perf-results/baseline holds; a night is measured against it
        nights = [("1", lambda base: night(ops=800, base=base), "c" * 40),
                  ("2", warn_night, "e" * 40),
                  ("3", lambda base: night(ops=800, base=base), "f" * 40)]
        for run_id, make, candidate in nights:
            verdict, summary = make(baseline)
            sync(gh, (verdict, summary), run_id)
            if file_issue.advance_baseline(verdict["overall"], gh.open_after):
                baseline = candidate
        self.assertEqual(baseline, BASE)
        self.assertEqual(len(gh.store), 1)
        self.assertEqual([call[0] for call in gh.writes()], ["label", "create", "comment"])
        self.assertEqual(file_issue.markers(gh.find(101))[0], {"load-c4-b1-ops-s:" + BASE[:12]})

    def test_a_warn_night_with_no_regression_open_moves_the_baseline(self):
        gh = FakeGh()
        verdict, summary = warn_night()
        sync(gh, (verdict, summary), "1")
        self.assertFalse(gh.open_after)
        self.assertTrue(file_issue.advance_baseline(verdict["overall"], gh.open_after))

    def test_a_forced_pass_closes_and_lets_a_warn_night_move_the_baseline(self):
        gh = FakeGh()
        sync(gh, night(ops=800), "1")
        verdict, summary = warn_night()
        sync(gh, (verdict, summary), "2", overall="pass")
        self.assertEqual(gh.find(101)["state"], "CLOSED")
        self.assertTrue(file_issue.advance_baseline(verdict["overall"], gh.open_after))

    def test_the_workflow_moves_the_baseline_as_file_issue_says(self):
        workflow = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir,
                                ".github", "workflows", "perf-nightly.yml")
        with open(workflow) as file:
            text = file.read()
        # The issue step runs first and its output reaches the record step.
        self.assertLess(text.index("id: issue"), text.index("name: Record on the perf-results branch"))
        self.assertIn("--github-output \"$GITHUB_OUTPUT\"", text)
        self.assertIn("ADVANCE: ${{ steps.issue.outputs.advance_baseline }}", text)
        condition = next(line.strip() for line in text.splitlines() if line.strip().startswith('if [ "$ADVANCE"'))
        script = condition + " echo moved; fi"
        for advance, overall, moved in (("true", "warn", True), ("false", "warn", False),
                                        ("false", "pass", False), ("", "pass", True),
                                        ("", "warn", False), ("", "fail", False)):
            result = subprocess.run(["bash", "-c", script], env={"ADVANCE": advance, "OVERALL": overall},
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip() == "moved", moved, (advance, overall))


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

    def test_main_writes_advance_baseline_to_the_github_output(self):
        fake = FakeGh()
        with tempfile.TemporaryDirectory() as directory:
            output = os.path.join(directory, "output")
            for run_id, (verdict, summary), expected in (("1", night(ops=800), "false"),
                                                         ("2", warn_night(), "false"),
                                                         ("3", night(), "true")):
                paths = {}
                for name, content in (("verdict.json", json.dumps(verdict)), ("summary.md", summary)):
                    paths[name] = os.path.join(directory, name)
                    with open(paths[name], "w") as file:
                        file.write(content)
                with mock.patch.object(file_issue, "Gh", return_value=fake), redirect_stdout(io.StringIO()):
                    file_issue.main(["--verdict", paths["verdict.json"], "--summary", paths["summary.md"],
                                     "--run-id", run_id, "--run-url", URL + run_id, "--github-output", output])
                with open(output) as file:
                    self.assertEqual(file.read().splitlines()[-1], "advance_baseline=" + expected)

    def test_main_refuses_a_run_id_the_marker_cannot_hold(self):
        with self.assertRaises(SystemExit), redirect_stdout(io.StringIO()), \
                mock.patch("sys.stderr", io.StringIO()):
            file_issue.main(["--verdict", "v", "--summary", "s", "--run-id", "4 2", "--run-url", "u"])


if __name__ == "__main__":
    unittest.main()
