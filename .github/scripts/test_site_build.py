#!/usr/bin/env python3
"""Tests for site_build.sh, the site's build gate on Workers Builds (NRV-E1152, NRV-E1164,
P410), and for the dashboard commands docs/releases/packages.md gives. Run from the repository
root: python3 -I .github/scripts/test_site_build.py"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/scripts/site_build.sh"
SPEC = ROOT / "docs/releases/packages.md"

REQUIRED = ["index.html", "404.html", "_headers"]
POLICY = ".well-known/openpgpkey/policy"
KEY = ".well-known/openpgpkey/hu/ndqm47zydhyqyzabecddtdk1q3bponab"
WKD_DIRS = [".well-known", ".well-known/openpgpkey", ".well-known/openpgpkey/hu"]
FORBIDDEN_FILES = [
    "wrangler.toml", "wrangler.json", "wrangler.jsonc", "_worker.js", "_routes.json",
    "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
    "pnpm-workspace.yaml", "bun.lock", "bun.lockb", "bunfig.toml", ".npmrc", ".yarnrc",
    ".yarnrc.yml", "requirements.txt", "Pipfile", "Pipfile.lock", "pyproject.toml",
    "poetry.lock", "uv.lock", "Gemfile", "Gemfile.lock", "go.mod", ".tool-versions", ".nvmrc",
    ".node-version", ".python-version", ".ruby-version", "runtime.txt", ".env", ".env.local",
    ".env.production", ".envrc", ".dev.vars", ".dev.vars.staging",
]
FORBIDDEN_DIRS = ["functions", "node_modules", ".wrangler", ".nerva-site"]
CONFIG = {
    "name": "nerva-site",
    "compatibility_date": "2026-10-23",
    "workers_dev": True,
    "preview_urls": True,
    "assets": {
        "directory": "dist",
        "not_found_handling": "404-page",
        "html_handling": "auto-trailing-slash",
    },
    "previews": {},
}
# Every key that gives a Worker code or a resource (Wrangler's configuration reference).
BINDING_KEYS = {
    "main", "routes", "route", "vars", "kv_namespaces", "r2_buckets", "d1_databases",
    "services", "durable_objects", "queues", "hyperdrive", "vectorize", "analytics_engine_datasets",
    "ai", "browser", "images", "workflows", "send_email", "mtls_certificates", "dispatch_namespaces",
    "secrets_store_secrets", "pipelines", "tail_consumers", "version_metadata", "containers",
    "triggers", "unsafe", "worker_loaders", "assets_binding", "rules", "build", "env",
}
WRANGLER = "4.153.0"
COMMIT = "c886c9f3e5a1b2d4f6a8c0e2b4d6f8a0c2e4b6d8"
SHA256 = "0f" * 32


def run_gate(tree, env_skip="1"):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
    if env_skip is not None:
        env["SKIP_DEPENDENCY_INSTALL"] = env_skip
    return subprocess.run(["sh", str(SCRIPT)], cwd=tree, env=env, capture_output=True, text=True)


class Gate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tree = Path(self.tmp.name) / "site"
        self.tree.mkdir()
        for name in REQUIRED:
            (self.tree / name).write_text(f"{name}\n")
        (self.tree / ".github/scripts").mkdir(parents=True)
        (self.tree / ".github/scripts/site_check.mjs").write_text("// not copied\n")
        (self.tree / "README.md").write_text("not copied\n")
        (self.tree / ".nojekyll").write_text("")

    def add_wkd(self):
        (self.tree / ".well-known/openpgpkey/hu").mkdir(parents=True)
        (self.tree / POLICY).write_text("")
        (self.tree / KEY).write_bytes(b"\x99\x02\x0dkey")

    def passes(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.tree / ".nerva-site"

    def refused(self, result, fragment, wrote_nothing=True):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("error[NRV-E1152]: site build: ", result.stderr)
        self.assertIn(fragment, result.stderr)
        self.assertIn("nothing is deployed", result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)
        if wrote_nothing:
            self.assertFalse((self.tree / ".nerva-site").exists(), "a refused build wrote output")

    def served(self, out):
        dist = out / "dist"
        return sorted(str(p.relative_to(dist)) for p in dist.rglob("*") if not p.is_dir())

    def check_config(self, out):
        config = json.loads((out / "wrangler.json").read_text())
        self.assertEqual(config, CONFIG)
        self.assertNotIn("main", config)
        self.assertFalse(BINDING_KEYS & set(config), "the config gives the Worker code or a binding")
        self.assertFalse(BINDING_KEYS & set(config["previews"]), "a Preview gets a binding")
        self.assertEqual(sorted(p.name for p in out.iterdir()),
                         ["dist", "package-lock.json", "package.json", "wrangler.json"])

    def test_all_present_without_wkd(self):
        out = self.passes(run_gate(self.tree))
        self.assertEqual(self.served(out), sorted(REQUIRED))
        for name in REQUIRED:
            self.assertEqual((out / "dist" / name).read_text(), f"{name}\n")
        self.check_config(out)

    def test_all_present_with_wkd_pair(self):
        self.add_wkd()
        out = self.passes(run_gate(self.tree))
        self.assertEqual(self.served(out), sorted(REQUIRED + [POLICY, KEY]))
        self.assertEqual((out / "dist" / KEY).read_bytes(), b"\x99\x02\x0dkey")
        self.assertEqual((out / "dist" / POLICY).read_bytes(), b"")
        self.check_config(out)

    def test_each_required_missing(self):
        for name in REQUIRED:
            with self.subTest(name=name):
                (self.tree / name).unlink()
                self.refused(run_gate(self.tree), f"{name} is missing")
                (self.tree / name).write_text(f"{name}\n")

    def test_each_required_symlink_or_directory(self):
        elsewhere = Path(self.tmp.name) / "elsewhere.html"
        elsewhere.write_text("x\n")
        for name in REQUIRED:
            with self.subTest(name=name, kind="symlink"):
                (self.tree / name).unlink()
                (self.tree / name).symlink_to(elsewhere)
                self.refused(run_gate(self.tree), f"{name} is missing, not a regular file, or a symlink")
                (self.tree / name).unlink()
            with self.subTest(name=name, kind="directory"):
                (self.tree / name).mkdir()
                self.refused(run_gate(self.tree), f"{name} is missing, not a regular file")
                (self.tree / name).rmdir()
                (self.tree / name).write_text(f"{name}\n")

    def test_each_forbidden_name(self):
        for name in FORBIDDEN_FILES:
            with self.subTest(name=name):
                (self.tree / name).write_text("{}\n")
                self.refused(run_gate(self.tree), f"{name} is not allowed in the site repository")
                (self.tree / name).unlink()
        for name in FORBIDDEN_DIRS:
            with self.subTest(name=name):
                (self.tree / name).mkdir()
                (self.tree / name / "x.js").write_text("export default {}\n")
                self.refused(run_gate(self.tree), f"{name} is not allowed in the site repository",
                             wrote_nothing=name != ".nerva-site")
                self.assertEqual([p.name for p in (self.tree / name).iterdir()], ["x.js"])
                shutil.rmtree(self.tree / name)

    def test_forbidden_dangling_symlink(self):
        for name in ["wrangler.toml", ".env", "functions"]:
            with self.subTest(name=name):
                (self.tree / name).symlink_to("does-not-exist")
                self.refused(run_gate(self.tree), f"{name} is not allowed in the site repository")
                (self.tree / name).unlink()

    def test_unknown_names_are_refused(self):
        for name in ["notes.txt", ".hidden", ".gitignore", "sitemap.xml", "robots.txt",
                     ".mise.toml", "mise.toml", "..odd", "a b"]:
            with self.subTest(name=name, kind="file"):
                (self.tree / name).write_text("x\n")
                self.refused(run_gate(self.tree), f"{name} is not allowed in the site repository")
                (self.tree / name).unlink()
        for name in ["assets", ".config"]:
            with self.subTest(name=name, kind="directory"):
                (self.tree / name / "x").mkdir(parents=True)
                self.refused(run_gate(self.tree), f"{name} is not allowed in the site repository")
                shutil.rmtree(self.tree / name)

    def test_unknown_symlink_is_refused(self):
        for name in ["notes.txt", ".hidden", "sitemap.xml"]:
            with self.subTest(name=name):
                (self.tree / name).symlink_to("index.html")
                self.refused(run_gate(self.tree), f"{name} is not allowed in the site repository")
                (self.tree / name).unlink()

    def test_allowed_metadata_passes_and_is_not_copied(self):
        (self.tree / ".git").mkdir()
        (self.tree / "LICENSE").write_text("licence\n")
        out = self.passes(run_gate(self.tree))
        self.assertEqual(self.served(out), sorted(REQUIRED))

    def test_metadata_symlinks_are_refused(self):
        (Path(self.tmp.name) / "target").mkdir()
        for name in [".git", ".github", ".nojekyll", "README.md", "LICENSE", "CLAUDE.md"]:
            with self.subTest(name=name):
                backup = Path(self.tmp.name) / (name + ".bak")
                if (self.tree / name).exists():
                    (self.tree / name).rename(backup)
                (self.tree / name).symlink_to(Path(self.tmp.name) / "target")
                self.refused(run_gate(self.tree), f"{name} is a symlink")
                (self.tree / name).unlink()
                if backup.exists():
                    backup.rename(self.tree / name)

    def test_wkd_other_files_are_refused(self):
        for extra in [".well-known/other", ".well-known/openpgpkey/other",
                      ".well-known/openpgpkey/hu/other", ".well-known/security.txt"]:
            with self.subTest(extra=extra):
                self.add_wkd()
                (self.tree / extra).write_text("x\n")
                self.refused(run_gate(self.tree), f"{extra} is not allowed in the site repository")
                shutil.rmtree(self.tree / ".well-known")

    def test_well_known_not_a_directory(self):
        (self.tree / ".well-known").write_text("x\n")
        self.refused(run_gate(self.tree), ".well-known is not a directory")

    def test_lock_file(self):
        out = self.passes(run_gate(self.tree))
        package = json.loads((out / "package.json").read_text())
        lock = json.loads((out / "package-lock.json").read_text())
        self.assertEqual(package["dependencies"], {"wrangler": WRANGLER})
        self.assertEqual(lock["packages"][""]["dependencies"], {"wrangler": WRANGLER})
        self.assertEqual(lock["lockfileVersion"], 3)
        self.assertEqual(lock["packages"]["node_modules/wrangler"]["version"], WRANGLER)
        packages = {k: v for k, v in lock["packages"].items() if k}
        self.assertGreater(len(packages), 50)
        for name, entry in packages.items():
            with self.subTest(name=name):
                self.assertTrue(name.startswith("node_modules/"), name)
                self.assertRegex(entry["resolved"], r"^https://registry\.npmjs\.org/")
                self.assertRegex(entry["integrity"], r"^sha512-[A-Za-z0-9+/]+=*$")
                self.assertNotIn("link", entry)
        # the platform binaries are packages of their own, so no install script has to fetch them
        self.assertIn("node_modules/@cloudflare/workerd-linux-64", packages)

    def test_skip_dependency_install(self):
        for value in [None, "", "0", "true"]:
            with self.subTest(value=value):
                self.refused(run_gate(self.tree, env_skip=value), "SKIP_DEPENDENCY_INSTALL is not 1")

    def test_wkd_single(self):
        for keep, drop in [(POLICY, KEY), (KEY, POLICY)]:
            with self.subTest(keep=keep):
                self.add_wkd()
                (self.tree / drop).unlink()
                self.refused(run_gate(self.tree), "one WKD file is present without the other")
                shutil.rmtree(self.tree / ".well-known")

    def test_wkd_not_regular(self):
        for name in [POLICY, KEY]:
            with self.subTest(name=name):
                self.add_wkd()
                (self.tree / name).unlink()
                (self.tree / name).mkdir()
                self.refused(run_gate(self.tree), f"{name} is not a regular file")
                shutil.rmtree(self.tree / ".well-known")

    def test_wkd_hu_not_a_directory(self):
        (self.tree / ".well-known/openpgpkey").mkdir(parents=True)
        (self.tree / POLICY).write_text("")
        (self.tree / ".well-known/openpgpkey/hu").write_text("")
        self.refused(run_gate(self.tree), ".well-known/openpgpkey/hu is not a directory")

    def test_wkd_symlinks(self):
        real = Path(self.tmp.name) / "real"
        for name in [POLICY, KEY]:
            with self.subTest(name=name):
                self.add_wkd()
                (self.tree / name).rename(real)
                (self.tree / name).symlink_to(real)
                self.refused(run_gate(self.tree), f"{name} is a symlink")
                shutil.rmtree(self.tree / ".well-known")
                real.unlink()
        for name in WKD_DIRS:
            with self.subTest(name=name):
                self.add_wkd()
                target = Path(self.tmp.name) / "moved"
                (self.tree / name).rename(target)
                (self.tree / name).symlink_to(target, target_is_directory=True)
                self.refused(run_gate(self.tree), f"{name} is a symlink")
                (self.tree / name).unlink()
                shutil.rmtree(target)
                shutil.rmtree(self.tree / ".well-known", ignore_errors=True)


def spec_commands():
    """The build, deploy and preview commands as packages.md gives them, one per fenced block."""
    text = SPEC.read_text()
    blocks = re.findall(r"^```\n(.*?)\n```$", text, flags=re.S | re.M)
    build = [b for b in blocks if b.startswith("f=/tmp/gate.sh; ") and "site_build.sh" in b]
    deploy = [b for b in blocks if b.startswith("cd .nerva-site && npm ci ") and " deploy " in b]
    preview = [b for b in blocks if b.startswith("cd .nerva-site && npm ci ") and " preview " in b]
    return build, deploy, preview


class SpecCommands(unittest.TestCase):
    def setUp(self):
        build, deploy, preview = spec_commands()
        self.assertEqual((len(build), len(deploy), len(preview)), (1, 1, 1))
        self.build, self.deploy, self.preview = build[0], deploy[0], preview[0]

    def fill(self, command, commit=COMMIT, sha256=SHA256):
        return command.replace("<commit>", commit).replace("<sha256>", sha256)

    def test_lengths(self):
        for command in [self.build, self.deploy, self.preview]:
            with self.subTest(command=command[:40]):
                self.assertNotIn("\n", command)
                filled = self.fill(command)
                self.assertNotIn("<", filled.replace("<<", ""))
                self.assertLessEqual(len(filled), 400, filled)
                self.assertLess(len(filled), 512)  # the dashboard's limit

    def test_pins(self):
        self.assertIn("raw.githubusercontent.com/NervaLog/nerva/<commit>/.github/scripts/site_build.sh",
                      self.build)
        self.assertIn('echo "<sha256>  $f" | sha256sum -c --status', self.build)
        self.assertTrue(self.build.endswith("; sh $f"))
        for command in [self.deploy, self.preview]:
            self.assertRegex(command, r"^cd \.nerva-site && npm ci --ignore-scripts && "
                                      r"npx --no-install wrangler (deploy|preview) "
                                      r"--config wrangler\.json$")
            self.assertNotIn("wrangler@", command)  # the version is the lock file's, not npx's

    def run_build_command(self, sha256, commit=COMMIT):
        """Runs the spec's build command against a fake curl that serves this site_build.sh at
        COMMIT and fails (as curl -f does for a 404) for any other URL."""
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "curl"
        fake.write_text("#!/bin/sh\n"
                        "while [ $# -gt 0 ]; do case $1 in -*o) out=$2; shift 2;; -*) shift;; *) url=$1; shift;; esac; done\n"
                        f"[ \"$url\" = 'https://raw.githubusercontent.com/NervaLog/nerva/{COMMIT}/.github/scripts/site_build.sh' ] || exit 22\n"
                        f"cp '{SCRIPT}' \"$out\"\n")
        fake.chmod(0o755)
        tree = tmp / "site"
        tree.mkdir()
        for name in REQUIRED:
            (tree / name).write_text(name)
        env = {"PATH": f"{bin_dir}:{os.environ.get('PATH', '/usr/bin:/bin')}",
               "SKIP_DEPENDENCY_INSTALL": "1"}
        command = self.fill(self.build, commit=commit, sha256=sha256)
        self.assertIn("f=/tmp/gate.sh;", command)
        command = command.replace("f=/tmp/gate.sh;", f"f={tmp}/gate.sh;", 1)  # not a shared path
        return tree, subprocess.run(["sh", "-c", command], cwd=tree, env=env, capture_output=True, text=True)

    def test_build_command_runs_the_pinned_script(self):
        digest = hashlib.sha256(SCRIPT.read_bytes()).hexdigest()
        tree, result = self.run_build_command(digest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((tree / ".nerva-site/wrangler.json").is_file())

    def test_build_command_refuses_another_script(self):
        tree, result = self.run_build_command("00" * 32)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("error[NRV-E1164]: site build: ", result.stderr)
        self.assertFalse((tree / ".nerva-site").exists())

    def test_build_command_refuses_a_failed_fetch(self):
        digest = hashlib.sha256(SCRIPT.read_bytes()).hexdigest()
        tree, result = self.run_build_command(digest, commit="1" * 40)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("error[NRV-E1164]: site build: ", result.stderr)
        self.assertNotIn("site build: copied", result.stdout)
        self.assertFalse((tree / ".nerva-site").exists())


if __name__ == "__main__":
    unittest.main()
