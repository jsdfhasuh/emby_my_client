import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from prepare_release import APK_NAMES, SIGNING_RECEIPT
from sign_android_release import (KEYSTORE_SECRET, PASSWORD_SECRET, SigningError,
                                  credentials, main, run_tool, sign_release)


class AndroidSigningTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        for name in APK_NAMES:
            (self.inputs / name).write_bytes(b"mock tested APK")
        self.tool = self.root / "apksigner"
        self.tool.write_text("tool fixture")
        self.aapt = self.root / "aapt"
        self.aapt.write_text("metadata tool fixture")
        self.output = self.root / "signed"
        self.temp = self.root / "temp"
        self.temp.mkdir()
        self.password = "fixture-password-not-a-real-credential"
        self.environment = {
            KEYSTORE_SECRET: base64.b64encode(b"mock-keystore").decode(),
            PASSWORD_SECRET: self.password, "PATH": "fixture-path",
        }
        self.certificate = "a" * 64
        self.commands = []

    def sign(self):
        sign_release(self.inputs, self.output, self.tool, self.certificate,
                     self.environment, self.temp, aapt=self.aapt, run_number=180)

    def mock_tool(self, command, environment):
        self.commands.append((command, dict(environment)))
        self.assertNotIn(self.password, command)
        self.assertNotIn(self.environment[KEYSTORE_SECRET], command)
        self.assertNotIn(KEYSTORE_SECRET, environment)
        if command[1] == "sign":
            self.assertEqual(environment[PASSWORD_SECRET], self.password)
            self.assertIn(f"env:{PASSWORD_SECRET}", command)
            self.assertEqual(Path(command[command.index("--ks") + 1]).read_bytes(), b"mock-keystore")
            Path(command[command.index("--out") + 1]).write_bytes(b"mock stable-signed APK")
            return ""
        self.assertNotIn(PASSWORD_SECRET, environment)
        if command[1] == "dump":
            name = Path(command[-1]).name
            code, abis = {
                "app-debug.apk": (1800000, "'armeabi-v7a' 'arm64-v8a' 'x86_64'"),
                "app-armeabi-v7a-debug.apk": (1801000, "'armeabi-v7a'"),
                "app-arm64-v8a-debug.apk": (1802000, "'arm64-v8a'"),
                "app-x86_64-debug.apk": (1804000, "'x86_64'"),
            }[name]
            return (f"package: name='com.jsdfhasuh.emoemby' versionCode='{code}' versionName='1.0.180'\n"
                    "application-label:'Emo Emby 稳定版'\n"
                    f"native-code: {abis}\n")
        return f"Signer #1 certificate SHA-256 digest: {self.certificate}\n"

    def test_signs_all_apks_with_one_key_without_secret_arguments(self):
        with patch("sign_android_release.run_tool", side_effect=self.mock_tool):
            self.sign()
        self.assertEqual(len(self.commands), 12)
        self.assertEqual(list(self.temp.iterdir()), [])
        receipt = json.loads((self.output / SIGNING_RECEIPT).read_text())
        self.assertEqual(receipt["certificateSha256"], self.certificate)
        self.assertEqual(set(receipt["apks"]), set(APK_NAMES))
        for name in APK_NAMES:
            self.assertEqual(receipt["apks"][name], hashlib.sha256((self.output / name).read_bytes()).hexdigest())
        self.assertFalse(any(self.output.rglob("*.p12")))

    def test_missing_either_secret_fails_without_writing_files(self):
        for key in (KEYSTORE_SECRET, PASSWORD_SECRET):
            with self.subTest(secret=key):
                environment = dict(self.environment)
                del environment[key]
                with self.assertRaisesRegex(SigningError, key):
                    sign_release(self.inputs, self.output, self.tool, self.certificate, environment, self.temp,
                                 aapt=self.aapt, run_number=180)
                self.assertFalse(self.output.exists())
                self.assertEqual(list(self.temp.iterdir()), [])

    def test_invalid_secrets_are_redacted(self):
        for overrides in ({KEYSTORE_SECRET: "invalid!base64"}, {PASSWORD_SECRET: "short"},
                          {KEYSTORE_SECRET: ""}, {KEYSTORE_SECRET: "a" * (1024 * 1024 + 1)}):
            environment = dict(self.environment, **overrides)
            with self.assertRaises(SigningError) as raised:
                credentials(environment)
            for value in overrides.values():
                if value:
                    self.assertNotIn(value, str(raised.exception))

    def test_wrong_signer_blocks_output_and_removes_temporary_key(self):
        def wrong_signer(command, environment):
            output = self.mock_tool(command, environment)
            return output.replace(self.certificate, "b" * 64)
        with patch("sign_android_release.run_tool", side_effect=wrong_signer):
            with self.assertRaisesRegex(SigningError, "pinned"):
                self.sign()
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.temp.iterdir()), [])

    def test_multiple_signers_are_rejected(self):
        def multiple(command, environment):
            value = self.mock_tool(command, environment)
            if command[1] == "verify":
                value += f"Signer #2 certificate SHA-256 digest: {'b' * 64}\n"
            return value
        with patch("sign_android_release.run_tool", side_effect=multiple):
            with self.assertRaisesRegex(SigningError, "pinned"):
                self.sign()
        self.assertFalse(self.output.exists())

    def test_tool_failure_and_exception_do_not_print_diagnostics(self):
        for failure in (subprocess.CompletedProcess([], 1, self.password, self.password),
                        OSError(self.password)):
            with patch("sign_android_release.subprocess.run",
                       **({"side_effect": failure} if isinstance(failure, Exception) else {"return_value": failure})):
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    with self.assertRaises(SigningError) as raised:
                        run_tool(["apksigner", "sign"], self.environment)
                self.assertNotIn(self.password, str(raised.exception))
                self.assertEqual(output.getvalue(), "")

    def test_incomplete_or_duplicate_artifacts_are_rejected(self):
        (self.inputs / APK_NAMES[0]).unlink()
        with self.assertRaisesRegex(SigningError, "exactly one"):
            self.sign()
        (self.inputs / APK_NAMES[0]).write_bytes(b"restored")
        nested = self.inputs / "duplicate"
        nested.mkdir()
        (nested / APK_NAMES[0]).write_bytes(b"duplicate")
        with self.assertRaisesRegex(SigningError, "exactly one"):
            self.sign()

    def test_never_overwrites_previous_signed_output(self):
        self.output.mkdir()
        existing = self.output / "keep"
        existing.write_text("keep")
        with self.assertRaisesRegex(SigningError, "overwrite"):
            self.sign()
        self.assertEqual(existing.read_text(), "keep")

    def test_untrusted_branch_or_repository_never_reaches_signing(self):
        for overrides in ({"GITHUB_REF": "refs/pull/1/merge"},
                          {"GITHUB_EVENT_NAME": "pull_request"},
                          {"GITHUB_REPOSITORY": "someone/fork"}):
            environment = {"GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "push",
                           "GITHUB_REPOSITORY": "jsdfhasuh/emby_my_client", **overrides}
            with patch.dict(os.environ, environment, clear=True), patch("sys.argv", [
                "sign_android_release.py", "--artifacts-dir", "inputs", "--output-dir", "output",
                "--apksigner", "apksigner", "--aapt", "aapt", "--run-number", "180"]), patch("sign_android_release.sign_release") as sign:
                with self.assertRaisesRegex(SigningError, "trusted main"):
                    main()
                sign.assert_not_called()

    def test_wrong_identity_version_or_abi_never_becomes_publishable(self):
        for before, after in (("com.jsdfhasuh.emoemby", "com.example.embyclient"),
                              ("1.0.180", "1.0.179"), ("1800000", "2001"),
                              ("Emo Emby 稳定版", "Emby Client"),
                              ("'armeabi-v7a' 'arm64-v8a' 'x86_64'", "'x86_64'")):
            with self.subTest(replaced=before):
                def incorrect(command, environment):
                    output = self.mock_tool(command, environment)
                    return output.replace(before, after) if command[1] == "dump" else output
                with patch("sign_android_release.run_tool", side_effect=incorrect):
                    with self.assertRaisesRegex(SigningError, "stable-app contract"):
                        self.sign()
                self.assertFalse(self.output.exists())
                self.assertEqual(list(self.temp.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
