#!/usr/bin/env python3
"""Tests for sbom.py (N63). Run from the repository root: python3 .github/scripts/test_sbom.py"""
import contextlib
import importlib.util
import io
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sbom", ROOT / ".github/scripts/sbom.py")
sbom = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sbom)

HEAD = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True,
                      text=True, check=True).stdout.strip()


def refused(test, call):
    """Asserts that `call` exits with an error, without printing it."""
    with contextlib.redirect_stderr(io.StringIO()) as stderr:
        with test.assertRaises(SystemExit):
            call()
    test.assertIn("::error::", stderr.getvalue())


class Repository:
    """A copy of the three files sbom.py reads, to break them one at a time."""

    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="nerva-sbom-"))
        (self.root / "zig").mkdir()
        for path in ("UPSTREAM.md", "zig/download.sh", "build.zig"):
            shutil.copy(ROOT / path, self.root / path)

    def edit(self, path, old, new):
        text = (self.root / path).read_text()
        assert old in text, (path, old)
        (self.root / path).write_text(text.replace(old, new, 1))

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


class SbomTest(unittest.TestCase):
    def test_names_the_pins_of_this_repository(self):
        bom = sbom.sbom("v0.3.0", HEAD, ROOT)
        upstream = (ROOT / "UPSTREAM.md").read_text()
        download = (ROOT / "zig/download.sh").read_text()
        components = {c["bom-ref"]: c for c in bom["components"]}
        self.assertEqual(bom["metadata"]["component"]["version"], "0.3.0")
        self.assertIn({"name": "nerva:commit", "value": HEAD},
                      bom["metadata"]["component"]["properties"])
        self.assertIn(f"`{components['tigerbeetle']['version']}`", upstream)
        self.assertIn(f'ZIG_RELEASE="{components["zig-std"]["version"]}"', download)
        self.assertIn(f"x86_64-linux-{components['zig']['version']}.tar.xz "
                      f"{components['zig']['hashes'][0]['content']}", download)
        self.assertEqual(components["zig"]["scope"], "excluded")

    def test_is_well_formed_cyclonedx(self):
        bom = sbom.sbom("v0.3.0", HEAD, ROOT)
        self.assertEqual((bom["bomFormat"], bom["specVersion"]), ("CycloneDX", "1.5"))
        self.assertRegex(bom["serialNumber"], r"^urn:uuid:[0-9a-f-]{36}$")
        self.assertRegex(bom["metadata"]["timestamp"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        refs = {"nerva"} | {c["bom-ref"] for c in bom["components"]}
        for dependency in bom["dependencies"]:
            self.assertIn(dependency["ref"], refs)
            for ref in dependency["dependsOn"]:
                self.assertIn(ref, refs)
        for component in [bom["metadata"]["component"], *bom["components"]]:
            self.assertTrue(component["licenses"], component["name"])

    def test_is_reproducible(self):
        self.assertEqual(sbom.sbom("v0.3.0", HEAD, ROOT), sbom.sbom("v0.3.0", HEAD, ROOT))
        self.assertNotEqual(sbom.sbom("v0.3.0", HEAD, ROOT)["serialNumber"],
                            sbom.sbom("v0.3.1", HEAD, ROOT)["serialNumber"])

    def test_refuses_zig_versions_that_disagree(self):
        zig = re.search(r'ZIG_RELEASE="([^"]+)"', (ROOT / "zig/download.sh").read_text())[1]
        for path, old in (("UPSTREAM.md", f"**Zig:** {zig}"),
                          ("build.zig", f".minor = {zig.split('.')[1]},")):
            repository = Repository()
            try:
                repository.edit(path, old, old.replace(zig.split(".")[1], "99", 1))
                refused(self, lambda: sbom.pins(repository.root))
            finally:
                repository.close()

    def test_refuses_a_missing_pin(self):
        for path, old in (("UPSTREAM.md", "**Pinned commit:**"),
                          ("zig/download.sh", "zig-x86_64-linux-"),
                          ("build.zig", "const release = ")):
            repository = Repository()
            try:
                repository.edit(path, old, "removed")
                refused(self, lambda: sbom.pins(repository.root))
            finally:
                repository.close()

    def test_refuses_a_bad_tag_or_commit(self):
        refused(self, lambda: sbom.sbom("0.3.0", HEAD, ROOT))
        refused(self, lambda: sbom.sbom("v0.3.0", HEAD[:7], ROOT))
        refused(self, lambda: sbom.sbom("v0.3.0", "0" * 40, ROOT))


if __name__ == "__main__":
    unittest.main()
