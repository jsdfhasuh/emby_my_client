# Subtitle usability and playback recovery

This records the implemented behavior and local verification for the changes
following build 192. Local checks do not establish that a new Release exists.
The existing main-push workflow must complete, and the exact published APKs
and historical updater compatibility must then be independently verified.

The user separately reported that the already released build 192 works on
their physical phone. That feedback belongs to build 192. It is not evidence
that the changes described here have passed a new physical-device test.

## 1. Remembered choices and Chinese subtitle preferences

Account preferences support Chinese, simplified Chinese, traditional Chinese,
bilingual Chinese, and the server default, with separate avoid/allow/prefer
policies for forced subtitles. The initial preference is Chinese with forced
subtitles avoided when selecting a preference candidate. A bare `zho` or `chi`
language tag does not establish simplified Chinese. Conflicting metadata and
equally eligible tracks remain ambiguous instead of selecting an arbitrary row.

Manual choices, including disabling subtitles, are remembered only after the
controller confirms they were applied. Identity is scoped to server/account,
item and resolved media source, with a track metadata fingerprint. Native IDs,
local paths and authenticated URLs are not durable track identity. Restoration
waits for the resolved source and ready input, and can reconsider late native
tracks. A manual choice wins over an outstanding preference load or restore.
Changing input requires a fresh binding; switching items does not carry a
previous item's disabled state as its new selection.

Account switching/deactivation invalidates stale writes. Account deletion clears
subtitle preferences even when downloaded media is retained. Missing remembered
tracks and unavailable or ambiguous preference matches do not invent a mapping;
the current server choice can remain. In particular, the avoid-forced preference
does not promise to disable a forced track already selected by the server.

Test entry points: `test/subtitle_preferences_test.dart`,
`test/subtitle_preferences_repository_test.dart`,
`test/subtitle_preference_binding_test.dart`,
`test/account_data_cleanup_test.dart`, and
`test/app_controller_multi_server_test.dart`. These cover source/item/account
isolation, late native IDs, manual precedence, failed applies, shutdown and
deletion races, and restoration across input changes.

## 2. Subtitle menu evidence

Each row reports its ordinal, language evidence, source and delivered format
where known, embedded/external origin, and download state. Native-only tracks
whose origin or per-track download state is unavailable say so. Source codec and
converted delivery format remain distinct. Simplified, traditional, bilingual
and forced hints are shown without turning missing or conflicting flags into
confirmed facts. Duplicate names remain separate rows; duplicate or ambiguous
server indices are not made selectable through an ordinal guess.

Test entry points: `test/subtitle_track_labels_test.dart`,
`test/playback_subtitle_options_test.dart`,
`test/player_screen_subtitle_options_test.dart`, and
`test/subtitle_mapping_evidence_test.dart`.

## 3. Independent offline assets and subtitle repair

Download rows display video, subtitle and cover states independently. A completed
video does not imply that all external subtitles or its cover are available.
Subtitle state distinguishes saved tracks, missing tracks, incomplete discovery,
embedded subtitles retained with the original video, and no subtitles provided
by the server. Cover state distinguishes available, missing, failed, unknown and
not provided.

Completed videos expose subtitle repair and cancellation without re-downloading
the video. Successful existing subtitle files remain usable when a refresh fails
or repair is cancelled. Discovery and repair preserve source identity; late work
cannot republish into a removed task or another account's active task. Offline
selection requires a local available asset and cannot silently fall back to an
online subtitle. Asset and media verification distinguishes missing, unreadable
and invalid payloads. Where a stored digest exists, a fresh cache check can detect
same-size video corruption; legacy entries without a digest report their more
limited file-header and size check honestly.

Test entry points: `test/download_subtitle_discovery_test.dart`,
`test/download_service_test.dart`, `test/download_asset_verifier_test.dart`,
`test/download_media_verifier_test.dart`, `test/downloads_ui_test.dart`, and
`test/offline_playback_test.dart`.

## 4. Display controls follow the active renderer

The production video uses `ConfiguredPlaybackVideo` and its Flutter subtitle
layer for text cues. Text font size, color, outline and vertical position affect
that painted layer instead of relying only on native font properties. The
subtitle subscription follows the current video controller, and position
changes do not implicitly shrink the text scale. Delay follows the playback
engine's subtitle timing setting.

Available controls depend on the confirmed active subtitle and delivered codec.
Supported text formats expose timing, position and text style. Bitmap subtitles
expose timing and position while retaining their image size, color and outline.
Burned-in server subtitles do not expose independent presentation controls.
Unconfirmed selection states do not advertise usable controls; an unknown active
format permits timing only. The active codec is not inferred from an unrelated
download format hint on a direct-play embedded stream.

