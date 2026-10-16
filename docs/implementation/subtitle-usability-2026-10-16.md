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

### Cross-build first-failure timeline

The three original failures use the same 15-second deadline and 40-millisecond
polling interval. Opening waits for a mounted `BottomSheet`; closing waits for
that element to disappear. A native sid change never satisfies either predicate.
The complete extracted events and source/evidence hashes are retained externally
in regression/build197/cross-build-first-failure-timeline.json. Times below are
relative to each harness process, not shared wall-clock timestamps.

| Original run | Actual target and gesture | Route evidence | Playback / scrolling evidence | Missing causal evidence |
| --- | --- | --- | --- | --- |
| 195, 9/34 | Options target hit after native 1 selection; no measured pointer duration or callback trace | No route observer existed; failure screenshot has no sheet | Native pause/EOF and scroll activity were not recorded | Whether the child callback ran and which production guard applied |
| 196, 10/34 | BETA row hit at 44.550279 s; pointer down/up 44.550427–44.555986 s | Modal pushed at 42.969780 s; no following pop before timeout | Tap-time row enablement, native pause/EOF and scroll activity were not recorded | Whether the selection callback ran and whether its captured input/source remained current |
| 197, 1/34 | Options hit at 6.668764 s; pointer down/up 6.685972–6.703147 s; child recognizer onTap at 7.047133 s | Only initial and player routes pushed; no modal push or player pop | UI/Dart/native paused, position 0/12 s, no EOF; no scroll ancestors | Whether InkWell forwarded to the production method, and the method's guard values |

The controlled long-press vulnerability and the separate local stale-pause/EOF
failure were independently demonstrated and corrected. Neither proves the
original 195 or 196 cause. Build 197's recorded pause and route state exclude
that local EOF explanation for its occurrence. The recognizer's onTap trace is
not itself a production-method entry record. No further publication is accepted
on the strength of those earlier local controls alone.

### Build 197 first options-open failure

Commit c7297ad213e420d715bb5cdf4b07cb848fdf4cf1 triggered run 38897403987,
attempt 1. The full Linux suite passed **1916 tests**, release preparation passed
**32 tests**, Android verifier discovery passed **40 tests**, and cache safety
passed **29 tests**. Native and position pixels and all **32 Flutter texture
frames** passed. Production navigation failed after **1 of 34 stages**, when the
first online player options sheet did not open.

The new evidence excludes the earlier local EOF failure for this occurrence:
native pause=yes, UI and Dart playing=false, no completion/end-of-file state,
and position zero of a 12-second fixture. The enabled options button received
a successful hit and a 17.175-millisecond pointer pair. Gesture arbitration
selected its child tap recognizer and recorded its onTap callback. No modal
route push or player route pop followed. The screenshot shows the paused player
with its controls visible and no bottom sheet. The cause remains under
investigation; successful callback dispatch alone does not prove that the
production method passed its state guards or completed navigation.

All seven application cleanup fields are true, and the emulator wrapper returned
failure normally. iPadOS and publication were skipped; no build-197 Release was
created. Raw logs, exact run metadata, gesture/route diagnostics and screenshots
remain under release/build-197-first-failure. The earlier open, close and local
EOF failures remain separate; no failed workflow was rerun to obtain a pass.

One predeclared follow-up added only observation: fixed menu entry/guard/mapping/
push/close fields, plus callback error types and allowlisted source frames while
preserving the original Flutter/platform handlers. It records no media URLs,
IDs or exception messages. The focused lifecycle check passed once and analysis
passed. No playback, subtitle, gesture or wait behavior was changed.

That single serial diagnostic passed **32 texture frames**, then failed at
**17 of 34 route stages**. Both online cycles opened and closed their sheets
normally. On the first offline player, the pause helper timed out waiting for
playing=true even though UI, Dart and native state already agreed on paused at
zero of 12 seconds, with no EOF or completion. The final real touch was the
download play row; no player-video or play/pause touch followed, so an accidental
control tap is not established. The cause of the initial offline pause is also
unproven because startup/lifecycle events were not recorded. No callback errors
were recorded; all seven cleanup fields are true. This distinct failure remains preserved in
regression/build197/serial-diagnostic-first. It is not an acceptance run or a
reproduction of build 197's first options-open failure, and no repeat was run.

The original build 197 cause remains unestablished. Its existing artifact did
not capture the application method entry or callback exceptions, and that past
run cannot provide the missing observations retroactively. At the end of that
local investigation, the diagnosis-only changes remained uncommitted, remote
main was c7297ad, and the latest published Release was build 192.

The next controlled run carries these reviewed, redacted diagnostics into the
same existing CI workflow to obtain the missing evidence. It is a new diagnostic
commit, not an unchanged retry or a claimed repair of the historical failure.
Navigation, subtitle behavior, fixtures, deadlines, stage counts and pixel gates
are unchanged. The initial offline-pause failure is retained without a speculative
behavior fix. A passing run would not establish the original 195-197 cause;
any actual Release still requires exact-commit CI, payload integrity, signing,
version and historical-updater verification before being accepted.

### Build 198 controlled diagnostic result

