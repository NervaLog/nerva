#!/usr/bin/env python3
"""Tests for site_release.py (NRV-E1132). Run from the repository root:
python3 -I .github/scripts/test_site_release.py"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/scripts/site_release.py"

PAGE = """<html><script>
const SITE = {
  updated: "2026-11-10",
  repo: "https://github.com/NervaLog/nerva",
  version: "0.7.0",
  released: "2026-11-10",
  stage: "Research",
};
const RELEASES = [
  {v:"0.7.0", date:"2026-11-10", d:"Older."},
  {v:"0.6.1", date:"2026-10-21", d:"Oldest."},
];
const DOCS = [
  {t:"Tutorial", path:"docs/TUTORIAL.md"},
];
</script></html>
"""


class SiteRelease(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.page = Path(self.tmp.name) / "index.html"
        self.page.write_text(PAGE)
        self.page.chmod(0o644)

    def run_script(self, *args):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), str(self.page), *args],
                              capture_output=True, text=True)

    def refused(self, result, fragment):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("error[NRV-E1132]: site_release.py: ", result.stderr)
        self.assertIn(fragment, result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)
        self.assertIn("::error::NRV-E1132", result.stderr)

    def test_a_release_is_prepended_and_the_site_keys_move(self):
        result = self.run_script("0.7.1", "2026-11-13", "A new line.")
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = (PAGE.replace('updated: "2026-11-10"', 'updated: "2026-11-13"')
                    .replace('version: "0.7.0"', 'version: "0.7.1"')
                    .replace('released: "2026-11-10"', 'released: "2026-11-13"')
                    .replace('const RELEASES = [\n', 'const RELEASES = [\n  {v:"0.7.1", date:"2026-11-13", d:"A new line."},\n'))
        self.assertEqual(self.page.read_text(), expected)
        self.assertEqual(self.page.stat().st_mode & 0o777, 0o644)
        self.assertEqual(os.listdir(self.tmp.name), ["index.html"])

    def test_a_second_run_changes_nothing(self):
        self.assertEqual(self.run_script("0.7.1", "2026-11-13", "A new line.").returncode, 0)
        once = self.page.read_text()
        result = self.run_script("0.7.1", "2026-11-14", "Another line.")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already holds 0.7.1", result.stdout)
        self.assertEqual(self.page.read_text(), once)

    def test_a_prerelease_version_is_its_own_entry(self):
        self.assertEqual(self.run_script("0.7.1-rc.1", "2026-11-12", "Release candidate v0.7.1-rc.1.").returncode, 0)
        self.assertIn('{v:"0.7.1-rc.1", date:"2026-11-12", d:"Release candidate v0.7.1-rc.1."},', self.page.read_text())

    def test_a_reshaped_page_is_refused_and_left_alone(self):
        for old, new, fragment in (
            ("const SITE = {", "const SITE =  {", "0 of 'const SITE = {'"),
            ("const RELEASES = [", "const RELEASES = {", "0 of 'const RELEASES = ['"),
            ("const RELEASES = [\n", "const RELEASES = [\n];\nconst RELEASES = [\n", "2 of 'const RELEASES = ['"),
            ('  updated: "2026-11-10",\n', "", "0 string values for 'updated'"),
            ('  version: "0.7.0",\n', '  version: "0.7.0",\n  version: "0.7.0",\n', "2 string values for 'version'"),
            ('released: "2026-11-10"', "released: released", "0 string values for 'released'"),
            ("\n];\nconst DOCS = [\n  {t:\"Tutorial\", path:\"docs/TUTORIAL.md\"},\n];\n", "\n", "has no end"),
        ):
            page = PAGE.replace(old, new)
            self.assertNotEqual(page, PAGE, old)
            self.page.write_text(page)
            self.refused(self.run_script("0.7.1", "2026-11-13", "A new line."), fragment)
            self.assertEqual(self.page.read_text(), page)

    def test_a_key_outside_site_does_not_count(self):
        self.page.write_text(PAGE.replace('  repo:', '  other: 1,\n  repo:').replace(
            "const DOCS", 'const X = {\n  version: "1",\n};\nconst DOCS'))
        self.assertEqual(self.run_script("0.7.1", "2026-11-13", "A new line.").returncode, 0)
        self.assertIn('version: "1",', self.page.read_text())

    def test_arguments_that_are_not_well_formed_are_refused(self):
        for args, fragment in (
            (("v0.7.1", "2026-11-13", "x"), "'v0.7.1' is not a version"),
            (("0.7", "2026-11-13", "x"), "'0.7' is not a version"),
            (("0.7.1", "13 Nov", "x"), "'13 Nov' is not a date"),
            (("0.7.1", "2026-11-13", ""), "the site line is empty"),
            (("0.7.1-beta", "2026-11-13", "x"), "is not a version"),
            *((("0.7.1", "2026-11-13", f"a{c}b"), "a character the site does not take")
              for c in ('"', "\\", "<", ">", "&", "`", "\t", "\x01", "\u00e9", "\u2014")),
            (("0.7.1", "2026-11-13", "x" * 301), "over 300 characters"),
        ):
            self.refused(self.run_script(*args), fragment)
            self.assertEqual(self.page.read_text(), PAGE)

    def test_a_site_line_of_exactly_300_characters_passes(self):
        self.assertEqual(self.run_script("0.7.1", "2026-11-13", "x" * 300).returncode, 0)

    def test_the_output_passes_the_sites_own_checker_when_it_is_reachable(self):
        """Runs NervaLog/nervalog.github.io's site_check.mjs (branch claude/site-check, or main once
        merged) on the output, against the page before. Skipped, and the skip says so, when the
        checkout or node is not there (SITE_REPO names the checkout)."""
        repo = Path(os.environ.get("SITE_REPO", "/home/user/nervalog.github.io"))
        node = shutil.which("node")
        shown = subprocess.run(["git", "-C", str(repo), "show", "origin/claude/site-check:.github/scripts/site_check.mjs"],
                               capture_output=True, text=True) if repo.is_dir() else None
        page = subprocess.run(["git", "-C", str(repo), "show", "origin/main:index.html"],
                              capture_output=True, text=True) if repo.is_dir() else None
        if not node or not shown or shown.returncode or page.returncode:
            self.skipTest("site_check.mjs (origin/claude/site-check of the site checkout) or node is not reachable")
        checker = Path(self.tmp.name) / "site_check.mjs"
        checker.write_text(shown.stdout)
        base = Path(self.tmp.name) / "base.html"
        base.write_text(page.stdout)
        self.page.write_text(page.stdout)
        self.assertEqual(self.run_script("9.9.9", "2099-01-01", "A sentence, with (punctuation): 1-2 and 'quotes'.").returncode, 0)
        checked = subprocess.run([node, str(checker), str(self.page), "--release", str(base), "index.html"],
                                 capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)

    def test_the_usage_is_exit_2(self):
        result = subprocess.run([sys.executable, "-I", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
