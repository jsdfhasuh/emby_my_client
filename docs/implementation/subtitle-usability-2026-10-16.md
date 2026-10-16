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

### Build 193 first CI failure

Commit a38a18f5bc9bfac07c5920a2e1b8f28ea5da6599 triggered the single
push run 38882067860 (attempt 1). Its full Linux suite reported **1911 passed,
1 failed**: the HTTP SubtitleView/native test did not obtain CUE_ALPHA_FIRST
within its five-second limit. The original test did not identify which A step
failed. iPadOS and publication were skipped, and this attempt produced no new
Release. Raw UTF-8 logs and exact run metadata remain in the external
release/build-193-first-failure evidence directory.

The unchanged focused test initially passed in a matching Linux Flutter/libmpv
scratch environment. A full diagnostic run also passed the two target cases,
but ended with 1901 passed and 11 other failures; it is retained as diagnostic
evidence, not acceptance. Instrumentation found repeated `ao/null` errors,
`illegal state: start() while paused`, in the original SubtitleView-only test,
which had no VideoController and therefore used an audio-only null clock.
The precise cause of the original CI cue timeout was not independently proven.

A predeclared four-cycle file/HTTP comparison required both decoded/native cue
identity and real painted glyphs, with the original greater-than-50 bright-pixel
threshold. All eight original-clock cases failed the added native-error check;
all eight explicit video-clock cases passed, producing 32 glyph PNGs. The
minimal follow-up changes this host test to `aid=no` / `vid=auto`, checks zero
native errors, binds each selection to a fresh subtitle event and completed
seek at a distinct target, and retains the five-second deadline. Every A/B/A
screenshot receives a unique step name. No production audio or seek policy is
changed, and this host test is not evidence of Android audio quality.

The first stricter Windows run exposed a previously unchecked file-cache error;
this fixture test now explicitly disables unrelated disk caching and verifies
the readback. A subsequent Windows tester exited with code 79 without completing
both cases; its cause remains unexplained. One verbose diagnostic run then
passed both cases and retained eight PNGs. The final Linux focused run also
passed both cases with eight PNGs. Format and analysis passed. All three Windows
attempts are preserved (07, 10 and 12 under regression/build193); the last pass
does not erase the incomplete run. The next exact-commit CI is still required.

### Build 194 wrapper cancellation

Commit 7fd010713b939cb1c56923147e77e97571c0a8d0 triggered run 38884659015,
attempt 1. Its Linux suite passed all **1912 tests**; production APK builds,
compatibility policy, native subtitle pixels and subtitle-position pixels also
passed. The API 33 UI wrapper did not reach either Python gate. The root agent
actively cancelled this run to retrieve evidence and repair a separately proven
wrapper defect. Its result remains **cancelled**, not an automatic CI failure or
a successful release. iPadOS and publication did not execute.

The exact original shell wrapper was tested once against isolated fake SDK/adb/
emulator commands. An initial offline device caused the `set -e` boot assignment
to exit after one probe in 0.115 seconds. When `adb emu kill` also failed, its
unconditional cleanup `wait` remained blocked beyond the three-second external
diagnostic limit with the owned fake emulator alive. Those first results are
preserved under regression/build194/offline-repro. The real CI log completed
AVD creation at 10:20:14 UTC; its emulator artifact reported successful boot in
46897 milliseconds, but no UI gate output appeared before cancellation at
10:29:56 UTC. This is consistent with the reproduced defect; the original CI
shell did not record a line-by-line trace.

The wrapper follow-up treats bounded offline boot probes as not ready and gives
owned-process cleanup a finite shutdown sequence while retaining the original
failure status. Before the fix, the first four regression checks reported
three failures and one pass. All five final fake-command checks passed, including
a boot probe that ignores TERM and requires timeout's bounded KILL. The complete
Android verifier discovery then passed **40 tests** with Pillow 11.3.0 and no
skips; final shell syntax and ShellCheck passed. Actual Flutter texture and
production-route acceptance still depend
on a new successful exact-commit run; build 194 supplies no UI acceptance result.

### Build 195 first production-route CI failure

Commit a95b19e02d69218887fb92c18028910b2ed1348d triggered run 38888512556,
attempt 1. The full Linux suite passed **1912 tests**, release preparation passed
**32 tests**, and Android verifier discovery passed **40 tests**. Native subtitle
and position gates passed. The repaired wrapper reached both Flutter gates and
returned failure normally with explicit cleanup status 1; it did not hang.

The actual Android texture gate passed **32 frames** with zero native errors and
complete cleanup. Production navigation completed only **9 of 34 stages**. During
the second online cycle, native subtitle 1 was selected and the generated PGS
ALPHA content was visible, but the next options-sheet open timed out. The first
failure screenshot shows the production player and visible options button with
no bottom sheet. The route's seven cleanup fields are all true. This is a failed
route acceptance result; texture pixels and selected-track state do not replace
its missing navigation stages. iPadOS and publication were skipped, and no
build-195 Release was published. Raw logs, run identity, screenshot and structured
failure data remain under release/build-195-first-failure. The precise input or
modal lifecycle cause requires the follow-up investigation below.

