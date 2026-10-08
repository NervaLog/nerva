#!/usr/bin/env python3
"""Files, updates and closes `perf-regression` issues for one nightly run (N56; the dedup is
docs/decisions/P121).

One regression gets one issue, however many nights it lasts. Each failing metric has a
fingerprint, `<metric>:<baseline commit, 12 hex>`, which the issue body (or a later comment)
carries as `<!-- nerva-perf:fingerprint=... -->`. The baseline names the regression because it
does not move while nights fail: the workflow advances it only after a night that did not fail.

  * a failing night whose fingerprints no issue carries     -> open one issue with all of them
  * a failing night sharing a fingerprint with an issue     -> comment with the night's numbers
                                                               (reopening the issue if closed)
  * a passing night                                         -> comment "recovered" on every open
                                                               perf-regression issue and close it
  * a warn or no-comparison night                           -> change nothing

Every comment carries `<!-- nerva-perf:run=<run id> -->`, so running this twice for one run
(a re-run of the job) changes nothing the second time. Usage:

    file_issue.py --verdict verdict.json --summary summary.md --run-id ID --run-url URL \
        [--overall fail|pass] [--repo owner/name] [--dry-run]

`--overall` replaces the verdict's (the workflow's forced runs); `--dry-run` reads the existing
issues, prints what it would do and the text it would post, and changes nothing. It needs the
`gh` CLI, authenticated (GH_TOKEN), for anything but a dry run with no issues to read.
"""

import argparse
import json
import re
import subprocess
import sys

LABEL = "perf-regression"
LABEL_COLOR = "B60205"
LABEL_DESCRIPTION = "Nightly performance regression"
FINGERPRINT = re.compile(r"<!-- nerva-perf:fingerprint=([A-Za-z0-9._:-]+) -->")
RUN = re.compile(r"<!-- nerva-perf:run=([A-Za-z0-9._-]+) -->")
REPRODUCE = (
    "Reproduce with the workflow's manual run (candidate and baseline as above), or locally:\n"
    "`./zig/zig build -Drelease bench:load -- --local --workload=<workload> --batch=<batch>`"
)


def slug(metric):
    """`load c4/b1 p99 µs` -> `load-c4-b1-p99-us`: letters, digits, '.', '_' and '-' only."""
    return re.sub(r"[^A-Za-z0-9._]+", "-", metric.replace("µ", "u")).strip("-")


def fingerprints(verdict):
    """The fingerprints of a failing night, sorted: one per failing metric, `errors` for a night
    with errors, and `overall` for a night that failed with neither (a forced run)."""
    baseline = (verdict.get("commits", {}).get("baseline") or "unknown")[:12]
    names = sorted({slug(row["metric"]) for row in verdict.get("metrics", []) if row["status"] == "fail"})
    if verdict.get("errors"):
        names.append("errors")
    if not names:
        names.append("overall")
    return [f"{name}:{baseline}" for name in names]


def markers(issue):
    """(fingerprints, run ids) recorded in an issue's body and comments."""
    texts = [issue.get("body") or ""] + [comment.get("body") or "" for comment in issue.get("comments") or []]
    found, runs = set(), set()
    for text in texts:
        found.update(FINGERPRINT.findall(text))
        runs.update(RUN.findall(text))
    return found, runs


