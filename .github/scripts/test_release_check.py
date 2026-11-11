#!/usr/bin/env python3
"""Tests for release_check.sh (NRV-E1112 to NRV-E1115). Run from the repository root:
python3 .github/scripts/test_release_check.py

A stand-in `nerva` and a stand-in `gh` (a script that answers from files) stand for the real two."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/scripts/release_check.sh"


def fake_nerva(directory, version, keys="deduplicate"):
    path = Path(directory) / "nerva"
    path.write_text(f"""#!/bin/sh
echo "Nerva version 0.0.6+abcdef0"
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
    """`gh api .../git/ref/tags/X` succeeds when tag_exists; `gh api .../releases` prints the lines
    a real --jq would for each release named in `releases` ('draft' or 'release')."""
    path = Path(directory) / "gh"
    path.write_text(f"""#!/bin/sh
case "$*" in
  *git/ref/tags*) exit {0 if tag_exists else 1} ;;
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

    def test_assets(self):
        with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as dist:
            for name in ("a.tar.gz", "nerva_0.7.1~rc.1-1_amd64.deb"):
                Path(dist, name).write_text("x")
            fake_gh(d, False, [], ["a.tar.gz", "nerva_0.7.1~rc.1-1_amd64.deb"])
            self.assertEqual(run("assets", "v0.7.1-rc.1", dist, path_dir=d).returncode, 0)
            fake_gh(d, False, [], ["a.tar.gz", "nerva_0.7.1.rc.1-1_amd64.deb"])
            self.refused(run("assets", "v0.7.1-rc.1", dist, path_dir=d), "NRV-E1115",
                         "does not hold the assets that were built")


if __name__ == "__main__":
    unittest.main()
