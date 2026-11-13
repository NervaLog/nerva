#!/usr/bin/env python3
"""Tests for the failures of mac-sign.yml's scripts that have a code: mac_keychain.sh (NRV-E1121 and
NRV-E1125), mac_zip_check.sh (NRV-E1126, NRV-E1127) and release_check.sh mac-same and mac-upload
(NRV-E1128, NRV-E1129). Run from the repository root:
python3 .github/scripts/test_mac_sign.py

Stand-ins for macOS's `security`, `xcrun` and `codesign` and for `gh` (scripts that answer from
environment variables) stand for the real ones, so the failures that need Apple's secrets or a
broken runner are triggered here; ci.yml's `mac-keychain` job triggers the rest with the real tools."""
import base64
import os
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / ".github/scripts"

SECURITY = """#!/bin/sh
# FAIL_ON: a subcommand that exits 1. IDENTITIES: what find-identity prints.
[ "$1" = "$FAIL_ON" ] && { echo "security: $1 failed (stand-in)" >&2; exit 1; }
case "$1" in
  import) printf '%s\\n' "$*" >> "$SECURITY_LOG"; cp "$2" "$IMPORTED" ;;
  find-identity) printf '%s\\n' "$IDENTITIES" ;;
  list-keychains|default-keychain) case " $* " in *" -s "*) ;; *) echo '    "/Users/runner/Library/Keychains/login.keychain-db"' ;; esac ;;
esac
exit 0
"""
REAL_PASSWORD = "real-export-password-0123"


def make_p12(directory):
    """A real .p12 (a self-signed certificate and its key) under REAL_PASSWORD, as bytes."""
    key, crt, out = (Path(directory) / n for n in ("k.pem", "c.pem", "t.p12"))
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj",
                    "/CN=Nerva test", "-keyout", key, "-out", crt], check=True, capture_output=True)
    subprocess.run(["openssl", "pkcs12", "-export", "-inkey", key, "-in", crt, "-passout",
                    f"pass:{REAL_PASSWORD}", "-out", out], check=True, capture_output=True)
    return out.read_bytes()


XCRUN = '#!/bin/sh\n[ "$FAIL_ON" = notarytool ] && { echo "notarytool: refused (stand-in)" >&2; exit 1; }\nexit 0\n'


def stub(directory, name, text):
    path = Path(directory) / name
    path.write_text(text)
    path.chmod(0o755)


def b64(text):
    return base64.b64encode(text.encode()).decode()