The reviewed diagnostic commit 9595a1dac021f7cdf95c340b103d315884870426
triggered the single automatic push run 38902253378, attempt 1. It was a new
observation run in the same workflow, not an unchanged retry. All **1916 Linux
tests**, **32 release preparation tests**, **40 Android verifier tests**, and
**29 cache safety tests** passed. Native pixels, position pixels and all
**32 texture frames** passed. Navigation failed at **12 of 34 stages**; iPadOS
and publication were skipped. All seven application cleanup fields are true.
Raw logs and original screenshots are retained in release/build-198-first-failure.

The new record establishes this occurrence's direct failure mechanism. At
45.613638 seconds the native ASS row was enabled, not scrolling, and bound to
ready input epoch 1. Its callback popped the sheet at 45.625409 seconds. The
next enabled options button received a real hit, a 6.375-millisecond pointer
pair, and its child callback at 46.438013 seconds. The production method entered
at 46.518086 seconds with controller present but plan absent, phase=resolving,
and input epoch 3. It returned `blocked reason=no_plan` at 46.518709 seconds.
No modal push followed. UI, Dart and native playback remained paused at zero
of 12 seconds without EOF, and callbackErrors was empty. The screenshot shows
TEXT_CUE and the enabled settings control without an open sheet.

Thus the click was discarded during an input transition. The normal native
subtitle selection path does not itself reconfigure or increment the input
revision. A stop followed by prepareSource can account for epoch 1 to 3 before
a replacement plan resolves, but these fields do not establish which recovery
or cache/lifecycle event triggered it. In this same run, the first cycle's first
menu already reported ready epoch 3 at 6.189842 seconds, before the first native
subtitle row tap at 7.699474 seconds. Input replacement therefore also occurred
without a manual subtitle selection. Its upstream trigger remains under
investigation. The result does not retroactively prove the causes of builds
195-197.

The targeted correction opens the requested settings modal during resolution,
shows its loading state, and refreshes the contents from the current controller.
Current contents capture the current input/source binding while previously
queued callbacks retain their stale-input rejection. Three controlled resolver
tests first failed against the original production code: a single real tap while
resolving produced no sheet, an already-open sheet did not show resolution, and
failed resolution did not show the unavailable state. These original failures
are retained in regression/build198/02-resolving-negative-first.log.

After the fix, all three behavioral regressions passed. The first complete
focused file had **8 passes and 1 failure** in diagnostic ordering: a departing
sheet emitted a mapping record after close. That result is retained in
04-menu-focused-first.log. Mapping is now recorded only while the menu is open
and its input/source binding changes; the source value is never exported. The
final focused run passed **11 tests**, including both fixed-field diagnostic
parser tests, and static analysis passed. Old callbacks remain rejected during
and after input replacement, while a freshly rendered row selects the current
native ID and closes the same modal.

One declared serial run of this menu fix passed **32 texture frames**, then
failed at **17 of 34 route stages**, with **14 of 28 paused-frame confirmations**
and all seven cleanup fields true. The original diagnostic is retained in
regression/build198/serial-menu-fixed-first. At 44.528365 seconds the offline
player logged inactive, at 44.684934 resumed, and at 44.771940 playback_ready
with UI and Dart playing=false and duration 12 seconds. The timeout snapshot
also had native pause=yes, time-pos=0 and eof-reached=no. No callback errors
were recorded. This establishes a ready, paused input while the initial harness
unconditionally awaited playing=true. The lifecycle sequence is consistent with
startup quiescence but does not independently prove the unique upstream cause
or reclassify the earlier failures.

The controlled harness correction observes the current ready input and
acknowledges matching UI, Dart and native state before acting. An initially
paused input is explicitly played through the real control, acknowledged as
playing, then paused through the real control and acknowledged again. An
already-playing input is explicitly paused. Production lifecycle behavior is
unchanged. The cue flow still requires its explicit play and pause confirmations;
no retry, longer deadline or lower pixel/stage/paused-frame gate is introduced.

The startup helper's first focused run passed **5 tests**, retaining the two
existing stale-cue controls. Its first analysis reported one missing-braces lint;
that report remains in 15-startup-analyze-first.log. After adding the braces,
analysis passed and the final APK was built from the recorded source hashes.
The one declared run of that changed driver passed **32 texture screenshots**,
**34 route stages**, **28 paused-frame confirmations**, all three texture cleanup
fields and all seven route cleanup fields. Callback errors were empty. The owned
API 33 emulator was stopped without wiping it. Evidence and source/APK hashes
are retained in regression/build198/handoff.json and serial-startup-fixed-first.

The visual scopes remain distinct: the 32 texture screenshots exercise files
and local HTTP, two cycles each, with A-B-A-off-A-ASS-SRT-A selection. They include
20 actual PGS glyph frames, four subtitle-off frames and eight text frames.
The production-route PGS stages validate choice binding and navigation at the
initial paused position; they do not prove a visible PGS cue there. Route ASS/SRT
stages do check visible text. Independent review of the original PNGs confirmed
this distinction. A selected native ID alone is not treated as display evidence.

No physical-phone acceptance run was performed for this change. The user's
films and Emby credentials were not accessed. iOS subtitle pixels, arbitrary
server media and perceived audio quality remain untested. Generated-media,
host, emulator and CI results cannot establish those scopes. The separate
build 192 phone feedback is not validation of this change.

### Build 199 dependency-install first failure

