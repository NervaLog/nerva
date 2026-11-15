#!/usr/bin/env python3
"""Tests for repos_alarm.sh (docs/releases/packages.md, "Alarms"; NRV-W1103). Run from the repository
root: python3 -I .github/scripts/test_repos_alarm.py

A stand-in `gh` (a Python script that keeps issues and comments in a directory and logs every call)
stands for GitHub's REST API; the real jq filters its answers."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "repos_alarm.sh"
REPO = "NervaLog/nerva"
TOKEN = "ghp_FAKE_TOKEN_0123456789"
RUN = "https://github.com/NervaLog/nerva/actions/runs/42"
NOW = 1_800_000_000

GH = """#!/usr/bin/env python3
import json, os, subprocess, sys
d = os.environ["GH_DIR"]
args = sys.argv[1:]
with open(d + "/log", "a") as f:
    f.write(json.dumps(args) + "\\n")
assert args[0] == "api"
method, path, jq, fields = "GET", None, None, {}
i = 1
while i < len(args):
    a = args[i]
    if a == "-X":
        i += 1
        method = args[i]
    elif a == "--jq":
        i += 1
        jq = args[i]
    elif a == "-f":
        i += 1
        k, _, v = args[i].partition("=")
        fields.setdefault(k, []).append(v)
    else:
        path = a
    i += 1
for f in (open(d + "/fail").read().split() if os.path.exists(d + "/fail") else []):
    if f in method + " " + path:
        sys.stderr.write("gh: HTTP 422 Validation Failed\\n" if "POST" in f else "gh: HTTP 502\\n")
        sys.exit(1)
st = json.load(open(d + "/state.json"))
now = int(os.environ["REPOS_ALARM_NOW"])
iso = lambda t: __import__("time").strftime("%Y-%m-%dT%H:%M:%SZ", __import__("time").gmtime(t))
route, _, query = path.partition("?")
parts = route.split("/")  # repos OWNER REPO issues [N comments]
out = None
if method == "GET" and parts[3:] == ["issues"]:
    q = dict(x.split("=", 1) for x in query.split("&") if "=" in x)
    out = [i for i in st["issues"] if i["state"] == "open" and "package-repos" in i["labels"]]
    out.sort(key=lambda i: i["number"], reverse=q.get("direction", "desc") == "desc")
    out = out[:int(q.get("per_page", 30))]
    out = [{k: v for k, v in i.items() if k in ("number", "pull_request")} for i in out]
elif method == "GET" and parts[5:] == ["comments"]:
    out = [c for c in st["comments"] if c["issue"] == int(parts[4])]
elif method == "POST" and parts[3:] == ["issues"]:
    n = len(st["issues"]) + 1
    st["issues"].append({"number": n, "state": "open", "title": fields["title"][0], "body": fields["body"][0],
                         "labels": fields.get("labels[]", []), "assignees": fields.get("assignees[]", [])})
    out = {"number": n}
elif method == "POST" and parts[5:] == ["comments"]:
    st["comments"].append({"issue": int(parts[4]), "body": fields["body"][0], "created_at": iso(now),
                          "user": {"login": "github-actions[bot]"}})
    out = {}
else:
    sys.stderr.write("gh: unexpected " + method + " " + path + "\\n")
    sys.exit(2)
json.dump(st, open(d + "/state.json", "w"))
if jq:
    sys.stdout.write(subprocess.run(["jq", "-r", jq], input=json.dumps(out), check=True, capture_output=True,
                                    text=True).stdout)
