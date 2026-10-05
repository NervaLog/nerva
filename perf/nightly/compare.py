#!/usr/bin/env python3
"""Compares the candidate with the baseline in one nightly run (docs/DECISIONS.md N56).

Both builds ran in the same rounds on the same Machine, so each round gives one paired change
per metric. A metric fails when the candidate is worse than its threshold in every round (at
least two), warns when the median change is worse than the threshold, and improves when the
median change is better than it. Usage:

    compare.py results.jsonl --summary summary.md --verdict verdict.json
"""

import argparse
import json
import statistics
import sys

# How much worse (a fraction) a metric may get before it counts. Calibrated later (N56).
THRESHOLDS = {"ops_per_s": 0.10, "micro": 0.10, "p50_us": 0.15, "p99_us": 0.25}


def metrics(result, kind):
    """Yields (metric, value, kind_of_threshold, higher_is_better) for one result line."""
    if kind == "micro":
        yield "micro " + result["name"], result["value"], "micro", False
    elif kind == "load":
        key = "load " + result["key"]
        yield key + " ops/s", result["operations_per_s"], "ops_per_s", True
        yield key + " p50 µs", result["latency_us"]["p50"], "p50_us", False
        yield key + " p99 µs", result["latency_us"]["p99"], "p99_us", False


def compare(lines):
    values = {}  # (metric) -> {"threshold", "higher", rounds: {round: {role: value}}}
    commits = {}
    errors = []
    health = None
    for line in lines:
        record = json.loads(line)
        kind, role = record["kind"], record["role"]
        if kind == "health":
            health = record["result"]
            continue
        commits[role] = record["commit"]
        if kind == "error":
            errors.append({"role": role, "round": record["round"], **record["result"]})
            continue
        for metric, value, threshold, higher in metrics(record["result"], kind):
            entry = values.setdefault(metric, {"threshold": THRESHOLDS[threshold], "higher": higher, "rounds": {}})
            entry["rounds"].setdefault(record["round"], {})[role] = value

    rows = []
    for metric, entry in sorted(values.items()):
        changes = []
        for _, pair in sorted(entry["rounds"].items()):
            if "baseline" not in pair or "candidate" not in pair or pair["baseline"] == 0:
                continue
            base, cand = pair["baseline"], pair["candidate"]
            # Positive means worse, whichever direction the metric runs.
            change = (base - cand) / base if entry["higher"] else (cand - base) / base
            changes.append(change)
        if not changes:
            continue
        threshold = entry["threshold"]
        median = statistics.median(changes)
        if len(changes) >= 2 and all(change > threshold for change in changes):
            status = "fail"
        elif median > threshold:
            status = "warn"
        elif median < -threshold:
            status = "improved"
        else:
            status = "pass"
        baseline_median = statistics.median(pair["baseline"] for pair in entry["rounds"].values() if "baseline" in pair)
        candidate_median = statistics.median(pair["candidate"] for pair in entry["rounds"].values() if "candidate" in pair)
        rows.append({
            "metric": metric,
            "status": status,
            "baseline": baseline_median,
            "candidate": candidate_median,
            "worse_by": round(median, 4),
            "worse_by_rounds": [round(change, 4) for change in changes],
            "threshold": threshold,
        })

    statuses = {row["status"] for row in rows}
    if errors or "fail" in statuses:
        overall = "fail"
    elif "warn" in statuses:
        overall = "warn"
    elif not rows:
        overall = "no-comparison"
    else:
        overall = "pass"
    return {"overall": overall, "commits": commits, "health": health, "errors": errors, "metrics": rows}


ORDER = {"fail": 0, "warn": 1, "improved": 2, "pass": 3}


def summary(verdict):
    commits = verdict["commits"]
    out = [
        f"## Nightly performance: **{verdict['overall']}**",
        "",
        f"Baseline `{commits.get('baseline', '?')[:12]}`, candidate `{commits.get('candidate', '?')[:12]}`. "
        f"Machine disk: {json.dumps(verdict['health'])}.",
        "",
    ]
    for error in verdict["errors"]:
        out.append(f"- **Error** in {error['role']} round {error['round']}: {error.get('key', '')} {error['error']}")
    if verdict["errors"]:
        out.append("")
    out += [
        "| Status | Metric | Baseline | Candidate | Worse by (median) | Per round | Threshold |",
        "|---|---|---|---|---|---|---|",
    ]
    for row in sorted(verdict["metrics"], key=lambda row: (ORDER[row["status"]], row["metric"])):
        rounds = ", ".join(f"{change:+.1%}" for change in row["worse_by_rounds"])
        out.append(
            f"| {row['status']} | {row['metric']} | {row['baseline']:g} | {row['candidate']:g} | "
            f"{row['worse_by']:+.1%} | {rounds} | {row['threshold']:.0%} |"
        )
    return "\n".join(out) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("results")
    parser.add_argument("--summary", required=True)
    parser.add_argument("--verdict", required=True)
    args = parser.parse_args()
    with open(args.results) as file:
        verdict = compare(line for line in file if line.strip())
    with open(args.verdict, "w") as file:
        json.dump(verdict, file, indent=1)
    with open(args.summary, "w") as file:
        file.write(summary(verdict))
    print(f"overall: {verdict['overall']}")


if __name__ == "__main__":
    sys.exit(main())