class Keychain(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.runner = Path(self.tmp.name) / "runner"
        self.runner.mkdir()
        self.log = Path(self.tmp.name) / "security.log"
        self.imported = Path(self.tmp.name) / "imported.p12"
        if not hasattr(Keychain, "p12"):
            with tempfile.TemporaryDirectory() as d:
                Keychain.p12 = base64.b64encode(make_p12(d)).decode()
        stub(self.bin, "security", SECURITY)
        stub(self.bin, "xcrun", XCRUN)

    def create(self, *args, **extra):
        return self.script("create", *args, **extra)

    def script(self, sub, *args, **extra):
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", RUNNER_TEMP=str(self.runner),
                   APPLE_DEVELOPER_ID_P12=self.p12, APPLE_DEVELOPER_ID_P12_PASSWORD=REAL_PASSWORD,
                   SECURITY_LOG=str(self.log), IMPORTED=str(self.imported),
                   APPLE_NOTARY_KEY_P8=b64("p8"), APPLE_NOTARY_KEY_ID="ABC123DEFG",
                   APPLE_NOTARY_ISSUER_ID="00000000-0000-0000-0000-000000000000",
                   IDENTITIES="     1) ABCDEF \"Developer ID Application: X\"\n     1 valid identities found")
        env.update({k: v for k, v in extra.items() if v is not None})
        for k, v in extra.items():
            if v is None:
                env.pop(k, None)
        return subprocess.run([str(SCRIPTS / "mac_keychain.sh"), sub, *args],
                              capture_output=True, text=True, env=env)

    def refused(self, result, code, fragment):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"error[{code}]: mac_keychain.sh: ", result.stderr)
        self.assertIn(fragment, result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)
        self.assertIn(f"::error::{code}", result.stderr)
        self.assertEqual(list(self.runner.glob("nerva-id*")) + list(self.runner.glob("nerva-notary.p8")), [])

    def test_a_good_run_passes(self):
        result = self.create()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_real_p12_password_never_reaches_security_and_the_rewrapped_file_is_gone(self):
        result = self.create()
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = self.log.read_text()
        self.assertNotIn(REAL_PASSWORD, argv)
        self.assertNotIn(REAL_PASSWORD, result.stdout + result.stderr)
        throwaway = argv.split(" -P ")[1].split(" -T ")[0]
        self.assertNotEqual(throwaway, REAL_PASSWORD)
        # The file security imported opens with the throwaway, not with the real password.
        def opens(password):
            return subprocess.run(["openssl", "pkcs12", "-in", self.imported, "-noout", "-passin", f"pass:{password}"],
                                  capture_output=True).returncode == 0
        self.assertTrue(opens(throwaway))
        self.assertFalse(opens(REAL_PASSWORD))
        self.assertEqual(list(self.runner.glob("nerva-id*")), [])

    def test_a_wrong_p12_password_is_refused_before_security_sees_the_file(self):
        self.refused(self.create(APPLE_DEVELOPER_ID_P12_PASSWORD="wrong"), "NRV-E1121",
                     "the keychain could not import APPLE_DEVELOPER_ID_P12")
        self.assertFalse(self.log.exists())

    def test_a_secret_that_is_not_a_p12_is_refused(self):
        self.refused(self.create(APPLE_DEVELOPER_ID_P12=b64("not a p12")), "NRV-E1121",
                     "the keychain could not import APPLE_DEVELOPER_ID_P12")

    def test_a_partition_list_that_fails_is_refused(self):
        self.refused(self.create(FAIL_ON="set-key-partition-list"), "NRV-E1121",
                     "the keychain's signing key could not be opened for codesign")

    def test_not_exactly_one_valid_identity_is_refused(self):
        for found in ("     0 valid identities found", "     2 valid identities found"):
            self.refused(self.create(IDENTITIES=found), "NRV-E1121",
                         "the keychain does not hold exactly one valid code-signing identity")

    def test_no_identity_with_skip_notary_is_refused(self):
        self.refused(self.create("--skip-notary", IDENTITIES="     0 identities found"), "NRV-E1121",
                     "the keychain holds no code-signing identity")

    def test_the_notary_profile_that_cannot_be_stored_is_refused(self):
        result = self.create(FAIL_ON="notarytool")
        self.refused(result, "NRV-E1121", "the notary profile could not be stored")
        self.assertIn("notarytool: ", result.stderr)

    def test_each_security_command_that_fails_is_coded(self):
        for failing, headline in (
            ("create-keychain", "the signing keychain could not be created or unlocked"),
            ("set-keychain-settings", "the signing keychain could not be created or unlocked"),
            ("unlock-keychain", "the signing keychain could not be created or unlocked"),
            ("find-identity", "the keychain's identities could not be listed"),
        ):
            self.refused(self.create(FAIL_ON=failing), "NRV-E1125", headline)
        # list-keychains and default-keychain fail both when read (before the keychain exists) and
        # when set; the stand-in fails every call of the subcommand, so the first one, the read, is hit.
        for failing in ("list-keychains", "default-keychain"):
            self.refused(self.create(FAIL_ON=failing), "NRV-E1125",
                         "the user's keychain search list and default keychain could not be read")

    def test_arranging_the_keychains_that_fails_is_coded(self):
        # A stand-in that fails only the -s forms, which come after the read.
        stub(self.bin, "security", SECURITY.replace(
            '[ "$1" = "$FAIL_ON" ] &&',
            'case "$1 $*" in "list-keychains "*" -s "*|"default-keychain "*" -s "*) [ -n "$FAIL_SET" ] && exit 1 ;; esac\n[ "$1" = "$FAIL_ON" ] &&'))
        self.refused(self.create(FAIL_SET="1"), "NRV-E1125",
                     "the signing keychain could not be put first in the search list and made the default")

    def test_a_runner_temp_that_is_not_a_directory_is_refused(self):
        self.refused(self.create(RUNNER_TEMP=str(self.runner / "missing")), "NRV-E1125", "is not a writable directory")
        self.refused(self.create(RUNNER_TEMP=""), "NRV-E1125", "is not a writable directory")
        self.refused(self.create(RUNNER_TEMP=None), "NRV-E1125", "is not a writable directory")

    def test_destroy_without_a_runner_temp_is_refused(self):
        for value in ("", None):
            result = self.script("destroy", RUNNER_TEMP=value)
            self.refused(result, "NRV-E1125", "is not a writable directory")

    def test_an_existing_keychain_is_refused_and_left_alone(self):
        (self.runner / "nerva-signing.keychain-db").write_text("x")
        self.refused(self.create(), "NRV-E1125", "a signing keychain already exists at")
        self.assertEqual((self.runner / "nerva-signing.keychain-db").read_text(), "x")
        self.assertFalse((self.runner / "nerva-signing.keychain-list").exists())

    def test_the_header_does_not_claim_every_failure_is_one_code(self):
        self.assertNotIn("Every failure is NRV-E1121", (SCRIPTS / "mac_keychain.sh").read_text())


