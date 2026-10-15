import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from prepare_release import ANDROID_APPLICATION_ID, APK_NAMES, SIGNING_RECEIPT, certificate_pin, prepare_release, versioned_apk_names


class PrepareReleaseTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.inputs = self.root / "artifacts"
        self.output = self.root / "release"
        self.notes = self.root / "notes.md"
        self.commit = "a" * 40
        self.ipa_name = f"emby-ios-core-{self.commit[:12]}-192.ipa"
        self.files = {}
        # Universal APK artifacts retain nested paths; split APKs do not.
        for name in (*APK_NAMES, self.ipa_name):
            directory = self.inputs / ("nested/app/outputs" if name in APK_NAMES else "ios")
            directory.mkdir(parents=True, exist_ok=True)
            path = directory / name
            path.write_bytes(f"fixture:{name}".encode())
            self.files[name] = path
        self.checksum = self.files[self.ipa_name].with_suffix(".ipa.sha256")
        digest = hashlib.sha256(self.files[self.ipa_name].read_bytes()).hexdigest()
        self.checksum.write_text(f"{digest}  {self.ipa_name}\n", encoding="utf-8", newline="\n")
        self.signing_receipt = self.inputs / SIGNING_RECEIPT
        self.signing_receipt.write_text(json.dumps({
            "format": 2, "certificateSha256": certificate_pin(),
            "applicationId": ANDROID_APPLICATION_ID, "runNumber": 192,
            "apks": {name: hashlib.sha256(self.files[name].read_bytes()).hexdigest() for name in APK_NAMES},
        }), encoding="utf-8")

    def prepare(self, **overrides):
        arguments = {
            "artifacts_dir": self.inputs,
            "output_dir": self.output,
            "notes_path": self.notes,
            "run_number": 192,
            "commit": self.commit,
            "run_url": "https://github.com/example/repo/actions/runs/123",
        }
        arguments.update(overrides)
        return prepare_release(**arguments)

    def test_collects_only_installable_packages_with_portable_checksums(self):
        (self.inputs / "diagnostic.txt").write_text("not a release asset")
        assets = self.prepare()
        self.assertEqual(
            {path.name for path in assets},
            {*APK_NAMES, self.ipa_name, self.checksum.name, "SHA256SUMS.txt",
             "EmoEmby-1.0.192-universal.apk", "EmoEmby-1.0.192-arm64-v8a.apk",
             "EmoEmby-1.0.192-armeabi-v7a.apk", "EmoEmby-1.0.192-x86_64.apk"},
        )
        records = (self.output / "SHA256SUMS.txt").read_text().splitlines()
        self.assertEqual(len(records), 9)
        self.assertNotIn(b"\r", (self.output / "SHA256SUMS.txt").read_bytes())
        for record in records:
            digest, name = record.split("  ")
            self.assertEqual(digest, hashlib.sha256((self.output / name).read_bytes()).hexdigest())
        notes = self.notes.read_text(encoding="utf-8")
        self.assertIn(self.commit, notes)
        self.assertIn("fixed app key", notes)
        self.assertIn(certificate_pin(), notes)
        self.assertIn("TrollStore", notes)

    def test_versioned_apks_are_identical_to_the_verified_updater_aliases(self):
        self.prepare()
        for alias, versioned in versioned_apk_names(192).items():
            self.assertEqual((self.output / versioned).read_bytes(), self.files[alias].read_bytes())
            self.assertEqual((self.output / alias).read_bytes(), self.files[alias].read_bytes())
        notes = self.notes.read_text(encoding="utf-8")
        self.assertIn("Compatibility aliases for installed apps", notes)
        self.assertIn("byte-identical", notes)
        for name in versioned_apk_names(192).values():
            self.assertIn(name, notes)

    def test_names_follow_the_shared_build_version_and_all_architectures(self):
        for number in (1, 193, 2048, 209999):
            self.assertEqual(versioned_apk_names(number), {
                "app-debug.apk": f"EmoEmby-1.0.{number}-universal.apk",
                "app-arm64-v8a-debug.apk": f"EmoEmby-1.0.{number}-arm64-v8a.apk",
                "app-armeabi-v7a-debug.apk": f"EmoEmby-1.0.{number}-armeabi-v7a.apk",
                "app-x86_64-debug.apk": f"EmoEmby-1.0.{number}-x86_64.apk",
            })
        with patch("prepare_release.build_version", return_value={"APP_VERSION_NAME": "2.4.193"}):
            self.assertEqual(versioned_apk_names(193)["app-arm64-v8a-debug.apk"],
                             "EmoEmby-2.4.193-arm64-v8a.apk")

    def test_unsupported_build_number_never_creates_output(self):
        with self.assertRaisesRegex(ValueError, "version range"):
            self.prepare(run_number=210000)
        self.assertFalse(self.output.exists())

    def test_existing_versioned_inputs_cannot_replace_verified_signed_bytes(self):
        stale = self.inputs / "EmoEmby-1.0.192-arm64-v8a.apk"
        stale.write_bytes(b"unverified stale file")
        self.prepare()
        self.assertEqual((self.output / stale.name).read_bytes(),
                         self.files["app-arm64-v8a-debug.apk"].read_bytes())

    def test_release_output_matches_the_cross_version_updater_contract(self):
        fixture = Path(__file__).parents[2] / "test/fixtures/releases/versioned-build-192.json"
        expected = json.loads(fixture.read_text(encoding="utf-8"))
        self.prepare()
        self.assertEqual((self.output / "SHA256SUMS.txt").read_text(encoding="utf-8"),
                         expected["checksums"])
        self.assertEqual(
            [{"name": path.name, "size": path.stat().st_size,
              "browser_download_url": "https://github.com/jsdfhasuh/emby_my_client/releases/download/build-192/" + path.name}
             for path in sorted(self.output.iterdir(), key=lambda path: path.name)], expected["release"]["assets"])
        for name, data in expected["apkContents"].items():
            self.assertEqual((self.output / name).read_bytes(), data.encode())

    def test_missing_apk_fails_before_creating_release_output(self):
        self.files[APK_NAMES[0]].unlink()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_duplicate_apk_is_rejected(self):
        (self.inputs / APK_NAMES[0]).write_bytes(b"duplicate")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.prepare()

    def test_empty_package_is_rejected(self):
        self.files[APK_NAMES[1]].write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "non-empty"):
            self.prepare()

    def test_corrupt_ipa_is_rejected(self):
        self.files[self.ipa_name].write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_checksum_must_reference_exact_build_basename(self):
        self.checksum.write_text(f"{'0' * 64}  /runner/{self.ipa_name}\n")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.prepare()

    def test_missing_checksum_is_rejected(self):
        self.checksum.unlink()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.prepare()

    def test_wrong_build_number_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.prepare(run_number=176)

    def test_invalid_build_identity_is_rejected(self):
        for invalid in ({"run_number": 0}, {"commit": "main"}):
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(ValueError, "commit SHA"):
                    self.prepare(**invalid)

    def test_existing_output_is_not_overwritten(self):
        self.output.mkdir()
        existing = self.output / "existing.ipa"
        existing.write_bytes(b"keep")
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual(existing.read_bytes(), b"keep")

    def test_missing_fixed_signing_record_blocks_publication(self):
        self.signing_receipt.unlink()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_changed_apk_after_signing_blocks_publication(self):
        self.files[APK_NAMES[0]].write_bytes(b"changed after signing")
        with self.assertRaisesRegex(ValueError, "fixed-signature"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_wrong_certificate_record_blocks_publication(self):
        record = json.loads(self.signing_receipt.read_text())
        record["certificateSha256"] = "0" * 64
        self.signing_receipt.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, "fixed-signature"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_old_package_or_wrong_build_receipt_blocks_publication(self):
        original = json.loads(self.signing_receipt.read_text())
        for overrides in ({"applicationId": "com.example.embyclient"}, {"runNumber": 174}):
            self.signing_receipt.write_text(json.dumps({**original, **overrides}))
            with self.assertRaisesRegex(ValueError, "fixed-signature"):
                self.prepare()
            self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
