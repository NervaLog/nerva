#!/usr/bin/env python3
"""Tests for jepsen_report.py (R1 slice 6), without network. Run from the repository root:
python3 -I ops/jepsen/test_jepsen_report.py"""
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
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
    def __init__(self, fail=None, markers=None, theirs=None):
        self.opened, self.comments, self.statuses = [], [], []
        self.theirs = theirs  # What GitHub already shows for the context.
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

    def current_status(self, commit, context):
        if "read" in self.fail:
            raise self.fail.pop("read")
        return self.theirs

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


class ExpectedWorkloads(unittest.TestCase):
    def test_a_night_missing_a_workload_is_never_success(self):
        store = Store(self)
        store.test("1", VALID)
        runs, host = rep.read_night(store.path, store.write_runs())
        self.assertEqual(rep.night_state(runs, host, False, ["retry"])[0], "success")
        state, why = rep.night_state(runs, host, False, ["retry", "bank"])
        self.assertEqual(state, "error")
        self.assertIn("bank", why)

    def test_a_run_whose_workload_cannot_be_read_does_not_count_as_bank(self):
        # No `--workload` anywhere: the run is `bank` only by default, so it must not stand in
        # for a bank run the night never made.
        store = Store(self)
        store.test("1", VALID, args="--time-limit 300")
        runs, host = rep.read_night(store.path, store.write_runs())
        self.assertEqual(runs[0].workload, "bank")
        state, why = rep.night_state(runs, host, False, ["bank"])
        self.assertEqual(state, "error")
        self.assertIn("bank", why)

    def test_a_finding_outranks_a_missing_workload(self):
        store = Store(self)
        store.test("1", invalid())
        runs, host = rep.read_night(store.path, store.write_runs())
        self.assertEqual(rep.night_state(runs, host, False, ["retry", "bank"])[0], "failure")


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

    def test_no_jepsen_at_all_is_the_hosts(self):
        store = Store(self)
        store.host("1", 1)
        runs, _ = rep.read_night(store.path, store.write_runs())
        self.assertEqual(runs[0].kind, "host")
        self.assertIn("never started", runs[0].host_reason)

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

    def test_a_canary_that_threw_is_a_crash_not_blind(self):
        store = Store(self)
        directory = store.test("1", "", with_results=False, code=255, args="--workload retry")
        with open(os.path.join(directory, "jepsen.log"), "a") as log:
            log.write("ERROR the replica 3 exited during format\n")
        github, _, summary = night(self, store, canary=True)
        self.assertEqual(github.statuses[0][1:3], ("failure", "jepsen/canary"))
        self.assertIn("crashed", github.statuses[0][3])
        self.assertNotIn("blind", github.statuses[0][3])
        self.assertEqual(summary["filed"], 1)
        self.assertIn("crashed", github.opened[0][1])
        self.assertNotIn("blind", github.opened[0][1])
        self.assertIn("Jepsen canary", github.opened[0][1])
        body = github.opened[0][2]
        self.assertIn("canary", body.split("\n")[0])
        self.assertNotIn("found this on `main`", body)
        self.assertIn("-Dtest-commit-keys=off", body)
        # Its fingerprint is not the nightly's crash of the same workload.
        plain = Store(self)
        plain.test("1", "", with_results=False, code=255, args="--workload retry")
        nightly, _, _ = night(self, plain)
        self.assertNotEqual(rep.MARKER.search(body).group(1),
                            rep.MARKER.search(nightly.opened[0][2]).group(1))


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


# The shapes Jepsen really prints. `retry` is the slice 3 hosted run 42173915710 (trimmed);
# bank's `:workload` is `checker/compose` of :bank :source :view :refusals (bank.clj), itself
# under core.clj's `:workload`, beside :protocol; jepsen.tests.bank's own result is
# {:valid? :read-count :error-count :first-error :errors {:wrong-total {...}}}.
RETRY_REAL = """{:perf {:latency-graph {:valid? true}, :rate-graph {:valid? true}, :valid? true},
 :timeline {:valid? true},
 :stats {:valid? true, :count 5983, :by-f {:pay {:valid? true, :count 5973}}},
 :exceptions {:valid? true},
 :protocol {:valid? true, :violations 0, :examples []},
 :workload {:duplicate {:count 613, :examples [{:key "dad07594c7e9ff54aae1c51e40e077c9",
                                                :ops [2759 2766]}]},
            :key-reused {:count 0, :examples []}, :valid? false,
            :applied-lie {:count 0, :examples []}, :unresolved {:count 0, :examples []},
            :dropped 613, :replayed 0, :committed 5973,
            :balance {:count 0, :examples []}, :keys 5973, :reads 5,
            :key-collision {:count 0, :examples []}},
 :valid? false}
"""


def bank_results(bank="true", source="true", view="true", refusals="true", protocol="true"):
    bad_bank = ("{:valid? false, :read-count 9, :error-count 1, :first-error {:type :wrong-total,"
                " :total 399, :op {:index 7}}, :errors {:wrong-total {:count 1, :first {:index 7}}}}")
    parts = {"bank": bad_bank if bank == "false" else "{:valid? true, :read-count 9, :error-count 0,"
             " :first-error nil, :errors {}}",
             "source": f"{{:valid? {source}, :expected -400, :errors []}}",
             "view": f"{{:valid? {view}, :answers 4, :errors []}}",
             "refusals": f"{{:valid? {refusals}, :refusals {{:out_of_bounds 3}}, :unexpected []}}"}
    inner = ", ".join(f":{k} {v}" for k, v in parts.items())
    ok = all(v == "true" for v in (bank, source, view, refusals))
    proto = "{:valid? true, :violations 0, :examples []}" if protocol == "true" else \
        "{:valid? false, :violations 2, :examples [{:op 5}]}"
    valid = "true" if ok and protocol == "true" else "false"
    return (f"{{:perf {{:valid? true}}, :timeline {{:valid? true}}, :stats {{:valid? true}},"
            f" :exceptions {{:valid? true}}, :protocol {proto},"
            f" :workload {{{inner}, :valid? {'true' if ok else 'false'}}}, :valid? {valid}}}")