"""


class Alarm(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pra", dir="/tmp"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        (self.tmp / "bin").mkdir()
        (self.tmp / "bin/gh").write_text(GH)
        (self.tmp / "bin/gh").chmod(0o755)
        self.state({"issues": [], "comments": []})

    def state(self, st=None):
        if st is not None:
            (self.tmp / "state.json").write_text(json.dumps(st))
        return json.loads((self.tmp / "state.json").read_text())

    def fail(self, *what):
        (self.tmp / "fail").write_text(" ".join(what))

    def log(self):
        p = self.tmp / "log"
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def alarm(self, workflow="release-finish.yml", job="repos", code="NRV-E1142", url=RUN, at=NOW, owner="topwombat",
              **extra):
        env = {"PATH": f"{self.tmp}/bin:" + os.environ["PATH"], "HOME": str(self.tmp), "GH_TOKEN": TOKEN,
               "GITHUB_REPOSITORY": REPO, "GH_DIR": str(self.tmp), "REPOS_ALARM_NOW": str(at)}
        if owner is not None:
            env["PACKAGE_REPOS_OWNER"] = owner
        env.update(extra)
        p = subprocess.run(["bash", str(SCRIPT), workflow, job, code, url], env=env, capture_output=True, text=True,
                           timeout=60)
        self.assertNotIn(TOKEN, p.stdout + p.stderr)
        self.assertNotIn(TOKEN, json.dumps(self.log()))
        return p

    def test_none_open_opens_one_labelled_assigned_to_the_owner(self):
        p = self.alarm()
        self.assertEqual(p.returncode, 0, p.stderr)
        (issue,) = self.state()["issues"]
        self.assertEqual(issue["title"], "Package repositories: `release-finish.yml` failed (`NRV-E1142`)")
        self.assertEqual(issue["labels"], ["package-repos"])
        self.assertEqual(issue["assignees"], ["topwombat"])
        self.assertIn(f"`release-finish.yml` / `repos` failed with `NRV-E1142`: {RUN}", issue["body"])
        self.assertIn("Recovery", issue["body"])
        self.assertEqual(self.state()["comments"], [])

    def test_an_open_issue_gets_a_comment_and_no_second_issue_is_opened(self):
        self.alarm()
        p = self.alarm(workflow="ci.yml", job="repos-fresh", code="NRV-E1150")
        self.assertEqual(p.returncode, 0, p.stderr)
        st = self.state()
        self.assertEqual(len(st["issues"]), 1)
        self.assertEqual([c["body"] for c in st["comments"]],
                         [f"`ci.yml` / `repos-fresh` failed with `NRV-E1150`: {RUN}"])

    def test_one_comment_per_workflow_job_and_code_per_day(self):
        self.alarm()
        self.alarm(code="NRV-E1145")  # the first comment, on the open issue
        self.assertEqual(len(self.state()["comments"]), 1)
        again = self.alarm(code="NRV-E1145", at=NOW + 3600, url=RUN + "3")
        self.assertEqual(again.returncode, 0)
        self.assertEqual(len(self.state()["comments"]), 1, "the same triple within a day adds nothing")
        self.alarm(code="NRV-E1142", at=NOW + 3600)
        self.assertEqual(len(self.state()["comments"]), 2, "another code is another comment")
        self.alarm(job="repos-ready", code="NRV-E1145", at=NOW + 3600)
        self.assertEqual(len(self.state()["comments"]), 3, "another job is another comment")
        self.alarm(workflow="package-repos-refresh.yml", code="NRV-E1145", at=NOW + 3600)
        self.assertEqual(len(self.state()["comments"]), 4, "another workflow is another comment")

    def test_the_same_triple_after_a_day_is_commented_again(self):
        self.alarm()
        self.alarm(code="NRV-E1145")
        self.alarm(code="NRV-E1145", at=NOW + 86400 + 60)
        self.assertEqual(len(self.state()["comments"]), 2)

    def test_a_comment_of_another_triple_does_not_hide_this_one(self):
        # `NRV-E1142` is a prefix of nothing else, but `unknown` and `unknown2` must stay apart
        self.alarm()
        self.alarm(code="unknown")
        self.alarm(code="unknown2")
        self.assertEqual(len(self.state()["comments"]), 2)

    def test_a_pull_request_with_the_label_is_not_the_alarm_issue(self):
        self.state({"issues": [{"number": 1, "state": "open", "labels": ["package-repos"], "title": "pr",
                                "body": "", "assignees": [], "pull_request": {}}], "comments": []})
        self.alarm()
        self.assertEqual(len(self.state()["issues"]), 2)
        self.assertEqual(self.state()["comments"], [])

    def test_a_newer_pull_request_with_the_label_does_not_hide_the_open_issue(self):
        self.alarm()
        st = self.state()
        st["issues"].append({"number": 2, "state": "open", "labels": ["package-repos"], "title": "pr",
                             "body": "", "assignees": [], "pull_request": {}})
        self.state(st)
        self.alarm(code="NRV-E1145")
        st = self.state()
        self.assertEqual(len(st["issues"]), 2, "no second alarm issue")
        self.assertEqual([c["issue"] for c in st["comments"]], [1])

    def test_a_comment_by_anyone_else_does_not_suppress_the_alarm(self):
        self.alarm()
        st = self.state()
        st["comments"].append({"issue": 1, "body": f"`release-finish.yml` / `repos` failed with `NRV-E1145`: x",
                               "created_at": "2027-01-15T08:00:00Z", "user": {"login": "someone"}})
        self.state(st)
        self.alarm(code="NRV-E1145")
        self.assertEqual(len(self.state()["comments"]), 2, "the alarm is commented although a stranger wrote its line")

    def test_a_closed_issue_is_not_commented_on(self):
        self.state({"issues": [{"number": 1, "state": "closed", "labels": ["package-repos"], "title": "old",
                                "body": "", "assignees": []}], "comments": []})
        self.alarm()
        self.assertEqual(len(self.state()["issues"]), 2)

    def test_the_alarm_test_and_missed_and_cancelled_are_codes_too(self):
        for code in ("alarm-test", "missed", "cancelled", "unknown"):
            p = self.alarm(job=f"j-{code}", code=code)
            self.assertEqual(p.returncode, 0, p.stderr)
        text = json.dumps(self.state())
        for code in ("alarm-test", "missed", "cancelled", "unknown"):
            self.assertIn(f"failed with `{code}`", text)

    def test_a_code_that_is_not_a_plain_word_is_not_trusted_into_the_issue(self):
        p = self.alarm(code="x`\n@everyone [click](http://evil)")
        self.assertEqual(p.returncode, 0, p.stderr)
        (issue,) = self.state()["issues"]
        self.assertIn("failed with `unknown`", issue["body"])
        self.assertNotIn("evil", json.dumps(issue))

    def test_without_an_owner_the_issue_is_opened_unassigned(self):
        p = self.alarm(owner=None)
        self.assertEqual(p.returncode, 0, p.stderr)
        (issue,) = self.state()["issues"]
        self.assertEqual(issue["assignees"], [])

    def test_only_rest_calls_and_the_token_only_in_the_environment(self):
        self.alarm()
        self.alarm(code="NRV-E1145")
        for call in self.log():
            self.assertEqual(call[0], "api")
            self.assertTrue(call[1].startswith(("repos/", "-X")), call)
            self.assertNotIn("graphql", json.dumps(call))

    def test_a_github_failure_is_w1103_and_never_a_failed_step(self):
        for what in ("GET repos/NervaLog/nerva/issues?", "POST repos/NervaLog/nerva/issues"):
            self.state({"issues": [], "comments": []})
            self.fail(what)
            p = self.alarm()
            self.assertEqual(p.returncode, 0, what)
            self.assertIn("warning[NRV-W1103]: repos_alarm.sh: the alarm could not be filed", p.stderr)
            self.assertIn("  cause  ", p.stderr)
            self.assertIn("  fix    ", p.stderr)
            self.assertEqual(self.state()["issues"], [])

    def test_a_failed_comment_and_a_failed_comment_read_are_w1103(self):
        self.alarm()
        for what in ("POST repos/NervaLog/nerva/issues/1/comments", "GET repos/NervaLog/nerva/issues/1/comments"):
            self.fail(what)
            p = self.alarm(code="NRV-E1145")
            self.assertEqual(p.returncode, 0, what)
            self.assertIn("warning[NRV-W1103]", p.stderr)
        self.assertEqual(self.state()["comments"], [])

    def test_a_missing_label_is_w1103(self):
        self.fail("POST repos/NervaLog/nerva/issues")
        p = self.alarm()
        self.assertEqual(p.returncode, 0)
        self.assertIn("the label package-repos exists", p.stderr)

    def test_bad_arguments_are_a_usage_error(self):
        for args in (("a", "b", "NRV-E1142"), ("a b", "j", "c", RUN), ("w", "j", "c", "not a url")):
            p = subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True,
                               env={"PATH": os.environ["PATH"], "GITHUB_REPOSITORY": REPO})
            self.assertEqual(p.returncode, 64, args)


if __name__ == "__main__":
    unittest.main()