def fake_codesign(directory, text, status=0, tag="v0.7.1"):
    # It reads only the unpacked binary: any other path is a bug in the script under test.
    want = f"*/nerva-{tag}-universal-macos/nerva"
    stub(directory, "codesign", f"#!/bin/sh\ncase \"$1 $2 $3\" in \"-dv --verbose=4 \"{want}) ;; *) echo \"unexpected codesign args: $*\" >&2; exit 2 ;; esac\n"
         f"cat >&2 <<'EOT'\n{text}\nEOT\nexit {status}\n")


GOOD = ("Executable=/x/nerva\nIdentifier=nerva\nFormat=Mach-O universal\n"
        "CodeDirectory v=20500 flags=0x10000(runtime) hashes=1+7\n"
        "Authority=Developer ID Application: Nerva (ABCDE12345)\n"
        "Timestamp=Nov 11, 2026 at 10:00:00\n")


class ZipCheck(unittest.TestCase):
    TAG = "v0.7.1"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.dist = Path(self.tmp.name) / "dist"
        self.dist.mkdir()

    def make_zip(self, member=None, checksum=True):
        name = f"nerva-{self.TAG}-universal-macos"
        member = member or f"{name}/nerva"
        zpath = self.dist / f"{name}.zip"
        with zipfile.ZipFile(zpath, "w") as z:
            z.writestr(member, "binary")
        if checksum:
            sha = subprocess.run(["shasum", "-a", "256", zpath.name], cwd=self.dist,
                                 capture_output=True, text=True, check=True).stdout
            (self.dist / f"{zpath.name}.sha256").write_text(sha)

    def check(self):
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", RUNNER_TEMP=self.tmp.name)
        return subprocess.run([str(SCRIPTS / "mac_zip_check.sh"), str(self.dist), self.TAG],
                              capture_output=True, text=True, env=env)

    def refused(self, result, code, fragment):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"error[{code}]: mac-sign.yml: ", result.stderr)
        self.assertIn(fragment, result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)
        self.assertIn(f"::error::{code}", result.stderr)

    def test_a_good_zip_passes(self):
        self.make_zip()
        fake_codesign(self.bin, GOOD)
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(Path(self.tmp.name).glob("zipcheck.*")), [])

    def test_a_zip_that_does_not_match_its_checksum_is_refused(self):
        self.make_zip()
        (self.dist / f"nerva-{self.TAG}-universal-macos.zip.sha256").write_text("0" * 64 + f"  nerva-{self.TAG}-universal-macos.zip\n")
        self.refused(self.check(), "NRV-E1126", "does not match its checksum file")

    def test_a_missing_checksum_file_is_refused(self):
        self.make_zip(checksum=False)
        self.refused(self.check(), "NRV-E1126", "or one of the two is missing")

    def test_a_zip_that_cannot_be_unpacked_is_refused(self):
        self.make_zip()
        z = self.dist / f"nerva-{self.TAG}-universal-macos.zip"
        z.write_bytes(b"not a zip")
        subprocess.run(f"shasum -a 256 {z.name} > {z.name}.sha256", shell=True, cwd=self.dist, check=True)
        self.refused(self.check(), "NRV-E1126", "cannot be unpacked")

    def test_a_zip_without_the_binary_is_refused(self):
        self.make_zip(member="other/nerva")
        self.refused(self.check(), "NRV-E1126", f"holds no nerva at nerva-{self.TAG}-universal-macos/nerva")

    def test_each_signature_defect_is_refused(self):
        self.make_zip()
        cases = (
            ("", 1, "codesign cannot read a signature"),
            (GOOD.replace("Developer ID Application", "Nerva CI Test"), 0, "not signed with a Developer ID Application"),
            (GOOD.replace("(runtime)", "(adhoc)"), 0, "does not have the hardened runtime"),
            (GOOD.replace("Timestamp=", "Signed Time="), 0, "has no secure timestamp"),
        )
        for text, status, headline in cases:
            fake_codesign(self.bin, text, status)
            self.refused(self.check(), "NRV-E1127", headline)