class NestedCheckers(unittest.TestCase):
    def found(self, text):
        found, graphs_only = rep.findings_of(rep.parse_edn(text))
        self.assertFalse(graphs_only)
        return [(c, n) for c, n, _ in found]

    def test_the_real_retry_shape_names_workload_duplicate(self):
        self.assertEqual(self.found(RETRY_REAL), [("workload", "duplicate")])

    def test_a_bank_conservation_failure_names_the_leaf(self):
        self.assertEqual(self.found(bank_results(source="false")),
                         [("workload.source", "conservation")])
        self.assertEqual(self.found(bank_results(bank="false")),
                         [("workload.bank", "conservation")])
        self.assertEqual(self.found(bank_results(view="false")),
                         [("workload.view", "conservation")])

    def test_a_bank_refusal_regression_is_not_a_conservation_break(self):
        self.assertEqual(self.found(bank_results(refusals="false")),
                         [("workload.refusals", "refusal")])

    def test_a_protocol_failure_has_its_violations_class(self):
        self.assertEqual(self.found(bank_results(protocol="false")), [("protocol", "violations")])

    def test_distinct_bank_failures_are_distinct_issues(self):
        bodies = []
        for kind in ("source", "refusals", "view"):
            store = Store(self)
            store.test("1", bank_results(**{kind: "false"}), args="--workload bank")
            github, _, summary = night(self, store)
            bodies.append(github.opened[0][2])
        self.assertEqual(len({rep.MARKER.search(b).group(1) for b in bodies}), 3)

    def test_two_failures_in_one_run_are_two_findings(self):
        found = self.found(bank_results(source="false", refusals="false"))
        self.assertEqual(set(found), {("workload.source", "conservation"),
                                      ("workload.refusals", "refusal")})


class ExitCodes(unittest.TestCase):
    def test_an_invalid_verdict_outranks_a_deadline_exit(self):
        for code in (124, 137):
            store = Store(self)
            store.test("1", invalid(), code=code)
            github, _, summary = night(self, store)
            self.assertEqual(summary["filed"], 1)
            self.assertEqual(github.statuses[0][1], "failure")

    def test_a_host_exit_with_a_valid_verdict_is_still_the_hosts(self):
        store = Store(self)
        store.test("1", VALID, code=137)
        github, _, summary = night(self, store)
        self.assertEqual(github.statuses[0][1], "error")
        self.assertEqual(summary["filed"], 0)

    def test_a_host_exit_with_no_results_is_the_hosts(self):
        store = Store(self)
        store.test("1", "", with_results=False, code=124)
        github, _, summary = night(self, store)
        self.assertEqual((github.statuses[0][1], summary["filed"]), ("error", 0))

    def test_a_test_that_threw_is_nervas_and_is_filed_with_the_log_end(self):
        store = Store(self)
        directory = store.test("1", "", with_results=False, code=255, args="--workload bank")
        with open(os.path.join(directory, "jepsen.log"), "a") as log:
            log.write("ERROR the replica 3 exited during format\n")
        github, _, summary = night(self, store)
        self.assertEqual((github.statuses[0][1], summary["filed"]), ("failure", 1))
        title, body = github.opened[0][1], github.opened[0][2]
        self.assertIn("crashed", title)
        self.assertIn("replica 3 exited during format", body)
        again, _, _ = night(self, store)
        self.assertEqual(rep.MARKER.search(again.opened[0][2]).group(1),
                         rep.MARKER.search(body).group(1))


class HistoryRead(unittest.TestCase):
    def test_the_history_is_read_once_per_run_however_many_findings(self):
        store = Store(self)
        results = ("{:valid? false, :workload {:valid? false, :duplicate {:count 1, :examples "
                   '[{:key "aaaa", :ops [3 5]}]}, :balance {:count 1, :examples [{:key "bbbb"}]}}}')
        store.test("1", results, history=[f"{{:index {i}, :key \"aaaa\"}}" for i in range(10)])
        real, calls = rep.read_history, []

        def counting(path):
            calls.append(path)
            return real(path)

        rep.read_history = counting
        self.addCleanup(setattr, rep, "read_history", real)
        github, _, _ = night(self, store)
        self.assertGreaterEqual(len(github.opened), 2)
        self.assertEqual(len(calls), 1)


class HostSignatures(unittest.TestCase):
    def crashed(self, tail):
        store = Store(self)
        directory = store.test("1", "", with_results=False, code=255, args="--workload retry")
        with open(os.path.join(directory, "jepsen.log"), "a") as log:
            log.write(tail)
        return night(self, store)

    def test_host_failures_in_the_log_tail_are_never_filed(self):
        for tail in ("com.jcraft.jsch.JSchException: java.net.ConnectException: Connection "
                     "refused (n3:22)\n", "java.lang.OutOfMemoryError: Java heap space\n",
                     "java.io.IOException: No space left on device\n",
                     "Cannot connect to the Docker daemon at unix:///var/run/docker.sock\n",
                     "ssh: connect to host n3 port 22: Connection refused\n",
                     "WARN jepsen.control - n3 session is down\n"):
            github, _, summary = self.crashed(tail)
            self.assertEqual((github.statuses[0][1], summary["filed"], github.opened),
                             ("error", 0, []), tail)

    def test_a_signature_outside_the_tail_does_not_count(self):
        store = Store(self)
        directory = store.test("1", "", with_results=False, code=255, args="--workload retry")
        Path(directory, "jepsen.log").write_text(
            "JSchException: Auth fail\n" + "x\n" * rep.LOG_SIGNATURE_BYTES + "replica died\n")
        github, _, summary = night(self, store)
        self.assertEqual((github.statuses[0][1], summary["filed"]), ("failure", 1))

    def test_client_connection_errors_before_a_nerva_crash_are_still_filed(self):
        client = ("WARN jepsen.client - invoke failed: java.net.ConnectException: Connection "
                  "refused (http://10.77.0.12:8080)\nConnection timed out\nNo route to host\n")
        github, _, summary = self.crashed(client * 50 + "ERROR replica 3 exited: assertion\n")
        self.assertEqual((github.statuses[0][1], summary["filed"]), ("failure", 1))
        self.assertIn("crashed", github.opened[0][1])

    def test_other_crashes_are_still_nervas(self):
        github, _, summary = self.crashed("ERROR replica 3 exited during format\n")
        self.assertEqual((github.statuses[0][1], summary["filed"]), ("failure", 1))


class GitHubOwnStatus(unittest.TestCase):
    def test_a_failure_github_shows_is_not_turned_green_with_an_empty_state(self):
        store = Store(self)
        store.test("1", VALID)
        github, state, summary = night(self, store, github=Recorder(theirs="failure"))
        self.assertEqual(github.statuses, [])
        self.assertEqual(state["verdicts"], {})
        self.assertIn("not posted", summary["status"])

    def test_a_timed_out_post_that_github_stored_is_seen_on_the_next_night(self):
        state = rep.new_state()
        store = Store(self)
        store.test("1", invalid())
        lost = Recorder(fail={"status": rep.GitHubError("unreachable", "no answer")})
        _, state, _ = night(self, store, github=lost, state=state)
        store = Store(self)
        store.test("1", VALID)
        again, _, _ = night(self, store, github=Recorder(theirs="failure"), state=state,
                            now=NOW + DAY)
        self.assertEqual(again.statuses, [])

    def test_a_lower_github_status_is_replaced(self):
        store = Store(self)
        store.test("1", VALID)
        github, _, _ = night(self, store, github=Recorder(theirs="error"))
        self.assertEqual([s[1] for s in github.statuses], ["success"])

    def test_an_unreadable_status_posts_nothing_and_the_tracker_says_so(self):
        store = Store(self)
        store.test("1", VALID)
        github = Recorder(fail={"read": rep.GitHubError("unreachable", "no answer")})
        github, _, summary = night(self, store, github=github, tracker=7)
        self.assertEqual(github.statuses, [])
        self.assertIn("could not read", summary["status"])
        self.assertIn("could not read", github.comments[0][1])

    def test_the_read_is_one_bounded_get(self):
        calls = []
        client = rep.GitHub("o/r", "t", lambda m: None)
        client.request = lambda method, path, payload=None: calls.append((method, path)) or {
            "statuses": [{"context": "x", "state": "error"},
                         {"context": rep.CONTEXT_NIGHTLY, "state": "failure"}]}
        self.assertEqual(client.current_status(COMMIT, rep.CONTEXT_NIGHTLY), "failure")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "GET")
        self.assertIn("per_page=100", calls[0][1])