Test entry points: `test/subtitle_presentation_test.dart`,
`test/configured_playback_video_test.dart`, and `test/playback_controller_test.dart`.
Native PGS position verification uses `scripts/android/subtitle_position_probe.c`
and `scripts/android/verify_subtitle_position.py`, with
`scripts/android/test_subtitle_position_verifier.py` for the verifier. The
12-frame native results below do not substitute for the pending Flutter texture
and production-route checks.

## 5. Subtitle failures and recovery

Failure messages distinguish supported evidence for network errors, missing
offline subtitles, unsupported decoding/delivery, unreadable content, and an
unknown cause. Generic native video/decoder errors are not attributed to a
subtitle unless the current subtitle codec is positively identified. Raw remote
or native error text is not displayed as the user-facing message, and unknown
failures do not claim the subtitle file is corrupt.

Subtitle failure retains controls to retry, choose another track, disable
subtitles, and open the current playback's diagnostics. Subtitle-only failure
does not intentionally stop the video. Repeated failed downloads release their
budget; cancelled responses and retired input callbacks cannot attach to a new
player session. These guarantees do not make an independent media-source or
video-decoder failure recoverable as a subtitle-only problem.

Test entry points: `test/subtitle_problem_test.dart`,
`test/subtitle_fault_recovery_test.dart`,
`test/external_subtitle_loader_test.dart`,
`test/player_route_lifecycle_test.dart`, and `test/playback_controller_test.dart`.

## 6. Offline browse state and network recovery

Cached browse data, posters, item details and episode listings remain available
within their existing account/server scope. Cached or stale presentation keeps
its timestamp and offline status visible. It does not imply that every listed
video is downloaded; an explicit local-playback entry never falls back online.
An unavailable local item is handled before opening the player.

Mounted browse views refresh after recovery signals and foreground return.
Offline retries are bounded by a timer, pause in the background, and debounce
repeated recovery notifications. A network-type change or websocket connection
does not itself establish that cached content is current: a relevant successful
request does. Authentication failures stop automatic retry. Request generations
prevent older successes or failures from overwriting newer cache/recovery state,
and account boundaries remain intact.

Test entry points: `test/browse_recovery_test.dart`, `test/browse_cache_test.dart`,
`test/offline_playback_test.dart`, and `test/photo_viewer_screen_test.dart`.

## 7. Update summary and stable playback diagnostics

The update screen separates installed version/build information from the latest
public version and the state of the check. Its short summary is an excerpt of
the actual release notes, with the complete notes available separately. A failed
or cancelled check is not presented as up to date. Checking, downloading and
installer handoff retain the existing explicit user actions and package/signing
verification policy.

Diagnostics default to the selected playback session, with an explicit switch
to all logs. Association uses structured trace fields rather than timestamps,
nearby records or text inside a JSON detail field. The current selection remains
stable through refresh and scope changes; a later playback does not silently
replace an explicitly selected trace. The summary distinguishes requested,
downloaded, applied, disabled and failed subtitle stages and reports confirmed
format/track information when available. Older generations cannot overwrite
the current summary.

Preview and export use an immutable snapshot through confirmation and native
handoff. Credential redaction remains enabled in current-playback and all-log
exports, including native export paths. Empty or truncated evidence is identified
instead of fabricating a complete playback history.

Test entry points: `test/app_update_screen_test.dart`,
`test/playback_diagnostic_snapshot_test.dart`,
`test/diagnostic_session_ui_test.dart`,
`test/playback_engine_diagnostic_session_test.dart`,
`test/full_diagnostic_export_test.dart`,
`test/android_diagnostic_export_test.dart`, and
`test/token_only_diagnostics_test.dart`.

## 8. Native pixels, routes and lifecycle regression

The regression work exercises generated PGS, ASS and SRT content through local
files and loopback HTTP. Native and route tests cover selection changes,
disable/re-enable, seek, input replacement, exit/reopen, background/foreground
events, and late failures. Fresh routes and native players must not inherit a
retired input's selected track, subtitle download, callback or diagnostic trace.
The route harness enters the production player and checks return navigation and
resource disposal, alongside the independently exercised native renderer.

Test entry points: `test/subtitle_lifecycle_native_test.dart`,
`test/subtitle_bitmap_native_test.dart`, `test/subtitle_render_native_test.dart`,
`test/subtitle_delivery_native_test.dart`, and
`test/player_route_lifecycle_test.dart`. Android harnesses are
`test/support/android_bitmap_harness.dart` and
`test/support/android_player_route_harness.dart`; their drivers are
`scripts/android/run_flutter_subtitle_texture.py`,
`scripts/android/run_player_route_ui.py`, and
`scripts/android/run_flutter_subtitle_gates.sh`. The texture/route protocol
negative checks are in `scripts/android/test_subtitle_texture_protocol.py` and
`scripts/android/test_player_route_protocol.py`.

## Local verification at commit time

Evidence is retained in the task's usability-evidence directory outside the
repository. The final full run completed **1909 passed, 3 skipped**, including
native tests with the test libmpv and input bridge available. Static analysis,
source formatting and 17 shell scripts passed. Android verifier tests passed
**35/35**, and release preparation tests passed **32/32**.

