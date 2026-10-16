"""Verify the additive native bitmap-position evidence without changing its gates."""
import argparse
import json
from pathlib import Path

FRAME_NAMES = {f"position-{index:02d}.ppm" for index in range(12)}
HEADER = b"P6\n320 180\n255\n"
WIDTH, HEIGHT, MASK_WIDTH, MASK_HEIGHT = 320, 180, 180, 24


def prepare_output(directory):
    directory = Path(directory)
    if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
        raise ValueError("Native evidence output is not an ordinary directory")
    if directory.exists() and any(directory.iterdir()):
        raise ValueError("Refusing to overwrite existing native evidence; preserve the first attempt")
    directory.mkdir(parents=True, exist_ok=True)


def _mask_top(data, mask):
    if not data.startswith(HEADER) or len(data) != len(HEADER) + WIDTH * HEIGHT * 3:
        raise ValueError("Malformed or truncated position PPM")
    pixels = data[len(HEADER):]
    first_mask_row = next((i // MASK_WIDTH for i, bit in enumerate(mask) if bit), None)
    first_white_row = next((i // (WIDTH * 3) for i in range(0, len(pixels), 3)
                            if min(pixels[i:i + 3]) >= 245), None)
    if first_mask_row is None or first_white_row is None:
        raise ValueError("Missing native PGS mask pixels")
    top = first_white_row - first_mask_row
    if not 0 <= top <= HEIGHT - MASK_HEIGHT:
        raise ValueError("PGS mask is outside the frame")
    for y in range(HEIGHT):
        for x in range(WIDTH):
            white = (70 <= x < 70 + MASK_WIDTH and top <= y < top + MASK_HEIGHT
                     and mask[(y - top) * MASK_WIDTH + x - 70])
            index = (y * WIDTH + x) * 3
            rgb = pixels[index:index + 3]
            # The native software gate's original tolerance: white >=245,
            # background <=10. No allowance for a wrong/stale PGS pixel.
            if min(rgb) < 245 if white else max(rgb) > 10:
                raise ValueError(f"PGS mask mismatch at {x},{y}")
    return top


def verify_position(manifest_path, frames_directory, mask_path):
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    fixed = {
        "schema": "emby-android-bitmap-position/v1",
        "platform": "android",
        "nativeSoftwarePixels": "PASSED",
        "subPos100To75To100": "PASSED",
        "verifiedFrames": 12,
        "flutterTexture": "NOT_RUN",
        "physicalPhone": "NOT_RUN",
    }
    if not isinstance(manifest, dict) or set(manifest) != set(fixed) | {"minimumMaskTop"}:
        raise ValueError("Position manifest schema fields mismatch")
    for key, expected in fixed.items():
        if type(manifest[key]) is not type(expected) or manifest[key] != expected:
            raise ValueError(f"Position manifest field mismatch: {key}")
    minimum = manifest["minimumMaskTop"]
    if type(minimum) is not int or not 0 <= minimum < 140:
        raise ValueError("Invalid minimumMaskTop")
    frames = Path(frames_directory)
    if not frames.is_dir() or frames.is_symlink():
        raise ValueError("Position frames directory missing")
    entries = list(frames.iterdir())
    if {entry.name for entry in entries} != FRAME_NAMES or any(
            not entry.is_file() or entry.is_symlink() for entry in entries):
        raise ValueError("Expected exactly position-00.ppm through position-11.ppm")
    mask = Path(mask_path).read_bytes()
    if len(mask) != MASK_WIDTH * MASK_HEIGHT or set(mask) - {0, 1} or not any(mask):
        raise ValueError("Invalid ALPHA mask")
    tops = [_mask_top((frames / f"position-{index:02d}.ppm").read_bytes(), mask)
            for index in range(12)]
    for index in range(0, 12, 3):
        normal, shifted, restored = tops[index:index + 3]
        if normal != 140 or restored != normal or not 0 <= shifted < normal:
            raise ValueError("Position sequence did not move and restore the actual mask")
    if minimum != min(tops):
        raise ValueError("Manifest minimum does not match the captured pixels")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare-output")
    prepare.add_argument("directory", type=Path)
    verify = commands.add_parser("verify")
    verify.add_argument("manifest", type=Path)
    verify.add_argument("frames", type=Path)
    verify.add_argument("mask", type=Path)
    args = parser.parse_args()
    if args.command == "prepare-output":
        prepare_output(args.directory)
    else:
        verify_position(args.manifest, args.frames, args.mask)
        print("ANDROID_PACKAGED_SUBTITLE_POSITION_PIXELS=PASSED")


if __name__ == "__main__":
    main()
