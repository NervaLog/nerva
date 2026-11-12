#!/usr/bin/env python3
"""Tests for release_finish.sh (NRV-E1134 to NRV-E1138; release-finish.yml's steps). Run from the
repository root: python3 -I .github/scripts/test_release_finish.py

A stand-in `gh` (a script that logs its arguments and answers from environment variables) stands for
the real one; the tap and the site are bare git repositories in a temporary directory, so the real
`git` clones, commits and pushes to them."""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/scripts/release_finish.sh"
WORKFLOW = ROOT / ".github/workflows/release-finish.yml"
SHA = "a" * 64
COMMIT = "0123456789abcdef0123456789abcdef01234567"

FORMULA = """class Nerva < Formula
  desc "Research database"
  homepage "https://github.com/NervaLog/nerva"
  url "https://github.com/NervaLog/nerva/releases/download/v0.7.1/nerva-v0.7.1-universal-macos.zip"
  version "0.7.1"
  sha256 "%s"
  license "Apache-2.0"
end
""" % SHA

PAGE = """<html><script>
const SITE = {
  updated: "2026-11-10",
  version: "0.7.0",
  released: "2026-11-10",
};
const RELEASES = [
  {v:"0.7.0", date:"2026-11-10", d:"Older."},
];
</script></html>
"""

# Answers by the first words of the call. DRAFT is true or false, TAG_AT the commit a tag ref
# resolves to ("" for none), MERGED the pull request's merged flag, CHECK the site-check conclusion,
# OPEN_PR a number or "", ASSET_SHA the zip checksum file's content.
GH = r"""#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  "pr list"*"--state open"*) [ -n "$OPEN_PR" ] && echo "$OPEN_PR" ;;
  "pr list"*) ;;
  "pr create"*) echo "https://github.com/o/site/pull/7" ;;
  "pr merge"*) exit 0 ;;
  "release edit"*) [ -n "$EDIT_FAILS" ] && { echo "gh: boom (HTTP 422)" >&2; exit 1; }; exit 0 ;;
  *git/ref/tags*) [ -n "$TAG_AT" ] && echo "$TAG_AT" || exit 1 ;;
  *releases/assets/*) printf '%s' "$ASSET_SHA" ;;
  *releases*"select(.tag_name"*"assets[]"*) [ -n "$ASSET_ID" ] && echo "$ASSET_ID" ;;
  *releases*) echo "$DRAFT" ;;
  *check-runs*) echo "$CHECK" ;;
  *pulls/*"head.sha"*) echo deadbeef ;;
  *pulls/*) echo "$MERGED" ;;
esac
exit 0
"""


def git(*args, cwd=None):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout


