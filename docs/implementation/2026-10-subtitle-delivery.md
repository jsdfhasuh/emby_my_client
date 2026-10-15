# Subtitle identity and delivery

This supersedes the DirectStream/Transcode subtitle assumptions in the older
initial-subtitle plan. Video transcoding does not prove subtitles are burned in.

## Selection and lifecycle

The controller distinguishes server stream indices, native engine track IDs, and
local external assets. The current-file section of the subtitle sheet selects
the actual native ID even when server metadata conflicts or two tracks share a
title and language. It never derives an ID from a server index or display order.
Duplicate native IDs are unavailable. Native selections do not report a guessed
server subtitle index.

Native/local rows bind to the item session, engine, generation, and input epoch.
Every selection gets a monotonically increasing revision. Queued writes and late
results validate that revision, so the first A in A -> B -> A cannot overwrite the
new A. Retired input rows cannot select tracks in a newly opened input.

## Delivery

- External: download and validate through the subtitle loader, then attach a
  local file lease. Keep the lease until actual native disposal. Offline external
  assets must be file URIs; offline playback does not fetch network subtitles.
- Embed: map the declared delivered Format against the output's real tracks.
  Explicit converted output formats may differ from the source Codec. VTT maps
  to WebVTT; SRT/SubRip uses the existing codec normalization.
- Encode: record server application only when the selected server stream and
  resolved playback plan agree. DirectPlay cannot claim an encoded subtitle.
- Unknown/Hls/unsupported delivery: show a retryable failure, without claiming
  server application from the video's Transcode method.

Diagnostic exports retain allowlisted codec/delivery/format enums in separate
fields while continuing to redact credentials, paths, titles, and unknown values.

## Verification and limits

Native tests generate their own Matroska video/audio and three ASS tracks, two
with identical metadata. They exercise local files and local HTTP, repeated
native switching, external SRT, converted Embed, and actual decoded cue text.
The test HTTP server supports both bounded and open-ended byte ranges.

Production uses media_kit_video's Flutter SubtitleView (libass=false). Native
sub-visibility=no is expected for that configuration. The rendering tests consume
the real media_kit subtitle stream in the same SubtitleView, assert the expected
text and painted glyph pixels, exercise A -> B -> A and disabling, and optionally
save screenshots using SUBTITLE_RENDER_EVIDENCE. They omit the platform video
texture, so they are host subtitle-layer checks, not phone display acceptance.

Widget tests cover selection success/failure, repeated callbacks, stale/dismissed
sheets, continuing playback, and returning to the existing download list.

Initial failures are retained in the task evidence directories. Earlier runs
without libmpv reported 16 native failures; a later interrupted related run ended
at +111 with no final result. Installing the pinned media_kit Windows libmpv exposed
an incorrect native-visibility test assertion and an HTTP fixture that did not
honor open-ended ranges. Both were corrected on evidence, not retried unchanged.

No user Emby credentials or private videos were accessed. Physical Android/iOS
devices, user media, bitmap subtitle rendering, and real-server delivery remain
unverified. CI/release success does not establish that the user's movie is fixed.

Final host verification after building the existing strm_input.c into a local DLL:
1698 tests passed, 3 existing Windows skips; analyze passed; 330 Dart files
formatted with no changes; 27 release-script tests passed. The first resumed
full run (1688 passed, 6 failed, 4 incomplete) remains recorded separately from
the successful run with both native dependencies present.