class StatusesOnlyMoveUp(unittest.TestCase):
    def test_a_malformed_verdict_is_dropped_on_load(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.json")
            Path(path).write_text(json.dumps({"version": rep.STATE_VERSION, "filed": {},
                                              "days": {}, "verdicts": {
                "a:b": {"state": "pending", "day": "d"}, "c:d": 5,
                "e:f": {"state": "success", "day": "2026-11-01"}}}))
            self.assertEqual(list(rep.load_state(path)["verdicts"]), ["e:f"])

    def run_night(self, test, results, state, code=0, **kwargs):
        store = Store(test)
        store.test("1", results, code=code)
        return night(test, store, state=state, **kwargs)

    def test_a_later_success_does_not_replace_a_failure(self):
        state = rep.new_state()
        first, state, _ = self.run_night(self, invalid(), state)
        second, state, summary = self.run_night(self, VALID, state, now=NOW + DAY)
        self.assertEqual([s[1] for s in first.statuses], ["failure"])
        self.assertEqual(second.statuses, [])
        self.assertIn("not posted", summary["status"])

    def test_a_host_error_does_not_replace_a_success(self):
        state = rep.new_state()
        _, state, _ = self.run_night(self, VALID, state)
        second, state, _ = self.run_night(self, "", state, code=137, now=NOW + DAY)
        self.assertEqual(second.statuses, [])

    def test_a_success_replaces_an_error_and_a_failure_replaces_a_success(self):
        state = rep.new_state()
        for results, code, want in (("", 137, "error"), (VALID, 0, "success"),
                                    (invalid(), 0, "failure")):
            github, state, _ = self.run_night(self, results, state, code=code)
            self.assertEqual([s[1] for s in github.statuses], [want])

    def test_another_commit_has_its_own_status(self):
        state = rep.new_state()
        _, state, _ = self.run_night(self, invalid(), state)
        second, state, _ = self.run_night(self, VALID, state, commit=OTHER)
        self.assertEqual([s[1] for s in second.statuses], ["success"])

    def test_a_failed_post_is_not_remembered(self):
        state = rep.new_state()
        github = Recorder(fail={"status": rep.GitHubError("unreachable", "no answer")})
        _, state, _ = self.run_night(self, VALID, state, github=github)
        again, state, _ = self.run_night(self, VALID, state)
        self.assertEqual([s[1] for s in again.statuses], ["success"])

    def test_no_status_posts_none_and_remembers_none(self):
        store = Store(self)
        store.host("1", 137)
        runs, host = rep.read_night(store.path, store.write_runs())
        github, state = Recorder(), rep.new_state()
        rep.ingest(github, state, runs, host, COMMIT, None, None, False, NOW, "o/r",
                   lambda m: None, status=False)
        self.assertEqual(github.statuses, [])
        self.assertEqual(state["verdicts"], {})

    def test_an_old_state_file_without_verdicts_loads(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.json")
            Path(path).write_text('{"version": 1, "filed": {}, "days": {}}')
            self.assertEqual(rep.load_state(path)["verdicts"], {})

    def test_the_verdicts_are_bounded(self):
        state = rep.new_state()
        for i in range(rep.VERDICTS_MAX + 20):
            rep.record_status(state, f"{i:040x}", rep.CONTEXT_NIGHTLY, "success", f"d{i:04}")
        self.assertEqual(len(state["verdicts"]), rep.VERDICTS_MAX)


class DryRunState(unittest.TestCase):
    def test_a_dry_run_leaves_nothing_in_a_state_file_it_could_poison(self):
        store = Store(self)
        store.test("1", invalid())
        store.write_runs()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.json")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(rep.main(["ingest", "--dry-run", "--store", store.path,
                                           "--commit", COMMIT, "--state", path], now=NOW), 0)
            self.assertEqual(rep.load_state(path)["filed"], {})

    def test_negative_numbers_in_an_old_state_are_dropped_on_load(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.json")
            state = rep.new_state()
            state["filed"]["a" * 32] = {"issue": -1, "first_commit": "", "last_commit": ""}
            state["filed"]["b" * 32] = {"issue": 7, "first_commit": "", "last_commit": ""}
            Path(path).write_text(json.dumps(state))
            self.assertEqual(list(rep.load_state(path)["filed"]), ["b" * 32])


class HistoryMemory(unittest.TestCase):
    def test_one_runs_history_is_live_at_a_time(self):
        store = Store(self)
        for label, workload in (("1", "retry"), ("2", "bank")):
            store.test(label, invalid(), args=f"--workload {workload}",
                       history=['{:index 0, :type :ok, :key "aaaa", :f :pay}'])
        runs, host = rep.read_night(store.path, store.write_runs())
        live = []
        real = rep.read_history

        def watching(path):
            live.append(sum(1 for r in runs if r.history is not None))
            return real(path)

        rep.read_history = watching
        self.addCleanup(setattr, rep, "read_history", real)
        rep.ingest(Recorder(), rep.new_state(), runs, host, COMMIT, None, None, False, NOW,
                   "o/r", lambda m: None)
        self.assertEqual(len(live), 2)
        self.assertEqual(max(live), 0)
        self.assertTrue(all(r.history is None for r in runs))


class Interrupted(unittest.TestCase):
    def test_exit_143_is_the_hosts_and_the_night_is_error(self):
        store = Store(self)
        Path(store.path, "runs").write_text("1 143 20 test --workload retry\n")
        runs, host = rep.read_night(store.path, None)
        self.assertEqual(runs[0].kind, "host")
        self.assertIn("interrupted", runs[0].host_reason)
        github = Recorder()
        rep.ingest(github, rep.new_state(), runs, host, COMMIT, None, None, False, NOW, "o/r",
                   lambda m: None)
        self.assertEqual(github.statuses[0][1:3], ("error", "jepsen/nightly"))

    def test_exit_143_with_a_log_and_no_results_is_the_hosts_not_a_crash(self):
        # The case the trap makes: Jepsen had started (a jepsen.log) and was stopped.
        store = Store(self)
        store.test("1", "", code=143, with_results=False)
        runs, host = rep.read_night(store.write_runs() and store.path, None)
        self.assertEqual(runs[0].kind, "host")
        self.assertEqual(runs[0].findings, [])
        github = Recorder()
        rep.ingest(github, rep.new_state(), runs, host, COMMIT, None, None, False, NOW, "o/r",
                   lambda m: None)
        self.assertEqual(github.opened, [])
        self.assertEqual(github.statuses[0][1:3], ("error", "jepsen/nightly"))


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


class BodyBound(unittest.TestCase):
    def filed_body(self, results, history, args="--workload retry"):
        store = Store(self)
        store.test("1", results, history=history, args=args)
        github, _, _ = night(self, store)
        return github.opened[0][2]

    def test_many_sparse_anomalies_stay_under_the_bound(self):
        # 1,334 isolated anomalous lines: the omission markers were not charged to the budget.
        keys = tuple(f"{i:032x}" for i in range(1334))
        history = []
        for i in range(1334):
            history.append(f'{{:index {i * 3}, :type :ok, :key "{keys[i]}", :f :pay}}')
            history.extend(f'{{:index {i * 3 + j}, :type :ok, :f :read, :pad "{"p" * 150}"}}'
                           for j in (1, 2))
        body = self.filed_body(invalid(keys=keys), history)
        self.assertLessEqual(len(body.encode()), rep.BODY_BYTES_MAX)
        excerpt = body[body.index("The history"):]
        self.assertLessEqual(len(excerpt.encode()), rep.HISTORY_BYTES_ISSUE + 1024)

    def test_ten_keys_five_hundred_times_with_a_big_verdict(self):
        keys = tuple(f"{i:032x}" for i in range(10))
        history = [f'{{:index {i}, :type :ok, :key "{keys[i % 10]}", :f :pay, :pad "{"x" * 90}"}}'
                   for i in range(5000)]
        body = self.filed_body(invalid(keys=keys, extra=', :pad "' + "v" * 20_000 + '"'), history)
        self.assertLessEqual(len(body.encode()), rep.BODY_BYTES_MAX)
        self.assertIn("jepsen fingerprint", body)

    def test_invalid_utf8_in_a_history_is_charged_as_decoded(self):
        keys = ("a" * 32,)
        store = Store(self)
        directory = store.test("1", invalid(keys=keys), history=[])
        bad = b'{:index %d, :key "' + keys[0].encode() + b'", :pad "' + b"\xff" * 1400 + b'"}\n'
        with open(os.path.join(directory, "history.edn"), "wb") as file:
            for i in range(400):
                file.write(bad % i)
        github, _, _ = night(self, store)
        self.assertLessEqual(len(github.opened[0][2].encode()), rep.BODY_BYTES_MAX)

    def test_an_oversize_part_is_cut_not_asserted(self):
        item = {"run": rep.Run("1"), "canary": False, "checker": "workload", "class": "x",
                "subtree": None, "key": "k", "fingerprint": "f" * 32, "title": "t"}
        item["run"].results_text = "v" * 10
        original = rep.VERDICT_BYTES
        try:
            rep.VERDICT_BYTES = 10 * rep.BODY_BYTES_MAX  # a bound that was raised by mistake
            item["run"].results_text = "v" * (2 * rep.BODY_BYTES_MAX)
            text = rep.report_text(item, COMMIT, None, first=True)
        finally:
            rep.VERDICT_BYTES = original
        self.assertLessEqual(len(text.encode()), rep.BODY_BYTES_MAX)
        self.assertIn("jepsen fingerprint", text)

    def test_a_fault_after_the_status_still_saves_the_state(self):
        store = Store(self)
        store.test("1", invalid())
        store.write_runs()
        original = rep.report_text
        rep.report_text = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom"))
        try:
            with tempfile.TemporaryDirectory() as tmp:
                path = os.path.join(tmp, "s.json")
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(RuntimeError):
                    rep.main(["ingest", "--dry-run", "--store", store.path, "--commit", COMMIT,
                              "--state", path], now=NOW)
                self.assertIn(f"{COMMIT}:jepsen/nightly", rep.load_state(path)["verdicts"])
        finally:
            rep.report_text = original


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


FAKE_RUN = """#!/bin/sh
# A fake tests/jepsen/run.sh: one invalid retry store, as Jepsen leaves it.
mkdir -p tests/jepsen/store/t/2026-11-02T01:00:00Z
cd tests/jepsen/store/t/2026-11-02T01:00:00Z || exit 9
printf 'Command line:\\nlein run test --workload retry --seed 1\\n' > jepsen.log
cat > results.edn <<'EDN'
%s
EDN
: > history.edn
exit 0
"""


@unittest.skipUnless(shutil.which("git") and shutil.which("flock"), "needs git and flock")
class Nightly(unittest.TestCase):
    """nightly.sh against a local remote, with the build, Docker and Jepsen faked."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.remote = root / "remote"
        self.bin = root / "bin"
        self.bin.mkdir()
        (self.bin / "docker").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "docker").chmod(0o755)
        if not shutil.which("zstd"):  # tar --zstd needs it; gzip stands in where it is not installed
            (self.bin / "zstd").write_text("#!/bin/sh\nexec gzip \"$@\"\n")
            (self.bin / "zstd").chmod(0o755)
        # The runner as setup.sh installs it: the night runs this copy, never the tip's.
        self.installed = root / "installed"
        self.installed.mkdir()
        shutil.copy(HERE / "nightly.sh", self.installed / "nightly.sh")
        shutil.copy(HERE / "jepsen_report.py", self.installed / "jepsen_report.py")
        self.write_remote_tree(self.remote, "one")
        self.git(self.remote, "init", "-q", "-b", "main")
        self.git(self.remote, "add", "-A")
        self.commit(self.remote, "one")

    def git(self, cwd, *args):
        return subprocess.run(["git", "-C", str(cwd), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, cwd, message):
        self.git(cwd, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)

    def write_remote_tree(self, path, marker, results=None):
        for name, text in {
            "zig/download.sh": "#!/bin/sh\nexit 0\n",
            "zig/zig": "#!/bin/sh\nexit 0\n",
            "tests/jepsen/run.sh": FAKE_RUN % (results or invalid()),
            "marker": marker + "\n",
        }.items():
            target = Path(path, name)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
            if name != "marker":
                target.chmod(0o755)
        jepsen = Path(path, "ops/jepsen")
        jepsen.mkdir(parents=True, exist_ok=True)
        shutil.copy(HERE / "jepsen_report.py", jepsen / "jepsen_report.py")
        shutil.copy(HERE / "nightly.sh", jepsen / "nightly.sh")
        with open(jepsen / "nightly.sh", "a") as script:
            script.write(f"# tip {marker}\n")

    def night(self, *flags, remote=None, extra=None, script=None):
        env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "JEPSEN_HOME": str(self.home),
               "JEPSEN_REMOTE": remote or str(self.remote), "JEPSEN_WORKLOADS": "retry",
               "JEPSEN_NEMESIS": "kill", "JEPSEN_TIME_LIMIT": "1",
               "JEPSEN_NIGHT_SECONDS": "120", "HOME": self.tmp.name, **(extra or {})}
        return subprocess.run(["bash", str(script or self.installed / "nightly.sh"), *flags], env=env,
                              capture_output=True, text=True, timeout=120)

    def test_a_dry_run_has_a_state_and_a_night_of_its_own(self):
        done = self.night("--dry-run")
        self.assertEqual(done.returncode, 0, done.stderr)
        state = self.home / "state"
        self.assertTrue((state / "dry-run.json").exists())
        self.assertFalse((state / "state.json").exists())
        self.assertEqual([p.name.endswith("-dry") for p in (self.home / "nights").iterdir()],
                         [True])
        self.assertIn("would open issue", done.stdout)
        self.assertEqual(rep.load_state(str(state / "dry-run.json"))["filed"], {})

    def test_the_environment_variable_does_the_same_as_the_flag(self):
        done = self.night(extra={"JEPSEN_DRY_RUN": "1"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse((self.home / "state" / "state.json").exists())

    def test_a_failed_fetch_posts_no_status(self):
        self.assertEqual(self.night("--dry-run").returncode, 0)
        self.git(self.home / "nerva", "remote", "set-url", "origin", str(Path(self.tmp.name, "gone")))
        done = self.night("--dry-run")
        self.assertIn("git fetch failed", done.stderr)
        self.assertNotIn("would set status", done.stdout)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_failed_checkout_aborts_the_night_as_the_hosts(self):
        self.assertEqual(self.night("--dry-run").returncode, 0)
        clone = self.home / "nerva"
        self.write_remote_tree(self.remote, "two")
        self.git(self.remote, "add", "-A")
        self.commit(self.remote, "two")
        (clone / "marker").write_text("local edit\n")  # conflicts with the incoming change
        done = self.night("--dry-run")
        self.assertIn("git checkout of the fetched tip failed", done.stderr)
        self.assertNotIn("run 1", done.stderr)
        self.assertNotIn("would set status", done.stdout)  # it tested nothing
        self.assertIn("the night did not run: git checkout", done.stdout)

    def holding(self):
        """A process holding the night's lock, as a running night does."""
        self.home.mkdir(parents=True, exist_ok=True)
        holder = subprocess.Popen(["flock", str(self.home / "nightly.lock"), "sleep", "60"])
        self.addCleanup(holder.kill)
        lock = self.home / "nightly.lock"
        for _ in range(100):
            probe = subprocess.run(["flock", "-n", str(lock), "true"])
            if probe.returncode != 0:
                return
            time.sleep(0.05)
        self.fail("the holder never took the lock")

    def push(self, remote, message, edit):
        """A new commit on `remote` whose nightly.sh is the current one, passed through `edit`."""
        script = Path(remote, "ops/jepsen/nightly.sh")
        shutil.copy(HERE / "nightly.sh", script)
        script.write_text(edit(script.read_text()) + f"# {message}\n")
        self.git(remote, "add", "-A")
        self.commit(remote, message)

    def test_the_lock_is_held_by_the_night_and_not_by_its_children(self):
        # The lock is held while run.sh runs, and run.sh (a child) has no fd 9, so an orphan
        # cannot keep it.
        probe = Path(self.tmp.name, "probe")
        run = ("#!/bin/sh\nino=$(stat -c %i " + str(self.home) + "/nightly.lock)\n"
               "holder=$(awk -v ino=$ino '$2==\"FLOCK\" {split($6,a,\":\"); if (a[3]==ino) print $5}'"
               " /proc/locks)\n"
               "fd=no; [ -e /proc/$$/fd/9 ] && fd=yes\n"
               f"echo \"$holder $fd\" > {probe}\nexit 0\n")
        Path(self.remote, "tests/jepsen/run.sh").write_text(run)
        self.git(self.remote, "add", "-A")
        self.commit(self.remote, "probe")
        done = self.night("--dry-run")
        self.assertEqual(done.returncode, 0, done.stderr)
        holder, fd = probe.read_text().split()
        self.assertTrue(holder.isdigit(), probe.read_text())
        self.assertEqual(fd, "no")

    def test_a_second_night_cannot_start_while_the_lock_is_held(self):
        self.holding()
        (self.home / "nightly.pid").write_text("4242\n")
        done = self.night("--dry-run")
        self.assertIn("another night is running (pid 4242)", done.stderr)
        self.assertEqual(list((self.home / "nights").iterdir()), [])

    def test_the_old_stage_variables_skip_nothing(self):
        env = {"JEPSEN_STAGE": "2", "JEPSEN_STAGE1_PID": "1", "JEPSEN_LOCK_HELD": "1",
               "JEPSEN_COPY_OF": str(HERE), "JEPSEN_COPY_PATH": "/nonexistent/copy"}
        self.holding()
        done = self.night("--dry-run", extra=env)
        self.assertIn("another night is running", done.stderr)

    def break_tip(self, what):
        """A new commit on the remote whose ops/jepsen files named by `what` are broken."""
        broken = {"nightly.sh": "if then fi (\n", "jepsen_report.py": "import sys\nsys.exit(7)\n"}
        for name in broken if what == "both" else [what]:
            Path(self.remote, "ops/jepsen", name).write_text(broken[name])
        Path(self.remote, "broken").write_text(f"{what} {time.monotonic()}\n")
        self.git(self.remote, "add", "-A")
        self.commit(self.remote, f"broken {what}")

    def test_a_broken_tip_changes_nothing_about_the_nights_reporting(self):
        for what in ("nightly.sh", "jepsen_report.py", "both"):
            with self.subTest(what):
                self.break_tip(what)
                done = self.night("--dry-run", extra={"JEPSEN_TRACKER": "7"})
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertIn("would set status jepsen/nightly = failure", done.stdout)
                self.assertIn("would open issue", done.stdout)
                self.assertIn("would comment on #7", done.stdout)
                self.assertNotIn("the host's:", done.stdout)
                self.assertNotIn("tip's nightly.sh", done.stderr)
                self.assertEqual(self.git(self.home / "nerva", "rev-parse", "HEAD"),
                                 self.git(self.remote, "rev-parse", "HEAD"))

    def test_two_broken_nights_and_then_a_fixed_tip_each_report(self):
        # The unit runs the installed copy; nothing in the checkout can wedge the next night.
        self.assertEqual(self.night("--dry-run").returncode, 0)
        for _ in range(2):
            self.break_tip("both")
            done = self.night("--dry-run", extra={"JEPSEN_TRACKER": "7"})
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn("would comment on #7", done.stdout)
        self.write_remote_tree(self.remote, "fixed")
        self.git(self.remote, "add", "-A")
        self.commit(self.remote, "fixed")
        done = self.night("--dry-run", extra={"JEPSEN_TRACKER": "7"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("would comment on #7", done.stdout)
        self.assertIn("would set status", done.stdout)

    def env(self, extra=None):
        return {"PATH": f"{self.bin}:{os.environ['PATH']}", "JEPSEN_HOME": str(self.home),
                "JEPSEN_REMOTE": str(self.remote), "JEPSEN_WORKLOADS": "retry",
                "JEPSEN_NEMESIS": "kill", "JEPSEN_TIME_LIMIT": "1", "HOME": self.tmp.name,
                **(extra or {})}

    def interrupt(self, hang, workloads="retry"):
        """Starts a dry night whose `hang` step (or, None, a run.sh already committed that
        touches `started`) never ends, sends TERM, returns (rc, out, err, secs)."""
        started = Path(self.tmp.name, "started")
        if hang:
            step = f"#!/bin/sh\ntouch {started}\nexec sleep 300\n"
            Path(self.remote, hang).write_text(step)
            Path(self.remote, hang).chmod(0o755)
            self.git(self.remote, "add", "-A")
            self.commit(self.remote, "hangs")
        env = self.env({"JEPSEN_TRACKER": "7", "JEPSEN_NIGHT_SECONDS": "250",
                       "JEPSEN_WORKLOADS": workloads})
        night = subprocess.Popen(["bash", str(self.installed / "nightly.sh"), "--dry-run"],
                                 env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True)
        self.addCleanup(night.kill)
        for _ in range(300):
            if started.exists():
                break
            time.sleep(0.1)
        else:
            self.fail("the hanging step never started")
        began = time.monotonic()
        night.send_signal(signal.SIGTERM)
        out, err = night.communicate(timeout=60)
        return night.returncode, out, err, time.monotonic() - began

    def test_term_mid_run_posts_error_and_the_trackers_line(self):
        code, out, err, secs = self.interrupt("tests/jepsen/run.sh")
        self.assertEqual(code, 143, err)
        self.assertLess(secs, 30)
        self.assertIn("would set status jepsen/nightly = error", out, err)
        self.assertIn("would comment on #7", out)
        self.assertNotIn("would open issue", out)
        night = next((self.home / "nights").iterdir())
        self.assertRegex((night / "store/runs").read_text(), r"^1 143 ")

    def test_term_mid_build_posts_error_and_the_trackers_line(self):
        code, out, err, secs = self.interrupt("zig/zig")
        self.assertEqual(code, 143, err)
        self.assertLess(secs, 30)
        self.assertIn("would set status jepsen/nightly = error", out)
        self.assertIn("would comment on #7", out)
        night = next((self.home / "nights").iterdir())
        self.assertIn("interrupted", (night / "store/host-failure").read_text())

    def test_term_after_a_finished_run_keeps_its_finding(self):
        # retry ends invalid; bank is stopped by TERM. The stop must not hide the finding behind
        # a host failure (P235): the night is `failure` and the issue is filed.
        count = Path(self.tmp.name, "count")
        started = Path(self.tmp.name, "started")
        first = FAKE_RUN % invalid()
        run = (f"#!/bin/sh\nif [ -e {count} ]; then touch {started}; exec sleep 300; fi\n"
               f"touch {count}\n" + first.split("\n", 1)[1])
        Path(self.remote, "tests/jepsen/run.sh").write_text(run)
        self.git(self.remote, "add", "-A")
        self.commit(self.remote, "retry then hang")
        code, out, err, secs = self.interrupt(None, "retry bank")
        self.assertEqual(code, 143, err)
        self.assertIn("would set status jepsen/nightly = failure", out, err)
        self.assertEqual(out.count("would open issue"), 1, out)
        night = next((self.home / "nights").iterdir())
        self.assertFalse((night / "store/host-failure").exists())
        self.assertRegex((night / "store/runs").read_text(), r"(?m)^2 143 ")
        # The cut-short night still archives the run that finished, and the report names it.
        archives = list((self.home / "archive").glob("*.tar.zst"))
        self.assertEqual(len(archives), 1, err)
        self.assertIn(str(archives[0]), out)

    def test_an_early_end_after_a_failed_build_keeps_the_real_reason(self):
        Path(self.remote, "zig/zig").write_text("#!/bin/sh\nexit 1\n")
        self.git(self.remote, "add", "-A")
        self.commit(self.remote, "broken build")
        shim = Path(self.bin, "tar")  # TERM arrives while the (empty) night is archived
        shim.write_text(f'#!/bin/sh\nkill -TERM "$(cat {self.home}/nightly.pid)"; sleep 5\n')
        shim.chmod(0o755)
        done = self.night("--dry-run", extra={"JEPSEN_TRACKER": "7"})
        self.assertEqual(done.returncode, 143, done.stderr)
        night = next((self.home / "nights").iterdir())
        reason = (night / "store/host-failure").read_text()
        self.assertIn("the build of", reason)
        self.assertNotIn("interrupted", reason)
        self.assertIn("would set status jepsen/nightly = error", done.stdout, done.stderr)

    def test_a_reporter_that_exits_2_is_not_called_a_second_report(self):
        Path(self.installed, "jepsen_report.py").write_text("import sys\nsys.exit(2)\n")
        done = self.night("--dry-run", extra={"JEPSEN_TRACKER": "7"})
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("the reporter exited 2", done.stderr)
        self.assertIn("rate limit or GitHub unreachable", done.stderr)
        self.assertNotIn("not reporting it twice", done.stderr)

    def test_a_finished_run_not_yet_on_record_keeps_its_finding(self):
        # retry ends invalid and TERM arrives as its store is moved, before its line is written:
        # the run's own code is recorded and the finding is reported, not hidden (P235).
        shim = Path(self.bin, "mv")
        shim.write_text(f'#!/bin/sh\ncase "$*" in *tests/jepsen/store*) kill -TERM $PPID;; esac\n'
                        f'exec {shutil.which("mv")} "$@"\n')
        shim.chmod(0o755)
        done = self.night("--dry-run", extra={"JEPSEN_TRACKER": "7",
                                              "JEPSEN_WORKLOADS": "retry bank"})
        self.assertEqual(done.returncode, 143, done.stderr)
        self.assertIn("would set status jepsen/nightly = failure", done.stdout, done.stderr)
        self.assertEqual(done.stdout.count("would open issue"), 1, done.stdout)
        night = next((self.home / "nights").iterdir())
        self.assertFalse((night / "store/host-failure").exists())
        self.assertRegex((night / "store/runs").read_text(), r"(?m)^1 0 ")

    def test_term_between_two_runs_is_never_success(self):
        # run 1 is valid; TERM arrives before run 2 starts. bank never ran: it is the host's 143.
        Path(self.remote, "tests/jepsen/run.sh").write_text(FAKE_RUN % VALID)
        self.git(self.remote, "add", "-A")
        self.commit(self.remote, "valid")
        shim = Path(self.bin, "od")
        count = Path(self.tmp.name, "od-count")
        shim.write_text(f'#!/bin/sh\nif [ -e {count} ]; then kill -TERM "$(cat {self.home}/nightly.pid)"; '
                        f'sleep 5; fi\ntouch {count}\nexec {shutil.which("od")} "$@"\n')
        shim.chmod(0o755)
        done = self.night("--dry-run", extra={"JEPSEN_TRACKER": "7",
                                              "JEPSEN_WORKLOADS": "retry bank"})
        self.assertEqual(done.returncode, 143, done.stderr)
        self.assertNotIn("= success", done.stdout, done.stderr)
        self.assertIn("would set status jepsen/nightly = error", done.stdout, done.stderr)
        night = next((self.home / "nights").iterdir())
        self.assertRegex((night / "store/runs").read_text(), r"(?m)^2 143 .*--workload bank")

    def test_term_during_the_final_report_does_not_report_twice(self):
        # systemd's TERM reaches the reporter too: this wrapper, on its first call, sends TERM to
        # the night's bash (its grandparent, past `timeout`) and dies unsaved, as a killed
        # reporter does. The trap must not run a second report.
        calls = Path(self.tmp.name, "calls")
        Path(self.installed, "jepsen_report.py").write_text(
            "import os, signal\n"
            f"calls = {str(calls)!r}\n"
            "n = len(open(calls).read().split()) if os.path.exists(calls) else 0\n"
            "open(calls, 'a').write('call\\n')\n"
            "if n == 0:\n"
            "    ppid = int(open(f'/proc/{os.getppid()}/stat').read().rsplit(')', 1)[1].split()[1])\n"
            "    os.kill(ppid, signal.SIGTERM)\n"
            "    os.kill(os.getpid(), signal.SIGKILL)\n"
            "print('would set status jepsen/nightly')\n")
        done = self.night("--dry-run", extra={"JEPSEN_TRACKER": "7"})
        self.assertEqual(calls.read_text().split(), ["call"], done.stderr)
        self.assertEqual(done.returncode, 143, done.stderr)
        self.assertIn("not reporting it twice", done.stderr)

    def test_a_set_e_abort_reports_the_night_once_as_the_hosts(self):
        # `mv` of the finished run's store fails (the disk is full, say): the night still ends
        # in one status `error` and the tracker's line, never silently.
        shim = Path(self.bin, "mv")
        shim.write_text(f'#!/bin/sh\ncase "$*" in *tests/jepsen/store*) exit 1;; esac\n'
                        f'exec {shutil.which("mv")} "$@"\n')
        shim.chmod(0o755)
        done = self.night("--dry-run", extra={"JEPSEN_TRACKER": "7"})
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(done.stdout.count("would set status jepsen/nightly = error"), 1,
                         done.stderr)
        self.assertEqual(done.stdout.count("would comment on #7"), 1)
        self.assertIn("ended early (exit 1)", done.stderr)
        self.assertNotIn("would open issue", done.stdout)

    def test_docker_info_that_hangs_is_the_hosts_failure_not_a_lost_night(self):
        docker = Path(self.bin, "docker")
        docker.write_text("#!/bin/sh\nexec sleep 300\n")
        # `timeout 60` is the script's: shorten it by shadowing `timeout` for docker only.
        shim = Path(self.bin, "timeout")
        shim.write_text(f'#!/bin/sh\n[ "$1" = 60 ] && shift && set -- 1 "$@"\n'
                        f'exec {shutil.which("timeout")} "$@"\n')
        shim.chmod(0o755)
        began = time.monotonic()
        done = self.night("--dry-run", extra={"JEPSEN_TRACKER": "7"})
        self.assertLess(time.monotonic() - began, 60)
        self.assertIn("Docker is not answering", done.stderr)
        self.assertIn("would set status jepsen/nightly = error", done.stdout)

    def test_a_real_night_that_finds_the_lock_held_exits_75(self):
        self.holding()
        token = Path(self.tmp.name, "token")
        token.write_text("secret\n")
        done = self.night(extra={"JEPSEN_TOKEN_FILE": str(token)})
        self.assertEqual(done.returncode, 75, done.stderr)
        self.assertIn("another night is running", done.stderr)

    def test_an_interrupted_run_with_a_log_and_no_results_is_not_a_crash(self):
        # Jepsen had started (a jepsen.log) and the stop killed it: the host's, no issue.
        run = ("#!/bin/sh\nd=tests/jepsen/store/t/2026-11-02T01:00:00Z\nmkdir -p $d\n"
               "echo 'lein run test --workload retry' > $d/jepsen.log\n"
               f"touch {self.tmp.name}/started\nexec sleep 300\n")
        Path(self.remote, "tests/jepsen/run.sh").write_text(run)
        self.git(self.remote, "add", "-A")
        self.commit(self.remote, "log")
        code, out, err, _ = self.interrupt(None)
        self.assertEqual(code, 143, err)
        self.assertIn("would set status jepsen/nightly = error", out)
        self.assertNotIn("would open issue", out)
        self.assertRegex(next((self.home / "nights").iterdir()).joinpath("store/runs").read_text(),
                         r"^1 143 ")

    def test_the_unit_runs_the_installed_copy_and_leaves_room_for_the_trap(self):
        unit = (HERE / "jepsen.service").read_text()
        self.assertIn("ExecStart=/opt/jepsen/bin/nightly.sh\n", unit)
        self.assertNotIn("/nerva/ops/jepsen", unit)
        stop = int(re.search(r"^TimeoutStopSec=(\d+)$", unit, re.M).group(1))
        script = (HERE / "nightly.sh").read_text()
        child = int(re.search(r"seq (\d+)", script).group(1))
        limit = int(re.search(r"report_limit=(\d+)\n  if", script).group(1))
        self.assertGreater(stop, child + limit)

    def test_the_readme_says_the_runner_changes_only_when_setup_runs_again(self):
        readme = " ".join((HERE / "README.md").read_text().split())
        self.assertIn("reaches the host only when `setup.sh` runs again", readme)
        self.assertIn("run `sh ops/jepsen/setup.sh` again", readme)

    def test_no_token_ends_the_night_at_once_before_anything_runs(self):
        Path(self.tmp.name, "empty").write_text("")
        done = self.night(extra={"JEPSEN_TOKEN_FILE": str(Path(self.tmp.name, "empty"))})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stderr.count("jepsen-nightly:"), 1)
        self.assertIn("no token", done.stderr)
        self.assertFalse((self.home / "nerva").exists())
        check = self.night("--check-token",
                           extra={"JEPSEN_TOKEN_FILE": str(Path(self.tmp.name, "empty"))})
        self.assertEqual(check.returncode, 1)

    def test_the_unit_checks_the_token_before_it_stops_the_fleet(self):
        unit = (HERE / "jepsen.service").read_text()
        check = unit.index("nightly.sh --check-token")
        self.assertLess(check, unit.index("systemctl stop sim-fleet"))
        self.assertEqual(unit[:check].splitlines()[-1].split("=")[0], "ExecStartPre")


class SetupScript(unittest.TestCase):
    """setup.sh with root, apt, systemctl and /etc faked: the timer needs a token."""

    def setup(self, token, enabled=False, umask=None, hold=False, git75=False):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name in ("apt-get", "usermod", "useradd"):
            (bin_dir / name).write_text("#!/bin/sh\nexit 0\n")
            (bin_dir / name).chmod(0o755)
        # runuser runs nothing, except that jepsen's tests also change the checkout setup.sh is run
        # from (the night does), and `exec` (a file) makes it run the command, as root would.
        (bin_dir / "runuser").write_text(
            "#!/bin/sh\nshift 3\n"
            f'case "$*" in *test_jepsen_report.py*) echo "# changed" >> {root}/nightly.sh;; esac\n'
            f'[ -e {root}/exec-runuser ] && case "$*" in *test_jepsen_report.py*) ;; '
            '*) exec "$@";; esac\nexit 0\n')
        (bin_dir / "runuser").chmod(0o755)
        (bin_dir / "id").write_text('#!/bin/sh\n[ "$1" = -u ] && echo 0\nexit 0\n')
        state = root / "timer-enabled"
        if enabled:
            state.write_text("1")
        (bin_dir / "systemctl").write_text(
            f'#!/bin/sh\necho "$@" >> {root}/systemctl.log\n'
            f'case "$*" in "enable jepsen.timer") echo 1 > {state};; '
            f'"disable --now jepsen.timer") rm -f {state};; esac\n')
        for name in ("id", "systemctl"):
            (bin_dir / name).chmod(0o755)
        (root / "etc/systemd/system").mkdir(parents=True)
        home = root / "var/lib/jepsen"
        (home / "nerva/.git").mkdir(parents=True)
        for name in ("nightly.sh", "jepsen_report.py", "jepsen.service", "jepsen.timer"):
            shutil.copy(HERE / name, root / name)
        self.root = root
        if git75:
            (root / "exec-runuser").write_text("1")
            (bin_dir / "git").write_text("#!/bin/sh\nexit 75\n")
            (bin_dir / "git").chmod(0o755)
        text = (HERE / "setup.sh").read_text().replace("/etc/", f"{root}/etc/")
        text = text.replace("/opt/jepsen", f"{root}/opt/jepsen")
        text = text.replace("/var/lib/jepsen", str(home))
        script = root / "setup.sh"
        script.write_text(text)
        shutil.copy(HERE / "jepsen.env.example", root / "jepsen.env.example")
        args = []
        if token:
            Path(root, "tok").write_text("secret\n")
            args = ["--token-file", str(root / "tok")]
        if hold:
            holder = subprocess.Popen(["flock", str(home / "nightly.lock"), "sleep", "60"])
            self.addCleanup(holder.kill)
            time.sleep(0.5)
        done = subprocess.run(
            ["sh", str(script), *args], capture_output=True, text=True,
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"}, timeout=60,
            preexec_fn=(lambda: os.umask(umask)) if umask is not None else None)
        self.timer_enabled = state.exists()
        calls = (root / "systemctl.log").read_text() if (root / "systemctl.log").exists() else ""
        return done, calls

    def test_the_timer_is_enabled_only_with_a_token(self):
        done, calls = self.setup(token=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("enable jepsen.timer", calls)
        self.assertNotIn("start jepsen.timer", calls)
        self.assertEqual(done.stderr.count("no token installed"), 1)
        done, calls = self.setup(token=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("enable jepsen.timer", calls)
        self.assertNotIn("no token installed", done.stderr)

    def test_the_runner_is_installed_from_the_checkout_it_runs_in(self):
        done, _ = self.setup(token=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        bin_dir = self.root / "opt/jepsen/bin"
        for name in ("nightly.sh", "jepsen_report.py"):
            self.assertEqual((bin_dir / name).read_text(), (HERE / name).read_text())
        self.assertTrue(os.access(bin_dir / "nightly.sh", os.X_OK))
        self.assertEqual(sorted(p.name for p in bin_dir.iterdir()),
                         ["jepsen_report.py", "nightly.sh"])
        unit = (self.root / "etc/systemd/system/jepsen.service").read_text()
        self.assertEqual(unit, (HERE / "jepsen.service").read_text())

    def test_the_runner_directories_are_readable_whatever_the_umask(self):
        done, _ = self.setup(token=True, umask=0o077)
        self.assertEqual(done.returncode, 0, done.stderr)
        for path in ("opt/jepsen", "opt/jepsen/bin"):
            self.assertEqual((self.root / path).stat().st_mode & 0o777, 0o755, path)
        for name in ("nightly.sh", "jepsen_report.py"):
            self.assertTrue((self.root / "opt/jepsen/bin" / name).stat().st_mode & 0o004)

    def test_setup_does_not_move_the_checkout_while_a_night_holds_the_lock(self):
        done, calls = self.setup(token=True, hold=True)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertIn("a night is running", done.stderr)
        self.assertFalse((self.root / "opt/jepsen/bin/nightly.sh").exists())

    def test_a_75_from_the_checkout_step_is_not_a_night_running(self):
        done, _ = self.setup(token=True, git75=True)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertNotIn("a night is running", done.stderr)
        self.assertFalse((self.root / "opt/jepsen/bin/nightly.sh").exists())

    def test_the_runner_installed_is_the_copy_that_was_tested(self):
        # The test run changes the checkout's nightly.sh (a night moving it to the tip).
        done, _ = self.setup(token=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("# changed", (self.root / "nightly.sh").read_text())
        installed = (self.root / "opt/jepsen/bin/nightly.sh").read_text()
        self.assertEqual(installed, (HERE / "nightly.sh").read_text())

    def test_a_timer_already_enabled_is_disabled_when_there_is_no_token(self):
        done, calls = self.setup(token=False, enabled=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("disable --now jepsen.timer", calls)
        self.assertEqual(self.timer_enabled, False)


if __name__ == "__main__":
    unittest.main()