class Gh:
    """The few `gh` calls this needs. Tests replace it with a fake that records the calls."""

    def __init__(self, repo):
        self.repo = repo

    def run(self, args, stdin=None):
        repo = ["--repo", self.repo] if self.repo and args[0] != "api" else []
        result = subprocess.run(["gh", *args, *repo], input=stdin, capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(f"gh {' '.join(args[:2])} failed: {result.stderr.strip()[:500]}")
        return result.stdout

    def get(self, path):
        """Every item of a paginated REST list (`gh api` reads with REST, not GraphQL)."""
        pages = json.loads(self.run(["api", "--paginate", "--slurp", f"repos/{self.repo or '{owner}/{repo}'}/{path}"]) or "[]")
        return [item for page in pages for item in page]

    def issues(self):
        """Every perf-regression issue, open or closed, with its comments."""
        issues = [issue for issue in self.get(f"issues?labels={LABEL}&state=all&per_page=100")
                  if "pull_request" not in issue]
        for issue in issues:
            count = issue.get("comments") or 0
            issue["comments"] = self.get(f"issues/{issue['number']}/comments?per_page=100") if count else []
        return issues

    def ensure_label(self):
        self.run(["label", "create", LABEL, "--color", LABEL_COLOR, "--description", LABEL_DESCRIPTION, "--force"])

    def create(self, title, body):
        url = self.run(["issue", "create", "--title", title, "--label", LABEL, "--body-file", "-"], body).strip()
        return int(url.rstrip("/").rsplit("/", 1)[-1])

    def comment(self, number, body):
        self.run(["issue", "comment", str(number), "--body-file", "-"], body)

    def reopen(self, number):
        self.run(["issue", "reopen", str(number)])

    def close(self, number):
        self.run(["issue", "close", str(number), "--reason", "completed"])


def short(verdict, role):
    return (verdict.get("commits", {}).get(role) or "?")[:12]


def new_body(verdict, summary, prints, run_id, run_url):
    return "\n".join([
        *(f"<!-- nerva-perf:fingerprint={fp} -->" for fp in prints),
        f"<!-- nerva-perf:run={run_id} -->",
        summary.rstrip(),
        "",
        f"Run: {run_url}",
        "",
        REPRODUCE,
        "",
        "---",
        f"Filed by perf-nightly. Fingerprints: {', '.join(f'`{fp}`' for fp in prints)}. Later failing "
        "nights with any of them are added here as comments (reopening this issue if it was "
        "closed), and the next passing night closes it.",
    ]) + "\n"


def fail_comment(verdict, summary, prints, run_id, run_url, reopened):
    lead = "Failing again after this issue was closed, so it is reopened. " if reopened else "Failing again. "
    return "\n".join([
        *(f"<!-- nerva-perf:fingerprint={fp} -->" for fp in prints),
        f"<!-- nerva-perf:run={run_id} -->",
        f"{lead}Candidate `{short(verdict, 'candidate')}`, baseline `{short(verdict, 'baseline')}`. "
        f"Run: {run_url}",
        "",
        summary.rstrip(),
    ]) + "\n"


def recovered_comment(verdict, run_id, run_url):
    return (
        f"<!-- nerva-perf:run={run_id} -->\n"
        f"Recovered: the night at candidate `{short(verdict, 'candidate')}` passed against baseline "
        f"`{short(verdict, 'baseline')}`, so this is closed. Run: {run_url}\n"
    )


def sync(verdict, summary, gh, run_id, run_url, overall=None, dry_run=False, say=print):
    """Returns a list of (action, issue number or None)."""
    overall = overall or verdict["overall"]
    if overall not in ("fail", "pass"):
        say(f"overall {overall}: no issue changes")
        return []
    issues = gh.issues()
    results = []

    def act(action, number, text=None):
        results.append((action, number))
        say(f"{'would be ' if dry_run and action != 'unchanged' else ''}{action:10} "
            f"{('#' + str(number)) if number else '(new)'}")
        if dry_run and text:
            say("  " + text.rstrip().replace("\n", "\n  "))

    if overall == "pass":
        for issue in sorted(issues, key=lambda issue: issue["number"]):
            if issue["state"].lower() != "open":
                continue
            if run_id in markers(issue)[1]:
                act("unchanged", issue["number"])
                continue
            text = recovered_comment(verdict, run_id, run_url)
            if not dry_run:
                gh.comment(issue["number"], text)
                gh.close(issue["number"])
            act("closed", issue["number"], text)
        if not results:
            say("passed, and no perf-regression issue is open")
        return results

    prints = fingerprints(verdict)
    matching = [issue for issue in issues if markers(issue)[0] & set(prints)]
    if not matching:
        title = f"Performance regression at {short(verdict, 'candidate')}"
        text = new_body(verdict, summary, prints, run_id, run_url)
        number = None
        if not dry_run:
            gh.ensure_label()
            number = gh.create(title, text)
        act("created", number, f"{title}\n\n{text}")
        return results

    # An open issue over a closed one; then the newest, the likeliest to be about this regression.
    issue = max(matching, key=lambda issue: (issue["state"].lower() == "open", issue["number"]))
    number = issue["number"]
    if run_id in markers(issue)[1]:
        act("unchanged", number)
        return results
    reopened = issue["state"].lower() != "open"
    text = fail_comment(verdict, summary, prints, run_id, run_url, reopened)
    if not dry_run:
        if reopened:
            gh.reopen(number)
        gh.comment(number, text)
    act("reopened" if reopened else "commented", number, text)
    return results


def main(argv=None):
    parser = argparse.ArgumentParser(description="File the night's perf-regression issue, or close it.")
    parser.add_argument("--verdict", required=True, help="compare.py's verdict.json")
    parser.add_argument("--summary", required=True, help="compare.py's summary.md")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--overall", choices=("fail", "pass"), help="replace the verdict's overall")
    parser.add_argument("--repo", help="owner/name (default: gh's, from the checkout or GH_REPO)")
    parser.add_argument("--dry-run", action="store_true", help="read the issues, print what would change, change nothing")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.run_id):
        parser.error("--run-id may hold only letters, digits, '.', '_' and '-'")
    with open(args.verdict) as file:
        verdict = json.load(file)
    with open(args.summary) as file:
        summary = file.read()
    sync(verdict, summary, Gh(args.repo), args.run_id, args.run_url, args.overall, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
