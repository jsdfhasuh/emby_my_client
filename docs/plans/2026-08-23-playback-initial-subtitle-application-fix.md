# Playback Initial Subtitle Application Fix

Status: IMPLEMENTATION_COMPLETE
Device acceptance: DEVICE_ACCEPTANCE_PENDING

## Problem

When an Emby media source returned a default subtitle stream, the playback
menu could show that stream as selected before the current media engine had
loaded it. The first playback therefore showed no subtitle until the user
disabled subtitles and selected the stream again.

## Root Cause

`EmbyApi` already resolved `DefaultSubtitleStreamIndex` into
`PlaybackPlan.subtitleStreamIndex`, but initial playback only applied explicit
controller selections. The UI also treated the plan value as proof that the
engine had applied the stream. The two meanings were not equivalent.

## State Model

- Desired selection: `SubtitleSelection.followServerDefault`,
  `SubtitleSelection.disabled`, or `SubtitleSelection.explicitStream(index)`.
- Resolved selection: `PlaybackPlan.subtitleStreamIndex`, which is only the
  stream resolved for the current playback plan.
- Applied selection: `PlaybackState.subtitleSelectionStatus`,
  `appliedSubtitleKind`, `appliedSubtitleStreamIndex`, and the bound generation
  and engine. The UI uses this state for checkmarks and retry availability.

Explicit disable is represented internally by `subtitleDisabled`. PlaybackInfo
requests use `SubtitleStreamIndex=-1`; generated media URLs omit the subtitle
parameter so disable is distinct from following the server default.

## Playback Behavior

### DirectPlay

The controller applies the plan default when the desired selection follows the
server default. Embedded subtitles wait for the current engine track stream and
use `TrackMapper`; external subtitles resolve `DeliveryUrl` and call
`loadExternalSubtitle`. Applied state is updated only after the engine call
returns successfully. Explicit disable calls `selectSubtitleTrack(null)`.

### DirectStream and Transcode

Subtitle selection remains a server-side stream decision. The resolver receives
the explicit disable flag or selected stream, and the controller records the
server-applied result without issuing a local engine track selection.

### Offline DirectPlay

Offline playback remains local-only. A stored `IsDefault` subtitle stream may
become the resolved default, while explicit disable clears it. No network
DeliveryUrl is used and offline playback cannot force transcode.

## Async and Failure Handling

Track waits are stream-based and bounded. They are cancelled when generation,
engine, shutdown, or disposal changes. Engine identity and generation checks
discard stale events and stale applied results. Subtitle mapping or loading
failure records a redacted diagnostic, leaves video playback usable, clears
the applied state, and leaves the menu item retryable. No fixed delay or
unbounded polling is used.

Diagnostic categories include requested, applied, disabled, failed, mapping
failed, cancelled, and stale subtitle application events. They contain only
selection source, kind, stream index, generation, and error type; URLs, tokens,
paths, titles, and server addresses are excluded.

## Test Matrix

- Initial DirectPlay applies the resolved embedded subtitle and server audio.
- Subtitle tracks arriving after ready are applied through the track stream.
- No default subtitle does not select the first available track.
- External default subtitles load once and update applied state.
- A resolved but unapplied subtitle fails visibly and can be retried.
- DirectStream and Transcode record server-applied subtitle state.
- Explicit disable survives bitrate reconfiguration and controlled reopen.
- Explicit subtitle selection survives controlled reopen.
- Resume playback applies the server default subtitle before the resume seek.
- A new media controller follows its own default, and engine recreation
  reapplies an explicit subtitle disable.
- PlaybackInfo compatibility fallback preserves explicit disable.
- URL generation omits `SubtitleStreamIndex=-1` while requests retain the
  explicit disable marker.
- Offline default and disable semantics remain local and test-covered.
- Widget tests cover unapplied, applied, disabled, and failed menu states.
- Existing generation, shutdown, recovery, cache, resume, and seek tests
  remain in the controller suite.

## Non-Goals

This change does not add subtitle search or download features, language
preferences, encoding conversion, a new renderer, a media engine replacement,
cache architecture changes, or unrelated UI/theme changes.

## Implementation Result

The implementation and regression tests are complete on the independent
branch. Automated validation evidence is recorded in the task handoff after
the final verification commands. No real Emby media session or physical device
has been used for acceptance.

## Verification Evidence

- `dart format --output=none --set-exit-if-changed lib test`: PASS (239 files,
  no changes).
- `flutter analyze`: PASS (no issues found).
- `flutter test test/playback_controller_test.dart`: PASS (28 tests).
- `flutter test test/playback_cache_controller_test.dart`: PASS (39 tests).
- `flutter test test/emby_api_playback_test.dart`: PASS (29 tests).
- `flutter test test/playback_subtitle_options_test.dart`: PASS (4 tests).
- `flutter test test/player_screen_subtitle_options_test.dart`: PASS (2 tests).
- `flutter test`: PASS (987 tests, 3 skipped).
- `git diff --check`: PASS.
- `flutter build apk --debug --split-per-abi`: PASS. Generated
  `app-armeabi-v7a-debug.apk`, `app-arm64-v8a-debug.apk`, and
  `app-x86_64-debug.apk`.
- Real device acceptance: DEVICE_ACCEPTANCE_PENDING.
