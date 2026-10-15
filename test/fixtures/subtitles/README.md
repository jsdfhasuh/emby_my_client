# Generated subtitle fixtures

All content is generated from code; no private or downloaded media is included.
The Matroska fixture contains 12 seconds of 320x180 black MJPEG video, silent
PCM audio, PGS ALPHA and PGS BETA bitmap tracks, and an ASS TEXT_CUE track.
external.srt contains EXTERNAL_CUE. The two .mask files contain the exact 0/1
PGS bitmap pixels, 180x24 at video coordinate (70, 140).

Regenerate with Python and Pillow 11.3.0:

    python test/support/generate_pgs_fixture.py

fixture-manifest.json records the generated video hash and size. CI consumes
the checked-in fixture and needs no font download or Pillow installation.
scripts/android/run_subtitle_render_probe.sh verifies every native output pixel
from actual APK libraries on Android, including local file and loopback HTTP,
PGS A/B/A, disable, seek, reopen, ASS and external SRT switching.

For a separate Flutter texture check, build the explicit test target:

    flutter build apk --debug --split-per-abi --target-platform android-x64 --target test/support/android_bitmap_harness.dart
    python scripts/android/run_flutter_subtitle_texture.py --serial emulator-5556 --apk build/app/outputs/flutter-apk/app-x86_64-debug.apk --output build/texture-check

Run only on a dedicated disposable emulator. It installs the harness, changes
emulator resolution/density and captures generated-media screenshots. It binds
only loopback port 38765 and requires adb on PATH plus Pillow 11.3.0. Never
publish this test-target APK; the release workflow always builds lib/main.dart.
