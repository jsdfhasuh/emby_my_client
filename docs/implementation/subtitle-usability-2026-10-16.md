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
