#!/usr/bin/env python3
"""Tests for release_finish.sh (NRV-E1134 to NRV-E1138; release-finish.yml's steps). Run from the
repository root: python3 -I .github/scripts/test_release_finish.py

A stand-in `gh` (a script that logs its arguments and answers from environment variables) stands for
the real one; the tap and the site are bare git repositories in a temporary directory, so the real
`git` clones, commits and pushes to them."""
import http.server
import json
import os
import re
import subprocess
import tempfile
import threading
import time
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
# MSTATE its mergeable_state, ASSET_SHA the zip checksum file's content, PUBLISHED the tags of the
# published releases (one a line). PULLS_OPEN and PULLS_CLOSED are the JSON the pull request list
# returns for each state: the call's own --jq filter is run on them with the real jq. AUTO_FAILS and
# MERGE_FAILS make `pr merge --auto` and a plain `pr merge` fail, API_FAILS every `api` call.
GH = r"""#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
[ -n "$API_FAILS" ] && [ "$1" = api ] && { echo "gh: HTTP 502" >&2; exit 1; }
case "$*" in
  "pr create"*) echo "https://github.com/o/site/pull/7" ;;
  "pr merge"*--match-head-commit*) [ -n "$HEAD_MOVED" ] && { echo "gh: head branch was modified" >&2; exit 1; }; case "$*" in *--auto*) [ -n "$AUTO_FAILS" ] && { echo "gh: auto merge is not allowed (HTTP 422)" >&2; exit 1; } ;; *) [ -n "$MERGE_FAILS" ] && { echo "gh: not mergeable" >&2; exit 1; } ;; esac; exit 0 ;;
  "pr merge"*--auto*) [ -n "$AUTO_FAILS" ] && { echo "gh: auto merge is not allowed (HTTP 422)" >&2; exit 1; }; exit 0 ;;
  "pr merge"*) [ -n "$MERGE_FAILS" ] && { echo "gh: not mergeable" >&2; exit 1; }; exit 0 ;;
  "release edit"*) [ -n "$EDIT_FAILS" ] && { echo "gh: boom (HTTP 422)" >&2; exit 1; }; exit 0 ;;
  *"pulls?head="*)
    f=; p=
    for a in "$@"; do [ "$p" = --jq ] && f=$a; p=$a; done
    case "$*" in *state=open*) j=$PULLS_OPEN ;; *) j=$PULLS_CLOSED ;; esac
    [ -n "$j" ] && printf '%s' "$j" | jq -r "$f"
    exit 0 ;;
  *git/ref/tags*) [ -n "$TAG_AT" ] && echo "$TAG_AT" || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *releases/assets/*) printf '%s' "$ASSET_SHA" ;;
  *releases*"prerelease == false"*) [ -n "$PUBLISHED" ] && printf '%s\n' "$PUBLISHED" ;;
  *releases*"select(.tag_name"*"assets[]"*) [ -n "$ASSET_ID" ] && echo "$ASSET_ID" ;;
  *releases*) echo "$DRAFT" ;;
  *check-runs*)
    n=$(cat "$GH_LOG.n" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$GH_LOG.n"
    f=; p=
    for a in "$@"; do [ "$p" = --jq ] && f=$a; p=$a; done
    c=$CHECK; [ -n "$CHECK_AFTER" ] && [ "$n" -gt 1 ] && c=$CHECK_AFTER
    j=$CHECK_RUNS
    [ -z "$j" ] && j="{\"check_runs\":[{\"id\":1,\"name\":\"site-check\",\"app\":{\"slug\":\"github-actions\"},\"conclusion\":$([ -n "$c" ] && echo "\"$c\"" || echo null)}]}"
    printf '%s' "$j" | jq -r "$f"
    exit 0 ;;
  *pulls/*"mergeable_state"*) echo "$MSTATE" ;;
  *pulls/*"head.sha"*) echo deadbeef ;;
  *pulls/*) echo "$MERGED" ;;
esac
exit 0
"""


WKD_HASH = "ndqm47zydhyqyzabecddtdk1q3bponab"
WKD = ".well-known/openpgpkey"


def make_key():
    """A throwaway armored key, made once: the release key file of these tests."""
    with tempfile.TemporaryDirectory() as home:
        os.chmod(home, 0o700)
        env = dict(os.environ, GNUPGHOME=home)
        subprocess.run(["gpg", "--batch", "--quiet", "--passphrase", "", "--quick-generate-key",
                        "Nerva Test <nerva@nerva.pro>", "ed25519", "sign", "never"],
                       env=env, check=True, capture_output=True)
        out = subprocess.run(["gpg", "--batch", "--armor", "--export"], env=env, check=True,
                             capture_output=True, text=True).stdout
        subprocess.run(["gpgconf", "--kill", "all"], env=env, capture_output=True)
        return out


