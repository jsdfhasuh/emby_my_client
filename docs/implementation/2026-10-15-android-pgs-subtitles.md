# Android PGS decoding and rendering

Build 187 could select a real PGS track but its Android libmpv default flavor
did not register FFmpeg's pgssub decoder. Its Flutter SubtitleView also receives
only text, so enabling a decoder alone cannot display bitmap subtitles.

The Android plugin project now uses the same upstream v1.1.8 full, non-GPL
artifacts. Every JAR and packaged native library has a fixed SHA256 lock. The
Gradle task verifies existing cached JARs as well as fresh downloads, and CI
verifies the actual APK bytes. The original Java helper and registration are
unchanged. Dart/iOS locks, signing, application ID, version derivation and
release policy are unchanged. Full-codec binaries increase APK size.

After confirming the selected native ID, the engine enables native subtitle
visibility only for a recognized native bitmap codec. Text tracks keep the
existing Flutter subtitle overlay. Opening an input and changing selection
reset the rendering mode inside the existing native operation barrier. Server
ordinals, ambiguous metadata and video transcoding never establish a bitmap
track's identity. Existing selection revision and input lifetime guards remain.

## Verification

- Complete local Flutter suite: 1700 passed, 3 platform skips, using a full-codec
  Windows reference library. This is host regression evidence only.
- Android updater unit tests and 27 release preparation tests passed.
- Five APK provenance tests cover exact pairs, tampering, missing helpers,
  unrecognized ABIs and empty APKs. Analyze, source format and ShellCheck pass.
- Actual local ARM64 APK libmpv SHA256:
  c0d797517822ac8e3006318cc5b80a5331a086282690043881448a9fbc843678.
  Relocation-aware enumeration of its compiled av_codec_iterate table finds
  pgssub and preserves every prior codec name. This is static ARM64 evidence.
- Actual APK x86_64 library executes on API 35. The native software renderer
  verifies 40 complete frames against generated PGS masks, including file and
  loopback HTTP, A/B/A, disable, seeks with position readback, reopen, ASS and
  external SRT switching. Required PGS/ASS/SRT decoders are looked up at runtime.
- A separate test-target APK uses the production engine and media_kit Video
  widget on API 33. All 32 Android screenshots pass: exact PGS pixels and
  visible ASS/SRT Flutter text across file/HTTP, switches, disable and reopen.
  The emulator uses software video decoding and the gpu video output. This
  does not establish hardware-decoder or physical-phone behavior.
- The existing download/player navigation suite remains in the full run.

## First failures retained

The old pinned Windows library failed the new PGS test because it lacks that
decoder. With the full-codec host reference, the first run exposed fixture disk
cache errors; the subtitle-only tests now disable disk caching explicitly.
An existing Embed test also timed out before that fixture adjustment; it passed
with diagnostic state reporting, then passed in the full suite.

Local build attempts initially failed in the Windows JDK Unix-domain loopback
implementation. A process-local JDK setting enabled its normal TCP fallback;
no project JVM setting changed. An Android unit invocation omitted the SDK
environment and failed before compilation, then passed with the SDK configured.
The initial analyzer found two minor source issues, both fixed. The first whole
directory format invocation traversed a generated Gradle path that disappeared;
all 330 source Dart files pass. Windows CRLF shell copies were checked again as
the LF bytes used by Linux checkout; the literal dynamic-loader ORIGIN token is
explicitly documented for ShellCheck.

The separate Flutter screenshot harness first failed on test-tool launcher,
chunked HTTP parsing and the emulator's full-screen tutorial. After those fixes,
API 35 still failed to initialize EGL video output with both SwiftShader and
host GPU modes. It had no active video output, not just missing subtitle pixels.
This known emulator limitation is retained as a failed scope; see upstream
https://github.com/media-kit/media-kit/issues/912. The native API 35 software
pixel gate does not claim Flutter texture success. On API 33, the first text
screenshot assertion incorrectly required solid-white pixels in small antialiased
glyphs. The saved screenshot visibly contained TEXT_CUE; correcting that test
to count visible neutral glyph pixels allowed the full 32-frame sequence to
complete. The original failure and screenshots remain in the local evidence.

Physical Android hardware, its hardware decode path, and the user's films or
Emby account have not been tested. A successful CI run is not user acceptance.
Only generated public test content was used; no credentials or private media
were accessed or committed. Final release bytes and updater compatibility must
be checked against the exact workflow commit after publication.

## First CI attempt

Build 188 (commit c745af8, workflow 38724824258) failed with 1701 passed and
2 failed. Both new PGS tests completed their subtitle assertions, then rejected
errors from the Linux libmpv null audio device during paused seeks. The fixture
now explicitly disables its silent audio track and checks that it stays disabled.
It also enables video explicitly: a headless media_kit player defaults to vid=no
without a VideoController. The first audio-only fixture adjustment therefore had
no playback clock and timed out locally; that failed attempt is retained too.
The native error assertion remains intact; no error filtering or retry was added.
Production playback audio is unchanged. Build 188 was not rerun or published.

Build 189 (commit 1f11fa9, workflow 38726146747) also failed with 1701 passed
and 2 failed. Disabling audio and enabling headless video passed on the newer
Windows host library but timed out in both PGS tests on Ubuntu 24.04. This
failure was not rerun or published. Stage-specific native diagnostics and a
local Ubuntu reproduction were added before attempting another CI run.
Both failed workflows blocked iOS and release publication as intended.

The Ubuntu native probe reproduced the exact failure mechanism: with audio off,
the default MKV demuxer reports the MJPEG video as image=true and time-pos stays
at 2.0 while pause=no. This matches mpv 0.37's demux_mkv_open_video source, which
sets still_image for image codecs. The same bytes with the FFmpeg demuxer report
image=false, advance normally, and expose TEXT_CUE. The host fixture now selects
demuxer=lavf and asserts image=false after each open. This setting is test-only;
production input selection and the Android pixel/texture gates are unchanged.
Timeouts now name the cycle/stage and report native state from generated content.
The missing-library first probe invocation during container setup is also kept;
the actual failing clock trace and corrected comparison use the same libmpv.

Upstream cause: https://github.com/mpv-player/mpv/blob/v0.37.0/demux/demux_mkv.c#L1428-L1436
