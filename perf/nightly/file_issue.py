#!/usr/bin/env python3
"""Files, updates and closes `perf-regression` issues for one nightly run (N56; the dedup is
docs/decisions/P121, amended by P122).

One regression gets one issue, however many nights it lasts. Each failing metric has a
fingerprint, `<metric>:<baseline commit, 12 hex>`, which the issue body (or a later comment)
carries as `<!-- nerva-perf:fingerprint=... -->`. The baseline names the regression because it
does not move while a regression lasts: the workflow advances it only after a night that passed,
or one that did not fail while no fingerprinted issue is open (`advance_baseline`, written to
`--github-output`). An open issue is also found by the metric alone, whatever baseline its
fingerprints name.

  * a failing night whose metrics no open issue carries,    -> open one issue with all of them
    and whose fingerprints no closed issue carries
  * a failing night sharing a metric with an open issue,    -> comment with the night's numbers
    or a fingerprint with a closed one                         (reopening the issue if closed)
  * a passing night                                         -> comment "recovered" on every open
                                                               issue with a fingerprint and close
                                                               it (hand-filed ones are left alone)
  * a warn or no-comparison night                           -> change nothing

Every comment carries `<!-- nerva-perf:run=<run id> -->`, so running this twice for one run
(a re-run of the job) changes nothing the second time. Usage:

    file_issue.py --verdict verdict.json --summary summary.md --run-id ID --run-url URL \
        [--overall fail|pass] [--repo owner/name] [--dry-run] [--github-output FILE]

`--overall` replaces the verdict's (the workflow's forced runs); `--dry-run` reads the existing
issues, prints what it would do and the text it would post, and changes nothing;
`--github-output` appends `advance_baseline=true|false` to FILE (the step's $GITHUB_OUTPUT). It needs the
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


def metric(fingerprint):
    """`load-c4-b1-ops-s:bbbbbbbbbbbb` -> `load-c4-b1-ops-s`. Slugs hold no ':', so the metric is
    everything before the last one; a fingerprint with no ':' is all metric."""
    return fingerprint.rsplit(":", 1)[0]


def markers(issue):
    """(fingerprints, run ids) recorded in an issue's body and comments."""
    texts = [issue.get("body") or ""] + [comment.get("body") or "" for comment in issue.get("comments") or []]
    found, runs = set(), set()
    for text in texts:
        found.update(FINGERPRINT.findall(text))
        runs.update(RUN.findall(text))
    return found, runs


def pages_items(text):
    """The items of what `gh api --paginate` prints: one JSON array per page, back to back (not
    `--slurp`, which the runner's `gh` lacks)."""
    decoder = json.JSONDecoder()
    items, position = [], 0
    while True:
        while position < len(text) and text[position].isspace():
            position += 1
        if position == len(text):
            return items
        page, position = decoder.raw_decode(text, position)
        items += page


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
        return pages_items(self.run(["api", "--paginate", f"repos/{self.repo or '{owner}/{repo}'}/{path}"]))

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


def is_open(issue):
    return issue["state"].lower() == "open"


def matches(issue, prints):
    """An open issue is the night's regression if it carries any of the night's metrics, whatever
    baseline its fingerprints name (P122); a closed one only if it carries one of its fingerprints."""
    carried = markers(issue)[0]
    if is_open(issue):
        return bool({metric(fp) for fp in carried} & {metric(fp) for fp in prints})
    return bool(carried & set(prints))


def advance_baseline(measured, open_after):
    """Whether the night's candidate becomes the next baseline. `measured` is the verdict's own
    overall (a forced verdict changes the issues, not the baseline); `open_after` is whether an
    issue with a fingerprint is open once the night is filed. A failing night never advances it;
    a passing night always does; a warn or no-comparison night only when no regression is open,
    so that a warn night in the middle of a regression neither absorbs it into the baseline nor
    changes the fingerprints of the nights after it (P122)."""
    if measured == "fail":
        return False
    return measured == "pass" or not open_after


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
    """Returns (a list of (action, issue number or None), whether an issue with a fingerprint is
    open afterwards). On a dry run, the second is what it would be."""
    overall = overall or verdict["overall"]
    issues = gh.issues()
    open_now = {issue["number"] for issue in issues if is_open(issue) and markers(issue)[0]}
    if overall not in ("fail", "pass"):
        say(f"overall {overall}: no issue changes")
        return [], bool(open_now)
    results = []

    def act(action, number, text=None):
        results.append((action, number))
        say(f"{'would be ' if dry_run and action != 'unchanged' else ''}{action:10} "
            f"{('#' + str(number)) if number else '(new)'}")
        if dry_run and text:
            say("  " + text.rstrip().replace("\n", "\n  "))

    if overall == "pass":
        # Only issues this script filed (they carry a fingerprint); hand-filed ones stay open.
        for issue in sorted(issues, key=lambda issue: issue["number"]):
            if issue["number"] not in open_now:
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
            say("passed, and no perf-regression issue with a fingerprint is open")
        # A re-run of a night that already closed an issue finds it closed, so none is left open
        # except one this run marked but could not close (left for the next pass).
        return results, any(action == "unchanged" for action, _ in results)

    prints = fingerprints(verdict)
    matching = [issue for issue in issues if matches(issue, prints)]
    if not matching:
        title = f"Performance regression at {short(verdict, 'candidate')}"
        text = new_body(verdict, summary, prints, run_id, run_url)
        number = None
        if not dry_run:
            gh.ensure_label()
            number = gh.create(title, text)
        act("created", number, f"{title}\n\n{text}")
        return results, True

    # An open issue over a closed one; then the newest, the likeliest to be about this regression.
    issue = max(matching, key=lambda issue: (issue["state"].lower() == "open", issue["number"]))
    number = issue["number"]
    if run_id in markers(issue)[1]:
        act("unchanged", number)
        return results, True
    reopened = issue["state"].lower() != "open"
    text = fail_comment(verdict, summary, prints, run_id, run_url, reopened)
    if not dry_run:
        if reopened:
            gh.reopen(number)
        gh.comment(number, text)
    act("reopened" if reopened else "commented", number, text)
    return results, True


def main(argv=None):
    parser = argparse.ArgumentParser(description="File the night's perf-regression issue, or close it.")
    parser.add_argument("--verdict", required=True, help="compare.py's verdict.json")
    parser.add_argument("--summary", required=True, help="compare.py's summary.md")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--overall", choices=("fail", "pass"), help="replace the verdict's overall")
    parser.add_argument("--repo", help="owner/name (default: gh's, from the checkout or GH_REPO)")
    parser.add_argument("--dry-run", action="store_true", help="read the issues, print what would change, change nothing")
    parser.add_argument("--github-output", help="append advance_baseline=true|false to this file ($GITHUB_OUTPUT)")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.run_id):
        parser.error("--run-id may hold only letters, digits, '.', '_' and '-'")
    with open(args.verdict) as file:
        verdict = json.load(file)
    with open(args.summary) as file:
        summary = file.read()
    _, open_after = sync(verdict, summary, Gh(args.repo), args.run_id, args.run_url, args.overall, args.dry_run)
    advance = advance_baseline(verdict["overall"], open_after)
    print(f"advance_baseline={str(advance).lower()} (measured {verdict['overall']}, "
          f"{'a' if open_after else 'no'} fingerprinted issue open)")
    if args.github_output:
        with open(args.github_output, "a") as file:
            file.write(f"advance_baseline={str(advance).lower()}\n")


if __name__ == "__main__":
    sys.exit(main())