def dearmor(armored):
    with tempfile.TemporaryDirectory() as home:
        os.chmod(home, 0o700)
        return subprocess.run(["gpg", "--batch", "--quiet", "--dearmor"], input=armored.encode(),
                              env=dict(os.environ, GNUPGHOME=home), check=True,
                              capture_output=True).stdout


def git(*args, cwd=None):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout


class Finish(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = make_key()
        cls.key_bin = dearmor(cls.key)

    def make_source(self):
        """This repository as the workflow's checkout sees it: `self.src` is a clone of `origin`
        taken before any tag exists (the release's tag is made after the checkout), main holds the
        key file from v0.7.1 on, v0.7.0 has none, and v0.7.2-rc.1 is tagged on a branch off main."""
        work = self.dir / "srcwork"
        self.origin = self.dir / "origin.git"
        git("init", "-q", "-b", "main", str(work))
        (work / "README.md").write_text("one\n")
        git("add", ".", cwd=work)
        git("commit", "-q", "-m", "before the key", cwd=work)
        git("tag", "v0.7.0", cwd=work)
        (work / "packaging/keys").mkdir(parents=True)
        (work / "packaging/keys/nerva-release.asc").write_text(self.key)
        git("add", ".", cwd=work)
        git("commit", "-q", "-m", "the key", cwd=work)
        git("tag", "v0.7.1", cwd=work)
        git("tag", "v0.7.1-rc.2", cwd=work)
        git("checkout", "-q", "-b", "cand", cwd=work)
        (work / "packaging/keys/nerva-release.asc").write_text("not a key\n")
        git("commit", "-q", "-am", "a broken key on a branch", cwd=work)
        git("tag", "v0.7.2-rc.1", cwd=work)
        git("tag", "v0.7.3", cwd=work)
        git("checkout", "-q", "main", cwd=work)
        git("clone", "-q", "--bare", str(work), str(self.origin))
        self.src = self.dir / "src"
        # the checkout is taken before the release's tag exists: it holds main and none of the tags
        git("clone", "-q", "--no-tags", f"file://{self.origin}", str(self.src))

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
        self.make_source()
        self.env = dict(
            os.environ, GITHUB_REPOSITORY="o/r", GH_TOKEN="s3cret-token", GH_LOG=str(self.log),
            PATH=f"{self.bin}:{os.environ['PATH']}", BOT_NAME="nerva-release[bot]",
            BOT_EMAIL="1+nerva-release[bot]@users.noreply.github.com", SITE_REPO="o/site",
            SITE_WAIT_SECONDS="1", SITE_POLL_SECONDS="1", TAG_POLL_SECONDS="0",
            DRAFT="true", TAG_AT="", MERGED="false", CHECK="", MSTATE="", ASSET_SHA="", ASSET_ID="",
            EDIT_FAILS="", PUBLISHED="", PULLS_OPEN="", PULLS_CLOSED="", AUTO_FAILS="", MERGE_FAILS="", CHECK_AFTER="", CHECK_RUNS="", HEAD_MOVED="", API_FAILS="", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
        )

    def run_script(self, *args, **env):
        result = subprocess.run([str(SCRIPT), *args], capture_output=True, text=True,
                                cwd=self.src, env=dict(self.env, **env))
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

    def test_ref_takes_only_a_version_or_a_release_candidate(self):
        for tag in ("v0.7.1-beta.1", "v0.7.1-rc", "v0.7.1-rc.1.2", "v0.7.1-rc.x", "v0.7.1-"):
            self.refused(self.run_script("ref", "refs/heads/main", tag), "NRV-E1137", "is not a release tag")

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

    def test_a_tap_that_is_newer_is_not_taken_back(self):
        newer = FORMULA.replace("0.7.1", "0.7.2").replace(SHA, "c" * 64)
        url, bare = self.bare("tap", {"Formula/nerva.rb": newer})
        f, _ = self.formula()
        for cmd in ("tap-check", "tap"):
            self.refused(self.run_script(cmd, "v0.7.1", f, TAP_URL=url), "NRV-E1135", "holds version 0.7.2")
        self.assertEqual(git("rev-list", "--count", "main", cwd=bare).strip(), "1")
        # a candidate goes to its own branch and may be older than main
        rc, _ = self.formula(FORMULA.replace("0.7.1", "0.7.1-rc.2"))
        self.assertEqual(self.run_script("tap", "v0.7.1-rc.2", rc, TAP_URL=url).returncode, 0)

    def test_tap_check_commits_and_pushes_nothing(self):
        old = FORMULA.replace("0.7.1", "0.7.0").replace(SHA, "c" * 64)
        url, bare = self.bare("tap", {"Formula/nerva.rb": old})
        f, _ = self.formula()
        self.assertEqual(self.run_script("tap-check", "v0.7.1", f, TAP_URL=url).returncode, 0)
        self.assertEqual(git("show", "main:Formula/nerva.rb", cwd=bare), old)
        bad = self.dir / "bad.rb"
        bad.write_text(FORMULA + "  depends_on :macos\n")
        self.refused(self.run_script("tap-check", "v0.7.1", str(bad), TAP_URL=url), "NRV-E1135", "more than")

    def test_make_formula_fills_the_template_and_passes_the_formula_check(self):
        sha = self.dir / "sha"
        sha.write_text(f"{SHA}  x.zip\n")
        out = self.dir / "made.rb"
        self.assertEqual(self.run_script("make-formula", "v0.7.1", str(sha), str(out)).returncode, 0)
        self.assertEqual(self.run_script("formula", "v0.7.1", str(out), str(sha)).returncode, 0)
        self.assertNotIn("@", out.read_text().replace("@macos", ""))

    def test_state_says_published_or_draft(self):
        self.assertEqual(self.run_script("state", "v0.7.1", DRAFT="false").stdout, "published\n")
        self.assertEqual(self.run_script("state", "v0.7.1", DRAFT="true").stdout, "draft\n")
        self.assertEqual(self.run_script("state", "v0.7.1", DRAFT="").stdout, "draft\n")
        self.refused(self.run_script("state", "v0.7.1", API_FAILS="1"), "NRV-E1137", "cannot list the releases")

    def test_an_older_release_is_not_made_latest(self):
        self.assertEqual(self.run_script("latest-check", "v0.7.1", PUBLISHED="v0.7.0\nv0.7.1").returncode, 0)
        self.assertEqual(self.run_script("latest-check", "v0.7.1", PUBLISHED="").returncode, 0)
        self.assertEqual(self.run_script("latest-check", "v0.7.1-rc.2", PUBLISHED="v0.7.2").returncode, 0)
        newer = dict(PUBLISHED="v0.7.2\nv0.7.0")
        self.refused(self.run_script("latest-check", "v0.7.1", **newer), "NRV-E1138",
                     "not newer than the latest release v0.7.2")
        self.refused(self.run_script("latest-check", "v0.7.10", PUBLISHED="v0.7.11"), "NRV-E1138", "v0.7.11")
        self.refused(self.run_script("latest-check", "v0.7.1", API_FAILS="1"), "NRV-E1138", "cannot list")
        result = self.run_script("publish", "v0.7.1", COMMIT, TAG_AT=COMMIT, **newer)
        self.refused(result, "NRV-E1138", "not newer")
        self.assertNotIn("release edit", self.calls())

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
        self.refused(self.run_script("publish", "v0.7.1", COMMIT, DRAFT="false", TAG_AT="f" * 40), "NRV-E1138", "not at 0123456")
        self.refused(self.run_script("publish", "v0.7.1", COMMIT), "NRV-E1138", "is at 'nothing'")

    def test_a_tag_that_already_exists_elsewhere_is_refused_before_the_draft_is_published(self):
        result = self.run_script("publish", "v0.7.1", COMMIT, DRAFT="true", TAG_AT="f" * 40)
        self.refused(result, "NRV-E1138", "already exists at " + "f" * 40)
        self.assertNotIn("release edit", self.calls())
        # a tag already at the draft's target is fine; a lookup that fails for another reason is not
        self.assertEqual(self.run_script("publish", "v0.7.1", COMMIT, TAG_AT=COMMIT).returncode, 0)
        self.log.write_text("")
        self.refused(self.run_script("publish", "v0.7.1", COMMIT, API_FAILS="1"), "NRV-E1138", "cannot list")
        self.assertNotIn("release edit", self.calls())

    def test_fetching_the_checksum_fails_with_a_code(self):
        self.refused(self.run_script("fetch-sha", "v0.7.1", str(self.dir / "o"), API_FAILS="1"), "NRV-E1134", "cannot list")
        self.refused(self.run_script("fetch-sha", "v0.7.1", str(self.dir / "o")), "NRV-E1134", "has no")

    def test_a_failed_edit_is_refused(self):
        self.refused(self.run_script("publish", "v0.7.1", COMMIT, EDIT_FAILS="1"), "NRV-E1138",
                     "could not be published")

    # the site (NRV-E1136, E1132)
    def test_a_release_opens_the_site_pull_request_and_merges_it_at_the_checked_commit(self):
        url, bare = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK="success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "7")
        page = git("show", "release/v0.7.1:index.html", cwd=bare)
        self.assertIn('{v:"0.7.1", date:"2026-11-13", d:"A line."}', page)
        self.assertEqual(git("show", "main:index.html", cwd=bare), PAGE)
        self.assertIn("pr create --repo o/site --base main --head release/v0.7.1", self.calls())
        tip = git("rev-parse", "release/v0.7.1", cwd=bare).strip()
        self.assertIn(f"pr merge 7 --repo o/site --squash --match-head-commit {tip}", self.calls())
        self.assertNotIn("--auto", self.calls())

    def test_a_prerelease_pull_request_is_not_merged(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1-rc.2", "2026-11-13", "Release candidate v0.7.1-rc.2.", SITE_URL=url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("pr merge", self.calls())

    BOT = "nerva-release[bot]"

    def pull(self, number, sha, login=BOT, repo="o/site", merged=False):
        return {"number": number, "head": {"sha": sha, "repo": {"full_name": repo}},
                "user": {"login": login}, "merged_at": "2026-11-13T00:00:00Z" if merged else None}

    def test_a_rerun_reuses_the_branch_and_the_open_pull_request(self):
        url, bare = self.bare("site", {"index.html": PAGE})
        self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK="success")
        tip = git("rev-parse", "release/v0.7.1", cwd=bare).strip()
        self.log.write_text("")
        open_prs = json.dumps([self.pull(7, tip)])
        result = self.run_script("site", "v0.7.1", "2026-11-14", "A line.", SITE_URL=url, CHECK="success", PULLS_OPEN=open_prs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "7")
        self.assertEqual(git("rev-parse", "release/v0.7.1", cwd=bare).strip(), tip)
        self.assertNotIn("pr create", self.calls())
        # the list is asked for by owner and branch, not by the branch name alone
        self.assertIn("pulls?head=o:release/v0.7.1&state=open", self.calls())

    def test_a_fork_pull_request_of_the_same_branch_name_is_never_ours(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        # The author is the App's, so only the head repository tells a fork's pull request apart.
        fork = self.pull(99, "f" * 40, login=self.BOT, repo="fork/site")
        # a fork's open pull request, and a fork's merged one, are both passed over
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK="success",
                                 PULLS_OPEN=json.dumps([fork]), PULLS_CLOSED=json.dumps([dict(fork, merged_at="2026-11-01T00:00:00Z")]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "7")
        self.assertIn("pr create --repo o/site", self.calls())
        self.assertIn("pr merge 7 --repo o/site --squash --match-head-commit", self.calls())
        self.assertNotIn("pr merge 99", self.calls())

    def test_a_closed_pull_request_that_was_not_merged_is_not_a_merged_one(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        closed = dict(self.pull(4, "a" * 40), merged_at=None)
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK="success", PULLS_CLOSED=json.dumps([closed]))
        self.assertEqual(result.stdout.strip(), "7", result.stderr)
        self.assertIn("pr create", self.calls())

    def test_a_pull_request_by_another_author_or_at_another_commit_is_not_ours(self):
        url, bare = self.bare("site", {"index.html": PAGE})
        self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK="success")
        tip = git("rev-parse", "release/v0.7.1", cwd=bare).strip()
        for prs in ([self.pull(5, tip, login="someone")], [self.pull(5, "e" * 40)]):
            self.log.write_text("")
            result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK="success", PULLS_OPEN=json.dumps(prs))
            self.assertEqual(result.stdout.strip(), "7", result.stderr)
            self.assertIn("pr create", self.calls())
            self.assertNotIn("pr merge 5", self.calls())

    def test_our_merged_pull_request_ends_the_step(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url,
                                 PULLS_CLOSED=json.dumps([self.pull(4, "a" * 40, merged=True)]))
        self.assertEqual(result.stdout.strip(), "4", result.stderr)
        self.assertNotIn("pr create", self.calls())

    def test_a_failed_site_check_is_not_merged_and_is_refused(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url,
                                 MSTATE="clean", CHECK="failure")
        self.refused(result, "NRV-E1136", "is 'failure'")
        self.assertNotIn("pr merge", self.calls())

    def test_a_site_check_still_pending_at_the_deadline_is_not_merged_and_is_refused(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url,
                                 MSTATE="clean", CHECK="")
        self.refused(result, "NRV-E1136", "is 'missing'")
        self.assertNotIn("pr merge", self.calls())

    def test_the_check_run_is_the_latest_site_check_of_github_actions(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        runs = lambda *r: json.dumps({"check_runs": [
            {"id": i, "name": n, "app": {"slug": a}, "conclusion": c} for i, n, a, c in r]})
        gha = "github-actions"
        for expected, rs in (
            ("is 'missing'", runs((5, "site-check", "evil-app", "success"))),
            ("is 'missing'", runs((5, "other", gha, "success"))),
            ("is 'failure'", runs((2, "site-check", gha, "success"), (3, "site-check", gha, "failure"))),
            ("is 'failure'", runs((3, "site-check", gha, "failure"), (2, "site-check", gha, "success"))),
            ("is 'missing'", runs((2, "site-check", gha, "success"), (3, "site-check", gha, None))),
        ):
            self.log.write_text("")
            result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK_RUNS=rs)
            self.refused(result, "NRV-E1136", expected)
            self.assertNotIn("pr merge", self.calls())
        self.log.write_text("")
        ok = runs((2, "site-check", gha, "failure"), (3, "site-check", gha, "success"), (9, "site-check", "evil-app", "failure"))
        self.assertEqual(self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK_RUNS=ok).returncode, 0)

    def test_every_conclusion_but_success_is_refused(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        for conclusion in ("cancelled", "skipped", "neutral", "timed_out", "action_required", "stale"):
            self.log.write_text("")
            result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK=conclusion)
            self.refused(result, "NRV-E1136", f"is '{conclusion}'")
            self.assertNotIn("pr merge", self.calls())

    def test_a_pending_check_that_then_passes_is_waited_for_and_merged(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url,
                                 CHECK="", CHECK_AFTER="success", SITE_WAIT_SECONDS="30")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pr merge 7", self.calls())

    def test_a_head_that_moved_after_the_check_is_not_merged(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url,
                                 CHECK="success", HEAD_MOVED="1")
        self.refused(result, "NRV-E1136", "cannot merge the site's pull request #7")
        self.assertIn("head branch was modified", result.stderr)

    def test_a_poll_interval_below_one_second_is_refused(self):
        for bad in ("0", "x", "-1", "1.5"):
            result = self.run_script("site-wait", "7", "release", SITE_POLL_SECONDS=bad)
            self.refused(result, "NRV-E1136", "is not a whole number of seconds")
        result = self.run_script("site-wait", "7", "release", SITE_WAIT_SECONDS="x")
        self.refused(result, "NRV-E1136", "is not a whole number of seconds")

    def test_the_wait_ends_at_the_shared_deadline(self):
        past = str(int(time.time()) - 5)
        result = self.run_script("site-wait", "7", "release", SITE_DEADLINE=past, SITE_WAIT_SECONDS="600")
        self.refused(result, "NRV-E1136", "did not merge in 10 minutes")

    def test_a_pending_rule_falls_back_to_auto_merge_at_the_same_commit(self):
        url, bare = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url,
                                 MERGE_FAILS="1", CHECK="success")
        self.assertEqual(result.returncode, 0, result.stderr)
        tip = git("rev-parse", "release/v0.7.1", cwd=bare).strip()
        calls = self.calls()
        plain = f"pr merge 7 --repo o/site --squash --match-head-commit {tip}"
        auto = f"pr merge 7 --repo o/site --auto --squash --match-head-commit {tip}"
        self.assertIn(auto, calls)
        self.assertLess(calls.index(plain), calls.index(auto))

    def test_a_merge_that_gh_refuses_both_ways_after_a_passed_check_is_coded(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url,
                                 AUTO_FAILS="1", MERGE_FAILS="1", CHECK="success")
        self.refused(result, "NRV-E1136", "cannot merge the site's pull request #7")

    def test_site_check_edits_a_scratch_clone_and_writes_nothing(self):
        url, bare = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site-check", "v0.7.1", "A line.", SITE_URL=url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git("branch", "--format=%(refname:short)", cwd=bare).split(), ["main"])
        self.assertEqual(self.calls(), "")
        bad = self.run_script("site-check", "v0.6.0", "A line.", SITE_URL=url)
        self.assertEqual(bad.returncode, 1)
        self.assertIn("error[NRV-E1132]: site_release.py: ", bad.stderr)

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
        self.assertEqual(self.run_script("site-wait", "7", "release", MERGED="true", CHECK="success").returncode, 0)

    def test_a_merged_pull_request_whose_check_failed_or_is_missing_is_refused(self):
        self.refused(self.run_script("site-wait", "7", "release", MERGED="true", CHECK="failure"), "NRV-E1136", "ended failure")
        self.refused(self.run_script("site-wait", "7", "release", MERGED="true"), "NRV-E1136", "has no result on its head")

    def test_wait_gives_up_and_says_so(self):
        self.refused(self.run_script("site-wait", "7", "release"), "NRV-E1136",
                     "#7 did not merge in 0 minutes")

    def test_a_failed_site_check_ends_a_release_wait_at_once(self):
        result = self.run_script("site-wait", "7", "release", CHECK="failure", SITE_WAIT_SECONDS="600")
        self.refused(result, "NRV-E1136", "ended failure")

    def test_a_failing_call_is_not_yet_and_ends_in_a_coded_refusal(self):
        self.refused(self.run_script("site-wait", "7", "release", API_FAILS="1"), "NRV-E1136", "did not merge")
        self.refused(self.run_script("site-wait", "7", "prerelease", API_FAILS="1"), "NRV-E1136", "did not pass site-check")

    def test_a_prerelease_waits_for_the_site_check(self):
        self.assertEqual(self.run_script("site-wait", "7", "prerelease", CHECK="success").returncode, 0)
        self.refused(self.run_script("site-wait", "7", "prerelease", CHECK="failure"), "NRV-E1136", "ended failure")
        self.refused(self.run_script("site-wait", "7", "prerelease"), "NRV-E1136", "did not pass site-check")


    # the WKD pair, written into the site's pull request (P398)
    def site_files(self, bare, ref):
        return git("ls-tree", "-r", "--name-only", ref, cwd=bare).split()

    def test_a_release_writes_both_wkd_files_into_the_site_pull_request(self):
        url, bare = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK="success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git("show", f"release/v0.7.1:{WKD}/policy", cwd=bare), "")
        key = subprocess.run(["git", "show", f"release/v0.7.1:{WKD}/hu/{WKD_HASH}"], cwd=bare,
                             capture_output=True, check=True).stdout
        self.assertEqual(key, self.key_bin)
        # only the page and the two files; the site's main is untouched until the merge
        diff = git("diff", "--name-only", "main", "release/v0.7.1", cwd=bare).split()
        self.assertEqual(sorted(diff), sorted(["index.html", f"{WKD}/policy", f"{WKD}/hu/{WKD_HASH}"]))
        self.assertEqual(self.site_files(bare, "main"), ["index.html"])

    def test_a_candidate_on_main_writes_the_files_too(self):
        url, bare = self.bare("site", {"index.html": PAGE})
        self.assertEqual(self.run_script("site", "v0.7.1-rc.2", "2026-11-13", "Release candidate v0.7.1-rc.2.", SITE_URL=url).returncode, 0)
        self.assertIn(f"{WKD}/hu/{WKD_HASH}", self.site_files(bare, "release/v0.7.1-rc.2"))

    def test_a_candidate_tagged_on_a_branch_leaves_the_wkd_files_as_the_site_has_them(self):
        # the tag's key file is not even a key: it is never read as one, because the tag is not on main
        url, bare = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.2-rc.1", "2026-11-13", "Release candidate v0.7.2-rc.1.", SITE_URL=url)
        self.assertEqual(result.returncode, 1, result.stderr)  # a broken key file refuses first, see below
        # a branch candidate with a good key file: on the branch, off main
        work = self.dir / "srcwork"
        git("checkout", "-q", "cand", cwd=work)
        (work / "packaging/keys/nerva-release.asc").write_text(self.key + "\n")
        git("commit", "-q", "-am", "a key", cwd=work)
        git("tag", "v0.7.2-rc.2", cwd=work)
        git("push", "-q", str(self.origin), "cand", "v0.7.2-rc.2", cwd=work)
        # the site already holds a WKD pair from an earlier release: it stays as it is
        url, bare = self.bare("site2", {"index.html": PAGE, f"{WKD}/policy": "", f"{WKD}/hu/{WKD_HASH}": "old"})
        result = self.run_script("site", "v0.7.2-rc.2", "2026-11-13", "Release candidate v0.7.2-rc.2.", SITE_URL=url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is not on main", result.stderr)
        self.assertEqual(git("show", f"release/v0.7.2-rc.2:{WKD}/hu/{WKD_HASH}", cwd=bare), "old")
        self.assertEqual(git("diff", "--name-only", "main", "release/v0.7.2-rc.2", cwd=bare).split(), ["index.html"])

    def test_a_tag_without_a_key_file_writes_no_wkd_file(self):
        older = PAGE.replace("0.7.0", "0.6.9")
        url, bare = self.bare("site", {"index.html": older})
        # v0.7.0 has no key file: the site's pull request is the page alone
        result = self.run_script("site", "v0.7.0", "2026-11-10", "A line.", SITE_URL=url, CHECK="success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("has no packaging/keys/nerva-release.asc", result.stderr)
        self.assertEqual(self.site_files(bare, "release/v0.7.0"), ["index.html"])

    def test_an_existing_policy_file_is_kept_and_a_rerun_adds_nothing(self):
        url, bare = self.bare("site", {"index.html": PAGE, f"{WKD}/policy": "# kept\n"})
        self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK="success")
        tip = git("rev-parse", "release/v0.7.1", cwd=bare).strip()
        self.assertEqual(git("show", f"release/v0.7.1:{WKD}/policy", cwd=bare), "# kept\n")
        self.run_script("site", "v0.7.1", "2026-11-13", "A line.", SITE_URL=url, CHECK="success")
        self.assertEqual(git("rev-parse", "release/v0.7.1", cwd=bare).strip(), tip)

    def test_a_key_file_that_is_not_a_key_is_refused_before_anything_is_pushed(self):
        url, bare = self.bare("site", {"index.html": PAGE})
        result = self.run_script("site", "v0.7.3", "2026-11-13", "A line.", SITE_URL=url)
        self.refused(result, "NRV-E1136", "is not an armored key")
        self.assertNotIn("release/v0.7.3", git("branch", "-a", cwd=bare))
        self.assertNotIn("pr create", self.calls())

    def test_a_tag_this_repository_does_not_have_is_refused(self):
        url, _ = self.bare("site", {"index.html": PAGE})
        self.refused(self.run_script("site", "v0.9.9", "2026-11-13", "A line.", SITE_URL=url),
                     "NRV-E1136", "cannot read the tag v0.9.9")

    # site-live (NRV-E1151, E1162)
    def serve(self, routes):
        """A local stand-in for nerva.pro. routes: {path: (status, body)}; a callable body is
        called with the request count of the path. Returns the base URL; self.seen lists
        (path, Cache-Control) of the requests."""
        seen, counts = [], {}
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(handler):
                path = handler.path.split("?")[0]
                seen.append((handler.path, handler.headers.get("Cache-Control")))
                counts[path] = counts.get(path, 0) + 1
                status, body = routes.get(path, (404, b"not found"))
                if callable(body):
                    body = body(counts[path])
                handler.send_response(status)
                handler.send_header("Content-Length", str(len(body)))
                handler.end_headers()
                handler.wfile.write(body)
            def log_message(handler, *args):
                pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.seen = seen
        return f"http://127.0.0.1:{server.server_address[1]}"

    LIVE = dict(SITE_LIVE_WAIT_SECONDS="3", SITE_POLL_SECONDS="1")

    def test_site_live_passes_when_the_page_and_the_wkd_key_are_the_releases(self):
        page = PAGE.replace('{v:"0.7.0"', '{v:"0.7.1", date:"2026-11-13", d:"A."},\n  {v:"0.7.0"').encode()
        base = self.serve({"/": (200, page), f"/{WKD}/hu/{WKD_HASH}": (200, self.key_bin)})
        result = self.run_script("site-live", "v0.7.1", SITE_LIVE_URL=base, **self.LIVE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("shows 0.7.1", result.stdout)
        # the page is asked for uncached; the WKD file as users ask for it, with its l= parameter
        self.assertEqual(self.seen[0], ("/", "no-cache"))
        self.assertEqual(self.seen[-1][0], f"/{WKD}/hu/{WKD_HASH}?l=nerva")
        self.assertIsNone(self.seen[-1][1])

    def test_site_live_waits_for_the_page_and_then_passes(self):
        entry = '{v:"0.7.1", date:"2026-11-13", d:"A."}'
        base = self.serve({"/": (200, lambda n: (entry if n >= 3 else "{v:\"0.7.0\"").encode()),
                           f"/{WKD}/hu/{WKD_HASH}": (200, self.key_bin)})
        result = self.run_script("site-live", "v0.7.1", SITE_LIVE_URL=base, SITE_LIVE_WAIT_SECONDS="10", SITE_POLL_SECONDS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([p for p, _ in self.seen].count("/"), 3)

    def test_site_live_refuses_a_page_that_never_shows_the_release(self):
        base = self.serve({"/": (200, b'{v:"0.7.0"'), f"/{WKD}/hu/{WKD_HASH}": (200, self.key_bin)})
        result = self.run_script("site-live", "v0.7.1", SITE_LIVE_URL=base, SITE_LIVE_WAIT_SECONDS="2", SITE_POLL_SECONDS="1")
        self.refused(result, "NRV-E1151", "nerva.pro does not show 0.7.1")
        self.assertIn("packages are unaffected", result.stderr)
        self.assertIn("Retry deployment", result.stderr)
        # an unreachable site is the same: "not yet" until the deadline
        result = self.run_script("site-live", "v0.7.1", SITE_LIVE_URL="http://127.0.0.1:9", SITE_LIVE_WAIT_SECONDS="1", SITE_POLL_SECONDS="1")
        self.refused(result, "NRV-E1151", "does not show 0.7.1")

    def test_site_live_refuses_a_wkd_key_that_differs(self):
        page = b'{v:"0.7.1", date:"2026-11-13", d:"A."}'
        for served in ((200, b"another key"), (200, b""), (404, b"not found"), (500, b"oops")):
            base = self.serve({"/": (200, page), f"/{WKD}/hu/{WKD_HASH}": served})
            result = self.run_script("site-live", "v0.7.1", SITE_LIVE_URL=base, **self.LIVE)
            self.refused(result, "NRV-E1162", "WKD key differs from packaging/keys at v0.7.1")
            self.assertIn(f"served status {served[0]}", result.stderr)

    def test_site_live_without_a_reference_key_file_requires_a_404(self):
        page = b'{v:"0.7.0", date:"2026-11-10", d:"A."}'
        base = self.serve({"/": (200, page)})
        result = self.run_script("site-live", "v0.7.0", SITE_LIVE_URL=base, **self.LIVE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("has no packaging/keys/nerva-release.asc", result.stdout)
        # the SPA-style answer, the page with 200, is not a 404
        base = self.serve({"/": (200, page), f"/{WKD}/hu/{WKD_HASH}": (200, page)})
        self.refused(self.run_script("site-live", "v0.7.0", SITE_LIVE_URL=base, **self.LIVE), "NRV-E1162",
                     "serves a WKD file (status 200) although v0.7.0 has no")

    def test_site_live_is_for_releases_only(self):
        for tag in ("v0.7.1-rc.2", "0.7.1", "v0.7.1; true"):
            result = self.run_script("site-live", tag)
            self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.run_script("site-live", "v0.7.1", SITE_POLL_SECONDS="0").returncode, 1)


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
        self.assertEqual(len(used), 5)  # the identity, the two checks, the tap, the pull request and its wait
        for step in used:
            self.assertRegex(step, r"release_finish\.sh (tap|site|site-wait)\b|users/\$\{SLUG\}", step)
        self.assertEqual(self.text.count("secrets.RELEASE_APP_PRIVATE_KEY"), 1)
        self.assertEqual(self.text.count("vars.RELEASE_APP_ID"), 1)

    def test_publish_waits_for_the_mac_checks_and_names_its_environment(self):
        publish = self.text.split("\n  publish:\n")[1].split("\n  verify:\n")[0]
        self.assertIn("needs: [guard, mac, mac-verify]", publish)
        self.assertIn("environment: release-publish", publish)
        # the tap and the site come after the draft is public
        self.assertLess(publish.index('release_finish.sh publish "$TAG"'), publish.index('release_finish.sh tap "$TAG"'))
        self.assertLess(publish.index('release_finish.sh publish "$TAG"'), publish.index('release_finish.sh site "$TAG"'))
        # what can refuse without writing runs first: the token, the sentence, the tap and the site checks
        for early in ("latest-check", "release_notes.sh site", "create-github-app-token", "tap-check", "site-check"):
            self.assertLess(publish.index(early), publish.index('release_finish.sh publish "$TAG"'), early)
        self.assertLess(publish.index("release_check.sh publish-ready"), publish.index("release_finish.sh publish"))

    def test_every_script_step_fails_on_any_error(self):
        self.assertRegex(self.text, r"(?m)^defaults:\n  run:\n    shell: bash\n")
        for block in re.findall(r"(?m)^        run: \|\n((?:          .*\n|\n)+)", self.text):
            self.assertTrue(block.startswith("          set -euo pipefail\n"), block[:60])

    def test_no_workflow_writes_a_command_substitution_straight_into_an_output(self):
        # `echo "x=$(cmd)" >> $GITHUB_OUTPUT` succeeds when cmd fails (set -e does not see it)
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            for n, line in enumerate(path.read_text().splitlines(), 1):
                if re.search(r"(echo|printf)\b.*\$\(", line) and re.search(r"GITHUB_(OUTPUT|ENV|STEP_SUMMARY)", line):
                    self.fail(f"{path.name}:{n}: {line.strip()}")
        for path in sorted((ROOT / ".github/scripts").glob("*.sh")):
            for n, line in enumerate(path.read_text().splitlines(), 1):
                if re.search(r"GITHUB_(OUTPUT|ENV)", line) and "$(" in line:
                    self.fail(f"{path.name}:{n}: {line.strip()}")

    def test_a_published_release_skips_the_signing_and_publish_still_runs(self):
        self.assertIn("published: ${{ steps.refs.outputs.published }}", self.text)
        # only the signing is skipped: the published zip is still checked (steps 1 to 4, no brew yet)
        mac = self.text.split("\n  mac:\n")[1].split("\n\n")[0]
        self.assertIn("if: needs.guard.outputs.published != 'true'", mac)
        verify = self.text.split("\n  mac-verify:\n")[1].split("\n\n")[0]
        self.assertNotIn("published != 'true'", verify.split("with:")[0])
        self.assertIn("brew: ${{ needs.guard.outputs.published == 'true' && 'no' || 'yes' }}", verify)
        publish = self.text.split("\n  publish:\n")[1].split("\n  verify:\n")[0]
        self.assertIn("'[\"success\", \"skipped\"]'", publish)
        self.assertIn("needs.mac-verify.result == 'success'", publish)
        self.assertIn("make-formula", publish)

    def test_release_yml_calls_finish_after_its_draft_and_refuses_a_missing_site_line_early(self):
        release = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("uses: ./.github/workflows/release-finish.yml", release)
        self.assertIn("needs: [version, release]", release.split("  finish:")[1])
        version = release.split("\n  ci:\n")[0]
        self.assertIn('release_notes.sh site "$TAG"', version)

    def test_release_yml_drafts_only_after_ci_and_the_packaging_tests_on_the_release_commit(self):
        # #384: the draft must wait for packages.yml, called (not observed) on this very commit
        release = (ROOT / ".github/workflows/release.yml").read_text()
        packages = release.split("\n  packages:\n")[1].split("\n\n")[0]
        self.assertIn("uses: ./.github/workflows/packages.yml", packages)
        draft = release.split("\n  release:\n")[1].split("\n  finish:\n")[0]
        self.assertIn("needs: [version, ci, packages]", draft)
        self.assertNotIn("\n    if:", draft)
        self.assertIn("workflow_call:", (ROOT / ".github/workflows/packages.yml").read_text())


if __name__ == "__main__":
    unittest.main()
