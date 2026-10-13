import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from prepare_release import ANDROID_APPLICATION_ID, APK_NAMES, SIGNING_RECEIPT, certificate_pin, prepare_release


class PrepareReleaseTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.inputs = self.root / "artifacts"
        self.output = self.root / "release"
        self.notes = self.root / "notes.md"
        self.commit = "a" * 40
        self.ipa_name = f"emby-ios-core-{self.commit[:12]}-175.ipa"
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
        self.checksum.write_text(f"{digest}  {self.ipa_name}\n", encoding="utf-8")
        self.signing_receipt = self.inputs / SIGNING_RECEIPT
        self.signing_receipt.write_text(json.dumps({
            "format": 2, "certificateSha256": certificate_pin(),
            "applicationId": ANDROID_APPLICATION_ID, "runNumber": 175,
            "apks": {name: hashlib.sha256(self.files[name].read_bytes()).hexdigest() for name in APK_NAMES},
        }), encoding="utf-8")

    def prepare(self, **overrides):
        arguments = {
            "artifacts_dir": self.inputs,
            "output_dir": self.output,
            "notes_path": self.notes,
            "run_number": 175,
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
            {*APK_NAMES, self.ipa_name, self.checksum.name, "SHA256SUMS.txt"},
        )
        records = (self.output / "SHA256SUMS.txt").read_text().splitlines()
        self.assertEqual(len(records), 5)
        for record in records:
            digest, name = record.split("  ")
            self.assertEqual(digest, hashlib.sha256((self.output / name).read_bytes()).hexdigest())
        notes = self.notes.read_text(encoding="utf-8")
        self.assertIn(self.commit, notes)
        self.assertIn("fixed app key", notes)
        self.assertIn(certificate_pin(), notes)
        self.assertIn("TrollStore", notes)

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