One predeclared diagnostic run used the same 640 by 360 screen at density 160,
with texture first and the instrumented production route second. It passed all
32 texture and 34 route stages. This did not reproduce or explain the original
CI failure. Its pointer and route traces are retained separately as diagnostic
evidence, rather than replacing the failed CI record.

A small controlled regression then reproduced a vulnerability in the test's
pointer protocol. With a Tooltip IconButton inside a parent double-tap detector,
an injected 650-millisecond synchronous pointer-down dispatch stall caused the
old down / await 40 milliseconds / up sequence to register a tooltip long press
and invoke the button zero times. A synchronous real pointer down/up pair
invoked it once, without a tooltip or double tap. Both initial control checks
passed their explicit expected outcomes. The original CI did not record dispatch
timing, so this experiment does not prove that it suffered the injected stall.

The follow-up changes only the harness pointer protocol to a synchronous pair,
as used by WidgetTester.tap, and retains actual hit-tested UI events. It retains
the post-tap settling interval, all 34 route stages, all screenshot thresholds,
and lightweight pointer/route diagnostics. No production gesture or playback
behavior changes. The controlled comparison is saved as
regression/build195/08-touch-control-first.log. The final two touch regressions,
formatting and analysis passed. One predeclared run of the final driver then
passed **32 texture stages followed by 34 production-route stages**, with all
seven route cleanup fields true. Evidence and source hashes are retained in
regression/build195/handoff.json and serial-fixed-first. Real offline ASS/SRT
glyphs are visible in the route screenshots; paused-at-zero PGS menu selections
are not counted as additional PGS pixel proof. The separate 32-frame texture
gate supplies that rendering evidence. Full acceptance still requires the next
exact-commit CI and actual Release verification.

### Build 196 first native-row close failure

Commit f814f14bd491fe5ea5de08acd099b8daf99c8b0d triggered run 38892950383,
attempt 1. The full Linux suite passed **1914 tests**, release preparation passed
**32 tests**, Android verifier discovery passed **40 tests**, and the cache safety
check passed **29 tests**. Native pixels, position pixels and all **32 Flutter
texture frames** passed. Production navigation failed at **10 of 34 stages**:
after the second online cycle selected PGS ALPHA, tapping native subtitle 2 did
not close the options sheet within the existing deadline.

The new diagnostic recorded a successful RenderBox hit at (320, 148.8) and a
5.559-millisecond pointer down/up sequence. That does not support attributing
this failure to a long press. The final screenshot shows the open subtitle list
with PGS BETA visible; there was no matching modal pop. The state recorded after
the timeout was ready/appliedEmbedded without a subtitle error. The existing
record does not establish whether the row callback was enabled at the exact tap
or whether its scroll activity was idle. The production callback closes the
sheet before starting asynchronous subtitle selection, so a decoder wait alone
does not explain the missing pop.

All seven route cleanup fields are true, and emulator cleanup returned status 1
normally. iPadOS and publication were skipped; no build-196 Release was created.
The exact first logs, metadata, pointer/route records and screenshots remain in
release/build-196-first-failure. The distinct build-195 open failure remains
preserved above. Neither was rerun to select a passing result.

One predeclared follow-up diagnostic preserved the exact click behavior and
added row availability, scroll/tab state and gesture callback traces. Its texture
gate passed all 32 frames, but its route gate failed at **14 of 34 stages** with
an options-open timeout. This is a separate first local failure, retained in
regression/build196/serial-diagnostic-first, rather than a reproduction of the
CI's BETA-row close timeout.

The local trace and screenshots establish a driver acknowledgment defect. The
ASS stage returned from the old pause helper while its screenshot still showed
the pause icon, meaning playback continued. The helper trusted a stale play
button tooltip, and a cue already present after seeking allowed the next pause
check before the play event had reached the UI. Later play/pause toggles reversed
the intended state. The SRT stage reached 11502 milliseconds of the 12-second
fixture. A MaterialPageRoute pop at 52.125070 seconds occurred before the options
button's actual onTap callback, as the fixture reached its end. The enabled
options button had received a 4.746-millisecond touch without scroll ancestors;
its callback did execute after the route had already begun exiting.

The test-only follow-up confirms play/pause using the actual button tooltip,
Player.state and native pause/end-of-file state together. All toggles still use
real UI events. A cue cannot bypass the play acknowledgment, and a player-route
stage cannot be accepted while playback is still running. Native pause, position,
duration, seek and completion evidence is saved alongside stage/failure records.
The 12-second fixture and existing route/pixel thresholds remain unchanged.
This fixes the independently proven local driver failure; it does not establish
the cause of build 196's earlier native-sheet close failure.

The final focused run passed four checks: two acknowledgment controls plus the
two retained touch controls. Formatting and analysis passed. One predeclared
serial run of the final driver passed **32 texture frames followed by 34 route
stages**; all **28 shown-player stages** recorded native pause=yes, UI and Dart
playing=false, and no end-of-file state. All seven cleanup fields are true. The
fixed external-text screenshot shows EXTERNAL_CUE while paused at three seconds.
Evidence and tested source hashes are saved in regression/build196/handoff.json.
Failure diagnostics additionally retain a bounded 512-message gesture/callback
history, without discarding unrelated application or native messages. This local
acceptance does not replace the pending exact-commit CI and Release checks.

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