Commit e6adad36f214b1fac898fcc670e13163c8247113 triggered the single automatic
run 38907907027, attempt 1. Format and analysis passed, followed by **1924 full
tests**, **32 release preparation tests**, **40 Android verifier tests**, and
**29 cache safety tests**. The first synthetic-harness build then failed during
Gradle project configuration: the implicit installation of fixed NDK
28.2.13676358 reported `ZipException: Archive is not a ZIP archive` and
assembleDebug exited 1. This occurred before the synthetic APK compiled, so no
new emulator or UI result exists for this run. iPadOS and publication were skipped.

The original 1,105,902-byte job log and run metadata are retained in
release/build-199-first-failure. The bad download response itself was not saved;
its upstream cause is unestablished. The workflow's explicit NDK installation
was ordered after the first Gradle builds, leaving those builds dependent on
an implicit SDK download. The next change prepares and validates the same fixed
NDK before the first build. It does not change the compiler version, signing,
package identity, publication policy or subtitle acceptance gates. The failed
run is not retried unchanged.

The bootstrap's first **6 Linux tests** passed, including invalid HTTP bodies,
checksum mismatch, invalid ZIP, wrong revision, evidence preservation, and real
unzip executable/symlink handling. The first full Android Python check used the
container system Python by mistake and ended with **30 tests / 1 import error**
because Pillow was absent. Its original log remains in
regression/build199/04-android-suite-final.log. Using the existing CI-equivalent
Pillow environment, the unchanged full suite passed **46 tests**.

One actual official download was then installed into a new isolated Linux SDK:
HTTP 200, **722261334 bytes**, official SHA1
`a7b54a5de87fecd125a17d54f73c446199e72a64`, revision **28.2.13676358**, and
executable Clang **19.0.1**. The real compiler symlinks were preserved. The
installer's source hashes match that run. The successful archive is removed
after validation; failure responses and phase receipts remain available. No
Flutter/device run was repeated for this dependency-only change. Evidence is in
regression/build199/real-official-first/receipt.json and handoff.json.

### Build 200 first failure: a retired test-driver element

Commit 5851e7f4b6d3272a30520798d75991d1060eb469 triggered automatic run
38910889499, attempt 1. The new NDK preparation passed in CI with one actual
verified download. Format, analysis, **1924 full tests**, **32 release tests**,
**46 Android verifier tests**, and **29 cache safety tests** passed. Both synthetic
APKs and the application APKs built. The native **40 subtitle frames** and
**12 position frames**, followed by **32 Flutter texture frames**, passed.
Production-route navigation failed at **9 of 34 stages**, with all seven cleanup
fields true and callbackErrors empty. iPadOS and publication were skipped.
The original 1,228,830-byte job log, JSON and PNG artifacts are preserved in
release/build-200-first-failure; the separate actual NDK receipt is retained in
release/build-200-ndk-setup-first.

This run provides a direct memory-pressure observation. The first online input
logged playback_cache_memory_pressure at 5.869491 seconds, then ready epoch 3
at 7.412632 seconds. On the second input, the real options button opened its
sheet at 34.873012 seconds. Memory pressure arrived at 35.072571 seconds while
paused at 0.5 seconds with input epoch 1; mapping then reported epoch 2 at
35.104797 seconds. During the resulting menu replacement, the driver retained
the old subtitle Text element across ensureVisible/endOfFrame awaits. Its next
findRenderObject call at android_player_route_harness.dart:486 threw because
that element was defunct. No pointer was dispatched to the subtitle tab for
that action. The screenshot still shows the actual settings sheet.

The failure is the driver's stale-element access during a real input transition.
The next driver correction resolves the current target through a stable selector
after asynchronous preparation, and performs its final hit test and one atomic
pointer pair in the same synchronous turn. It does not repeat an action after
sending a pointer or increase the original action deadline. This run's captured
memory-pressure cause must not be used to retroactively prove the unknown
upstream triggers in build 198 or the original 195-197 failures.

The controlled legacy case reproduced the inactive-element exception after
replacing the target during an asynchronous frame. The corrected cases replace
the target during ensureVisible and endOfFrame, pass through loading content,
and record exactly one pointer down, one pointer up, and one callback on the
current element. A missing-target deadline sends no pointer. The final focused
suite passed **11 tests**, and analysis passed for all three changed test files.
The first legacy fixture incorrectly reused a Text element, and the first new
fixture called an assertion inside an overlapping test guard (9 pass, 2 fail).
Both fixture failures and the initial two curly-brace lint findings are retained
unchanged in regression/build200; they are not product failures or discarded
attempts at the Android media run.

The changed driver then completed one predetermined texture-to-route run on the
owned API 33 emulator: **32 texture frames and 34 route stages passed**, with
**28 UI/Dart/native paused acknowledgements**, all seven route cleanup fields
true, all three texture cleanup fields true, zero native texture errors and no
callback errors. The parent's independent replay also accepted the 34 route
records and checked the complete menu observations. Actual screenshots visibly
show PGS ALPHA in the texture test and EXTERNAL_CUE in the offline production
player. The route's PGS stages establish binding/navigation only; separate
texture/native pixels establish glyph rendering. This local run did not receive
memory pressure: the build-200 cause is supported by its original CI trace and
the controlled replacement tests, not by claiming another local pressure event.
The emulator was stopped without wiping data. Source/APK hashes, first logs,
JSON and screenshots are retained in regression/build200. Physical phones,
private films and iOS subtitle rendering remain untested.

### Build 201 first failure: startup diagnostics masked the primary error

