"""Pinned NDK bootstrap checks use local fake HTTP bodies and isolated SDKs."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import unittest
from unittest import mock
import zipfile

import prepare_fixed_ndk as ndk


class Response(io.BytesIO):
    status = 200


@unittest.skipUnless(os.name == "posix" and shutil.which("unzip"),
                     "Linux NDK installation needs POSIX permissions and unzip")
class FixedNdkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ndk-bootstrap-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sdk = self.root / "sdk"
        self.evidence = self.root / "evidence"

    def archive(self, revision=ndk.VERSION):
        data = io.BytesIO()
        files = {
            "source.properties": f"Pkg.Revision = {revision}\n",
            "build/cmake/android.toolchain.cmake": "# synthetic toolchain\n",
            "toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/android/api-level.h": "// fixture\n",
            "toolchains/llvm/prebuilt/linux-x86_64/bin/clang-real": "#!/bin/sh\necho 'Synthetic clang'\n",
        }
        with zipfile.ZipFile(data, "w") as zipped:
            for name, body in files.items():
                entry = zipfile.ZipInfo(f"{ndk.ROOT}/{name}")
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | (0o755 if name.endswith('clang-real') else 0o644)) << 16
                zipped.writestr(entry, body)
            link = zipfile.ZipInfo(f"{ndk.ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            zipped.writestr(link, "clang-real")
        return data.getvalue()

    def run_body(self, body, *, expected=None):
        expected = body if expected is None else expected
        with mock.patch.object(ndk, "SIZE", len(expected)), \
                mock.patch.object(ndk, "SHA1", hashlib.sha1(expected).hexdigest()), \
                mock.patch.object(ndk.urllib.request, "urlopen", return_value=Response(body)) as get:
            try:
                return ndk.install(self.sdk, self.evidence)
            finally:
                self.assertEqual(get.call_count, 1)

    def test_verified_install_preserves_real_unzip_modes_and_symlink(self):
        receipt = self.run_body(self.archive())
        clang = self.sdk / "ndk" / ndk.VERSION / "toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
        self.assertTrue(clang.is_symlink())
        self.assertTrue(os.access(clang, os.X_OK))
        self.assertEqual(receipt["status"], "installed_verified")
        self.assertTrue(receipt["archiveVerified"])
        self.assertFalse((self.evidence / "download.part").exists())
        with mock.patch.object(ndk.urllib.request, "urlopen") as get:
            reused = ndk.install(self.sdk, self.root / "second-evidence")
            get.assert_not_called()
            self.assertEqual(reused["status"], "existing_install_verified")

    def test_http_200_bad_body_is_preserved_and_never_installed(self):
        body = b"<html>temporary upstream response</html>"
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.run_body(body, expected=self.archive())
        self.assertEqual((self.evidence / "download.part").read_bytes(), body)
        receipt = json.loads((self.evidence / "receipt.json").read_text())
        self.assertEqual(receipt["httpStatus"], 200)
        self.assertEqual(receipt["downloadAttempts"], 1)
        self.assertEqual(receipt["status"], "failed")
        self.assertFalse((self.sdk / "ndk" / ndk.VERSION).exists())

    def test_same_size_checksum_mismatch_is_rejected(self):
        body = self.archive()
        damaged = b"XX" + body[2:]
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.run_body(damaged, expected=body)
        self.assertEqual((self.evidence / "download.part").read_bytes(), damaged)

    def test_invalid_zip_and_wrong_revision_never_promote(self):
        with self.assertRaises(zipfile.BadZipFile):
            self.run_body(b"not a zip")
        self.evidence = self.root / "wrong-revision-evidence"
        with self.assertRaisesRegex(ValueError, "revision differs"):
            self.run_body(self.archive(revision="0.0.0"))
        self.assertFalse((self.sdk / "ndk" / ndk.VERSION).exists())
        self.assertTrue((self.evidence / "download.part").exists())

    def test_previous_failure_evidence_cannot_be_overwritten(self):
        self.evidence.mkdir()
        marker = self.evidence / "receipt.json"
        marker.write_text("first failure")
        with self.assertRaises(FileExistsError), \
                mock.patch.object(ndk.urllib.request, "urlopen") as get:
            ndk.install(self.sdk, self.evidence)
        get.assert_not_called()
        self.assertEqual(marker.read_text(), "first failure")

    def test_workflow_prepares_pinned_ndk_before_first_apk(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/ios-core.yml"
        source = workflow.read_text()
        self.assertLess(source.index("python3 scripts/android/prepare_fixed_ndk.py"),
                        source.index("flutter build apk"))
        self.assertIn(f"ANDROID_NDK_VERSION: {ndk.VERSION}", source)
        self.assertNotIn('"ndk;$ANDROID_NDK_VERSION"', source)
        self.assertIn("name: Upload fixed NDK setup evidence\n        if: always()", source)


if __name__ == "__main__":
    unittest.main()
