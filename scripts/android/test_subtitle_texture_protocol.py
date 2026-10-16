"""Negative controls for the device screenshot gate; no Android device needed."""
import copy
import pathlib
import unittest

from PIL import Image

from subtitle_texture_protocol import (
    CLEANUP_KEYS, SCHEMA, STAGES, ProtocolFailure, TextureProtocol, verify_pixels,
)


class TextureProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = pathlib.Path(__file__).resolve().parents[2] / "test/fixtures/subtitles"
        cls.masks = {name: (root / f"expected-PGS-{name.upper()}.mask").read_bytes()
                     for name in ("alpha", "beta")}
        cls.images = {}
        for name in ("alpha", "beta", "off", "text"):
            image = Image.new("RGB", (640, 360))
            if name in cls.masks:
                mask = cls.masks[name]
                for y in range(24):
                    for x in range(180):
                        if mask[y * 180 + x]:
                            image.putpixel((160 + 70 + x, 90 + 140 + y), (255, 255, 255))
            if name == "text":
                # Antialiased neutral glyph-like pixels, deliberately not solid white.
                for x in range(30):
                    image.putpixel((200 + x, 200), (100, 100, 100))
            cls.images[name] = image

    def record(self, index):
        stage, expected, cue = STAGES[index]
        return {"stage": stage, "expected": expected, "text": cue,
                "screenWidth": 640, "screenHeight": 360,
                "nativeErrorCount": 0, "currentVo": "gpu", "audioTrack": "1", "audioOutput": "opensles",
                "textureId": 0, "textureWidth": 320, "textureHeight": 180,
                "fixtureSeek": {"framedrop": "no", "hrSeekFramedrop": "no", "hrSeekDemuxerOffsetSeconds": 1.0},
                "sid": "no" if expected == "off" else "1",
                "visibility": "yes" if expected in ("alpha", "beta") else "no"}

    def terminal(self):
        return {"stage": "complete", "schema": SCHEMA, "platform": "android",
                "scope": "engine-texture", "physicalPhone": "NOT_RUN",
                "audioScope": "SILENT_FIXTURE_AUDIO_QUALITY_NOT_TESTED",
                "fixtureSeekPolicy": "INDEXLESS_GENERATED_MKV_PREROLL_1S",
                "verifiedStages": 32, "nativeErrorCount": 0,
                "cleanup": {key: True for key in CLEANUP_KEYS}}

    def fill(self, protocol):
        for i, (_, expected, _) in enumerate(STAGES):
            protocol.accept(self.record(i), self.images[expected])

    def test_complete_matrix_requires_cleanup(self):
        protocol = TextureProtocol(self.masks)
        self.fill(protocol)
        with self.assertRaises(ProtocolFailure):
            protocol.finish()
        protocol.accept(self.terminal())
        protocol.finish()

    def test_missing_duplicate_reordered_unknown_stages_fail(self):
        for stage in ("file-0-b", "file-1-a", "unknown", "../outside"):
            with self.subTest(stage=stage):
                protocol = TextureProtocol(self.masks)
                value = self.record(0)
                value["stage"] = stage
                with self.assertRaises(ProtocolFailure):
                    protocol.accept(value, self.images["alpha"])
        protocol = TextureProtocol(self.masks)
        protocol.accept(self.record(0), self.images["alpha"])
        with self.assertRaises(ProtocolFailure):
            protocol.accept(self.record(0), self.images["alpha"])

    def test_ass_cannot_pass_with_stale_external_cue(self):
        protocol = TextureProtocol(self.masks)
        for i in range(5):
            protocol.accept(self.record(i), self.images[STAGES[i][1]])
        value = self.record(5)
        value["text"] = "EXTERNAL_CUE"
        with self.assertRaisesRegex(ProtocolFailure, "wrong decoded cue"):
            protocol.accept(value, self.images["text"])

    def test_native_error_and_missing_video_output_are_fatal(self):
        for patch in ({"nativeErrorCount": 1}, {"currentVo": ""},
                      {"nativeErrorCount": False}, {"currentVo": True}, {"expected": "off"},
                      {"screenshotPixels": "PASSED"}):
            protocol = TextureProtocol(self.masks)
            value = self.record(0) | patch
            with self.assertRaises(ProtocolFailure):
                protocol.accept(value, self.images["alpha"])

    def test_generated_silence_requires_real_android_audio_and_no_quality_claim(self):
        for patch in ({"audioTrack": "no"}, {"audioTrack": "auto"}, {"audioOutput": "null"}):
            protocol = TextureProtocol(self.masks)
            with self.assertRaisesRegex(ProtocolFailure, "audio configuration"):
                protocol.accept(self.record(0) | patch, self.images["alpha"])
        for claim in ("PASSED", "DISABLED_NOT_TESTED"):
            protocol = TextureProtocol(self.masks)
            with self.assertRaisesRegex(ProtocolFailure, "audio claim"):
                protocol.accept(self.terminal() | {"audioScope": claim})

    def test_unready_surface_and_blank_bitmap_cannot_pass(self):
        for patch in ({"textureId": None}, {"textureId": True},
                      {"textureWidth": 1}, {"textureHeight": None}):
            with self.subTest(patch=patch):
                protocol = TextureProtocol(self.masks)
                with self.assertRaises(ProtocolFailure):
                    protocol.accept(self.record(0) | patch, self.images["alpha"])
        # Fourth real Android attempt produced a blank image with a valid clock.
        # Surface readiness metadata must never substitute for actual PGS pixels.
        protocol = TextureProtocol(self.masks)
        with self.assertRaisesRegex(ProtocolFailure, "pixel mismatch: 393"):
            protocol.accept(self.record(0), self.images["off"])

    def test_fixture_seek_policy_cannot_be_omitted_or_misrepresented(self):
        for seek in (None, {}, {"framedrop": "no", "hrSeekFramedrop": "no", "hrSeekDemuxerOffsetSeconds": True},
                     {"framedrop": "no", "hrSeekFramedrop": "no", "hrSeekDemuxerOffsetSeconds": 0}):
            protocol = TextureProtocol(self.masks)
            with self.assertRaisesRegex(ProtocolFailure, "seek configuration"):
                protocol.accept(self.record(0) | {"fixtureSeek": seek}, self.images["alpha"])
        protocol = TextureProtocol(self.masks)
        with self.assertRaisesRegex(ProtocolFailure, "seek scope"):
            protocol.accept(self.terminal() | {"fixtureSeekPolicy": "production-defaults"})

    def test_one_wrong_pgs_pixel_is_rejected(self):
        image = self.images["alpha"].copy()
        image.putpixel((160, 90), (255, 255, 255))
        with self.assertRaisesRegex(ProtocolFailure, "pixel mismatch: 1"):
            verify_pixels(self.record(0), image, self.masks, "alpha")

    def test_subtitle_disabled_requires_black_frame(self):
        with self.assertRaises(ProtocolFailure):
            verify_pixels(self.record(3), self.images["alpha"], self.masks, "off")

    def test_blank_text_frame_is_rejected(self):
        with self.assertRaises(ProtocolFailure):
            verify_pixels(self.record(5), self.images["off"], self.masks, "text")

    def test_original_antialiased_text_threshold_is_preserved(self):
        verify_pixels(self.record(5), self.images["text"], self.masks, "text")

    def test_first_failure_cannot_be_recovered_by_later_complete(self):
        protocol = TextureProtocol(self.masks)
        value = self.record(0) | {"nativeErrorCount": 1}
        with self.assertRaises(ProtocolFailure):
            protocol.accept(value, self.images["alpha"])
        first = protocol.first_failure
        with self.assertRaises(ProtocolFailure):
            protocol.accept(self.terminal())
        self.assertEqual(protocol.first_failure, first)
        with self.assertRaises(ProtocolFailure):
            protocol.finish()

    def test_premature_completion_wrong_scope_and_unconfirmed_cleanup_fail(self):
        for patch in ({}, {"scope": "player-ui"}, {"platform": "ios"},
                      {"physicalPhone": "PASSED"}, {"schema": "old"},
                      {"cleanup": {}}, {"nativeErrorCount": 1}):
            protocol = TextureProtocol(self.masks)
            with self.assertRaises(ProtocolFailure):
                protocol.accept(self.terminal() | patch)

    def test_cleanup_failure_cannot_pass_after_all_frames(self):
        protocol = TextureProtocol(self.masks)
        self.fill(protocol)
        terminal = copy.deepcopy(self.terminal())
        terminal["cleanup"]["engineDisposed"] = False
        with self.assertRaisesRegex(ProtocolFailure, "cleanup"):
            protocol.accept(terminal)

    def test_original_harness_failure_precedes_later_cleanup_failure(self):
        protocol = TextureProtocol(self.masks)
        terminal = self.terminal() | {"stage": "failed", "error": "first native failure"}
        terminal["cleanup"]["engineDisposed"] = False
        with self.assertRaisesRegex(ProtocolFailure, "first native failure"):
            protocol.accept(terminal)
        self.assertIn("first native failure", protocol.first_failure)

    def test_boolean_cleanup_error_count_is_rejected(self):
        protocol = TextureProtocol(self.masks)
        self.fill(protocol)
        with self.assertRaisesRegex(ProtocolFailure, "native error during cleanup"):
            protocol.accept(self.terminal() | {"nativeErrorCount": False})

    def test_record_after_completion_is_rejected(self):
        protocol = TextureProtocol(self.masks)
        self.fill(protocol)
        protocol.accept(self.terminal())
        with self.assertRaisesRegex(ProtocolFailure, "after terminal"):
            protocol.accept(self.terminal())
        with self.assertRaises(ProtocolFailure):
            protocol.finish()


if __name__ == "__main__":
    unittest.main()