class Finish(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        (self.bin / "gh").write_text(GH)
        (self.bin / "gh").chmod(0o755)
        self.log = self.dir / "gh.log"
        self.log.write_text("")
        self.env = dict(
            os.environ, GITHUB_REPOSITORY="o/r", GH_TOKEN="s3cret-token", GH_LOG=str(self.log),
            PATH=f"{self.bin}:{os.environ['PATH']}", BOT_NAME="nerva-release[bot]",
            BOT_EMAIL="1+nerva-release[bot]@users.noreply.github.com", SITE_REPO="o/site",
            SITE_WAIT_SECONDS="1", SITE_POLL_SECONDS="1", TAG_POLL_SECONDS="0",
            DRAFT="true", TAG_AT="", MERGED="false", CHECK="", OPEN_PR="", ASSET_SHA="", ASSET_ID="",
            EDIT_FAILS="", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
        )

    def run_script(self, *args, **env):
        result = subprocess.run([str(SCRIPT), *args], capture_output=True, text=True,
                                env=dict(self.env, **env))
        self.assertNotIn("s3cret-token", result.stdout + result.stderr)
        return result

    def refused(self, result, code, fragment):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"error[{code}]: release-finish.yml: ", result.stderr)
        self.assertIn(fragment, result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)
        self.assertIn(f"::error::{code}", result.stderr)

    def calls(self):
        return self.log.read_text()

    def bare(self, name, files):
        """A bare repository whose main holds `files` ({path: text})."""
        work = self.dir / f"{name}-work"
        bare = self.dir / f"{name}.git"
        git("init", "-q", "-b", "main", str(work))
        for path, text in files.items():
            (work / path).parent.mkdir(parents=True, exist_ok=True)
            (work / path).write_text(text)
        git("add", ".", cwd=work)
        git("commit", "-q", "-m", "init", cwd=work)
        git("clone", "-q", "--bare", str(work), str(bare))
        return f"file://{bare}", bare

    # ref and tap-ref (NRV-E1137)
    def test_ref_takes_main_and_a_version_tag(self):
        self.assertEqual(self.run_script("ref", "refs/heads/main", "v0.7.1").returncode, 0)
        self.assertEqual(self.run_script("ref", "refs/heads/main", "v0.7.1-rc.2").returncode, 0)

    def test_ref_refuses_a_branch_and_a_bad_tag(self):
        self.refused(self.run_script("ref", "refs/heads/claude/x", "v0.7.1"), "NRV-E1137",
                     "started from refs/heads/claude/x, not main")
        self.refused(self.run_script("ref", "refs/tags/v0.7.1", "v0.7.1"), "NRV-E1137", "not main")
        self.refused(self.run_script("ref", "refs/heads/main", "0.7.1; rm -rf"), "NRV-E1137",
                     "is not a release tag")

    def test_tap_ref(self):
        self.assertEqual(self.run_script("tap-ref", "v0.7.1").stdout, "main\n")
        self.assertEqual(self.run_script("tap-ref", "v0.7.1-rc.2").stdout, "rc/v0.7.1-rc.2\n")

    # the formula (NRV-E1134)
    def formula(self, text=FORMULA):
        path = self.dir / "nerva.rb"
        path.write_text(text)
        sha = self.dir / "sha"
        sha.write_text(f"{SHA}  nerva-v0.7.1-universal-macos.zip\n")
        return str(path), str(sha)

    def test_the_formula_that_matches_the_release_passes(self):
        f, s = self.formula()
        self.assertEqual(self.run_script("formula", "v0.7.1", f, s).returncode, 0)

    def test_a_formula_that_does_not_match_is_refused(self):
        f, s = self.formula(FORMULA.replace("v0.7.1/nerva-v0.7.1", "v0.7.0/nerva-v0.7.0"))
        self.refused(self.run_script("formula", "v0.7.1", f, s), "NRV-E1134", "formula's url is")
        f, s = self.formula(FORMULA.replace('version "0.7.1"', 'version "0.7.0"'))
        self.refused(self.run_script("formula", "v0.7.1", f, s), "NRV-E1134", "formula's version is '0.7.0'")
        f, s = self.formula(FORMULA.replace(SHA, "b" * 64))
        self.refused(self.run_script("formula", "v0.7.1", f, s), "NRV-E1134", "formula's sha256 is")
        f, s = self.formula(FORMULA + '  url "https://example.com/x.zip"\n')
        self.refused(self.run_script("formula", "v0.7.1", f, s), "NRV-E1134", "formula's url is 'none'")

    def test_a_checksum_file_that_is_not_a_hash_is_refused(self):
        f, s = self.formula()
        Path(s).write_text("not a hash\n")
        self.refused(self.run_script("formula", "v0.7.1", f, s), "NRV-E1134", "does not start with a SHA-256")

    def test_fetch_sha_writes_the_first_field(self):
        out = self.dir / "out"
        self.run_script("fetch-sha", "v0.7.1", str(out), ASSET_ID="55",
                        ASSET_SHA=f"{SHA}  nerva-v0.7.1-universal-macos.zip\n")
        self.assertEqual(out.read_text(), SHA + "\n")
        self.refused(self.run_script("fetch-sha", "v0.7.1", str(out)), "NRV-E1134", "has no nerva-v0.7.1")

    # the tap's diff and commit (NRV-E1135)
    def test_tap_diff_allows_only_the_three_values(self):
        old = self.dir / "old.rb"
        old.write_text(FORMULA.replace("0.7.1", "0.7.0").replace(SHA, "c" * 64))
        new = self.dir / "new.rb"
        new.write_text(FORMULA)
        self.assertEqual(self.run_script("tap-diff", str(old), str(new)).returncode, 0)
        old.write_text(FORMULA.replace('desc "Research database"', 'desc "Other"'))
        self.refused(self.run_script("tap-diff", str(old), str(new)), "NRV-E1135",
                     "changes more than its url, version and sha256")
        old.write_text(FORMULA + "  depends_on :macos\n")
        self.refused(self.run_script("tap-diff", str(old), str(new)), "NRV-E1135", "more than")

    def test_the_first_formula_goes_to_main(self):
        url, bare = self.bare("tap", {"README.md": "tap\n"})
        f, _ = self.formula()
        result = self.run_script("tap", "v0.7.1", f, TAP_URL=url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git("show", "main:Formula/nerva.rb", cwd=bare), FORMULA)
        self.assertEqual(git("log", "-1", "--format=%s|%an", "main", cwd=bare).strip(),
                         "nerva 0.7.1|nerva-release[bot]")

    def test_a_new_version_changes_only_its_values_and_a_rerun_commits_nothing(self):
        old = FORMULA.replace("0.7.1", "0.7.0").replace(SHA, "c" * 64)
        url, bare = self.bare("tap", {"Formula/nerva.rb": old})
        f, _ = self.formula()
        self.assertEqual(self.run_script("tap", "v0.7.1", f, TAP_URL=url).returncode, 0)
        self.assertEqual(git("show", "main:Formula/nerva.rb", cwd=bare), FORMULA)
        again = self.run_script("tap", "v0.7.1", f, TAP_URL=url)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("nothing to commit", again.stdout)
        self.assertEqual(git("rev-list", "--count", "main", cwd=bare).strip(), "2")

    def test_a_formula_that_changes_another_line_is_refused_and_nothing_is_pushed(self):
        url, bare = self.bare("tap", {"Formula/nerva.rb": FORMULA.replace('"Research database"', '"X"')})
        f, _ = self.formula()
        self.refused(self.run_script("tap", "v0.7.1", f, TAP_URL=url), "NRV-E1135", "more than")
        self.assertEqual(git("rev-list", "--count", "main", cwd=bare).strip(), "1")

    def test_a_prerelease_goes_to_its_branch_and_main_is_untouched(self):
        old = FORMULA.replace("0.7.1", "0.7.0").replace(SHA, "c" * 64)
        url, bare = self.bare("tap", {"Formula/nerva.rb": old})
        f, _ = self.formula(FORMULA.replace("0.7.1", "0.7.1-rc.2").replace("v0.7.1-rc.2/", "v0.7.1-rc.2/"))
        for _ in range(2):  # the second run continues the branch
            result = self.run_script("tap", "v0.7.1-rc.2", f, TAP_URL=url)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git("show", "main:Formula/nerva.rb", cwd=bare), old)
        self.assertIn('version "0.7.1-rc.2"', git("show", "rc/v0.7.1-rc.2:Formula/nerva.rb", cwd=bare))

    def test_an_unreachable_tap_is_refused(self):
        f, _ = self.formula()
        self.refused(self.run_script("tap", "v0.7.1", f, TAP_URL=f"file://{self.dir}/none.git"),
                     "NRV-E1135", "cannot clone the tap")

    def test_git_never_gets_the_token_in_a_url_or_argument(self):
        text = SCRIPT.read_text()
        self.assertNotIn("$GH_TOKEN@", text)
        self.assertNotIn("x-access-token:", text)
        self.assertIn("password=$GH_TOKEN", text)

    # publishing (NRV-E1138)
    def test_a_draft_is_published_and_a_release_is_latest(self):
        result = self.run_script("publish", "v0.7.1", COMMIT, TAG_AT=COMMIT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release edit v0.7.1 --draft=false --latest", self.calls())

    def test_a_prerelease_is_not_latest(self):
        self.assertEqual(self.run_script("publish", "v0.7.1-rc.2", COMMIT, TAG_AT=COMMIT).returncode, 0)
        edit = [c for c in self.calls().splitlines() if c.startswith("release edit")][0]
        self.assertEqual(edit, "release edit v0.7.1-rc.2 --draft=false")

    def test_a_published_release_is_not_edited_again(self):
        self.assertEqual(self.run_script("publish", "v0.7.1", COMMIT, DRAFT="false", TAG_AT=COMMIT).returncode, 0)
        self.assertNotIn("release edit", self.calls())

    def test_a_tag_on_another_commit_or_none_is_refused(self):
        self.refused(self.run_script("publish", "v0.7.1", COMMIT, TAG_AT="f" * 40), "NRV-E1138", "not at 0123456")
        self.refused(self.run_script("publish", "v0.7.1", COMMIT), "NRV-E1138", "is at 'nothing'")

    def test_a_failed_edit_is_refused(self):
        self.refused(self.run_script("publish", "v0.7.1", COMMIT, EDIT_FAILS="1"), "NRV-E1138",
                     "could not be published")

    # the site (NRV-E1136, E1132)
    def test_a_release_opens_the_site_pull_request_and_asks_for_auto_merge(self):
        url, bare = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "7")
        page = git("show", "release/v0.7.1:index.html", cwd=bare)
        self.assertIn('{v:"0.7.1", date:"2026-11-13", d:"A line."}', page)
        self.assertEqual(git("show", "main:index.html", cwd=bare), PAGE)
        self.assertIn("pr create --repo o/site --base main --head release/v0.7.1", self.calls())
        self.assertIn("pr merge 7 --repo o/site --auto --squash", self.calls())

    def test_a_prerelease_pull_request_is_not_merged(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1-rc.2", "2026-11-13", "Release candidate v0.7.1-rc.2.", SITE_URL=url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("pr merge", self.calls())

    def test_a_rerun_reuses_the_branch_and_the_open_pull_request(self):
        url, bare = self.bare("site", {"index.html": PAGE})
        self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url)
        before = git("rev-parse", "release/v0.7.1", cwd=bare)
        self.log.write_text("")
        result = self.run_script("site", "v0.7.1", "2026-11-14", "A line.", SITE_URL=url, OPEN_PR="7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git("rev-parse", "release/v0.7.1", cwd=bare), before)
        self.assertNotIn("pr create", self.calls())

    def test_a_site_edit_that_is_refused_pushes_nothing(self):
        url, bare = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.6.0", "2026-11-13", "A line.", SITE_URL=url)
        self.assertEqual(result.returncode, 1)
        self.assertIn("error[NRV-E1132]: site_release.py: ", result.stderr)
        self.assertNotIn("release/v0.6.0", git("branch", cwd=bare))

    def test_an_unreachable_site_is_refused(self):
        self.refused(self.run_script("site", "v0.7.1", "2026-11-13", "A.", SITE_URL=f"file://{self.dir}/none.git"),
                     "NRV-E1136", "cannot clone the site")

    def test_wait_passes_when_merged(self):
        self.assertEqual(self.run_script("site-wait", "7", "release", MERGED="true").returncode, 0)

    def test_wait_gives_up_and_says_so(self):
        self.refused(self.run_script("site-wait", "7", "release"), "NRV-E1136",
                     "#7 did not merge in 0 minutes")

    def test_a_prerelease_waits_for_the_site_check(self):
        self.assertEqual(self.run_script("site-wait", "7", "prerelease", CHECK="success").returncode, 0)
        self.refused(self.run_script("site-wait", "7", "prerelease", CHECK="failure"), "NRV-E1136", "ended failure")
        self.refused(self.run_script("site-wait", "7", "prerelease"), "NRV-E1136", "did not pass site-check")


class Workflow(unittest.TestCase):
    """Properties of release-finish.yml that a review checks by eye, kept as tests."""

    text = WORKFLOW.read_text()

    def test_every_action_is_pinned_by_sha(self):
        for line in self.text.splitlines():
            m = re.match(r"\s*-?\s*uses:\s*(\S+)", line)
            if m and not m.group(1).startswith("./"):
                self.assertRegex(m.group(1), r"@[0-9a-f]{40}$", line)

    def test_no_pull_request_target_and_no_secrets_inherit(self):
        self.assertNotIn("pull_request_target", self.text)
        self.assertNotIn("secrets: inherit", self.text)

    def test_every_job_declares_its_permissions(self):
        jobs = self.text.split("\njobs:\n")[1]
        for name in re.findall(r"(?m)^  ([a-z-]+):$", jobs):
            body = re.split(r"\n  [a-z-]+:\n", jobs.split(f"\n  {name}:\n")[1])[0]
            self.assertIn("permissions:", body, name)

    def test_the_app_token_reaches_only_the_steps_that_write_to_the_tap_and_the_site(self):
        used = [step for step in self.text.split("\n      - ")[1:] if "steps.app.outputs.token" in step]
        self.assertEqual(len(used), 4)  # the identity, the tap, the pull request and its wait
        for step in used:
            self.assertRegex(step, r"release_finish\.sh (tap|site|site-wait)\b|users/\$\{SLUG\}", step)
        self.assertEqual(self.text.count("secrets.RELEASE_APP_PRIVATE_KEY"), 1)
        self.assertEqual(self.text.count("vars.RELEASE_APP_ID"), 1)

    def test_publish_waits_for_the_mac_checks_and_names_its_environment(self):
        publish = self.text.split("\n  publish:\n")[1].split("\n  verify:\n")[0]
        self.assertIn("needs: [guard, mac, mac-verify]", publish)
        self.assertIn("environment: release-publish", publish)
        # the tap and the site come after the draft is public
        self.assertLess(publish.index("release_finish.sh publish"), publish.index("release_finish.sh tap"))
        self.assertLess(publish.index("release_check.sh publish-ready"), publish.index("release_finish.sh publish"))

    def test_release_yml_calls_finish_after_its_draft_and_refuses_a_missing_site_line_early(self):
        release = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("uses: ./.github/workflows/release-finish.yml", release)
        self.assertIn("needs: [version, release]", release.split("  finish:")[1])
        version = release.split("\n  ci:\n")[0]
        self.assertIn('release_notes.sh site "$TAG"', version)


if __name__ == "__main__":
    unittest.main()
