#!/usr/bin/env python3
"""Tests for release_check.sh (NRV-E1112 to NRV-E1116, and mac-draft: NRV-E1119, NRV-E1120) and release_notes.sh (NRV-E1117). Run from the repository root:
python3 .github/scripts/test_release_check.py

A stand-in `nerva` and a stand-in `gh` (a script that answers from files) stand for the real two."""
import os
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


def fake_gh_draft(directory, releases="true\tabc1234", version="0.7.1", status="ahead"):
    """The calls `mac-draft` makes: the releases list (`releases`, the tab-separated line a real --jq
    prints, or "" for none), the commit a target resolves to, VERSION at that commit, and the compare
    status against main."""
    path = Path(directory) / "gh"
    path.write_text(f"""#!/bin/sh
case "$*" in
  *select*) [ -n "{releases}" ] && printf '{releases}\\n' ;;
  *commits/*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  *contents/VERSION*) echo "{version}" ;;
  *compare/*) echo "{status}" ;;
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

    def test_a_release_off_main_is_refused_and_a_prerelease_is_not_compared(self):
        with tempfile.TemporaryDirectory() as d:
            for status in ("diverged", "behind"):
                fake_gh_draft(d, status=status)
                self.refused(run("mac-draft", "v0.7.1", path_dir=d), "NRV-E1116", "which is not on main")
            fake_gh_draft(d, version="0.7.1-rc.1", status="diverged")
            self.assertEqual(run("mac-draft", "v0.7.1-rc.1", path_dir=d).returncode, 0)

    def test_a_tag_that_is_not_a_version_is_a_misuse(self):
        result = run("mac-draft", "main")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("not a release tag", result.stderr)

    def test_the_workflow_checks_the_draft_before_the_secrets_and_again_before_the_upload(self):
        workflow = (ROOT / ".github/workflows/mac-sign.yml").read_text()
        call = 'mac-draft "$TAG")'
        keychain = workflow.index("run: .github/scripts/mac_keychain.sh create")
        upload = workflow.index('gh release upload "$TAG"')
        self.assertEqual(workflow.count(call), 2)
        self.assertLess(workflow.index(call), keychain)
        self.assertLess(keychain, workflow.index(call, keychain))
        self.assertLess(workflow.index(call, keychain), upload)


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


if __name__ == "__main__":
    unittest.main()
