#!/usr/bin/env python3
"""Tests for release_check.sh (NRV-E1112 to NRV-E1116, mac-draft: NRV-E1119, NRV-E1120, NRV-E1122 to NRV-E1124, publish-ready: NRV-E1131, and candidate: NRV-E1158) and release_notes.sh (NRV-E1117, and `site`: NRV-E1130). Run from the repository root:
python3 .github/scripts/test_release_check.py

A stand-in `nerva` and a stand-in `gh` (a script that answers from files) stand for the real two."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/scripts/release_check.sh"


def fake_nerva(directory, version, keys="deduplicate", suffix=""):
    path = Path(directory) / "nerva"
    path.write_text(f"""#!/bin/sh
echo "Nerva version 0.0.6+abcdef0{suffix}"
echo "release 0.0.6"
echo "bundles none"
echo "version {version}"
if [ "${{1:-}}" = version ] && [ "${{2:-}}" = --verbose ]; then
  echo "commit abcdef0"
  [ -n "{keys}" ] && echo "commit_keys {keys}"
fi
exit 0
""")
    path.chmod(0o755)
    return str(path)


def fake_gh(directory, tag_exists, releases, assets=()):
    """`gh api .../git/ref/tags/X` succeeds when tag_exists is True, fails as GitHub does for a
    missing tag (HTTP 404) when it is False, and fails for another reason (HTTP 500) when it is
    "error"; `gh api .../releases` prints the lines a real --jq would for each release named in
    `releases` ('draft' or 'release')."""
    tag_branch = {True: "exit 0", False: 'echo "gh: Not Found (HTTP 404)" >&2; exit 1',
                  "error": 'echo "gh: Server Error (HTTP 500)" >&2; exit 1'}[tag_exists]
    path = Path(directory) / "gh"
    path.write_text(f"""#!/bin/sh
case "$*" in
  *git/ref/tags*) {tag_branch} ;;
  *select*assets*) printf '%s\\n' {" ".join(assets)} ;;
  *) for kind in {" ".join(releases)}; do echo $kind; done ;;
