# Fixed Android libmpv with PGS decoding

This Android-only module replaces the Gradle project directory selected by
Flutter's plugin loader. The Java registration/helper and manifest are unchanged
copies of media_kit_libs_android_video 1.3.8 (MIT; LICENSE included). Dart plugin
resolution, generated registration, and other platform dependencies are unchanged.

Native JARs come from the same upstream project:
https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.8

The full flavor enables all FFmpeg decoders/demuxers/parsers while retaining
--disable-gpl --disable-nonfree. It is NOT the encoders-gpl flavor.
The v1.1.7 default build omitted pgssub. v1.1.8 restores missing full release
artifacts; source comparison does not change FFmpeg/mpv versions.
Source/config/license information:
- https://github.com/media-kit/libmpv-android-video-build/compare/v1.1.7...v1.1.8
- https://github.com/media-kit/libmpv-android-video-build/blob/v1.1.8/buildscripts/flavors/full.sh
- https://github.com/media-kit/libmpv-android-video-build/blob/v1.1.8/buildscripts/include/depinfo.sh
- https://github.com/mpv-player/mpv/blob/78d43740f52db817d98bcf24fb30a76ab6fa13ff/Copyright
- https://github.com/FFmpeg/FFmpeg/blob/n6.0/LICENSE.md

artifacts.json pins the release JAR SHA256 digests observed from GitHub and
independently verified locally, plus the SHA256 of every packaged native library.
Downloads use a temporary file and fail closed on mismatch. Existing JARs are
verified on every build. Never put prebuilt native binaries in this source tree.

To upgrade, review upstream source/configuration, obtain and independently verify
all ABI hashes, update the lock, then run APK provenance/capability tests and the
Android native subtitle pixel probe. Do not substitute a latest URL or bypass the
hash check. The full flavor increases APK size; signing and update policy remain
unchanged.
