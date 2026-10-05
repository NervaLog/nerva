#!/usr/bin/env python3
"""Tests for compare.py: python3 perf/nightly/test_compare.py"""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare  # noqa: E402


def load(role, round_, ops, p50=1000, p99=5000, key="c4/b1"):
    return json.dumps({"role": role, "commit": role[0] * 40, "round": round_, "kind": "load", "result": {
        "key": key, "operations_per_s": ops, "latency_us": {"p50": p50, "p99": p99}}})


def micro(role, round_, value, name="documents.encode_ns_per_document"):
    return json.dumps({"role": role, "commit": role[0] * 40, "round": round_, "kind": "micro",
                       "result": {"name": name, "value": value, "unit": "ns"}})


def status(verdict, metric):
    return next(row["status"] for row in verdict["metrics"] if row["metric"] == metric)


class Compare(unittest.TestCase):
    def test_same_numbers_pass(self):
        lines = [load(role, r, 1000) for r in (1, 2, 3) for role in ("baseline", "candidate")]
        verdict = compare.compare(lines)
        self.assertEqual(verdict["overall"], "pass")
        self.assertEqual(status(verdict, "load c4/b1 ops/s"), "pass")

    def test_worse_every_round_fails(self):
        lines = []
        for r in (1, 2, 3):
            lines += [load("baseline", r, 1000), load("candidate", r, 800)]  # 20% fewer ops/s
        verdict = compare.compare(lines)
        self.assertEqual(verdict["overall"], "fail")
        self.assertEqual(status(verdict, "load c4/b1 ops/s"), "fail")
        self.assertEqual(status(verdict, "load c4/b1 p50 µs"), "pass")

    def test_worse_in_some_rounds_warns(self):
        lines = []
        for r, cand in ((1, 800), (2, 800), (3, 1000)):  # median 20% worse, one round equal
            lines += [load("baseline", r, 1000), load("candidate", r, cand)]
        verdict = compare.compare(lines)
        self.assertEqual(status(verdict, "load c4/b1 ops/s"), "warn")
        self.assertEqual(verdict["overall"], "warn")

    def test_lower_is_better_and_improvements(self):
        lines = []
        for r in (1, 2, 3):
            lines += [micro("baseline", r, 1000), micro("candidate", r, 500)]  # twice as fast
            lines += [load("baseline", r, 1000, p99=5000), load("candidate", r, 1000, p99=8000)]
        verdict = compare.compare(lines)
        self.assertEqual(status(verdict, "micro documents.encode_ns_per_document"), "improved")
        self.assertEqual(status(verdict, "load c4/b1 p99 µs"), "fail")  # 60% worse > 25%

    def test_single_round_never_fails(self):
        verdict = compare.compare([load("baseline", 1, 1000), load("candidate", 1, 500)])
        self.assertEqual(status(verdict, "load c4/b1 ops/s"), "warn")

    def test_errors_fail_and_health_is_kept(self):
        lines = [
            json.dumps({"role": "machine", "round": 0, "kind": "health", "result": {"iops": 16000}}),
            load("baseline", 1, 1000), load("candidate", 1, 1000),
            json.dumps({"role": "candidate", "commit": "c" * 40, "round": 1, "kind": "error",
                        "result": {"key": "c2/b1", "error": "bench-load failed"}}),
        ]
        verdict = compare.compare(lines)
        self.assertEqual(verdict["overall"], "fail")
        self.assertEqual(verdict["health"], {"iops": 16000})
        self.assertIn("bench-load failed", compare.summary(verdict))

    def test_no_pairs_is_no_comparison(self):
        verdict = compare.compare([load("candidate", 1, 1000)])
        self.assertEqual(verdict["overall"], "no-comparison")


if __name__ == "__main__":
    unittest.main()