esac
""")
    path.chmod(0o755)


def run(*args, path_dir=None):
    env = dict(os.environ, GITHUB_REPOSITORY="o/r")
    if path_dir:
        env["PATH"] = f"{path_dir}:{env['PATH']}"
    return subprocess.run([str(SCRIPT), *args], capture_output=True, text=True, env=env)


class ReleaseCheck(unittest.TestCase):
    def refused(self, result, code, fragment):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"error[{code}]: release.yml: ", result.stderr)
        self.assertIn(fragment, result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)

    def test_binary_passes(self):
        with tempfile.TemporaryDirectory() as d:
            result = run("binary", fake_nerva(d, "0.7.1"), "0.7.1")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_binary_with_another_version_line(self):
        with tempfile.TemporaryDirectory() as d:
            result = run("binary", fake_nerva(d, "0.0.6"), "0.7.1")
            self.refused(result, "NRV-E1112", "reports version '0.0.6', and VERSION is 0.7.1")

    def test_binary_without_the_deduplication_line(self):
        with tempfile.TemporaryDirectory() as d:
            for keys in ("", "off"):
                result = run("binary", fake_nerva(d, "0.7.1", keys), "0.7.1")
                self.refused(result, "NRV-E1113", "not the commit-key deduplication build")

    def test_binary_with_the_keys_off_suffix(self):
        # Even when its verbose output claims deduplication: the version line is checked too (#271).
        # test_binary_passes is the control: the same fake without the suffix passes.
        with tempfile.TemporaryDirectory() as d:
            result = run("binary", fake_nerva(d, "0.7.1", suffix="+keys-off"), "0.7.1")
            self.refused(result, "NRV-E1113", "not the commit-key deduplication build")

    def test_binary_that_does_not_run(self):
        result = run("binary", "/nonexistent/nerva", "0.7.1")
        self.refused(result, "NRV-E1112", "version 'none'")

    def test_unreleased_passes(self):
        with tempfile.TemporaryDirectory() as d:
            fake_gh(d, False, [])
            self.assertEqual(run("unreleased", "v0.7.1", path_dir=d).returncode, 0)

    def test_unreleased_refuses_a_tag_a_draft_and_a_release(self):
        with tempfile.TemporaryDirectory() as d:
            fake_gh(d, True, [])
            self.refused(run("unreleased", "v0.7.1", path_dir=d), "NRV-E1114", "tag v0.7.1")
            fake_gh(d, False, ["draft"])
            self.refused(run("unreleased", "v0.7.1", path_dir=d), "NRV-E1114", "a draft named v0.7.1")
            fake_gh(d, False, ["release"])
            self.refused(run("unreleased", "v0.7.1", path_dir=d), "NRV-E1114", "a release named v0.7.1")

    def test_unreleased_stops_on_an_error_that_is_not_a_404(self):
        with tempfile.TemporaryDirectory() as d:
            fake_gh(d, "error", [])
            result = run("unreleased", "v0.7.1", path_dir=d)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("cannot tell whether the tag v0.7.1 exists", result.stderr)

    def test_ref(self):
        self.assertEqual(run("ref", "v0.7.1", "refs/heads/main").returncode, 0)
        self.assertEqual(run("ref", "v0.7.1-rc.1", "refs/heads/claude/x").returncode, 0)
        self.refused(run("ref", "v0.7.1", "refs/heads/claude/x"), "NRV-E1116",
                     "v0.7.1 is a release, and this run is on refs/heads/claude/x, not main")

    def test_the_draft_is_not_created_without_the_check_just_before(self):
        """"Re-run failed jobs" re-runs `release` and not `version`: the step that creates the
        draft must run the unreleased check itself, before `gh release create`."""
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        step = workflow.split("- name: Create the draft release")[1].split("\n      - name:")[0]
        self.assertIn("release_check.sh unreleased", step)
        self.assertLess(step.index("release_check.sh unreleased"), step.index("gh release create"))

    def test_assets(self):
        with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as dist:
            for name in ("a.tar.gz", "nerva_0.7.1.rc.1-1_amd64.deb"):
                Path(dist, name).write_text("x")
            fake_gh(d, False, [], ["a.tar.gz", "nerva_0.7.1.rc.1-1_amd64.deb"])
            self.assertEqual(run("assets", "v0.7.1-rc.1", dist, path_dir=d).returncode, 0)
            fake_gh(d, False, [], ["a.tar.gz", "nerva_0.7.1_rc.1-1_amd64.deb"])
            self.refused(run("assets", "v0.7.1-rc.1", dist, path_dir=d), "NRV-E1115",
                         "does not hold the assets that were built")


def fake_gh_draft(directory, releases="true\tabc1234", version="0.7.1", status="behind",
                  commit_fails=False, version_fails=False, files=(), compare_fails=False):
    """The calls `mac-draft` makes: the releases list (`releases`, the tab-separated line a real --jq
    prints, or "" for none), the commit a target resolves to, VERSION at that commit, and the compare
    status against main."""
    path = Path(directory) / "gh"
    path.write_text(f"""#!/bin/sh