def fake_gh_upload(directory, fails):
    # Records its argv, one word per line, in $GH_ARGV_FILE.
    stub(directory, "gh", '#!/bin/sh\nprintf \'%s\\n\' "$@" > "$GH_ARGV_FILE"\n'
         + ('echo "HTTP 502" >&2; exit 1\n' if fails else 'exit 0\n'))


class DraftAfterSigning(unittest.TestCase):
    def run_check(self, *args, path_dir=None, argv_file=None):
        env = dict(os.environ, GITHUB_REPOSITORY="o/r")
        if argv_file:
            env["GH_ARGV_FILE"] = str(argv_file)
        if path_dir:
            env["PATH"] = f"{path_dir}:{env['PATH']}"
        return subprocess.run([str(SCRIPTS / "release_check.sh"), *args], capture_output=True, text=True, env=env)

    def test_a_draft_that_still_targets_the_signed_commit_passes(self):
        self.assertEqual(self.run_check("mac-same", "v0.7.1", "a" * 40, "a" * 40).returncode, 0)

    def test_a_draft_that_was_retargeted_is_refused(self):
        result = self.run_check("mac-same", "v0.7.1", "a" * 40, "b" * 40)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("error[NRV-E1128]: mac-sign.yml: the draft v0.7.1 now targets bbbbbbb, not aaaaaaa, which was signed",
                      result.stderr)
        self.assertIn("\n  cause  ", result.stderr)
        self.assertIn("\n  fix    ", result.stderr)

    def test_an_upload_that_fails_is_refused_and_one_that_works_passes(self):
        with tempfile.TemporaryDirectory() as d:
            argv = Path(d) / "argv.txt"
            fake_gh_upload(d, fails=False)
            self.assertEqual(self.run_check("mac-upload", "v0.7.1", "dist", path_dir=d, argv_file=argv).returncode, 0)
            zip_path = "dist/nerva-v0.7.1-universal-macos.zip"
            self.assertEqual(argv.read_text().split("\n")[:-1],
                             ["release", "upload", "v0.7.1", zip_path, zip_path + ".sha256", "--clobber"])
            fake_gh_upload(d, fails=True)
            result = self.run_check("mac-upload", "v0.7.1", "dist", path_dir=d, argv_file=argv)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("error[NRV-E1129]: mac-sign.yml: the zip and its checksum could not be uploaded to the draft v0.7.1",
                          result.stderr)
            self.assertIn("\n  cause  ", result.stderr)
            self.assertIn("\n  fix    ", result.stderr)

    def test_the_workflow_runs_the_checks_through_the_scripts(self):
        workflow = (ROOT / ".github/workflows/mac-sign.yml").read_text()
        for call in ('mac_zip_check.sh" zig-out/mac-release "$TAG"', 'release_check.sh" mac-same "$TAG"',
                     'release_check.sh" mac-upload "$TAG"'):
            self.assertIn(call, workflow)
        self.assertIn("for f in release_check.sh mac_keychain.sh mac_zip_check.sh; do", workflow)
        self.assertNotIn("exit 1", workflow)


if __name__ == "__main__":
    unittest.main()