Commit 9bf6b732897bdb7a7f64b284548df69a159af61e triggered automatic run
38915362751, attempt 1. Format and analysis passed. The full suite reported
**1927 passed and 1 failed**: subtitle_delivery_native_test.dart's http-native
case. Android build/render checks, iPadOS and publication were not reached.
The complete 990,051-byte job log and exact run metadata are retained in
release/build-201-first-failure. No APK or UI artifact exists for this run.

The exception was `[Player] has been disposed` at the test's line 136, inside
the timeout description passed to _until. That description ran only after the
200 checks at 25 ms intervals failed to observe a non-applying subtitle state.
The preceding file-native test passed at 14:29:13.180925 UTC and this failure
was reported at 14:29:18.721115 UTC. This identifies a secondary diagnostic
failure, not the original reason startup failed. The controller's terminal
startup-error path sets phase failed and disposes the engine; this test has no
engine recreator or concurrent shutdown. The original primary error, startup
state and native error details were not retained, so the upstream cause remains
unknown. Neither network failure, audio failure nor the earlier Android memory
pressure is established by this evidence.

The follow-up will require ready state immediately after start and retain safe
startup/controller/engine observations before any disposed-handle read. It will
preserve the existing sid and decoded-cue requirements and failure result.

The first instrumented Linux run passed 11 tests (six diagnostic controls and
five actual delivery modes), but its retained native events revealed a separate
production defect: the cache capability probe wrote stream-buffer-size=1. Each
mode recorded both a native log and an error event rejecting that value before
opening media. The actual fixed Linux binary reports a ByteSize range of
4096..536870912 and a 128 KiB default. The
[mpv manual](https://mpv.io/manual/stable/#options-stream-buffer-size) specifies
byte units; the [reference source](https://github.com/mpv-player/mpv/blob/v0.39.0/stream/stream.c#L91-L113)
also bounds the option. A controlled range regression failed on the original
implementation with invalidValues=[1]; an ignored-write negative case passed.

The production change is limited to using **4096 bytes** for this probe. Its
existing write/readback and default-restoration checks remain intact. Test-only
diagnostics now require ready/live startup, retain the first 128 safe events,
preserve original exceptions and stacks, and use cached state when describing
failure. Native subtitle-text and overlay matching, sid checks, cue positions,
audio configuration and wait counts are unchanged.

One revised Linux run passed **28 tests**: 16 capability tests, six diagnostic
controls, and six actual native tests. The new strict native capability test
confirmed support, default restoration and no native errors after event-stream
closure. All five delivery modes recorded **zero invalid-probe events**, with
no dropped events. File/HTTP cue exercises still each recorded 11 ao/null
illegal-state log entries; these were retained, and this result does not claim
all native logs were error-free or that audible playback was validated. Both
instrumented variants completed startup, so neither reproduces build 201's
original primary startup failure. That historical cause remains unknown.

Analysis passed for all five changed Dart files. The original CI failure,
instrumented baseline, controlled negative and fixed run are retained under
regression/build201 with source hashes and per-mode snapshots. No unchanged
CI run was retried. Android rendering will be checked by the next exact-commit
workflow; no new local Android run is claimed for this probe change.

### Build 202 first failure: iOS plugin type unavailable during compilation

Commit 00a312e6234dd1fc5d7fabb917fbaa83fd96dad3 triggered automatic run
38918810461, attempt 1. **Quality and Android completed successfully**:
1937 full tests, native subtitle/position pixels, 32 Flutter texture frames and
34 production-route stages passed. The parent's replay of the actual saved
route records confirmed 28 paused player stages, six non-player stages, all
seven cleanup fields true, and no callback errors or blocked menu events.

The iPadOS job failed in Run native diagnostics and libmpv capability XCTest
before executing tests: media_kit_video 2.0.1's MPVVideoOutParams.swift line 23
could not find mpv_node_list in scope. xcodebuild exited 65. The device IPA and
Release were therefore not produced. The complete 1,432,893-byte iOS job log,
1,278,959-byte successful Android job log, original run metadata and Android UI
artifact are preserved in release/build-202-first-failure. The initial finding
was a Swift/C type-import compilation failure. The complete log subsequently
confirmed the cause: curl failed to connect to github.com while downloading
the fixed mpv v0.36.0 headers, then the upstream podspec ignored make's failure.
CocoaPods reported installation success without the required C declarations.
No unchanged CI attempt was rerun.

The repair invokes the original locked media_kit_video 2.0.1 Makefile before
CocoaPods. It retains each bounded attempt's output, exit code, duration and
partial download, and checks the archive against the upstream fixed SHA256.
All four generated headers must match the verified archive byte for byte.
After pod installation, their public copies and umbrella imports must also
match. A successful command alone cannot pass either gate. Evidence uploads
run even after failure. Dependency locks, package identity, signing and release
policy remain unchanged; no package source or podspec is patched.

The first Windows test run passed 12 checks and exposed one POSIX-simulation
fixture error (missing SIGKILL); its original log is retained. After fixing
that fixture, all 13 checks passed on Windows and Linux. An isolated Ubuntu
run retained the original Makefile's three failures under dash (unsupported
here-string syntax, with all downloaded archive hashes correct). Setting only
the Linux make shell to bash then completed the actual original Makefile on
its first attempt in 4.681 seconds; the pinned archive and all four output
headers passed verification. Darwin execution was not changed. These local
checks do not claim a macOS pod install or Xcode result; the next exact-commit
workflow must establish those results before publication.

### Build 203 first failure: native selection lost during cache safety reopen

Commit 3b9af8a241dfc5afbcff8be96c9cb677965a2cf2 triggered automatic run
38924973279, attempt 1. Format, analysis, 1937 full tests, 32 release tests,
46 Android verification tests and 29 cache-safety tests passed. Native subtitle
and position checks passed, and all 32 Flutter texture frames passed. The
production-route check stopped after one of 34 stages with UI timeout: native
applied check. All seven cleanup fields were true and callbackErrors was empty.
The complete 1,261,680-byte quality log and original UI artifact are retained
in release/build-203-first-failure. iPadOS and Release were skipped; the iOS
header fix therefore remains unverified by macOS CI.

This failure contains a concrete lifecycle sequence: selecting the native row
closed the sheet at 11.039701 seconds; memory pressure arrived at 11.133255
seconds in ready/input epoch 1; reopening the sheet observed waitingForReady
at epoch 3; playback returned to ready at 12.600294 seconds. The final state
was appliedNone while playback remained paused at 2/12 seconds without EOF.
The controller intentionally invalidates native/local input-bound targets on
generation changes, and the preference binding must resolve a safe logical
choice on the new input. The original trace does not record subtitle status
at the exact pressure event, so it cannot establish whether that request was
still awaiting native confirmation. No unchanged CI attempt was rerun.

Controlled tests demonstrated a reachable production race: a manual native
request still awaiting application was lost when the real memory-pressure
handler reopened the input. The two original-behavior checks failed, including
one with late track metadata. The repair captures only a volatile logical
fingerprint for the owning same-source safety transaction. It keeps subtitles
off during the reopen, then resolves a unique match against current tracks and
creates a fresh input binding. Confirmation is required before remembering or
saving the choice. New manual requests, another source, cancelled ownership and
retirement invalidate the pending transaction. Missing or ambiguous metadata
reports a subtitle failure while video remains usable; a later unique match can
still restore the request. Neither a stale native ID nor an ordinal is reused.

Review added a negative case with a different default subtitle in the reopened
input. The initial patch failed two such controls: it reported failure while
leaving that default active. Those failures are retained; the final patch keeps
the native subtitle disabled until the requested match is confirmed. A delayed
preference load is also covered. Local subtitle control uses a real generated
temporary SRT file and a fresh binding. Fixture compilation errors, initial
unlocalized fixture timeouts, the missing temporary file and one braces lint are
retained separately from production failures.

The final related suite passed 116 tests, and analysis passed. Safe passive
cache-lifecycle evidence now includes only typed subtitle status/source enums
and numeric revision/input epoch fields; invalid values and unrelated data are
excluded. Existing UI waits, pixel thresholds and navigation gates are unchanged.
The frozen source hashes and complete local first results are in
regression/build203. The single frozen-code Android API 33 emulator sequence
then passed all 32 texture frames and 34 route stages. Root independently replayed
the saved pixel/protocol artifacts, verified 28 paused player records and six
non-player records, all seven cleanup fields, clear menu/callback evidence and
matching source hashes. Visual review confirmed PGS ALPHA in the texture capture
and EXTERNAL_CUE on the offline production page. No memory-pressure event occurred
in this local sequence: the pending-choice race is demonstrated by the controlled
tests, and this pass does not establish the original CI's instantaneous state.
Physical phones and perceptual audio remain untested. Exact-commit CI and actual
Release payload verification remain required before publication.

### Build 204 first failure: play request overlaps cache safety reopen

Commit 4c6afbb01f3616a86ecb9d980856202912a85f14 triggered automatic run
38931361713, attempt 1. Format, analysis and 1948 full tests passed, as did
native subtitle/position pixels and all 32 Flutter texture frames. The route
check passed 13 of 34 stages before timing out waiting for playing=true during
the second loop's external subtitle playback. UI, Dart and native state all
remained paused at 3.5/12 seconds, without EOF or seeking. All seven cleanup
fields were true and callbackErrors was empty. The complete 1,248,489-byte
quality log and original UI artifacts are preserved in
release/build-204-first-failure. iPadOS and Release were skipped; no unchanged
CI attempt was rerun.

This is distinct from build 203's native-applied check. The final play pointer
sequence hit an enabled Play button at 56.755112 to 56.756566 seconds. Gesture
arbitration delivered its onTap at 57.195559 seconds. Memory pressure had arrived
at 57.035099 seconds, with subtitleStatus=appliedExternal, subtitleSource=explicit,
subtitleRevision=9 and inputEpoch=1. Playback became ready again at 57.583417
seconds but stayed paused. The original saved trace therefore places the actual
play callback inside the cache safety reopen. Review is checking how that new
play intent interacts with the restart's captured playAfterReady value; a code
snapshot overwrite is a hypothesis until controlled tests establish the path.
Subtitle display thresholds, pause acknowledgements and UI gesture gates remain
unchanged. Root also viewed diagnostic-00.png: EXTERNAL_CUE is visibly rendered,
the Play button is shown, and the timeline is near 00:03/00:12. The observed
failure concerns playback acknowledgement after the click.

Controlled gates then established a reachable loss of new playback intent during
stop, open and resume seek, plus stale Start reporting at the ready notification
boundary: all eight original-behavior cases failed. The controller now gives
explicit play/pause requests a revision, preserves that intent across internal
reopens, and delays applying it until input preparation has completed. Calls
waiting for the same revision share the tracked native operation. Old native
completions reapply the current intent only to the current, usable engine; they
cannot publish state into a retired generation or revoke a newer request. Lifecycle quiescence
retains priority, and Start reporting waits for the current operation to settle.

Review exposed three adjacent timeout mistakes in intermediate implementations,
each captured as a failing controlled test before correction. The first converted
a native timeout into a generic error and allowed a second open over an unsettled
operation. The second let a superseded timeout fail startup after a newer request
had succeeded. The third let an internal timeout downgrade increment the user
revision, so two waiters for the same operation mistook it for a new request.
The final implementation preserves typed, unsuperseded startup timeouts and the
existing no-fallback barrier; only an actual newer request supersedes a timeout.
Input command eligibility is reset on each startup attempt and before failure
cleanup. Internal timeout downgrade does not increment the explicit intent
revision. Tests assert a separate native-playing bit as well as controller state
and reporting, including both command orders and delayed native completion.

The final related suite passed 288 tests and analysis reported no issues. All
first results remain under regression/build204: 02-original-controls.log,
11-analyze-first.log (lint), 13-timeout-first.log, 16-related-final-first.log
(a lifecycle fixture whose nonzero resume was correctly cancelled),
21-superseded-startup-first.log and 27-shared-timeout-first.log. The zero-position
lifecycle fixture verifies native pause and paused reporting. The earlier fixture
observed existing cancellation of a nonzero resume; no independent new nonzero
resume test was added. The original CI trace still does
not identify the exact controller assignment executed at its failure instant;
controlled tests establish the reachable defects without retroactively adding
observations to that trace.

The first frozen-code local Android sequence passed all 32 texture frames, then
lost its host-side runner after an exec-server transport disconnect. The saved
route output contains 11 stages through 1-pgs-b, with no terminal record or
cleanup confirmation; this sequence is incomplete, not an accepted pass. Read-only
process and socket checks found no surviving serial/route runner while the owned
emulator and app still existed. The exact runner exit mechanism was not captured.
The original output and interruption evidence remain in serial-fixed-first.
After the execution connection recovered, one additional complete sequence was
authorized in a separate serial-after-transport-interruption directory, against
the same 254 frozen source/dependency hashes and unchanged acceptance gates. This
is a replacement for an interrupted local measurement; no failed CI run was
rerun. The separate complete sequence then passed 32 texture frames and 34
route stages, with 28 paused-player records, six non-player records, all seven
route cleanup fields true and no native/callback errors. Root independently
replayed the saved pixel/protocol artifacts and all 254 source hashes, and viewed
PGS ALPHA and offline EXTERNAL_CUE text in the screenshots. No memory-pressure
event occurred in this local run; the race remains established by controlled
tests, not by an observed local pressure event. The owned emulator was stopped
without wiping it. Physical phones, private movies and audible quality remain
untested. Exact-commit CI, the pending macOS header check and actual new Release
payload verification are still required.

### Build 205 first failure: first offline input fails to open

Commit 6c03d292ba5af3367d650af0b43619e242615f89 triggered automatic run
38937962766, attempt 1. Format, analysis and 1969 full tests passed, as did native
subtitle/position pixels and all 32 Flutter texture frames. Both online route
loops completed. The route check then stopped after stage 17 (download-list),
timing out on offline native ready. Root viewed the original screenshot: the
first offline route shows the playback-failed page and a Return button. The
terminal cleanup has routesClosed=false and the other six fields true;
callbackErrors is empty. iPadOS and Release were skipped. The full 1,267,766-byte
quality log and original artifacts remain in release/build-205-first-failure.

The offline route was pushed at 62.515629 seconds. Lifecycle inactive/resumed
events followed at 63.107373 and 63.202045 seconds, then native_open failed with
fingerprint=other at 63.460279 seconds. This native_open label reflects the
controller startup phase; it does not identify a particular native command as
the failing operation. MediaKit forwards selected native error-log prefixes, but
the saved artifact has neither the original prefix nor text, so the underlying
file/decoder/other failure cannot be distinguished. The later diagnostic has position and
duration zero and a Player-disposed native-read assertion. That later read is
not established as the primary opening failure. This is distinct from build
204's playing acknowledgement timeout; the primary cause remains under review.
An independent cleanup gap was found: the normal player-back widget remains in
the tree but can be hidden and ignore pointer input. The visible error Return
button had no stable key, while the harness cleanup only selected player-back.
This can leave the failed route open without identifying why startup failed.
No unchanged CI run has been rerun, and no new Release has been published.

### Build 205 investigation: preserve first failure and restore error Return

Controlled widget tests exposed a separate production defect: after initial
startup failure, the normal fullscreen control layer can remain visible because
playback never starts its hide timer, covering the error page's Return button.
The failed state now hides that layer and stops it receiving pointer events.
The existing error Return action has a stable key, and the harness selects this
visible action when cleaning up a failed route. The regression uses the real
DownloadsScreen and PlayerScreen, verifies hit testing, returns to Downloads,
and checks one engine disposal, zero network attempts and temporary-file removal.
The original missing-key failure, the first still-blocked Return failure, and
the subsequent insufficient navigation-wait/obsolete normal-back test failures
remain recorded. This controlled overlay defect is not established as the cause
of build 205's original failure screenshot or native startup error.

A passive diagnostic retains independent bounded evidence for preparation,
media startup, runtime and cleanup within each controller generation: each group
keeps its first error and at most eight error/fatal native-log events. It emits
only fixed channel, prefix, failure-kind, playback-phase and startup-step enums,
bounded generation/input counters and lifecycle state. Native text, URLs, paths,
tokens and media names are never emitted by this event. The startup step is the
Dart receipt point, not proof of which native operation originated the message.
The safe route-artifact extractor accepts the same closed schema; controlled
tests capture a primary permission error before disposal and reject private or
unrecognized fields. The diagnostic itself does not alter recovery. The subsequent probe-settlement
repair described below prevents reuse after an unconfirmed probe stop; cache
profile values and user playback intent are unchanged.

The fixed desktop experiment opened generated local media in three lifecycle
windows (before, overlapping and after open). Its first three cases all failed
the native-error gate with mkv: Failed to create file cache, despite completing
the playback/track assertions. The experiment inherited MediaKit's disk-cache
default and bypassed production's disabled offline cache profile. The mkv log
prefix is not forwarded to MediaKit's errorStream, so this observation does not
explain build 205's playback_engine_error. A separate, explicitly changed
condition applies and reads back the production-equivalent disabled profile:
all three cases passed. Both results are retained; no original failure is
relabelled as a pass. This host experiment checks input/lifecycle behavior and
tracks, with audio disabled; it does not establish Android causality, rendered
subtitle pixels or audible quality. The Android primary cause remains UNKNOWN.

### Build 205 follow-up: settle temporary probe input before deletion

The first instrumented local sequence (serial-diagnostic-first) passed 32 texture
frames and 34 route stages against 258 frozen hashes, with all cleanup checks
true. Texture nativeErrors was zero and route callbackErrors was empty. The
new route diagnostics nevertheless captured file/file_missing during the second
online cacheSetup (22.682843 seconds, error-stream counterpart at 22.685049),
and lavf/file_cache_failed during both offline cacheSetup phases (44.074155 and
65.330224). These messages were nonterminal; every route later reached ready.
The original artifacts, frozen manifest and successful measurement remain
unchanged. They establish the observation, not the cause of the old build 205
failure.

Read-only review found that all plans run the temporary WAV profile-switch probe
before resolving even the disabled offline profile. In the original probe,
accepted loadfile followed by a property-read or command failure could return
unsupported without stopping the accepted input; finally still attempted to
delete its directory. Two controlled original-code cases failed because input
remained pending. Their later file-deletion assertions were not reached and are
not claimed as observed results. A third negative case proved that a preparation
error consumed the single error slot and hid a subsequent media-startup error.
All three failures remain in 25-probe-evidence-original.log (five other tests
passed). The asynchronous loadfile contract is documented by
[mpv 0.36 input commands](https://raw.githubusercontent.com/mpv-player/mpv/v0.36.0/DOCS/man/input.rst):
command completion does not establish that the new file has finished loading.

The probe now checks that the context is paused, idle and has an empty playlist
before loading. It never writes or restores pause. A successful load must expose
the probe path and positive duration. Every accepted or potentially accepted
load is stopped, with idle and empty-playlist confirmation before deleting its
input. A failed or unconfirmed stop retains the temporary input until real
native disposal and propagates a typed unsafe-probe error through the controller,
preventing real-media open, cache configuration or startup fallback on that
context. Preparation errors also have a separate diagnostic quota from media
startup, runtime and cleanup errors. These are controlled, independently proven
defects; the missing original native message still prevents assigning build
205's primary cause.

### Instrumented Android first failure: stale debug reference pointer

The new serial-probe-fixed-first measurement against 262 frozen hashes failed
before its first texture frame. The app died about three seconds after launch;
the existing 180-second harness deadline then expired, the outer runner exited
1, and the route gate did not run. No cleanup completion was reported. Original
logs, APK hashes, screenshot, exit information and native crash buffer remain
in the build205 evidence directory; this is not a passing measurement.

Root independently matched the crash address 0x78ba000a0390 with the decimal
pointer 132740259906448 restored by MediaKit's debug NativeReferenceHolder. The
crashing app PID was 3960. Its matching reference file was last modified at
17:03:10 UTC, before this 18:11:36 UTC process, and still held exactly that old
pointer. The locked package restores the buffer by PID and immediately reads
it via FFI; the crash frame is anonymous Dart code. This establishes this
measurement's stale debug-reference failure before engine construction or cache
probing. The release-mode code skips this debug holder. It does not establish
the cause of build 205's older startup error or the separate Windows incomplete
test run. A scoped cold-start cleanup for the dedicated emulator harness is
required; production code and the package cache remain unchanged for this issue.

### Scoped runner repair and debug-APK publication boundary

The dedicated emulator runners now back up and remove only exact MediaKit
debug-holder filenames before a cold launch, after force-stop and two checks
that the app has no live process. The helper checks the emulator identity,
restricts enumeration on-device to the fixed holder prefix, refuses symlinks,
unexpected names, oversized files and non-pointer contents, and saves all
matching inputs before deleting any. It rechecks metadata before removal and
records partial failure. No app-data clear, private media access or package-cache
modification is involved. Ten focused helper cases passed. The first Linux
suite used an interpreter without Pillow and failed to import one test module;
the next invocation had already started on the same interpreter and also failed.
Both results remain in 52/53. With the existing Pillow environment, all 56 Python
cases passed in 54-android-python-linux-venv.log.

The new serial-holder-fixed-first measurement used the unchanged 41 APK hashes
and 264 source/dependency hashes frozen in 55. Both gates exited zero: 32 texture
frames and 34 route stages passed, with 28 paused-player acknowledgements, six
non-player records, all seven route and all three texture cleanup fields true.
There were no recorded native failure/error, memory-pressure or callback events
in this measurement. Root independently replayed the pixel/protocol artifacts,
verified all frozen hashes, and viewed PGS ALPHA and offline EXTERNAL_CUE pixels.
The owned emulator was stopped without wiping. This does not replace the earlier
zero-frame crash or establish the primary cause of build 205.

The expanded desktop suite in 32-probe-related-final.log completed 251 tests but
reported all three host-native lifecycle cases as did not complete, exiting 1
without a captured primary native/assertion cause. One authorized verbose
diagnostic invocation of those three unchanged cases passed with normal native
allocation/disposal and overall exit zero. That separate diagnostic did not
explain the earlier exit; the expanded run remains incomplete with unknown cause.
The earlier 134-test probe suite passed and final analysis found no issues; its
first six lint findings remain in 28-probe-analyze-first.log.

Review of the existing workflow confirmed that published APKs use --debug.
Although release-mode code skips the holder, that observation does not exempt
these published debug APKs: production main directly initializes MediaKit and
uses the same Android files directory, without a cold-process guard. The runner
repair alone is not sufficient to address this publication risk. A minimal
application cold-process guard is being added without changing build mode,
dependencies, package identity, signing or publication policy. The successful
runner-only measurement remains separate evidence, not acceptance of that
pending application change.

### Application cold-process guard and final local acceptance

The debug source set now registers DebugMediaKitApplication. Its onCreate runs
before Flutter initialization and invokes a synchronized process-once guard.
Only the current PID's exact MediaKit holder and safe_local_storage .src file
are candidates; both are validated as direct regular private files before any
removal. Pointer contents are never read, other PIDs and user data are untouched,
and failure prevents unsafe initialization with a fixed non-sensitive message.
The JVM-static guard preserves newly allocated live references across repeated
entry and Dart hot restart. Release build mode, package, signing and publishing
configuration are unchanged. The earlier runner cleanup was archived with its
hashes in 62 and removed: both final runners are byte-identical to the base commit.

The first six-case Windows JVM run passed five and failed while creating a
symlink fixture because this account lacks that OS privilege; no cleanup
assertion ran in that case. The failure and XML remain in 63. The Windows suite
then passed 43 with that one platform-limited fixture explicitly skipped. Linux
ran the same six cleanup cases with zero failures, skips or assumptions (66),
including actual symlink, stale-pointer, interrupted-write and same-process
preservation checks. Three merged manifests and both actual newly built APK
manifests identify the startup Application. The first read-only APK inspector
assumed a hex boolean, whereas aapt2 printed true; that parsing failure remains
in 77 and was corrected without rebuilding or rerunning a gate. Root separately
verified both actual APK manifests and hashes using aapt, and confirmed the
verifier rejects the older unguarded APK.

The first Linux native/probe set passed 137 and failed all three host lifecycle
cases (68). A single diagnostic run with unchanged configuration, five-second
deadline and assertions showed all three failures were position progress only:
duration was 12, pause=no, idle=no and eof=no, but native time-pos and Dart
position stayed zero. Diagnostic snapshots occur after a frozen failed-deadline
result and cannot extend acceptance. One two-condition experiment (71) observed
the default mkv demuxer marking the selected MJPEG track image=true, with no
progress. Explicit lavf alone produced image=false and time-pos=0.5 within the
same deadline. The original file-format was mkv, not an image demuxer. Only the
Linux generated-fixture host test now requests/readbacks lavf and checks the
video is not marked as an image. Production and Android demuxer settings are
unchanged. The resulting 140-case Linux target set passed (72), and final analysis
found no issues (73). These observations do not explain the Windows incomplete
run or the old build 205 primary startup failure.

The final ordinary-runner sequence serial-app-protected-first used two newly
built APKs and 265 frozen source/dependency hashes (74). It passed all 32 texture
frames and 34 production-route stages, with 28 paused-player acknowledgements,
six non-player records, all seven route and all three texture cleanup fields
true, no recorded native failure/error or memory-pressure events and no callback
errors. No external pointer pre-cleanup ran. Root independently replayed saved
pixel/protocol evidence, verified every frozen hash, and viewed PGS ALPHA and
offline EXTERNAL_CUE pixels. The owned emulator was stopped without wiping it.
Actual Android PID collision was not deliberately forced; current-PID reuse and
same-process preservation were controlled JVM filesystem cases, while these
Android runs validate normal cold startup and real subtitle/navigation behavior.
Physical phones, user movies, iOS subtitle pixels and audible quality remain
NOT_RUN. Exact-commit full CI and actual Release/update compatibility verification
are still required. All first failures remain preserved, and no CI was rerun.

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

Local validation outcomes and incomplete runs are recorded above. CI, actual
Release payloads and historical-updater compatibility must be verified against
the exact pushed commit and recorded in the external publication receipt. No
new build number or publication success is inferred from these local results.