case "$*" in
  *select*) [ -n "{releases}" ] && printf '{releases}\\n' ;;
  *commits/*) {'echo "gh: Not Found (HTTP 404)" >&2; exit 1' if commit_fails else "echo 0123456789abcdef0123456789abcdef01234567"} ;;
  *contents/VERSION*) {'echo "gh: Not Found (HTTP 404)" >&2; exit 1' if version_fails else f'echo "{version}"'} ;;
  *compare/*) {'echo "gh: Server Error (HTTP 500)" >&2; exit 1' if compare_fails else "printf '" + status + chr(92) + "n" + "".join(f + chr(92) + "n" for f in files) + "'"} ;;
esac
exit 0
""")
    path.chmod(0o755)


class MacDraft(unittest.TestCase):
    def refused(self, result, code, fragment):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"error[{code}]: mac-sign.yml: ", result.stderr)
        self.assertIn(fragment, result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)
        self.assertIn(f"::error::{code}", result.stderr)

    def test_a_draft_of_the_version_on_main_passes_and_prints_its_commit(self):
        with tempfile.TemporaryDirectory() as d:
            fake_gh_draft(d)
            result = run("mac-draft", "v0.7.1", path_dir=d)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "0123456789abcdef0123456789abcdef01234567\n")

    def test_a_published_release_or_no_release_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            fake_gh_draft(d, releases="false\tmain")
            self.refused(run("mac-draft", "v0.7.1", path_dir=d), "NRV-E1119", "release v0.7.1 is not a draft")
            fake_gh_draft(d, releases="")
            self.refused(run("mac-draft", "v0.7.1", path_dir=d), "NRV-E1119", "no draft release named v0.7.1")

    def test_a_target_whose_version_is_not_the_tag_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            fake_gh_draft(d, version="0.7.0")
            self.refused(run("mac-draft", "v0.7.1", path_dir=d), "NRV-E1120",
                         "whose VERSION is '0.7.0', not 0.7.1")

    def test_a_release_off_main_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            for status in ("diverged", "ahead"):
                fake_gh_draft(d, status=status, files=("VERSION",))
                self.refused(run("mac-draft", "v0.7.1", path_dir=d), "NRV-E1124",
                             "v0.7.1 is a release, and its draft targets 0123456, which is not on main")
            for status in ("identical", "behind"):
                fake_gh_draft(d, status=status)
                self.assertEqual(run("mac-draft", "v0.7.1", path_dir=d).returncode, 0)

    def test_a_prerelease_on_main_or_ahead_with_only_the_version_bump_passes(self):
        with tempfile.TemporaryDirectory() as d:
            for status, files in (("behind", ()), ("identical", ()), ("ahead", ("VERSION",)),
                                  ("ahead", ("CHANGELOG.md", "VERSION")), ("diverged", ("VERSION",))):
                fake_gh_draft(d, version="0.7.1-rc.2", status=status, files=files)
                result = run("mac-draft", "v0.7.1-rc.2", path_dir=d)
                self.assertEqual(result.returncode, 0, (status, files, result.stderr))

    def test_a_prerelease_ahead_of_main_with_another_file_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            for files in (("VERSION", "build.zig"), ("zig/download.sh",), ("VERSION", "docs/CHANGELOG.md")):
                fake_gh_draft(d, version="0.7.1-rc.2", status="ahead", files=files)
                self.refused(run("mac-draft", "v0.7.1-rc.2", path_dir=d), "NRV-E1124",
                             "v0.7.1-rc.2 is a prerelease, and its draft targets 0123456, which changes "
                             "more than VERSION and CHANGELOG.md on top of main")

    def test_a_compare_that_fails_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            for tag in ("v0.7.1", "v0.7.1-rc.2"):
                fake_gh_draft(d, version=tag[1:], compare_fails=True)
                result = run("mac-draft", tag, path_dir=d)
                self.refused(result, "NRV-E1122",
                             "cannot compare the commit 0123456, which the draft " + tag + " targets, with main")
                self.assertNotIn("HTTP 500", result.stderr)

    def test_a_tag_that_is_not_v_version_is_refused(self):
        for tag in ("main", "0.7.1", "v0.7.1 "):
            result = run("mac-draft", tag)
            self.refused(result, "NRV-E1123", f"'{tag}' is not a release tag v<VERSION>")

    def test_a_target_or_version_that_cannot_be_read_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            fake_gh_draft(d, commit_fails=True)
            self.refused(run("mac-draft", "v0.7.1", path_dir=d), "NRV-E1122",
                         "cannot read the commit abc1234 that the draft v0.7.1 targets")
            fake_gh_draft(d, version_fails=True)
            result = run("mac-draft", "v0.7.1", path_dir=d)
            self.refused(result, "NRV-E1122", "cannot read VERSION at 0123456")
            self.assertNotIn("HTTP 404", result.stderr)

    def test_the_workflow_checks_the_draft_before_the_secrets_and_again_before_the_upload(self):
        workflow = (ROOT / ".github/workflows/mac-sign.yml").read_text()
        call = 'mac-draft "$TAG")'
        self.assertNotIn(".github/scripts/release_check.sh mac-draft", workflow)
        self.assertNotIn(".github/scripts/mac_keychain.sh", workflow.split("steps:")[1])
        keychain = workflow.index('"$RUNNER_TEMP/wf/mac_keychain.sh" create')
        upload = workflow.index('mac-upload "$TAG"')
        self.assertEqual(workflow.count(call), 2)
        self.assertLess(workflow.index(call), keychain)
        self.assertLess(keychain, workflow.index(call, keychain))
        self.assertLess(workflow.index(call, keychain), upload)


def release_assets(tag, extra=(), without=()):
    """The fourteen names a release is published with, as the comma-joined list `gh` prints."""
    filever = tag[1:].replace("-", ".")
    names = [f"nerva-{tag}-{t}.tar.gz" for t in ("x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos")]
    names += [f"nerva_{filever}-1_amd64.deb", f"nerva_{filever}-1_arm64.deb",
              f"nerva-{filever}-1.x86_64.rpm", f"nerva-{filever}-1.aarch64.rpm",
              f"nerva-{tag}-x86_64-linux.debug", f"nerva-{tag}-aarch64-linux.debug",
              f"nerva-{tag}.cdx.json", "SHA256SUMS",
              f"nerva-{tag}-universal-macos.zip", f"nerva-{tag}-universal-macos.zip.sha256"]
    return ",".join([n for n in names if n not in without] + list(extra))


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t",
                           "-c", "commit.gpgsign=false", *args],
                          capture_output=True, text=True, check=True).stdout.strip()


class Candidate(unittest.TestCase):
    """`candidate` (NRV-E1158) in a throwaway repository: a candidate commit, then a release commit."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name)
        git(self.repo, "init", "-q", "-b", "main")
        for name in ("src/a.zig", "build.zig", "zig/download.sh", "docs/x.md", "packaging/i.sh", "VERSION"):
            self.write(name, "1\n")
        self.candidate = self.commit("candidate")

    def write(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", message)
        return git(self.repo, "rev-parse", "HEAD")

    def pin(self, text=None):
        """Name the candidate on main, in a commit of its own (the release commit follows)."""
        self.write("release/candidate", (text if text is not None else self.candidate) + "\n")
        return self.commit("pin the candidate")

    def check(self, tag="v0.7.1", commit=None, *before):
        commit = commit or git(self.repo, "rev-parse", "HEAD")
        env = dict(os.environ, GITHUB_REPOSITORY="o/r")
        return subprocess.run([str(SCRIPT), "candidate", tag, commit, *before], capture_output=True, text=True,
                              env=env, cwd=self.repo)

    def refused(self, result, fragment):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("error[NRV-E1158]: release.yml: ", result.stderr)
        self.assertIn(fragment, result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)

    def test_identical_pinned_paths_pass_with_packaging_docs_and_version_changed(self):
        self.pin()
        self.write("packaging/i.sh", "2\n")
        self.write("docs/x.md", "2\n")
        self.write(".github/workflows/release.yml", "x\n")
        self.write("VERSION", "2\n")
        self.commit("release")
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def drifted(self, change, name):
        self.pin()
        change()
        self.commit("drift")
        result = self.check()
        self.refused(result, "pinned path")
        self.assertIn(name, result.stderr)

    def test_a_drifted_pinned_path_is_refused_and_named(self):
        for n, path in enumerate(("src/a.zig", "build.zig", "zig/download.sh", "build.zig.zon", "src/new/b.zig")):
            git(self.repo, "checkout", "-q", "-B", f"t{n}", self.candidate)
            self.drifted(lambda: self.write(path, "changed\n"), path)

    def test_a_non_ascii_path_under_src_is_refused_and_named_unquoted(self):
        self.drifted(lambda: self.write("src/\u00e9.zig", "x\n"), "src/\u00e9.zig")

    def test_a_path_with_a_quote_under_src_is_refused(self):
        self.drifted(lambda: self.write('src/a"b.zig', "x\n"), "pinned path")

    def test_a_deleted_pinned_path_is_refused(self):
        self.drifted(lambda: (self.repo / "src/a.zig").unlink(), "src/a.zig")

    def test_a_rename_out_of_src_is_refused(self):
        self.drifted(lambda: (self.repo / "src/a.zig").rename(self.repo / "docs/a.zig"), "src/a.zig")

    def test_a_gitattributes_anywhere_is_refused(self):
        for path in (".gitattributes", "src/.gitattributes", "docs/.gitattributes", ".gitmodules"):
            git(self.repo, "checkout", "-q", "-B", "ga", self.candidate)
            self.drifted(lambda: self.write(path, "src/** eol=crlf\n"), path)

    def test_a_git_failure_is_refused_not_passed(self):
        self.pin()
        self.write("src/a.zig", "2\n")
        drift = self.commit("drift")
        blob = git(self.repo, "rev-parse", f"{drift}:src/a.zig")
        (self.repo / ".git/objects" / blob[:2] / blob[2:]).unlink()
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("error[NRV-E1158]", result.stderr)

    def test_a_pinned_path_changed_and_changed_back_passes(self):
        self.pin()
        self.write("src/a.zig", "2\n")
        self.commit("change")
        self.write("src/a.zig", "1\n")
        self.commit("back")
        self.assertEqual(self.check().returncode, 0)

    def test_a_missing_file_is_refused_for_a_release_and_passed_for_a_prerelease(self):
        self.write("docs/x.md", "2\n")
        self.commit("no pin")
        self.refused(self.check(), "release/candidate is missing")
        self.assertEqual(self.check("v0.7.1-rc.1").returncode, 0)

    def test_a_prerelease_with_the_file_is_checked(self):
        self.pin()
        self.write("src/a.zig", "2\n")
        self.commit("drift")
        self.refused(self.check("v0.7.1-rc.1"), "pinned path")

    def test_a_malformed_file_is_refused(self):
        for text in ("5d7d806", self.candidate.upper(), self.candidate + "\n" + self.candidate, "x" * 40):
            self.pin(text)
            self.commit("release " + text[:8])
            self.refused(self.check(), "is not one line of 40 lowercase hex characters")

    def test_a_candidate_that_is_not_an_ancestor_is_refused(self):
        git(self.repo, "checkout", "-q", "-b", "other", self.candidate)
        self.write("docs/x.md", "other\n")
        other = self.commit("other")
        git(self.repo, "checkout", "-q", "main")
        self.pin(other)
        self.commit("release")
        self.refused(self.check(), "is not an ancestor")

    def test_a_candidate_that_does_not_exist_is_refused(self):
        self.pin("0" * 40)
        self.commit("release")
        self.refused(self.check(), "is not an ancestor")

    def test_an_unknown_commit_is_refused(self):
        self.refused(self.check(commit="1" * 40), "cannot read the commit")

    def test_a_root_commit_is_refused(self):
        self.refused(self.check(commit=self.candidate), "has no parent")

    def swap(self, squash):
        """The attack: a fix lands after the soaked candidate, then the release commit repoints the file."""
        self.pin()
        self.write("src/a.zig", "fix\n")
        fix = self.commit("unsoaked fix")
        if squash:
            self.write("release/candidate", fix + "\n")
            self.write("VERSION", "2\n")
            self.commit("release")
        else:
            git(self.repo, "checkout", "-q", "-b", "pr", "HEAD")
            self.write("release/candidate", fix + "\n")
            self.commit("repoint")
            self.write("VERSION", "2\n")
            self.commit("bump")
            git(self.repo, "checkout", "-q", "main")
            git(self.repo, "merge", "-q", "--no-ff", "-m", "merge", "pr")

    def test_the_release_commit_may_not_repoint_the_candidate_squash(self):
        self.swap(squash=True)
        self.refused(self.check(), "changes release/candidate")

    def test_the_release_commit_may_not_repoint_the_candidate_merge_commit(self):
        self.swap(squash=False)
        self.refused(self.check(), "changes release/candidate")

    def test_a_release_commit_that_adds_the_file_is_refused_even_for_a_prerelease(self):
        self.write("docs/x.md", "2\n")
        self.commit("main")
        self.pin()
        self.refused(self.check("v0.7.1-rc.1"), "release/candidate is missing")

    def rebase_merged(self):
        """A rebase merge: `repoint` and `bump` both land on main, in one push."""
        self.pin()
        before = git(self.repo, "rev-parse", "HEAD")
        self.write("src/a.zig", "fix\n")
        fix = self.commit("unsoaked fix")
        self.write("release/candidate", fix + "\n")
        self.commit("repoint")
        self.write("VERSION", "2\n")
        self.commit("bump")
        return before

    def test_a_rebase_merged_repoint_and_bump_in_one_push_is_refused(self):
        before = self.rebase_merged()
        # The first parent rule alone is blind to it: this is why the push's `before` is checked.
        self.assertEqual(self.check().returncode, 0)
        self.refused(self.check("v0.7.1", None, before), "changed within the push")

    def test_a_candidate_repointed_in_an_earlier_push_is_honoured(self):
        self.write("src/a.zig", "fix\n")
        fix = self.commit("fix")
        self.pin(fix)
        before = git(self.repo, "rev-parse", "HEAD")
        self.write("VERSION", "2\n")
        self.commit("release")
        self.assertEqual(self.check("v0.7.1", None, before).returncode, 0)

    def test_a_before_of_all_zeros_is_refused(self):
        self.pin()
        self.write("VERSION", "2\n")
        self.commit("release")
        self.refused(self.check("v0.7.1", None, "0" * 40), "all zeros")

    def test_a_before_that_is_not_an_ancestor_is_refused(self):
        self.pin()
        self.write("VERSION", "2\n")
        self.commit("release")
        git(self.repo, "checkout", "-q", "-b", "side", self.candidate)
        self.write("docs/x.md", "side\n")
        side = self.commit("side")
        git(self.repo, "checkout", "-q", "main")
        self.refused(self.check("v0.7.1", None, side), "not an ancestor")

    def test_a_before_that_is_not_fetchable_is_refused(self):
        self.pin()
        self.write("VERSION", "2\n")
        self.commit("release")
        self.refused(self.check("v0.7.1", None, "1" * 40), "not in this checkout")

    def test_a_dispatch_has_no_before_and_a_release_is_refused(self):
        self.pin()
        self.write("VERSION", "2\n")
        self.commit("release")
        self.refused(self.check("v0.7.1", None, ""), "no push to check")

    def test_a_prerelease_dispatch_is_checked_at_the_first_parent_only(self):
        self.pin()
        self.write("VERSION", "2\n")
        self.commit("release")
        result = self.check("v0.7.1-rc.1", None, "")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("a dispatch", result.stderr)

    def test_a_shallow_clone_is_named(self):
        self.pin()
        self.write("VERSION", "2\n")
        self.commit("release")
        shallow = Path(self._tmp.name + "-shallow")
        self.addCleanup(shutil.rmtree, shallow, True)
        git(self.repo.parent, "clone", "-q", "--depth", "1", "file://" + str(self.repo), str(shallow))
        env = dict(os.environ, GITHUB_REPOSITORY="o/r")
        head = git(shallow, "rev-parse", "HEAD")
        result = subprocess.run([str(SCRIPT), "candidate", "v0.7.1", head], capture_output=True,
                                text=True, env=env, cwd=shallow)
        self.refused(result, "shallow clone")

    def test_the_workflows_run_it(self):
        release = (ROOT / ".github/workflows/release.yml").read_text()
        call = 'release_check.sh candidate "$TAG" "$GITHUB_SHA" "$BEFORE"'
        self.assertIn("fetch-depth: 0", release.split("  ci:")[0])
        self.assertIn("BEFORE: ${{ github.event.before }}", release.split("  ci:")[0])
        self.assertLess(release.index(call), release.index("  ci:"))
        finish = (ROOT / ".github/workflows/release-finish.yml").read_text()
        self.assertIn('release_check.sh candidate "$TAG" "$COMMIT"', finish)
        self.assertLess(finish.index("publish-ready"), finish.index("release_check.sh candidate"))
        self.assertLess(finish.index("release_check.sh candidate"),
                        finish.index('release_finish.sh publish "$TAG"'))

    def test_the_file_in_the_repository_is_a_full_sha(self):
        text = (ROOT / "release/candidate").read_text()
        self.assertRegex(text, r"^[0-9a-f]{40}\n$")


class PublishReady(unittest.TestCase):
    """`publish-ready` shares mac-draft's target checks, which print as release.yml's."""

    def refused(self, result, code, fragment):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"error[{code}]: release.yml: ", result.stderr)
        self.assertIn(fragment, result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)
        self.assertIn(f"::error::{code}", result.stderr)

    def gh(self, d, tag="v0.7.1", draft="true", assets=None, prerelease=None, **kwargs):
        names = release_assets(tag) if assets is None else assets
        flag = ("true" if "-" in tag else "false") if prerelease is None else prerelease
        fake_gh_draft(d, releases=f"{draft}\\tabc1234\\t{flag}\\t{names}", version=tag[1:], **kwargs)

    def test_a_draft_with_every_asset_on_main_passes_and_prints_its_commit(self):
        with tempfile.TemporaryDirectory() as d:
            for tag in ("v0.7.1", "v0.7.1-rc.1"):
                self.gh(d, tag)
                result = run("publish-ready", tag, path_dir=d)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "0123456789abcdef0123456789abcdef01234567\n")

    def test_a_release_that_is_already_published_carries_on(self):
        with tempfile.TemporaryDirectory() as d:
            self.gh(d, draft="false")
            self.assertEqual(run("publish-ready", "v0.7.1", path_dir=d).returncode, 0)

    def test_no_release_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            fake_gh_draft(d, releases="")
            self.refused(run("publish-ready", "v0.7.1", path_dir=d), "NRV-E1131",
                         "there is no release named v0.7.1 to publish")

    def test_a_missing_or_extra_asset_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            self.gh(d, assets=release_assets("v0.7.1", without=("nerva-v0.7.1-universal-macos.zip",)))
            result = run("publish-ready", "v0.7.1", path_dir=d)
            self.refused(result, "NRV-E1131", "does not hold exactly the assets it is published with")
            self.assertIn("nerva-v0.7.1-universal-macos.zip", result.stderr)
            self.gh(d, assets=release_assets("v0.7.1", extra=("stray.txt",)))
            self.refused(run("publish-ready", "v0.7.1", path_dir=d), "NRV-E1131", "stray.txt")

    def test_a_target_off_main_or_with_the_wrong_version_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            self.gh(d, status="diverged", files=("VERSION",))
            self.refused(run("publish-ready", "v0.7.1", path_dir=d), "NRV-E1124", "which is not on main")
            fake_gh_draft(d, releases=f"true\\tabc1234\\tfalse\\t{release_assets('v0.7.1')}", version="0.7.0")
            self.refused(run("publish-ready", "v0.7.1", path_dir=d), "NRV-E1120", "whose VERSION is '0.7.0'")

    def test_a_prerelease_flag_that_disagrees_with_the_tag_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            self.gh(d, "v0.7.1", prerelease="true")
            self.refused(run("publish-ready", "v0.7.1", path_dir=d), "NRV-E1133",
                         "the release v0.7.1 is marked prerelease=true, and its tag says false")
            self.gh(d, "v0.7.1-rc.2", prerelease="false")
            result = run("publish-ready", "v0.7.1-rc.2", path_dir=d)
            self.refused(result, "NRV-E1133", "the release v0.7.1-rc.2 is marked prerelease=false, and its tag says true")
            self.assertIn("gh release edit v0.7.1-rc.2 --prerelease=true", result.stderr)

    def test_a_tag_that_is_not_v_version_is_refused(self):
        for tag in ("main", "0.7.1", "v0.7.1 "):
            self.refused(run("publish-ready", tag), "NRV-E1131", f"'{tag}' is not a release tag v<VERSION>")

    def test_a_release_the_script_cannot_list_stops_the_run(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "gh").write_text('#!/bin/sh\necho "gh: Server Error (HTTP 500)" >&2\nexit 1\n')
            Path(d, "gh").chmod(0o755)
            result = run("publish-ready", "v0.7.1", path_dir=d)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("cannot list the releases", result.stderr)


NOTES = ROOT / ".github/scripts/release_notes.sh"


def notes(changelog):
    """Runs release_notes.sh v0.7.1 in a scratch directory holding `changelog` as CHANGELOG.md."""
    with tempfile.TemporaryDirectory() as d:
        Path(d, "CHANGELOG.md").write_text(changelog)
        return subprocess.run([str(NOTES), "v0.7.1"], cwd=d, capture_output=True, text=True)


class ReleaseNotes(unittest.TestCase):
    def test_a_clean_section_passes(self):
        result = notes("## v0.7.2 - next\n\nx\n\n## v0.7.1 \u2014 2026-11-12\n\nShipped.\n\n## v0.7.0 \u2014 d\n\nTO FILL\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Shipped.\n")

    def test_a_placeholder_is_refused(self):
        result = notes("## v0.7.1 \u2014 2026-11-12\n\n- Jepsen: **TO FILL**\n")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("error[NRV-E1117]: release.yml: the CHANGELOG.md notes for v0.7.1 still hold a TO FILL placeholder", result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)
        self.assertIn("::error::NRV-E1117", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_a_placeholder_in_another_section_is_not_this_ones(self):
        self.assertEqual(notes("## v0.7.1 \u2014 d\n\nok\n\n## v0.7.0 \u2014 d\n\nTO FILL\n").returncode, 0)

    def test_a_missing_or_empty_section_is_refused(self):
        for text in ("## v0.7.0 \u2014 d\n\nx\n", "## v0.7.1 \u2014 d\n\n\n## v0.7.0 \u2014 d\n\nx\n"):
            result = notes(text)
            self.assertEqual(result.returncode, 1)
            self.assertIn("has no notes for v0.7.1", result.stderr)


SITE_LINE = "<!-- site: The first release for outside users: a signed Mac binary. -->"


def site(changelog, tag="v0.7.1"):
    with tempfile.TemporaryDirectory() as d:
        Path(d, "CHANGELOG.md").write_text(changelog)
        return subprocess.run([str(NOTES), "site", tag], cwd=d, capture_output=True, text=True)


class SiteLine(unittest.TestCase):
    def refused(self, result, fragment):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("error[NRV-E1130]: release.yml: ", result.stderr)
        self.assertIn(fragment, result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)
        self.assertIn("::error::NRV-E1130", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_the_line_is_printed_and_dropped_from_the_notes(self):
        changelog = f"## v0.7.2 \u2014 d\n{SITE_LINE.replace('first', 'other')}\nx\n\n## v0.7.1 \u2014 2026-11-13\n{SITE_LINE}\n\nShipped.\n"
        result = site(changelog)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "The first release for outside users: a signed Mac binary.\n")
        result = notes(changelog)
        self.assertEqual(result.stdout, "Shipped.\n")

    def test_a_missing_line_is_refused_for_a_release_and_defaulted_for_a_prerelease(self):
        self.refused(site("## v0.7.1 \u2014 d\n\nShipped.\n"), "the CHANGELOG.md section of v0.7.1 has no site line")
        self.refused(site("## v0.7.0 \u2014 d\n" + SITE_LINE + "\n"), "has no site line")
        result = site("## v0.7.1-rc.1 \u2014 d\n\nShipped.\n", "v0.7.1-rc.1")
        self.assertEqual((result.returncode, result.stdout), (0, "Release candidate v0.7.1-rc.1.\n"))

    def test_an_empty_long_or_unsafe_line_is_refused(self):
        for text, fragment in (("<!-- site: -->", "is empty"), ("<!-- site:    -->", "is empty"),
                               (f"<!-- site: {'x' * 301} -->", "301 characters, over the limit of 300"),
                               *((f"<!-- site: a{c}b -->", "a character the site does not take")
                                 for c in ('"', "\\", "<", ">", "&", "`", "\x01", "\u00e9", "\u2014")),
                               ("<!-- site: TO FILL -->", "still holds a TO FILL")):
            self.refused(site(f"## v0.7.1 \u2014 d\n{text}\n\nx\n"), fragment)
        self.assertEqual(site(f"## v0.7.1 \u2014 d\n<!-- site: {'x' * 300} -->\n\nx\n").returncode, 0)
        self.refused(site("## v0.7.1 \u2014 d\n<!-- site: a -- b -->\n\nx\n"), "holds '--'")
        # `-->` inside the sentence is refused too (it holds a `>`), never cut at the first one.
        self.refused(site("## v0.7.1 \u2014 d\n<!-- site: a --> b -->\n\nx\n"), "a character the site does not take")
        # A prerelease's bad line is still refused: only a missing one is defaulted.
        self.refused(site('## v0.7.1-rc.1 \u2014 d\n<!-- site: "x" -->\n', "v0.7.1-rc.1"), "a character the site does not take")

    def test_two_site_lines_are_refused_and_a_fenced_one_does_not_count(self):
        self.refused(site(f"## v0.7.1 \u2014 d\n<!-- site: One. -->\n<!-- site: Two. -->\n\nx\n"),
                     "has more than one site line")
        fenced = "```\n<!-- site: Example sentence. -->\n```\n"
        self.refused(site(f"## v0.7.1 \u2014 d\n\nHow:\n{fenced}"), "has no site line")
        both = f"## v0.7.1 \u2014 d\n<!-- site: Real. -->\n\n{fenced}\n<!-- site: Other. -->\n"
        self.refused(site(both), "has more than one site line")
        one = f"## v0.7.1 \u2014 d\n<!-- site: Real. -->\n\nHow:\n{fenced}"
        self.assertEqual(site(one).stdout, "Real.\n")
        # The notes drop that line only: the example inside the fence stays.
        self.assertEqual(notes(one).stdout, "How:\n" + fenced)

    def test_only_the_release_and_rc_versions_are_taken(self):
        for tag in ("v0.8.0-beta.1", "v0.7.1-rc", "v0.7.1-rc.1.2", "0.7.1", "v0.7"):
            self.refused(site(f"## {tag} \u2014 d\n{SITE_LINE}\n", tag), f"'{tag}' is not a version the site can show")


if __name__ == "__main__":
    unittest.main()
