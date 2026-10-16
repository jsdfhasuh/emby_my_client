"""Fail-closed protocol and unchanged pixel gates for the generated texture test.

This is engine/Video texture evidence, not production PlayerScreen UI evidence.
Importing this module performs no device actions.
"""
import math


SCHEMA = "emby-android-texture/v2"
CLEANUP_KEYS = {"engineDisposed", "logsCancelled", "temporaryFilesRemoved"}
STAGES = tuple(
    (f"{transport}-{cycle}-{name}", expected, cue)
    for transport in ("file", "http")
    for cycle in range(2)
    for name, expected, cue in (
        ("a", "alpha", ""), ("b", "beta", ""), ("a2", "alpha", ""),
        ("off", "off", ""), ("a3", "alpha", ""),
        ("ass", "text", "TEXT_CUE"), ("srt", "text", "EXTERNAL_CUE"),
        ("a4", "alpha", ""),
    )
)


class ProtocolFailure(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ProtocolFailure(message)


def verify_pixels(value, image, masks, expected):
    """Keep the original full-frame PGS/off and antialiased text thresholds."""
    width = value.get("screenWidth")
    height = value.get("screenHeight")
    require(type(width) in (int, float) and math.isfinite(width) and width > 0,
            "invalid screen width")
    require(type(height) in (int, float) and math.isfinite(height) and height > 0,
            "invalid screen height")
    require(abs(image.width / width - 1) < .01, "unexpected screenshot scale")
    require(abs(image.height / height - 1) < .01, "unexpected screenshot height")
    require(image.width >= 320 and image.height >= 180, "cropped screenshot")
    x0, y0 = round((image.width - 320) / 2), round((image.height - 180) / 2)
    video = image.convert("RGB").crop((x0, y0, x0 + 320, y0 + 180))
    if expected in ("alpha", "beta"):
        mask = masks[expected]
        require(len(mask) == 180 * 24 and set(mask) <= {0, 1}, "invalid PGS mask")
        errors = 0
        for y in range(180):
            for x in range(320):
                white = (70 <= x < 250 and 140 <= y < 164 and
                         mask[(y - 140) * 180 + x - 70])
                pixel = video.getpixel((x, y))
                if min(pixel) < 230 if white else max(pixel) > 20:
                    errors += 1
        require(errors == 0, f"pixel mismatch: {errors}")
    elif expected == "off":
        require(max(video.getextrema()[i][1] for i in range(3)) <= 20,
                "subtitle pixels remain after disable")
    else:
        white = sum(min(p) > 64 and max(p) - min(p) < 15
                    for p in video.getdata())
        require(white > 20, f"missing Flutter text pixels: {white}")


class TextureProtocol:
    def __init__(self, masks):
        self.masks = masks
        self.frames = 0
        self.first_failure = None
        self.terminal = False
        self.complete = False

    def reject(self, reason):
        if self.first_failure is None:
            self.first_failure = str(reason)

    def accept(self, value, image=None):
        try:
            self._accept(value, image)
        except Exception as error:
            self.reject(error)
            raise

    def _accept(self, value, image):
        require(not self.terminal, "record after terminal")
        require(isinstance(value, dict), "stage must be an object")
        stage = value.get("stage")
        if stage in ("complete", "failed"):
            self.terminal = True
            require(value.get("schema") == SCHEMA, "wrong terminal schema")
            require(value.get("platform") == "android", "wrong platform")
            require(value.get("scope") == "engine-texture", "wrong evidence scope")
            require(value.get("audioScope") == "SILENT_FIXTURE_AUDIO_QUALITY_NOT_TESTED", "invalid audio claim")
            require(value.get("physicalPhone") == "NOT_RUN", "invalid phone claim")
            require(value.get("fixtureSeekPolicy") == "INDEXLESS_GENERATED_MKV_PREROLL_1S",
                    "wrong generated-fixture seek scope")
            require(stage == "complete", "harness failed: " + str(value.get("error")))
            cleanup = value.get("cleanup")
            require(isinstance(cleanup, dict) and set(cleanup) == CLEANUP_KEYS
                    and all(item is True for item in cleanup.values()),
                    "cleanup is unconfirmed")
            require(self.first_failure is None, "earlier failure: " + str(self.first_failure))
            require(self.frames == len(STAGES), "missing screenshot stages")
            require(type(value.get("verifiedStages")) is int
                    and value["verifiedStages"] == len(STAGES), "wrong stage count")
            require(type(value.get("nativeErrorCount")) is int and
                    value["nativeErrorCount"] == 0, "native error during cleanup")
            self.complete = True
            return
        require(self.first_failure is None, "earlier failure: " + str(self.first_failure))
        require(self.frames < len(STAGES), "extra screenshot stage")
        name, expected, cue = STAGES[self.frames]
        require(stage == name, f"stage order: expected {name}, got {stage}")
        require(value.get("expected") == expected, "stage expectation changed")
        require("failure" not in value and "screenshotPixels" not in value,
                "harness cannot supply verifier outcome")
        require(type(value.get("nativeErrorCount")) is int
                and value["nativeErrorCount"] == 0, "native error")
        require(isinstance(value.get("currentVo"), str) and
                value["currentVo"] not in ("", "null"), "no active video output")
        require(value.get("audioTrack") == "1" and value.get("audioOutput") == "opensles",
                "wrong Android audio configuration for generated silence")
        require(type(value.get("textureId")) is int and value["textureId"] >= 0,
                "no Android texture")
        require(value.get("textureWidth") == 320 and value.get("textureHeight") == 180,
                "Android texture dimensions not ready")
        seek = value.get("fixtureSeek")
        require(isinstance(seek, dict) and set(seek) == {
                    "framedrop", "hrSeekFramedrop", "hrSeekDemuxerOffsetSeconds"} and
                seek.get("framedrop") == "no" and seek.get("hrSeekFramedrop") == "no" and
                type(seek.get("hrSeekDemuxerOffsetSeconds")) in (float, int) and
                seek["hrSeekDemuxerOffsetSeconds"] == 1,
                "wrong generated-fixture seek configuration")
        require(value.get("text", "").strip() == cue, "wrong decoded cue for stage")
        if expected in ("alpha", "beta"):
            require(value.get("visibility") == "yes" and
                    value.get("sid") not in (None, "", "no", "auto"), "bitmap not selected")
        elif expected == "off":
            require(value.get("sid") == "no" and value.get("visibility") == "no",
                    "disable state mismatch")
        else:
            require(value.get("visibility") == "no" and
                    value.get("sid") not in (None, "", "no", "auto"), "text not selected")
        require(image is not None, "missing screenshot")
        verify_pixels(value, image, self.masks, expected)
        self.frames += 1

    def finish(self):
        require(self.first_failure is None, "first failure: " + str(self.first_failure))
        require(self.complete and self.terminal, "missing clean completion")
        require(self.frames == len(STAGES), "incomplete screenshot matrix")
