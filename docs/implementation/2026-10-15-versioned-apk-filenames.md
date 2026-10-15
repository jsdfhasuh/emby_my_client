# Versioned APK download filenames

`prepare_release.py` now emits `EmoEmby-{version}-{architecture}.apk` for manual
downloads. The version comes from `build_version(run_number)`, the same function
used by the build and signed-package verification. The architectures are
`arm64-v8a`, `armeabi-v7a`, `x86_64`, and `universal`. For example, a run whose
verified version is `1.0.192` produces `EmoEmby-1.0.192-arm64-v8a.apk`.
The number 192 appears only in the synthetic test contract; production naming
does not assume the next workflow number.

The existing signing receipt must still match all four input APK hashes,
application ID, run number, and pinned certificate before output is created.
The signing step already checks each embedded version and ABI against that run.
Renaming copies those verified bytes without rebuilding or signing again.
The signing code, package identity, version-code formula, and workflow are unchanged.

## Compatibility assets and update selection

Each future release contains four versioned APKs plus four byte-identical aliases:
`app-debug.apk`, `app-arm64-v8a-debug.apk`, `app-armeabi-v7a-debug.apk`, and
`app-x86_64-debug.apk`. Release notes identify the versioned names as the manual
downloads and explain why the old names remain. `SHA256SUMS.txt` contains all
eight APK names and the existing IPA name, with equal hashes for each alias pair.
Manifest lines use LF on both Windows and Linux.

Builds 186, 187 and 191 have the same updater source Git blob:
`17a42502e293bc9c1456d0f11c91f6794b34a08f`. It recognizes the old names exactly,
ignores the versioned names, and chooses the device's preferred supported ABI
before the universal fallback. Its code is unchanged. Asset ordering therefore
does not introduce a second eligible candidate for an ABI; duplicate recognized
names still fail validation. Alias entries must remain in both the release and
checksum manifest while those installed versions need upgrade support.

No existing release is migrated or edited by this change. Build-191's asset IDs,
names, sizes, digests, URLs, timestamps and release metadata were checked against
the previously downloaded receipt and remained unchanged during local validation.

## Validation before submission

- 32 Python release/signing tests pass on Windows and Ubuntu 24.04.
- 18 new compatibility tests cover 186/187/191 across three ABIs and universal
  fallback, shuffled and misleading candidates, duplicate aliases, and missing,
  duplicate or incorrect alias checksums. They use the unchanged updater's real
  metadata, download, and checksum code through a synthetic HTTP adapter.
- The Python tests compare generated release files with the same JSON contract
  consumed by Dart tests, preventing the two test suites from silently drifting.
- The existing 33 updater and update-screen tests pass; `flutter analyze` and the
  changed Dart file's format check pass.
- A local copy of the already downloaded build-191 ARM64 APK was named
  `EmoEmby-1.0.191-arm64-v8a.apk`. Its 109071532 bytes and SHA256 remained identical;
  `aapt` confirmed version 1.0.191 / 1912000 and `com.jsdfhasuh.emoemby`, and
  `apksigner` verified the existing pinned certificate. This copy was not uploaded.

This validation does not claim a new published build or a physical-device
installation. The changes remain uncommitted pending publication-scope review.
