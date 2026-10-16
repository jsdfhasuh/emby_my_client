"""Negative controls for retained first attempts and native position evidence."""
import json
from pathlib import Path
import tempfile
import unittest

from verify_subtitle_position import HEADER, prepare_output, verify_position


class PositionVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.frames = self.root / "frames"
        self.frames.mkdir()
        self.mask_path = (Path(__file__).resolve().parents[2] /
                          "test/fixtures/subtitles/expected-PGS-ALPHA.mask")
        mask = self.mask_path.read_bytes()
        for index in range(12):
            top = 95 if index % 3 == 1 else 140
            pixels = bytearray(320 * 180 * 3)
            for y in range(24):
                for x in range(180):
                    if mask[y * 180 + x]:
                        offset = ((top + y) * 320 + 70 + x) * 3
                        pixels[offset:offset + 3] = b"\xff\xff\xff"
            (self.frames / f"position-{index:02d}.ppm").write_bytes(HEADER + pixels)
        self.manifest = {
            "schema": "emby-android-bitmap-position/v1", "platform": "android",
            "nativeSoftwarePixels": "PASSED", "subPos100To75To100": "PASSED",
            "verifiedFrames": 12, "minimumMaskTop": 95,
            "flutterTexture": "NOT_RUN", "physicalPhone": "NOT_RUN",
        }
        self.manifest_path = self.root / "manifest.json"
        self.write_manifest()

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")

    def verify(self):
        return verify_position(self.manifest_path, self.frames, self.mask_path)

    def test_complete_pixel_sequence_passes(self):
        self.assertEqual(self.verify(), self.manifest)

    def test_output_guard_preserves_first_failure_byte_for_byte(self):
        output = self.root / "evidence"
        prepare_output(output)
        prepare_output(output)  # An existing empty directory is allowed.
        sentinel = output / "first-failure.json"
        original = b'{"error":"first attempt"}'
        sentinel.write_bytes(original)
        with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
            prepare_output(output)
        self.assertEqual(sentinel.read_bytes(), original)
        self.assertEqual(list(output.iterdir()), [sentinel])
        with self.assertRaises(ValueError):
            prepare_output(sentinel)

    def test_missing_extra_and_wrong_scope_manifest_fields_fail(self):
        original = self.manifest.copy()
        patches = [
            {"platform": "host"}, {"physicalPhone": "PASSED"},
            {"flutterTexture": "PASSED"}, {"schema": "old"},
            {"verifiedFrames": 12.0}, {"minimumMaskTop": True},
            {"minimumMaskTop": -1}, {"extra": "PASSED"},
        ]
        for patch in patches:
            with self.subTest(patch=patch):
                self.manifest = original | patch
                self.write_manifest()
                with self.assertRaises(ValueError):
                    self.verify()
        self.manifest = original.copy()
        del self.manifest["physicalPhone"]
        self.write_manifest()
        with self.assertRaises(ValueError):
            self.verify()

    def test_missing_duplicate_renamed_and_failure_frames_fail(self):
        last = self.frames / "position-11.ppm"
        data = last.read_bytes()
        for wrong in (None, "position-12.ppm", "position-1.ppm", "position-failure-11.ppm"):
            with self.subTest(wrong=wrong):
                last.unlink()
                if wrong:
                    (self.frames / wrong).write_bytes(data)
                with self.assertRaisesRegex(ValueError, "exactly"):
                    self.verify()
                if wrong:
                    (self.frames / wrong).unlink()
                last.write_bytes(data)

    def test_truncated_ppm_and_one_wrong_pixel_fail(self):
        frame = self.frames / "position-00.ppm"
        original = frame.read_bytes()
        for changed in (original[:-1], original[:len(HEADER)] + b"\xff\xff\xff" +
                        original[len(HEADER) + 3:]):
            frame.write_bytes(changed)
            with self.assertRaises(ValueError):
                self.verify()
        frame.write_bytes(original)

    def test_unchanged_shift_and_failed_restore_fail(self):
        for target, source in ((1, 0), (2, 1)):
            with self.subTest(target=target):
                frame = self.frames / f"position-{target:02d}.ppm"
                original = frame.read_bytes()
                frame.write_bytes((self.frames / f"position-{source:02d}.ppm").read_bytes())
                with self.assertRaisesRegex(ValueError, "move and restore"):
                    self.verify()
                frame.write_bytes(original)

    def test_minimum_must_match_actual_pixels(self):
        self.manifest["minimumMaskTop"] = 94
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "captured pixels"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