The final accepted Android API 33 texture run passed all **32 stages**, with
zero native errors and confirmed player/log/temp-file cleanup. It verifies
actual generated PGS pixels and decoded ASS/SRT cues in screenshots across
local files and local HTTP, repeated A/B/A changes, disable, seek and reopen.
The fixture uses actual Android OpenSL ES output and silent PCM audio; perceived
audio quality is not tested. One-second preroll is explicit for this generated
indexless MKV and is not a production seek-policy change. Screenshots are
evaluated once against the unchanged pixel criteria.

Production PlayerScreen and DownloadsScreen passed **34 stages**: two online
routes and two actual download-list/offline-player routes, subtitle switches,
return to the download list and reopen. Offline stages assert the actual offline
item, local video and subtitle files, zero network attempts, native backend and
complete owned-resource cleanup. This complements the separate pixel gate;
track selection alone is not rendering evidence.

Desktop and packaged-Android native PGS position probes each passed **12 frames**
for 100 -> 75 -> 100, with actual mask movement and restoration. CI also retains
the pre-existing **40-frame** native gate and must pass the expanded UI gates
before publishing. Post-publication verification downloads the exact CI artifacts
and rechecks native PPMs, texture PNGs, route stages and cleanup.

Final local records: 48-full-tests-third-serialized.log,
57-final-analyze-fixed.log, 57-final-format-check.log,
50-final-shellcheck-authorized.log, 60-stderr-shellcheck.log,
51-final-android-script-tests.log, 52-final-release-script-tests.log,
58-texture-api33-seventh.log, and 64-player-route-api33-fifth.log.
The local-test-ledger.json record links accepted and earlier failed runs.

### Preserved failures and corrections

- The first full run, 23-full-tests-first.log, had **1863 passed, 3 skipped,
  7 failed**. Old trace/session/rate-limit and converted-format expectations were
  corrected with strict replacement assertions. That original result remains failed.
- The second full run, 36-full-tests-second.log, had **1872 passed, 3 skipped,
  3 failed**, plus five native tests reported unfinished. Route tests now expect
  the server's explicit disabled default and scroll the actual subtitle list
  before tapping. The five native tests passed separately; the original log
  alone does not establish their noncompletion cause. The final full run
  completed with all other Flutter commands stopped.
- An isolated test compilation failed because concurrent Flutter commands tried
  to copy the same test-cache file (43-stale-menu-first.log). Commands were then
  serialized. This compiler failure was not counted as a behavioral test.
- Actual first failures were recorded before fixing server-default -1 handling
  and reporting, stale menu callbacks after input changes, applied/plan
  notification reentrancy, duplicate native subtitle errors, and download
  inspection/repair racing deletion or shutdown.
- Earlier texture attempts exposed test-only OSC/null-audio errors and a
  reproducible ALPHA omission with audio disabled. Surface readiness and preroll
  alone did not fix it. Independent native-versus-Flutter screenshots isolated
  it to the generated-media audio configuration; those diagnostic captures are
  marked NOT_ACCEPTANCE. The full 32-stage gate then passed with actual OpenSL ES,
  without relaxing pixel/error thresholds.
- The expanded download-route attempt first stopped at 17 stages because its
  test app omitted the cache scope supplied by the real app. Its red error screen
  and incomplete cleanup remain saved. Supplying the production scope allowed
  the complete 34-stage gate to pass.
- Earlier formatting, lint, Windows shell sandbox and native-probe setup failures
  remain retained. Their environment-only retries are identified separately.

No physical-phone acceptance run was performed for this change. The user's
films and Emby credentials were not accessed. iOS subtitle pixels, arbitrary
server media and perceived audio quality remain untested. Generated-media,
host, emulator and CI results cannot establish those scopes. The separate
build 192 phone feedback is not validation of this change.

## Earlier failures and publication boundary

The earlier build 187 findings and build 188/189/190 first failures remain part
of the record. Their original explanations and limits are preserved in
[Android PGS decoding and rendering](2026-10-15-android-pgs-subtitles.md).
This record does not reinterpret an old terse failure log or replace a failed
attempt with a later success. The existing filename/alias contract is documented
in [Versioned APK download filenames](2026-10-15-versioned-apk-filenames.md).

Independent post-publication verification tools have been prepared outside the
repository. They require an exact pushed commit and successful workflow identity
before inspecting a real new Release, all canonical/legacy APK pairs, and the
actual build 186/187/191/192 updater sources. They also recheck that build 192's
existing Release and assets have not changed. Preparation and static analysis
are not proof that a new Release exists or that compatibility has passed.

Local suite, texture and production-route results above are complete. CI, actual
Release payloads and historical-updater compatibility must be verified against
the exact pushed commit and recorded in the external publication receipt. No
new build number or publication success is inferred from these local results.
